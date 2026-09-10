# ClaudeDeck

Read [README.md](README.md) first — it covers what this is, the statuses, and
how the pieces fit. [FINDINGS.md](FINDINGS.md) records what was measured on a
real machine rather than assumed.

## The one rule

**No false positives, no false negatives.** A status is shown only when it was
established from evidence; anything that cannot be established says `Unknown`
with its reason. Silence is always preferable to a confident wrong answer.

Every bug this project has had was a violation of that rule, and every one
looked plausible at the time:

- a finish that predated first sight announced as **New**
- a resolved tool call still reported as **Running**, because only the last
  *assistant* record was consulted
- an orphaned backgrounded command keeping a finished chat **Running**
- an interrupt marker parsed as a new user prompt, so **Interrupted** was
  overwritten by **Running**
- file mtime used as the activity clock, when transcripts keep being appended by
  background bookkeeping long after the last turn — a chat idle 16 hours read as
  30 minutes, which also silently suppressed the stall guard
- `PermissionRequest` also fires for `AskUserQuestion`, so a question was
  reported as **Needs Permission**

## Before and after any change

```bash
./check.sh
```

17 checks: 9 derivation fixtures, 8 hook rules. The derivation cases call the
same `parseTranscript` the app uses, so a rule cannot pass there and fail in the
app.

**Add a fixture for every bug found.** That is the point of the harness — it
exists because fixes here were verified once by hand and then silently broken by
later changes. `tests/fixtures/*.jsonl` plus a line in `tests/cases.json`.

Not covered yet, and where bugs have already appeared: notification dedup, the
memento lookup, the cwd fallback, rate-limit detection, and the whole GUI.

## Follow Claude Notify

`~/Projects/ClaudeNotify` is the sibling project and the reference for anything
notification-shaped — wording, sounds, and especially the guards that decide
whether to fire at all. Several bugs here came from porting its *mechanism* and
leaving behind the logic wrapped around it. When touching hook behaviour, read
its hook first and port the whole thing.

## Things that are easy to get wrong

- **Transcript file mtime is not an activity time.** Use the last message
  record's `timestamp`. mtime is only for cache invalidation.
- **`stop_reason` on the last assistant record is not the whole story.** A
  `tool_use` whose result has since arrived is not in flight.
- **Hook-derived statuses need bounding too.** They used to never decay, so a
  parked or blocked session claimed Running forever.
- **A rate limit never reaches the transcript.** It is in the extension's
  per-window log, and VS Code writes a fresh log directory per launch — take the
  newest match, not the first.
- **A window with no folder** has no `workspaceFolders`, so anything keyed off
  them comes up empty. Fall back to the chat processes' own `cwd`.
- **VS Code truncates tab labels** at ~24 characters, and a tab keeps whichever
  title was current when it was last labelled — often the session's first, not
  its newest.
