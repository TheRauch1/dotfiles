/**
 * Cockpit bridge: tells Neovim what pi is doing.
 *
 * When pi runs in Neovim's agent drawer (Alt+a), Neovim sets COCKPIT_STATE
 * to a file path. This extension writes a small JSON file there:
 *
 *   { "state": "working" | "waiting" | "idle", "files": ["src/a.py", ...],
 *     "session": "/path/to/the/session.jsonl" }
 *
 * "waiting" = pi finished a prompt and it's your turn. "files" = every file
 * pi edited or wrote in this run (relative to the project, or absolute).
 * Neovim shows the state in its status line and tab line, and walks the
 * files with ]a / [a, and remembers the session so `dev` reopens exactly
 * this conversation after a restart. Outside Neovim (no COCKPIT_STATE) it does nothing.
 *
 * setup.sh links this to ~/.pi/agent/extensions/cockpit.ts.
 */
import * as fs from "node:fs";

export default function (pi: any) {
	const target = process.env.COCKPIT_STATE;
	if (!target) return;

	let state = "idle";
	let session: string | undefined;
	const files: string[] = [];
	const track = (ctx: any) => {
		try { session = ctx?.sessionManager?.getSessionFile?.() ?? session; } catch {}
	};

	const write = () => {
		const tmp = `${target}.${process.pid}.tmp`;
		try {
			fs.writeFileSync(tmp, JSON.stringify({ state, files, session, pid: process.pid, ts: Date.now() }));
			fs.renameSync(tmp, target);
		} catch {
			// Neovim's state dir is gone: nothing to tell.
		}
	};

	pi.on("session_start", async (_e: any, ctx: any) => { state = "idle"; track(ctx); write(); });
	pi.on("agent_start", async (_e: any, ctx: any) => { state = "working"; track(ctx); write(); });
	pi.on("agent_end", async (_e: any, ctx: any) => { state = "waiting"; track(ctx); write(); });
	pi.on("input", async () => {
		if (state === "waiting") { state = "idle"; write(); }
	});
	pi.on("tool_execution_start", async (event: any) => {
		const name = event?.toolName;
		if (name !== "edit" && name !== "write") return;
		const path = event?.args?.path ?? event?.args?.file_path;
		if (typeof path === "string" && !files.includes(path)) {
			files.push(path);
			write();
		}
	});
	pi.on("session_shutdown", async () => {
		state = "idle";
		write();
	});
}
