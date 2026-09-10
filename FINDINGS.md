# Probe findings

Measured on macOS 26, VS Code with 8 open windows, Claude Code extension
2.1.263/2.1.266. A throwaway extension was installed in every window, dumped
what it could see, and was removed.

## Q1 — Window ↔ chat mapping: exact

Every `claude` process is a direct child of the extension-host process of the
window that owns it. The probe confirmed `ppid === process.pid` from inside
each window, with no exceptions across 8 windows and 8 chat processes.

This holds even for the case the cwd/title heuristic cannot resolve: two
windows both named `docs-site` (one under `Projects/`, one under
`Documents/`) were separated correctly.

Extension-host `cwd` is always `/`, so it identifies nothing on its own — the
extension must publish `workspace.workspaceFolders` itself.

## Q2 — Tab ↔ session: exact, via VS Code's own state

**Corrected after the probe.** The conclusion below — that no direct link
exists — was drawn from the *extension API*, and is true of it: `tab.input`
exposes only `viewType: "mainThreadWebview-claudeVSCodePanel"`, identical for
every chat tab.

But VS Code persists each webview's state, and Claude Code puts the session id
in it. In the window's own `state.vscdb`, under
`memento/workbench.parts.editor`:

    "state": "{\"isFullEditor\":false,\"sessionID\":\"6abbd4f6-…\"}"

That is the authoritative tab → session link and is what the app uses. The log
directory identifies its workspace through the storage hash in its sibling
`exthost.log`, the same hash resolved from a folder — so a window's state and
log are both found exactly rather than guessed at.

Title matching, described below, remains the **fallback** for a tab the memento
has not caught up with (one opened seconds ago), and for a window with no
folder, where there is no hash to match on.

### Fallback: matching by title

Each session file carries repeated `ai-title` records of the form

    {"type":"ai-title","aiTitle":"Tag index backfill","sessionId":"8246a3f9-…"}

whose latest value matches the tab label exactly. Verified against all three
tabs of one window:

| Tab label (truncated by VS Code) | `aiTitle` | Session |
|---|---|---|
| `Rewrite the retry helpe…` | Rewrite the retry helper | `bdaf18eb` |
| `Tag index backfill`             | Tag index backfill                | `8246a3f9` |
| `Cache the docs build fo…` | Cache the docs build for CI | `c02d5f51` |

Labels are truncated at ~24 characters, so the join is a prefix match. Two
sessions sharing a 24-character prefix would collide — that is detectable
(more than one candidate) and must render as Unknown rather than a guess.

## Q3 — No extension API

`vscode.extensions.getExtension("Anthropic.claude-code").exports` is null.
Every contributed command is UI-level (`editor.open`, `focus`,
`reopenClosedSession`, …); none accepts a session id. There is no supported
way to ask the extension which session a tab holds.

## Consequence: tabs outnumber processes

Chat *tabs* and chat *processes* are not the same set. Observed counts:

| Window | Chat tabs | Live processes |
|---|---|---|
| media-tagger | 2 | 1 |
| blog-engine | 2 | 1 |
| docs-site | 2 | 1 |
| api-gateway | 3 | 2 |
| search-index | 1 | 1 |

An open tab with no process is a real, common state — the chat exists in the
UI but nothing is running. It must be shown as `Idle`, and must never be
reported as `Finished`, because no completion was ever observed.

## Status sources, ranked

1. Hook events — the only authoritative source of Running/Question/Permission/Finished.
2. Process liveness — demotes a stale "running" to `Ended`.
3. Transcript interrupt markers — `[Request interrupted by user]` and
   `[Request interrupted by user for tool use]`, present in 57 transcripts
   (136 occurrences). `Stop` does not fire on interrupt, so without this
   reconciler those sessions pin at Running forever.
