// durable: a coding agent that survives crashes, Ctrl+C and reboots (pi-durable).
// See `durable -h`. bin/durable runs this with node.
import { spawn } from "node:child_process";
import { closeSync, existsSync, mkdirSync, openSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { parseArgs } from "node:util";
import { openNodeSqliteStorage } from "@earendil-works/pi-durable/storage/sqlite/node";
import { follow, openAgent, prompt, resume } from "./agent.ts";
import { loadPiModels, parseModel } from "./models.ts";

const HELP = `durable [options] [prompt...]   a pi agent that finishes what it started

  durable "fix the failing tests"   work on it here, printing what it does
  durable                           continue an interrupted task (crash, Ctrl+C,
                                    reboot); otherwise show the last answer
  durable -b "long task"            the same in the background (log: durable -f)

  -b, --background   detach; output goes to the log
  -f, --follow       print the log of a background run as it grows
  -l, --log          the conversation so far (works while it runs)
  -m, --model M      provider/model or a model id (default: pi's default model)
      --new          forget this repo's conversation and start over
  -h, --help

One conversation per repo (git root, else this directory), kept in
~/.local/state/pi-durable/. Models come from pi (~/.pi/agent/models.json,
settings.json). Ctrl+C stops it; \`durable\` picks the task up again.`;

const { values: opts, positionals } = parseArgs({
  allowPositionals: true,
  options: {
    background: { type: "boolean", short: "b" },
    follow: { type: "boolean", short: "f" },
    log: { type: "boolean", short: "l" },
    model: { type: "string", short: "m" },
    new: { type: "boolean" },
    help: { type: "boolean", short: "h" },
  },
});
if (opts.help) {
  console.log(HELP);
  process.exit(0);
}

const cwd = process.env.DURABLE_CWD ?? process.cwd();
const stateDir = process.env.DURABLE_STATE ?? join(process.env.XDG_STATE_HOME ?? join(homedir(), ".local", "state"), "pi-durable");
mkdirSync(stateDir, { recursive: true });
const slug = cwd.replace(/^\/+/, "").replace(/[/\\:]/g, "%") || "root";
const db = join(stateDir, `${slug}.sqlite`);
const logFile = join(stateDir, `${slug}.log`);
const pidFile = join(stateDir, `${slug}.pid`);
const text = positionals.join(" ").trim();

function runningPid(): number | undefined {
  try {
    const pid = Number(readFileSync(pidFile, "utf8"));
    if (pid && pid !== process.pid) {
      process.kill(pid, 0);
      return pid;
    }
  } catch {}
  return undefined;
}

if (opts.follow) {
  if (!existsSync(logFile)) {
    console.error("durable: no background log for this repo");
    process.exit(1);
  }
  // tail -f until the background run exits.
  const tail = spawn("tail", ["-n", "+1", "-F", logFile], { stdio: "inherit" });
  const check = setInterval(() => runningPid() === undefined && (clearInterval(check), setTimeout(() => tail.kill(), 300)), 1000);
  tail.on("exit", () => process.exit(0));
} else if (opts.background) {
  const busy = runningPid();
  if (busy) {
    console.error(`durable: already working here (pid ${busy}); durable -f to watch, kill ${busy} to stop`);
    process.exit(1);
  }
  const args = [...process.execArgv, ...process.argv.slice(1).filter((a) => a !== "-b" && a !== "--background")];
  const fd = openSync(logFile, "w");
  const child = spawn(process.execPath, args, { detached: true, stdio: ["ignore", fd, fd], env: { ...process.env, DURABLE_CWD: cwd } });
  child.unref();
  closeSync(fd);
  console.log(`durable: working in the background (pid ${child.pid}); durable -f to watch`);
} else {
  await main();
}

async function main() {
  if (opts.log) {
    if (!existsSync(db)) return console.log("durable: no conversation in this repo yet");
    const { models } = loadPiModels();
    const agent = await openAgent({ storage: await openNodeSqliteStorage(db), models, cwd, readOnly: true });
    const stop = await follow(agent, (l) => console.log(l), undefined, 1000);
    await stop();
    await agent.close();
    return;
  }

  const busy = runningPid();
  if (busy) {
    console.error(`durable: already working here (pid ${busy}); durable -f to watch, kill ${busy} to stop`);
    process.exit(1);
  }
  writeFileSync(pidFile, String(process.pid));
  process.on("exit", () => {
    if (runningPid() === undefined) rmSync(pidFile, { force: true });
  });

  if (opts.new) for (const f of [db, `${db}-wal`, `${db}-shm`]) rmSync(f, { force: true });

  const { models, defaults } = loadPiModels();
  const model = opts.model ? parseModel(opts.model, models) : defaults;
  const stateFile = process.env.COCKPIT_STATE;
  const agent = await openAgent({ storage: await openNodeSqliteStorage(db), models, cwd, model, stateFile });

  let stopping = false;
  const stop = async (signal: string) => {
    if (stopping) process.exit(130); // second Ctrl+C: don't wait
    stopping = true;
    console.error(`\ndurable: stopped (${signal}); run \`durable\` to continue`);
    await agent.close(); // a close is not a crash: the task stays pending
    process.exit(130);
  };
  process.on("SIGINT", () => void stop("Ctrl+C"));
  process.on("SIGTERM", () => void stop("SIGTERM"));
  process.on("SIGHUP", () => void stop("SIGHUP"));

  const unwatch = await follow(agent, (l) => console.log(l), stateFile);
  let outcome = await resume(agent);
  if (outcome.status !== "idle" && text) console.log("durable: finished the interrupted task; now yours");
  if (text) outcome = await prompt(agent, text);
  else if (outcome.status === "idle") {
    // Nothing was left to do: show the last answer.
    await unwatch();
    const last = await follow(agent, (l) => console.log(l), undefined, 1);
    await last();
  }
  await unwatch();
  await agent.close();
  if (outcome.status === "unanswered") {
    console.error(`durable: stopped without an answer (${outcome.reason}); \`durable\` tries again`);
    process.exitCode = 1;
  }
}
