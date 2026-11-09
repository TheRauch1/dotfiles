/**
 * Command gate: bash rules for pi, written like omp's `bash.patterns`.
 *
 * - oc and kubectl: read-only subcommands run; anything else asks first.
 * - git: read-only and local commands (add, commit, stash, ...) run;
 *   anything that rewrites history, drops work or touches the remote asks.
 * - Everything else runs.
 *
 * Rules work like omp's: ordered `*`-glob patterns, the first match wins.
 * Pi checks every simple command of a compound line (`a && b | c`, `$(...)`,
 * `bash -c '...'`) on its own; the strictest result applies. With no UI
 * (print/json/rpc mode) a command that would ask is blocked instead.
 *
 * Pi runs nested calls (codemode scripts, ctx.executeTool) through the same
 * tool_call handlers, so this covers them too. It is a guard rail, not a
 * sandbox: a determined command (variables, scripts on disk) gets past it.
 *
 * Overlays (~/.config/dotfiles.d/<name>/, see README "Overlays") can add
 * rules in `pi/command-gate.json`: {"rules": [{"match": "kubectl*",
 * "approval": "deny"}]}. They are checked before the rules here, overlays
 * sorted by name. An overlay file that cannot be read blocks every command,
 * so a broken policy never loosens anything.
 */
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export type Approval = "allow" | "prompt" | "deny";
export type Rule = { match: string; approval: Approval };

const allow = (match: string): Rule => ({ match, approval: "allow" });
const prompt = (match: string): Rule => ({ match, approval: "prompt" });
const deny = (match: string): Rule => ({ match, approval: "deny" });
// `git <sub>` and `git -C dir <sub>` (or any other global flag) alike.
const gitPrompt = (sub: string): Rule[] => [prompt(`*git ${sub}*`), prompt(`*git -* ${sub}*`)];

export const RULES: Rule[] = [
  // git: read-only
  ...[
    "status", "log", "show", "diff", "ls-files", "ls-tree", "ls-remote", "describe",
    "blame", "shortlog", "rev-parse", "rev-list", "merge-base",
  ].map((sub) => allow(`git ${sub}*`)),
  // git: local, recoverable
  allow("git add*"),
  ...gitPrompt("commit --amend"),
  allow("git commit*"),
  ...gitPrompt("stash pop"),
  ...gitPrompt("stash drop"),
  ...gitPrompt("stash clear"),
  allow("git stash*"),
  allow("git worktree list*"),
  allow("git worktree add*"),
  allow("git submodule status*"),
  allow("git submodule init*"),
  allow("git submodule update*"),
  allow("git notes list*"),
  allow("git notes show*"),

  // oc: read-only subcommands run, every other oc command asks
  ...[
    "version", "whoami", "get", "describe", "explain", "api-resources", "api-versions",
    "project", "status", "logs",
  ].map((sub) => allow(`oc ${sub}*`)),
  prompt("oc *"),
  prompt("* oc *"),
  prompt("*/oc *"),

  // kubectl: like oc
  ...[
    "version", "get", "describe", "explain", "api-resources", "api-versions", "logs", "top",
    "cluster-info", "config current-context", "config get-contexts",
  ].map((sub) => allow(`kubectl ${sub}*`)),
  prompt("kubectl*"),
  prompt("* kubectl*"),
  prompt("*/kubectl*"),

  // git: remote, history rewriting, losing work
  ...[
    "push", "reset", "rebase", "checkout", "restore", "clean", "rm",
    "branch -D", "branch --delete --force", "tag -d", "tag --delete",
    "remote rm", "remote remove", "filter-branch", "filter-repo",
    "reflog expire", "reflog delete", "gc --prune",
  ].flatMap(gitPrompt),

  allow("*"),
];

const normalize = (s: string) => s.trim().replace(/\s+/g, " ");

const globCache = new Map<string, RegExp>();
function glob(pattern: string): RegExp {
  let re = globCache.get(pattern);
  if (!re) {
    const body = normalize(pattern)
      .split("*")
      .map((part) => part.replace(/[\\^$+?.()|[\]{}]/g, "\\$&"))
      .join(".*");
    re = new RegExp(`^${body}$`);
    globCache.set(pattern, re);
  }
  return re;
}

/** First rule that matches one simple command; allow when none does. */
export function ruleFor(simple: string, rules: Rule[] = RULES): Rule {
  const text = normalize(simple);
  return rules.find((r) => glob(r.match).test(text)) ?? allow("*");
}

/**
 * Split a shell line into simple commands, as word lists with quotes removed.
 * Splits on ; & | newlines ( ) and backticks, and pulls `$(...)` out of
 * double quotes too, since bash runs those. Redirections (`> file`,
 * `2>&1`) are dropped. Arguments of `bash -c`, `sh -c` and `eval` are split
 * again as commands of their own.
 */
export function simpleCommands(line: string, depth = 0): string[][] {
  const out: string[][] = [];
  let words: string[] = [];
  let word = "";
  let inWord = false;
  let quote: "'" | '"' | null = null;
  let skipNextWord = false; // the target of a redirection

  const endWord = () => {
    if (inWord) {
      if (skipNextWord) skipNextWord = false;
      else words.push(word);
    }
    word = "";
    inWord = false;
  };
  const endCommand = () => {
    endWord();
    if (words.length) out.push(words);
    words = [];
  };

  for (let i = 0; i < line.length; i++) {
    const c = line[i];
    if (quote === "'") {
      if (c === "'") quote = null;
      else word += c;
      continue;
    }
    if (quote === '"') {
      if (c === '"') quote = null;
      else if (c === "\\" && i + 1 < line.length) word += line[++i];
      else if (c === "`" || (c === "$" && line[i + 1] === "(")) {
        // Command substitution inside double quotes: a command of its own.
        const close = c === "`" ? "`" : ")";
        const start = c === "`" ? i + 1 : i + 2;
        const end = line.indexOf(close, start);
        const inner = line.slice(start, end === -1 ? undefined : end);
        out.push(...simpleCommands(inner, depth + 1));
        i = end === -1 ? line.length : end;
      } else word += c;
      continue;
    }
    if (c === "'" || c === '"') {
      quote = c;
      inWord = true;
    } else if (c === "\\" && i + 1 < line.length) {
      const next = line[++i];
      if (next !== "\n") {
        word += next;
        inWord = true;
      }
    } else if (c === " " || c === "\t") {
      endWord();
    } else if (";&|()`\n\r".includes(c) || (c === "$" && line[i + 1] === "(")) {
      endCommand();
    } else if (c === "<" || c === ">") {
      // Redirection: drop the operator (with any fd number) and its target.
      if (inWord && /^\d*$/.test(word)) {
        word = "";
        inWord = false;
      } else endWord();
      while (line[i + 1] === ">" || line[i + 1] === "<" || line[i + 1] === "|") i++;
      if (line[i + 1] === "&") {
        i++;
        while (/[\d-]/.test(line[i + 1] ?? "")) i++; // >&2, 2>&-
      } else skipNextWord = true;
    } else {
      word += c;
      inWord = true;
    }
  }
  endCommand();

  if (depth > 4) return out;
  const nested: string[][] = [];
  for (const cmd of out) {
    const prog = cmd[0]?.split("/").pop();
    if (prog && ["bash", "sh", "zsh", "dash"].includes(prog)) {
      const c = cmd.findIndex((w, j) => j > 0 && /^-[a-z]*c[a-z]*$/.test(w));
      if (c !== -1 && cmd[c + 1] !== undefined) nested.push(...simpleCommands(cmd[c + 1], depth + 1));
    } else if (prog === "eval" && cmd.length > 1) {
      nested.push(...simpleCommands(cmd.slice(1).join(" "), depth + 1));
    }
  }
  return [...out, ...nested];
}

const rank: Record<Approval, number> = { allow: 0, prompt: 1, deny: 2 };

/** The strictest rule over every simple command in `line`. */
export function decide(line: string, rules: Rule[] = RULES): { approval: Approval; command: string; rule: Rule } {
  let worst = { approval: "allow" as Approval, command: line, rule: allow("*") };
  for (const words of simpleCommands(line)) {
    const command = words.join(" ");
    const rule = ruleFor(command, rules);
    if (rank[rule.approval] > rank[worst.approval]) worst = { approval: rule.approval, command, rule };
  }
  return worst;
}

const APPROVALS: Approval[] = ["allow", "prompt", "deny"];

/** Rules from every `<overlay>/pi/command-gate.json`, overlays sorted by name. Throws on a bad file. */
export function overlayRules(dir = process.env.DOTFILES_D || join(homedir(), ".config", "dotfiles.d")): Rule[] {
  if (!existsSync(dir)) return [];
  const rules: Rule[] = [];
  for (const name of readdirSync(dir).sort()) {
    const file = join(dir, name, "pi", "command-gate.json");
    if (!existsSync(file)) continue;
    let parsed: unknown;
    try {
      parsed = JSON.parse(readFileSync(file, "utf8"));
    } catch (err) {
      throw new Error(`${file}: ${(err as Error).message}`);
    }
    const list = (parsed as { rules?: unknown })?.rules;
    if (!Array.isArray(list)) throw new Error(`${file}: expected {"rules": [...]}`);
    for (const r of list) {
      if (typeof r?.match !== "string" || !normalize(r.match) || !APPROVALS.includes(r.approval)) {
        throw new Error(`${file}: bad rule ${JSON.stringify(r)} (needs match and approval allow|prompt|deny)`);
      }
      rules.push({ match: r.match, approval: r.approval });
    }
  }
  return rules;
}

export default function (pi: ExtensionAPI) {
  let rules = RULES;
  let broken: string | undefined;
  try {
    rules = [...overlayRules(), ...RULES];
  } catch (err) {
    broken = (err as Error).message;
  }

  pi.on("session_start", async (_event, ctx) => {
    if (broken) ctx.ui.notify(`Command gate: every bash command is blocked. ${broken}`, "error");
  });

  pi.on("tool_call", async (event, ctx) => {
    if (event.toolName !== "bash") return undefined;
    const line = (event.input as { command?: unknown }).command;
    if (typeof line !== "string" || !line.trim()) return undefined;
    if (broken) return { block: true, reason: `Command gate overlay is broken, fix it and /reload: ${broken}` };

    const { approval, command, rule } = decide(line, rules);
    if (approval === "allow") return undefined;
    if (approval === "deny") {
      return { block: true, reason: `Blocked by command gate (${rule.match}): ${command}` };
    }
    if (!ctx.hasUI) {
      return { block: true, reason: `Needs approval, and there is no UI to ask (${rule.match}): ${command}` };
    }
    const ok = await ctx.ui.confirm(
      "Run this command?",
      [line, "", `Asks because of: ${command}`, `Rule: ${rule.match}`].join("\n"),
    );
    if (!ok) return { block: true, reason: `Not approved by the user: ${command}` };
    return undefined;
  });
}
