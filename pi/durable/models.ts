// pi's own model setup for pi-durable: the providers in ~/.pi/agent/models.json
// (what cockpit/pi-endpoint.sh writes) on top of pi-ai's built-in ones (keys
// from the environment), and pi's default model from settings.json.
import { execSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { openAICompletionsApi } from "@earendil-works/pi-ai/api/openai-completions.lazy";
import { openAIResponsesApi } from "@earendil-works/pi-ai/api/openai-responses.lazy";
import { anthropicMessagesApi } from "@earendil-works/pi-ai/api/anthropic-messages.lazy";
import { createProvider, type MutableModels } from "@earendil-works/pi-ai/models";
import { builtinModels } from "@earendil-works/pi-ai/providers/all";

export const PI_DIR = process.env.PI_CODING_AGENT_DIR ?? join(homedir(), ".pi", "agent");

const APIS: Record<string, () => unknown> = {
  "openai-completions": openAICompletionsApi,
  "openai-responses": openAIResponsesApi,
  "anthropic-messages": anthropicMessagesApi,
};

function readJson(path: string): any {
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch {
    return undefined;
  }
}

// models.json apiKey, as pi reads it: "!cmd" runs a command, a set env var's
// name means its value, anything else is the key itself.
export function resolveKey(value: unknown): string | undefined {
  if (typeof value !== "string" || value === "") return undefined;
  if (value.startsWith("!")) return execSync(value.slice(1), { encoding: "utf8" }).trim();
  return process.env[value] ?? value;
}

/** Providers from a models.json object, ready for `models.setProvider()`. */
export function customProviders(config: any) {
  const out = [];
  for (const [id, p] of Object.entries<any>(config?.providers ?? {})) {
    const models = (p.models ?? []).map((m: any) => ({
      id: m.id,
      name: m.name ?? m.id,
      api: m.api ?? p.api ?? "openai-completions",
      provider: id,
      baseUrl: m.baseUrl ?? p.baseUrl,
      reasoning: m.reasoning ?? false,
      input: m.input ?? ["text"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, ...m.cost },
      contextWindow: m.contextWindow ?? 128000,
      maxTokens: m.maxTokens ?? 16384,
      ...(m.thinkingLevelMap ? { thinkingLevelMap: m.thinkingLevelMap } : {}),
      ...(m.compat ?? p.compat ? { compat: { ...p.compat, ...m.compat } } : {}),
      ...(m.headers ?? p.headers ? { headers: { ...p.headers, ...m.headers } } : {}),
    }));
    const apis = Object.fromEntries(
      [...new Set(models.map((m: any) => m.api))].filter((a) => a in APIS).map((a) => [a, APIS[a]()]),
    );
    if (Object.keys(apis).length === 0) continue;
    out.push(
      createProvider({
        id,
        name: p.name ?? id,
        baseUrl: p.baseUrl,
        auth: {
          apiKey: {
            name: `${id} key (models.json)`,
            // Keyless local servers still count as configured.
            resolve: async () => ({ auth: { apiKey: resolveKey(p.apiKey) ?? "none" }, source: "models.json" }),
          },
        },
        models,
        api: apis as any,
      }),
    );
  }
  return out;
}

export type ModelChoice = { provider: string; modelId: string; thinkingLevel?: string };

/** "provider/model" or "model" (looked up among the known models). */
export function parseModel(spec: string, models: MutableModels): ModelChoice {
  const slash = spec.indexOf("/");
  if (slash > 0 && models.getProvider(spec.slice(0, slash))) {
    return { provider: spec.slice(0, slash), modelId: spec.slice(slash + 1) };
  }
  const hit = models.getModels().find((m) => m.id === spec);
  if (!hit) throw new Error(`unknown model: ${spec} (use provider/model)`);
  return { provider: hit.provider, modelId: hit.id };
}

/** pi-ai Models with pi's providers, and pi's default model choice. */
export function loadPiModels(dir = PI_DIR): { models: MutableModels; defaults?: ModelChoice } {
  const models = builtinModels();
  for (const provider of customProviders(readJson(join(dir, "models.json")))) models.setProvider(provider);
  const s = readJson(join(dir, "settings.json")) ?? {};
  const defaults =
    s.defaultProvider && s.defaultModel
      ? { provider: s.defaultProvider, modelId: s.defaultModel, thinkingLevel: s.defaultThinkingLevel }
      : undefined;
  return { models, defaults };
}
