// durable: npm test (in pi/durable)
// Uses pi-ai's scripted faux model, so no network and no API key.
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";
import { createModels } from "@earendil-works/pi-ai/models";
import { fauxAssistantMessage, fauxProvider, fauxToolCall } from "@earendil-works/pi-ai/providers/faux";
import { LiveDoc } from "@earendil-works/pi-durable";
import { openNodeSqliteStorage } from "@earendil-works/pi-durable/storage/sqlite/node";
import { context, describe, follow, openAgent, prompt, resume } from "../agent.ts";
import { customProviders, resolveKey } from "../models.ts";

const tmp = mkdtempSync(join(tmpdir(), "durable-test-"));
after(() => rmSync(tmp, { recursive: true, force: true }));
const MODEL = { provider: "faux", modelId: "faux-1" };

function fauxModels(responses: any[]) {
  const faux = fauxProvider();
  const models = createModels();
  models.setProvider(faux.provider);
  faux.setResponses(responses);
  return models;
}

const bash = (command: string, id: string) =>
  fauxAssistantMessage([fauxToolCall("bash", { command }, { id })], { stopReason: "toolUse" });

test("a prompt runs tools in the repo and answers", async () => {
  const cwd = mkdtempSync(join(tmp, "repo-"));
  writeFileSync(join(cwd, "AGENTS.md"), "Use tabs.");
  const models = fauxModels([bash("echo hi > out.txt", "c1"), fauxAssistantMessage("Wrote out.txt.")]);
  const agent = await openAgent({ storage: await openNodeSqliteStorage(join(cwd, "s.sqlite")), models, cwd, model: MODEL });
  const lines: string[] = [];
  const stop = await follow(agent, (l) => lines.push(l));
  assert.deepEqual(await prompt(agent, "write hi"), { status: "done" });
  await stop();
  await agent.close();
  assert.deepEqual(lines, ["› write hi", "▸ bash echo hi > out.txt", "Wrote out.txt."]);
});

test("killed mid-tool, the next process finishes the task", async () => {
  const cwd = mkdtempSync(join(tmp, "repo-"));
  const db = join(cwd, "s.sqlite");

  // First process: the model starts a slow command, then the process goes away.
  let agent = await openAgent({ storage: await openNodeSqliteStorage(db), models: fauxModels([bash("sleep 30", "c1")]), cwd, model: MODEL });
  const pending = prompt(agent, "do the long thing").catch(() => undefined);
  for (let i = 0; i < 100; i++) {
    const live: any = await agent.harness.snapshot(LiveDoc, agent.root.id, context);
    if (live?.tools?.some((t: any) => t.taskId)) break;
    await new Promise((r) => setTimeout(r, 50));
  }
  await agent.close();
  await pending;

  // Second process: same file, picks the run up; the model hears bash was cut off.
  let sawInterrupt = false;
  const models = fauxModels([
    (ctx: any) => {
      const last = ctx.messages.at(-1);
      sawInterrupt = last?.role === "toolResult" && last.isError;
      return fauxAssistantMessage("Picked it up again.");
    },
  ]);
  agent = await openAgent({ storage: await openNodeSqliteStorage(db), models, cwd, model: MODEL });
  const lines: string[] = [];
  const stop = await follow(agent, (l) => lines.push(l));
  assert.deepEqual(await resume(agent), { status: "done" });
  await stop();
  await agent.close();
  assert.ok(sawInterrupt, "model got the interrupted bash result");
  assert.equal(lines.at(-1), "Picked it up again.");

  // Third process: nothing left to do.
  agent = await openAgent({ storage: await openNodeSqliteStorage(db), models: fauxModels([]), cwd, model: MODEL });
  assert.deepEqual(await resume(agent), { status: "idle" });
  await agent.close();
});

test("models.json providers become pi-ai providers", () => {
  process.env.DURABLE_TEST_KEY = "secret";
  assert.equal(resolveKey("DURABLE_TEST_KEY"), "secret");
  assert.equal(resolveKey("literal-key"), "literal-key");
  assert.equal(resolveKey("!echo fromcmd"), "fromcmd");
  const [p] = customProviders({
    providers: {
      spark: {
        baseUrl: "http://spark:8000/v1",
        api: "openai-completions",
        apiKey: "none",
        compat: { supportsDeveloperRole: false },
        models: [{ id: "q", reasoning: true, contextWindow: 65536 }],
      },
    },
  });
  const [m]: any[] = p.getModels();
  assert.equal(p.id, "spark");
  assert.equal(m.provider, "spark");
  assert.equal(m.baseUrl, "http://spark:8000/v1");
  assert.equal(m.contextWindow, 65536);
  assert.deepEqual(m.compat, { supportsDeveloperRole: false });
});

test("describe shows tool errors in one line", () => {
  const entry = { kind: "pi.tool-result", model: [{ role: "toolResult", isError: true, content: [{ type: "text", text: "out\nexit code 2" }] }] };
  assert.deepEqual(describe(entry), ["  ✗ exit code 2"]);
  const cut = {
    kind: "pi.tool-result",
    model: [{ role: "toolResult", isError: true, content: [{ type: "text", text: "<harness>\n[error] Tool bash was interrupted and may have partially run\n</harness>" }] }],
  };
  assert.deepEqual(describe(cut), ["  ✗ Tool bash was interrupted and may have partially run"]);
});
