// ClaudeDeck bridge — one instance per VS Code window.
//
// Publishes what only a per-window extension host knows:
//   * its own pid, which is the parent of every `claude` process in this
//     window (verified — see FINDINGS.md Q1). This is the exact window<->chat
//     join that a cwd/title heuristic cannot provide.
//   * the window's workspace folders (the host's own cwd is always "/").
//   * the Claude chat tabs open in this window, with the group and index
//     needed to activate one.
//
// Also watches for a focus request and activates the named tab.

const vscode = require("vscode");
const fs = require("fs");
const os = require("os");
const path = require("path");

const DIR = path.join(os.homedir(), ".claude", "claudedeck");
const WINDOWS_DIR = path.join(DIR, "windows");
const REQUEST_FILE = path.join(DIR, "focus-request.json");

const CHAT_VIEW_TYPE = "mainThreadWebview-claudeVSCodePanel";

let outFile = null;
let storageDir = null;

/** Claude chat tabs, with the coordinates needed to activate one. */
function chatTabs() {
  const groups = (vscode.window.tabGroups && vscode.window.tabGroups.all) || [];
  const out = [];
  for (const g of groups) {
    g.tabs.forEach((t, index) => {
      const vt = t.input && t.input.viewType;
      if (vt !== CHAT_VIEW_TYPE) return;
      out.push({
        label: t.label,
        isActive: t.isActive,
        viewColumn: g.viewColumn,
        index,
      });
    });
  }
  return out;
}

function publish() {
  try {
    fs.mkdirSync(WINDOWS_DIR, { recursive: true });
    const payload = {
      ts: Date.now(),
      extHostPid: process.pid,
      workspaceName: vscode.workspace.name || null,
      workspaceFolders: (vscode.workspace.workspaceFolders || []).map((f) => f.uri.fsPath),
      focused: !!(vscode.window.state && vscode.window.state.focused),
      storageDir,
      tabs: chatTabs(),
    };
    fs.writeFileSync(outFile, JSON.stringify(payload));
  } catch {}
}

/** Activate a tab by group + index. Focus the group first: openEditorAtIndex
 *  acts on whichever group is active, so without this it can hit the wrong one. */
async function focusTab(req) {
  if (req.extHostPid !== process.pid) return;
  try {
    const col = req.viewColumn;
    if (typeof col === "number") {
      const byColumn = {
        1: "workbench.action.focusFirstEditorGroup",
        2: "workbench.action.focusSecondEditorGroup",
        3: "workbench.action.focusThirdEditorGroup",
        4: "workbench.action.focusFourthEditorGroup",
      }[col];
      if (byColumn) await vscode.commands.executeCommand(byColumn);
    }
    if (typeof req.index === "number") {
      await vscode.commands.executeCommand("workbench.action.openEditorAtIndex", req.index);
    }
    await vscode.commands.executeCommand("claude-vscode.focus").then(undefined, () => {});
  } catch {}
}

function watchRequests(context) {
  let last = 0;
  const check = () => {
    try {
      const st = fs.statSync(REQUEST_FILE);
      if (st.mtimeMs <= last) return;
      last = st.mtimeMs;
      const req = JSON.parse(fs.readFileSync(REQUEST_FILE, "utf-8"));
      // Ignore anything stale enough to be from a previous run.
      if (Date.now() - (req.ts || 0) > 10000) return;
      focusTab(req);
    } catch {}
  };
  const timer = setInterval(check, 300);
  context.subscriptions.push({ dispose: () => clearInterval(timer) });
}

function activate(context) {
  outFile = path.join(WINDOWS_DIR, `${process.pid}.json`);
  // VS Code stores each Claude tab's sessionID in this window's own
  // state.vscdb (memento/workbench.parts.editor). That is the only exact
  // tab -> session link there is; the extension API exposes none. Publish the
  // directory so ClaudeDeck can read it without guessing which hash is ours.
  try {
    if (context.storageUri) storageDir = path.dirname(context.storageUri.fsPath);
  } catch {}
  publish();

  const republish = () => publish();
  if (vscode.window.tabGroups) {
    context.subscriptions.push(vscode.window.tabGroups.onDidChangeTabs(republish));
    context.subscriptions.push(vscode.window.tabGroups.onDidChangeTabGroups(republish));
  }
  context.subscriptions.push(vscode.window.onDidChangeWindowState(republish));
  context.subscriptions.push(vscode.workspace.onDidChangeWorkspaceFolders(republish));
  context.subscriptions.push(vscode.commands.registerCommand("claudedeck.publish", republish));

  // Heartbeat: the GUI treats a window file as live only while it is fresh,
  // so a hard-killed host disappears instead of lingering as a phantom window.
  const beat = setInterval(republish, 4000);
  context.subscriptions.push({ dispose: () => clearInterval(beat) });

  watchRequests(context);

  context.subscriptions.push({
    dispose: () => { try { fs.unlinkSync(outFile); } catch {} },
  });
}

function deactivate() {
  try { fs.unlinkSync(outFile); } catch {}
}

module.exports = { activate, deactivate };
