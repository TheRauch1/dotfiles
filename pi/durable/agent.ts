// A coding agent on pi-durable: one conversation per repo in a SQLite file.
// Every model turn and tool call is committed before it shows, so a crash,
// Ctrl+C or reboot mid-task loses nothing: reopening the file continues the
// run where it stopped (a cut-off model request is retried; a cut-off bash or
// edit tells the model it was interrupted, so nothing runs twice).
import { existsSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import type { MutableModels } from "@earendil-works/pi-ai/models";
import {
  AssistantEntry,
  type Conversation,
  createRegistry,
  defineExtension,
  Harness,
  LiveDoc,
  section,
  type Storage,
} from "@earendil-works/pi-durable";
import { NodeExecutionEnv } from "@earendil-works/pi-durable/env/node";
import { CodingTools } from "@earendil-works/pi-durable/tools";
import type { ModelChoice } from "./models.ts";

export const context = BACKGROUND_CONTEXT;

const PREAMBLE = `You are a coding agent working in a repository on the user's machine.
Use the tools to read, change and run things in it. Keep going until the task is
done, then say briefly what you changed and what you checked. The user may not
watch while you work, so make sensible choices instead of stopping to ask.`;

// AGENTS.md / CLAUDE.md of the repo, like pi reads them.
function projectNotes(cwd: string | undefined): string | undefined {
  for (const name of ["AGENTS.md", "CLAUDE.md"]) {
    const path = join(cwd ?? ".", name);
    if (existsSync(path)) return readFileSync(path, "utf8");
  }
  return undefined;
}

const Coding = defineExtension({
  name: "dotfiles-coding",
  sections: [
    section("preamble", () => PREAMBLE, { tag: false }),
    section("cwd", (input) => input.env?.cwd),
    section("project_notes", (input) => projectNotes(input.env?.cwd)),
  ],
});

export type Out = (line: string) => void;

export interface OpenOptions {
  storage: Storage;
  models: MutableModels;
  cwd: string;
  model?: ModelChoice;
  readOnly?: boolean;
  /** $COCKPIT_STATE: the ide tab shows ◐ while this works. */
  stateFile?: string;
}

export interface Agent {
  harness: Harness;
  root: Conversation;
  close(): Promise<void>;
}

export async function openAgent(o: OpenOptions): Promise<Agent> {
  const registry = createRegistry();
  registry.install(CodingTools);
  registry.install(Coding);
  const harness = await Harness.open(
    o.storage,
    {
      models: o.models,
      registry,
      readOnly: o.readOnly,
      env: ({ cwd }) => new NodeExecutionEnv({ cwd: cwd ?? o.cwd }),
      settings: { retry: { maxRetries: 3 }, afterFailedRun: "continue" },
      onReport: (r: any) => {
        if (r.kind !== "task_interrupted") console.error(`durable: ${r.kind}: ${r.error?.message ?? r.reason ?? ""}`);
      },
    } as any,
    context,
  );
  const root = await harness.root(context, o.readOnly ? undefined : { agent: { cwd: o.cwd } });
  if (!o.readOnly && o.model) {
    const agent: any = await root.agent(context);
    const want = { provider: o.model.provider, modelId: o.model.modelId };
    if (agent.model?.provider !== want.provider || agent.model?.modelId !== want.modelId) {
      await root.configure(
        { model: want, ...(o.model.thinkingLevel ? { thinkingLevel: o.model.thinkingLevel as any } : {}) },
        context,
      );
    }
  }
  return { harness, root, close: () => harness.close(context) };
}

// One line per tool call, the answer's text, errors in short.
function argSummary(name: string, args: any): string {
  if (!args || typeof args !== "object") return "";
  if (name === "bash") return String(args.command ?? "").split("\n")[0];
  return String(args.path ?? args.file_path ?? JSON.stringify(args)).slice(0, 120);
}

export function describe(entry: any): string[] {
  const msg = entry.model?.[0];
  if (!msg) return [];
  if (entry.kind === "pi.user") {
    const text = typeof msg.content === "string" ? msg.content : msg.content?.map((c: any) => c.text ?? "").join("");
    return [`› ${text}`];
  }
  if (AssistantEntry.is(entry)) {
    const lines: string[] = [];
    for (const c of msg.content ?? []) {
      if (c.type === "text" && c.text.trim()) lines.push(c.text.trim());
      if (c.type === "toolCall") lines.push(`▸ ${c.name} ${argSummary(c.name, c.arguments)}`);
    }
    if (msg.stopReason === "error" || msg.stopReason === "aborted") lines.push(`  (${msg.stopReason}${msg.errorMessage ? `: ${msg.errorMessage}` : ""})`);
    return lines;
  }
  if (entry.kind === "pi.tool-result" && msg.isError) {
    // The harness's own note ("[error] Tool bash was interrupted ...") if any, else the output's last line.
    const text = (msg.content ?? []).map((c: any) => c.text ?? "").join("\n");
    const note = text.match(/<harness>\s*(?:\[error\]\s*)?([^\n]+)/)?.[1];
    const lines = text.trim().split("\n").filter((l: string) => l.trim());
    return [`  ✗ ${note ?? lines[lines.length - 1] ?? "error"}`.slice(0, 200)];
  }
  return [];
}

function writeState(file: string | undefined, state: string, files: string[]) {
  if (!file) return;
  try {
    let data: any = { files: [] };
    try {
      data = JSON.parse(readFileSync(file, "utf8"));
    } catch {}
    const merged = [...new Set([...(data.files ?? []), ...files])];
    writeFileSync(`${file}.${process.pid}.tmp`, JSON.stringify({ ...data, state, files: merged, ts: Date.now() }));
    renameSync(`${file}.${process.pid}.tmp`, file);
  } catch {}
}

/** Print entries as they are committed; returns a stop function. */
export async function follow(agent: Agent, out: Out, stateFile?: string, showExisting = 0) {
  const seen = new Set<string>();
  const files: string[] = [];
  const show = (entries: readonly any[]) => {
    for (const e of entries) {
      if (seen.has(e.id)) continue;
      seen.add(e.id);
      for (const line of describe(e)) out(line);
      for (const c of e.model?.[0]?.content ?? []) {
        if (c.type === "toolCall" && (c.name === "edit" || c.name === "write") && c.arguments?.path) files.push(c.arguments.path);
      }
    }
  };
  const watch = await agent.root.watch(context);
  const first = (watch.value as any).entries ?? [];
  for (const e of first.slice(0, Math.max(0, first.length - showExisting))) seen.add(e.id);
  show(first);
  watch.start(async (call: any) => {
    if (call.kind !== "value") return;
    show(call.value.entries ?? []);
    writeState(stateFile, call.value.docs?.["pi.live"]?.run ? "working" : "waiting", files);
  });
  return () => watch.stop();
}

export type Outcome = { status: "done" | "unanswered" | "idle"; reason?: string };

/** Send a prompt (queued behind a running task, if any) and wait for its answer. */
export async function prompt(agent: Agent, text: string): Promise<Outcome> {
  const submission = await agent.root.submit({ type: "input", content: text }, context);
  const settled: any = await submission.wait(context);
  return settled.status === "done" ? { status: "done" } : { status: "unanswered", reason: settled.reason };
}

/** Continue whatever the last process left unfinished; "idle" when nothing was. */
export async function resume(agent: Agent): Promise<Outcome> {
  const live: any = await agent.harness.snapshot(LiveDoc, agent.root.id, context);
  if (live?.run) {
    agent.harness.resume();
    await agent.root.waitForIdle(context);
    const after: any = await agent.harness.snapshot(LiveDoc, agent.root.id, context);
    return after?.runFailure ? { status: "unanswered", reason: after.runFailure.reason } : { status: "done" };
  }
  if (live?.runFailure && live.runFailure.reason !== "aborted") {
    const settled: any = await (await agent.root.submit({ type: "continue" }, context)).wait(context);
    return settled.status === "done" ? { status: "done" } : { status: "unanswered", reason: settled.reason };
  }
  return { status: "idle" };
}
