// Run: node tests/pi/test_command_gate.ts   (Node 23.6+ runs TypeScript directly)
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { decide, overlayRules, RULES, type Approval } from "../../pi/extensions/command-gate.ts";

const cases: [string, Approval][] = [
  // kubectl (gated like oc here; overlays can deny it, see below)
  ["kubectl get pods", "allow"],
  ["kubectl logs -f deploy/x | grep err", "allow"],
  ["kubectl config current-context", "allow"],
  ["kubectl delete ns x", "prompt"],
  ["KUBECONFIG=x kubectl get pods", "prompt"],
  ["/usr/local/bin/kubectl delete ns x", "prompt"],
  ["cd /tmp && kubectl apply -f x.yaml", "prompt"],
  ["bash -c 'kubectl scale deploy/x --replicas=0'", "prompt"],
  ["echo $(kubectl exec x -- cat /etc/passwd)", "prompt"],
  ["git status; kubectl edit cm x", "prompt"],

  // oc
  ["oc get pods", "allow"],
  ["oc get pods -o yaml | grep image", "allow"],
  ["oc describe deploy/x", "allow"],
  ["oc logs -f pod/x --tail=50", "allow"],
  ["oc whoami", "allow"],
  ["oc project my-ns", "allow"],
  ["oc delete pod x", "prompt"],
  ["oc apply -f x.yaml", "prompt"],
  ["oc rsh pod/x", "prompt"],
  ["oc -n foo get pods", "prompt"],
  ["oc get pods && oc delete pod x", "prompt"],
  ["sudo oc adm drain node1", "prompt"],
  ["sh -c \"oc scale --replicas=0 deploy/x\"", "prompt"],
  ["ocrmypdf in.pdf out.pdf", "allow"],

  // git: allowed
  ["git status", "allow"],
  ["git log --oneline -20", "allow"],
  ["git diff HEAD~1 > /tmp/d.patch", "allow"],
  ["git add -A && git commit -m 'reset the thing'", "allow"],
  ["git commit -m \"push it\"", "allow"],
  ["git stash", "allow"],
  ["git stash list", "allow"],
  ["git worktree add ../wt feature", "allow"],
  ["git log 2>&1 | head", "allow"],
  ["git fetch origin", "allow"],

  // git: asks
  ["git push", "prompt"],
  ["git push --force origin main", "prompt"],
  ["git -C repo push", "prompt"],
  ["git commit --amend --no-edit", "prompt"],
  ["git reset --hard HEAD~1", "prompt"],
  ["git rebase -i main", "prompt"],
  ["git checkout -- file", "prompt"],
  ["git restore .", "prompt"],
  ["git clean -fdx", "prompt"],
  ["git rm file", "prompt"],
  ["git stash pop", "prompt"],
  ["git stash drop", "prompt"],
  ["git branch -D feature", "prompt"],
  ["git tag -d v1", "prompt"],
  ["git status && git push", "prompt"],
  ["git commit -m \"$(git push)\"", "prompt"],
  ["eval 'git reset --hard'", "prompt"],

  // other
  ["ls -la", "allow"],
  ["npm test", "allow"],
];

let failed = 0;
let total = 0;
function check(name: string, ok: boolean, detail = "") {
  total++;
  if (!ok) {
    failed++;
    console.log(`FAIL  ${name}${detail ? `\n      ${detail}` : ""}`);
  }
}
function run(list: [string, Approval][], rules = RULES) {
  for (const [cmd, want] of list) {
    const got = decide(cmd, rules);
    check(cmd, got.approval === want, `want ${want}, got ${got.approval} (${got.rule.match} on "${got.command}")`);
  }
}
run(cases);

// Overlays: rules from <dir>/<name>/pi/command-gate.json come first.
const dir = mkdtempSync(join(tmpdir(), "command-gate-"));
check("no overlays", overlayRules(join(dir, "missing")).length === 0);
mkdirSync(join(dir, "work", "pi"), { recursive: true });
writeFileSync(
  join(dir, "work", "pi", "command-gate.json"),
  JSON.stringify({ rules: [{ match: "kubectl*", approval: "deny" }, { match: "* kubectl*", approval: "deny" }] }),
);
const withOverlay = [...overlayRules(dir), ...RULES];
run(
  [
    ["kubectl get pods", "deny"],
    ["cd x && kubectl delete ns y", "deny"],
    ["oc get pods", "allow"],
    ["oc delete pod x", "prompt"],
    ["git push", "prompt"],
  ],
  withOverlay,
);
mkdirSync(join(dir, "broken", "pi"), { recursive: true });
writeFileSync(join(dir, "broken", "pi", "command-gate.json"), '{"rules": [{"match": "x", "approval": "maybe"}]}');
let threw = false;
try {
  overlayRules(dir);
} catch {
  threw = true;
}
check("bad overlay rule throws", threw);

console.log(`${total - failed}/${total} passed`);
process.exit(failed ? 1 : 0);
