#!/usr/bin/env node
// ClaudeDeck status hook. One script, event named by argv[2].
//
//   node claudedeck-hook.js running|question|permission|stop|touch
//
// Writes ~/.claude/claudedeck/sessions/<sessionId>.json. The GUI treats this
// file as the *only* authority for "what is this chat doing", and refuses to
// show any status the file did not record.
//
// `stop` is not the same as finished: Claude Code fires Stop whenever the
// assistant yields its turn, including while parked on a backgrounded task.
// The pending-work scanner (taken from ClaudeNotify, where it was built and
// proven) is what separates the two.

const fs = require("fs");
const os = require("os");
const path = require("path");
const { execFileSync } = require("child_process");
const { createScanner } = require("./lib/pending-work");
const { readRecords } = require("./lib/transcript");

const DIR = path.join(os.homedir(), ".claude", "claudedeck", "sessions");

/** The `claude` process that owns this hook.
 *
 *  Hooks are not always a direct child — a shell may sit in between — so walk
 *  the ancestry rather than trusting process.ppid. This pid is what lets the
 *  GUI tie a session to a window (via the process's own parent, the extension
 *  host) and to notice when a session dies without ever reporting a status. */
function ownerClaudePid() {
  try {
    const ps = execFileSync("/bin/ps", ["-eo", "pid,ppid,command"], {
      encoding: "utf-8",
      timeout: 4000,
    });
    const info = new Map();
    for (const line of ps.split("\n")) {
      const m = line.trim().match(/^(\d+)\s+(\d+)\s+(.*)$/);
      if (m) info.set(Number(m[1]), { ppid: Number(m[2]), cmd: m[3] });
    }
    let pid = process.pid;
    for (let hop = 0; hop < 12; hop++) {
      const node = info.get(pid);
      if (!node) return null;
      if (/native-binary\/claude/.test(node.cmd)) return pid;
      pid = node.ppid;
      if (pid <= 1) return null;
    }
  } catch {}
  return null;
}

function isAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (e) {
    return e && e.code === "EPERM";
  }
}

const COMMAND_MAX = 80;

function truncate(text, max) {
  const flat = String(text);
  if (flat.length <= max) return flat;
  const cut = flat.slice(0, max);
  const space = cut.lastIndexOf(" ");
  return (space > max / 2 ? cut.slice(0, space) : cut) + "…";
}

/** The banner body, worded exactly as Claude Notify's hooks word it, so the
 *  two apps' notifications read identically when both are running. */
function detailFor(event, input) {
  if (event === "question") return "Claude is asking you a question.";
  if (event === "stop") return "Claude has finished the task.";
  if (event !== "permission") return null;
  const tool = input.tool_name || "a tool";
  const suggested =
    Array.isArray(input.permission_suggestions) &&
    input.permission_suggestions
      .flatMap((s) => (s && Array.isArray(s.rules) ? s.rules : []))
      .map((r) => r && r.ruleContent)
      .find(Boolean);
  const raw = suggested || (input.tool_input && input.tool_input.command) || "";
  if (!raw) return `Claude needs permission to use ${tool}.`;
  return `${tool}: ${truncate(String(raw).replace(/\s+/g, " ").trim(), COMMAND_MAX)}`;
}

function statusFor(event, input) {
  if (event !== "stop") {
    return { running: "running", question: "question", permission: "permission", touch: null }[event] || null;
  }
  // Stop: finished only if nothing is still outstanding.
  let records;
  try {
    records = readRecords(input.transcript_path);
  } catch {
    records = null;
  }
  // Fail closed: an unreadable transcript cannot prove the turn is finished,
  // and a wrong "finished" is exactly the failure this tool exists to avoid.
  if (!records || !records.length) return "unknown";
  try {
    const scanner = createScanner();
    for (const rec of records) scanner.push(rec);
    // The turn ended, but work this stage backgrounded has not reported back.
    // That is not the assistant running — reporting it as such is what made a
    // finished chat sit at "Running" indefinitely.
    if (scanner.outstanding().length > 0) return "background";
  } catch {
    return "unknown";
  }
  return "finished";
}

function main(raw) {
  const event = process.argv[2] || "touch";
  let input = {};
  try {
    input = JSON.parse(raw);
  } catch {}
  const sessionId = input.session_id;
  if (!sessionId) return;

  // Stop fires again from inside a stop hook's own continuation. Claude
  // Notify skips those; treating one as a fresh turn end records a completion
  // that never happened.
  if (event === "stop" && input.stop_hook_active) return;

  // PermissionRequest fires for AskUserQuestion as well, so without this the
  // permission event lands after the question event and overwrites it — the
  // chat reports "Needs Permission" for what is actually a question.
  if (event === "permission" && input.tool_name === "AskUserQuestion") return;
  if (event === "question" && input.tool_name !== "AskUserQuestion") return;
  // A subagent's question or permission request is not the main chat waiting
  // on you, and reporting it as such sends you to the wrong place.
  if ((event === "permission" || event === "question") && input.agent_id) return;
  // A subagent's tool finishing resolves nothing the user is waiting on, and
  // must not clear a question the top-level chat still has open — they share a
  // session id.
  if (event === "resolved" && input.agent_id) return;

  const file = path.join(DIR, `${sessionId}.json`);
  let prev = {};
  try {
    prev = JSON.parse(fs.readFileSync(file, "utf-8"));
  } catch {}

  // PostToolUse is Claude Notify's withdraw trigger: a tool finishing means an
  // AskUserQuestion was just answered, or a permission just granted — however
  // it was actually resolved. Without this the chat keeps reporting Question or
  // Needs Permission until the turn ends, long after you dealt with it.
  //
  // PostToolUse fires after every single tool call, so anything with nothing to
  // clear returns before writing.
  if (event === "resolved") {
    if (prev.status !== "question" && prev.status !== "permission") return;
    const cleared = { ...prev, status: "running", statusTs: Date.now(), ts: Date.now(),
                      event, detail: null };
    try {
      fs.mkdirSync(DIR, { recursive: true });
      fs.writeFileSync(file, JSON.stringify(cleared));
    } catch {}
    return;
  }

  const status = statusFor(event, input);
  const record = {
    sessionId,
    // `touch` refreshes liveness without asserting a new status.
    status: status || prev.status || "unknown",
    statusTs: status ? Date.now() : prev.statusTs || Date.now(),
    ts: Date.now(),
    event,
    // Re-walking the process table on every event is wasteful; the pid only
    // needs rediscovering when we have none or the old one has gone.
    claudePid: (prev.claudePid && isAlive(prev.claudePid) ? prev.claudePid : ownerClaudePid()) || null,
    cwd: input.cwd || prev.cwd || null,
    detail: detailFor(event, input) || prev.detail || null,
    transcriptPath: input.transcript_path || prev.transcriptPath || null,
  };
  try {
    fs.mkdirSync(DIR, { recursive: true });
    fs.writeFileSync(file, JSON.stringify(record));
  } catch {}
}

let raw = "";
process.stdin.setEncoding("utf-8");
process.stdin.on("data", (c) => (raw += c));
process.stdin.on("end", () => {
  try { main(raw); } catch {}
  process.exit(0);
});
