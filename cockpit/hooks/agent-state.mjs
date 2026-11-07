#!/usr/bin/env node
// Reports a coding agent's state to $COCKPIT_STATE (the same JSON file the
// pi extension writes), for the ide tab bar and the Neovim cockpit:
//   { "state": "working" | "waiting" | "blocked" | "idle", "files": [...] }
//
// Claude Code (~/.claude/settings.json "hooks", see cockpit/hooks/claude-settings.json):
//   UserPromptSubmit -> agent-state.mjs working
//   Stop             -> agent-state.mjs waiting
//   Notification     -> agent-state.mjs blocked   (asks for permission / input)
//   PostToolUse      -> agent-state.mjs file      (Edit/Write: remembers the file)
// Codex (~/.codex/config.toml):  notify = ["node", "<this file>", "waiting"]
//
// Without $COCKPIT_STATE (agent not started by ide / the cockpit) it does nothing.
import fs from "node:fs";

const target = process.env.COCKPIT_STATE;
if (!target) process.exit(0);
const what = process.argv[2];

let input = "";
try { if (!process.stdin.isTTY) input = fs.readFileSync(0, "utf8"); } catch {}
let event = {};
try { event = JSON.parse(input || process.argv[3] || "{}"); } catch {}

let data = { state: "idle", files: [] };
try { data = { ...data, ...JSON.parse(fs.readFileSync(target, "utf8")) }; } catch {}

if (what === "file") {
  const p = event?.tool_input?.file_path ?? event?.tool_input?.path;
  if (typeof p === "string" && !data.files.includes(p)) data.files.push(p);
} else if (["working", "waiting", "blocked", "idle"].includes(what)) {
  data.state = what;
}
if (event.session_id && event.transcript_path) data.session = event.transcript_path;

const tmp = `${target}.${process.pid}.tmp`;
fs.writeFileSync(tmp, JSON.stringify({ ...data, ts: Date.now() }));
fs.renameSync(tmp, target);
