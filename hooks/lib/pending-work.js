// Decides whether a Stop event means "the work is finished" or only "the
// assistant's turn ended while background work is still running".
//
// Claude Code fires Stop whenever the assistant yields the turn. When the main
// agent has nothing left to do but wait on a backgrounded task, that is a
// genuine turn end — so Stop fires, minutes before the work is actually done.
// The session is then re-invoked by a <task-notification> and carries on.
//
// The transcript records both halves of that:
//   launch     — a tool_result announcing the task was backgrounded
//   completion — a <task-notification> carrying the launching tool-use-id
//
// Anything launched and not yet notified is outstanding. The ledger is scoped
// to the current stage (cleared at each real user prompt), because a task
// abandoned in an earlier stage would otherwise leak and silence every later
// notification.

// Async subagents (Agent/Task) and backgrounded Bash commands both re-invoke
// the session, and both must be tracked — subagents alone miss roughly a third
// of real cases.
//
// Anchored to the start of the result on purpose. Both announcements *open* the
// tool result; the marker is never buried mid-way through a real one. An
// unanchored search matches any output that merely quotes these phrases — this
// file read back by cat/Read/grep, a transcript, the README — and that lands a
// launch in the ledger whose completion can never arrive, silencing every
// later Stop in the stage.
const LAUNCH_ANNOUNCEMENTS = [
  // Agent/Task — the marker opens the first text block.
  /^Async agent launched successfully/,
  // Bash — "Command running in background with ID: …", or the timeout form,
  // "Command did not complete within its 30s timeout and was moved to the
  // background (ID: …)". Short fixed lead-in, then the marker.
  /^Command\b.{0,80}?(?:running in background with ID:|moved to the background \(ID:)/s,
];
const TASK_NOTIFICATION = "<task-notification>";
const TOOL_USE_ID = /<tool-use-id>(toolu_[A-Za-z0-9]+)<\/tool-use-id>/;

/**
 * Any content shape as a searchable string.
 *
 * A tool_result's `content` is usually an array of blocks, so String() on it
 * yields "[object Object]" and silently matches nothing — stringify instead.
 */
function asText(value) {
  if (value == null) return "";
  if (typeof value === "string") return value;
  try {
    return JSON.stringify(value);
  } catch {
    return "";
  }
}

/** Content blocks as a searchable string, whatever shape the record uses. */
function contentText(rec) {
  return asText(rec && rec.message && rec.message.content);
}

/**
 * The human-readable text of a tool_result, with the block wrapper stripped.
 *
 * `content` is either a plain string or an array of blocks. Stringifying the
 * array would leave `[{"type": "text", "text": "` sitting in front of the real
 * text, which defeats an anchored match — pull the text out instead.
 */
function resultText(content) {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .map((b) => (typeof b === "string" ? b : b && b.type === "text" ? b.text || "" : ""))
    .join("\n");
}

/** True when a tool_result *is* a backgrounding announcement, rather than some
 *  longer output that happens to quote one. */
function isLaunchAnnouncement(content) {
  const text = resultText(content).trimStart();
  return LAUNCH_ANNOUNCEMENTS.some((re) => re.test(text));
}

/**
 * True for a message the human actually typed.
 *
 * Tool results and injected blocks (<system-reminder>, <ide_selection>,
 * <task-notification>) are all recorded as type "user" and would otherwise
 * reset the stage constantly.
 */
function isRealUserPrompt(rec) {
  if (!rec || rec.type !== "user") return false;
  const c = rec.message && rec.message.content;
  if (typeof c === "string") {
    const t = c.trim();
    return t.length > 0 && !t.startsWith("<");
  }
  if (!Array.isArray(c)) return false;
  if (c.some((b) => b && b.type === "tool_result")) return false;
  return c.some((b) => {
    if (!b || b.type !== "text" || typeof b.text !== "string") return false;
    const t = b.text.trim();
    return t.length > 0 && !t.startsWith("<");
  });
}

/**
 * Stateful single-pass reducer over transcript records.
 *
 * Kept incremental rather than "scan the whole file each time" so the
 * validator can ask for the ledger as it stood at any given Stop without
 * re-scanning the prefix.
 */
function createScanner() {
  const pending = new Map(); // tool_use_id -> record index it launched at
  let stageMarker = null; // uuid of the most recent real user prompt
  let index = -1;

  return {
    push(rec) {
      index += 1;

      // Stage boundary: a new prompt retires everything before it.
      if (isRealUserPrompt(rec)) {
        pending.clear();
        stageMarker = rec.uuid || `idx:${index}`;
      }

      const c = rec && rec.message && rec.message.content;
      if (Array.isArray(c)) {
        for (const b of c) {
          if (b && b.type === "tool_result" && isLaunchAnnouncement(b.content)) {
            pending.set(b.tool_use_id, index);
          }
        }
      }

      const text = contentText(rec);
      if (text.includes(TASK_NOTIFICATION)) {
        const m = TOOL_USE_ID.exec(text);
        if (m) pending.delete(m[1]);
      }
    },
    /** Ids of background work launched this stage with no completion yet. */
    outstanding() {
      return [...pending.keys()];
    },
    /** Identifies the current stage, for once-per-stage notification dedup. */
    stage() {
      return stageMarker;
    },
  };
}

module.exports = { createScanner, isRealUserPrompt, isLaunchAnnouncement };
