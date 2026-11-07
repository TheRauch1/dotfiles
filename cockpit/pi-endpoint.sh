#!/usr/bin/env bash
# Point pi at an OpenAI-compatible endpoint (vLLM, llama.cpp, Ollama, ...):
#
#   pi-endpoint.sh <name> <base-url> [model-id]
#   pi-endpoint.sh spark http://spark.r4uch.xyz:8000/v1
#
# Adds/replaces provider <name> in ~/.pi/agent/models.json with the models
# the endpoint lists under /models (or just [model-id]), and makes the first
# one pi's default. API key: $PI_ENDPOINT_KEY (default "none").
set -euo pipefail
name=${1:?usage: pi-endpoint.sh <name> <base-url> [model-id]}
url=${2:?usage: pi-endpoint.sh <name> <base-url> [model-id]}
url=${url%/}
model=${3:-}
dir="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
mkdir -p "$dir"

ids=$model
if [[ -z $ids ]]; then
  if ! json=$(curl -fsS -m 10 -H "Authorization: Bearer ${PI_ENDPOINT_KEY:-none}" "$url/models"); then
    echo "Could not reach $url/models. Pass the model id as the 3rd argument." >&2
    exit 1
  fi
  ids=$(node -e 'const d=JSON.parse(process.argv[1]);console.log((d.data||d.models||[]).map(m=>m.id||m.name).filter(Boolean).join("\n"))' "$json")
  [[ -n $ids ]] || { echo "$url/models lists no models. Pass one as the 3rd argument." >&2; exit 1; }
fi

NAME=$name URL=$url IDS=$ids KEY=${PI_ENDPOINT_KEY:-none} DIR=$dir node <<'JS'
const fs = require("fs");
const { NAME, URL, IDS, KEY, DIR } = process.env;
const read = (f) => { try { return JSON.parse(fs.readFileSync(f, "utf8")); } catch { return {}; } };
const models = read(`${DIR}/models.json`);
models.providers ??= {};
const ids = IDS.split("\n").filter(Boolean);
models.providers[NAME] = {
  baseUrl: URL,
  api: "openai-completions",
  apiKey: KEY,
  compat: { supportsDeveloperRole: false, supportsReasoningEffort: false },
  models: ids.map((id) => ({ id })),
};
fs.writeFileSync(`${DIR}/models.json`, JSON.stringify(models, null, 2) + "\n");
const settings = read(`${DIR}/settings.json`);
settings.defaultProvider = NAME;
settings.defaultModel = ids[0];
fs.writeFileSync(`${DIR}/settings.json`, JSON.stringify(settings, null, 2) + "\n");
console.log(`pi: provider ${NAME} (${URL}), default model ${ids[0]}` + (ids.length > 1 ? ` (+${ids.length - 1} more in /model)` : ""));
JS
