#!/usr/bin/env node
// Runs the shipped hook against crafted events and checks what it records.
//
// These are the routing rules, not the transcript logic: which events the hook
// must ignore, and which must overwrite what. Every case is a bug that shipped.
//
//   node tests/validate-hook.js

const { execFileSync } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

const HOOK = path.join(__dirname, "..", "hooks", "claudedeck-hook.js");
const DIR = path.join(os.homedir(), ".claude", "claudedeck", "sessions");
const SID = "validate-fixture-session";
const FILE = path.join(DIR, `${SID}.json`);

function run(event, input) {
  execFileSync("node", [HOOK, event], {
    input: JSON.stringify({ session_id: SID, ...input }),
    encoding: "utf-8",
  });
}
function state() {
  try { return JSON.parse(fs.readFileSync(FILE, "utf-8")); } catch { return null; }
}
function reset(seed) {
  fs.mkdirSync(DIR, { recursive: true });
  if (seed) fs.writeFileSync(FILE, JSON.stringify({ sessionId: SID, ...seed }));
  else { try { fs.unlinkSync(FILE); } catch {} }
}

let failures = 0;
function check(name, fn) {
  try {
    fn();
    console.log(`PASS ${name}`);
  } catch (e) {
    console.log(`FAIL ${name}: ${e.message}`);
    failures += 1;
  }
}
function eq(actual, want, what) {
  if (actual !== want) throw new Error(`${what}: got ${actual}, want ${want}`);
}

// PermissionRequest also fires for AskUserQuestion; it must not overwrite the
// question the PreToolUse hook just recorded.
check("permission ignores AskUserQuestion", () => {
  reset({ status: "question", statusTs: Date.now(), ts: Date.now() });
  run("permission", { tool_name: "AskUserQuestion" });
  eq(state().status, "question", "status");
});

check("question ignores other tools", () => {
  reset({ status: "running", statusTs: Date.now(), ts: Date.now() });
  run("question", { tool_name: "Bash" });
  eq(state().status, "running", "status");
});

check("subagent permission ignored", () => {
  reset({ status: "running", statusTs: Date.now(), ts: Date.now() });
  run("permission", { tool_name: "Bash", agent_id: "sub-1" });
  eq(state().status, "running", "status");
});

check("subagent tool does not clear a question", () => {
  reset({ status: "question", statusTs: Date.now(), ts: Date.now() });
  run("resolved", { tool_name: "Bash", agent_id: "sub-1" });
  eq(state().status, "question", "status");
});

// PostToolUse is the withdraw trigger: answering a question resolves it.
check("resolved clears a question", () => {
  reset({ status: "question", statusTs: Date.now(), ts: Date.now() });
  run("resolved", { tool_name: "AskUserQuestion" });
  eq(state().status, "running", "status");
});

check("resolved leaves a finished chat alone", () => {
  const ts = Date.now() - 5000;
  reset({ status: "finished", statusTs: ts, ts });
  run("resolved", { tool_name: "Bash" });
  eq(state().status, "finished", "status");
  eq(state().statusTs, ts, "statusTs untouched");
});

// Stop fires re-entrantly from inside a stop hook's own continuation.
check("re-entrant stop ignored", () => {
  reset({ status: "running", statusTs: Date.now(), ts: Date.now() });
  run("stop", { stop_hook_active: true, transcript_path: "/nonexistent" });
  eq(state().status, "running", "status");
});

check("permission records the tool and command", () => {
  reset(null);
  run("permission", { tool_name: "Bash", tool_input: { command: "rm -rf /tmp/x" } });
  const d = state();
  eq(d.status, "permission", "status");
  if (!d.detail.startsWith("Bash: ")) throw new Error(`detail: ${d.detail}`);
});

try { fs.unlinkSync(FILE); } catch {}
console.log(`\n${8 - failures}/8 passed`);
process.exit(failures ? 1 : 0);
