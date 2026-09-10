// ClaudeDeck probe — throwaway.
//
// Answers three questions that the real design depends on:
//   Q1  Is this extension host's pid the parent of the window's `claude` procs?
//   Q2  Can we see a session id per chat tab, or only a label?
//   Q3  Does the Claude Code extension expose an API to other extensions?
//
// Writes one report per window to ~/.claude/claudedeck/probe/<extHostPid>.json

const vscode = require("vscode");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { execFileSync } = require("child_process");

const OUT_DIR = path.join(os.homedir(), ".claude", "claudedeck", "probe");

function sh(cmd, args) {
  try {
    return execFileSync(cmd, args, { encoding: "utf-8", timeout: 5000 });
  } catch {
    return "";
  }
}

/** Q1: `claude` processes whose parent is *this* extension host. */
function claudeChildren() {
  const out = sh("/bin/ps", ["-eo", "pid,ppid,command"]);
  const rows = [];
  for (const line of out.split("\n")) {
    if (!line.includes("native-binary/claude")) continue;
    const m = line.trim().match(/^(\d+)\s+(\d+)\s+(.*)$/);
    if (!m) continue;
    const [, pid, ppid, cmd] = m;
    const resume = (cmd.match(/--resume=(\S+)/) || [])[1] || null;
    const cwd = (sh("/usr/sbin/lsof", ["-a", "-p", pid, "-d", "cwd", "-Fn"])
      .split("\n").find((l) => l.startsWith("n")) || "").slice(1) || null;
    rows.push({
      pid: Number(pid),
      ppid: Number(ppid),
      isOurChild: Number(ppid) === process.pid,
      sessionIdFromArgv: resume,
      cwd,
    });
  }
  return rows;
}

/** Q2: everything reachable about each open tab. */
function tabReport() {
  const groups = (vscode.window.tabGroups && vscode.window.tabGroups.all) || [];
  return groups.map((g) => ({
    viewColumn: g.viewColumn,
    isActive: g.isActive,
    tabs: g.tabs.map((t, i) => {
      const input = t.input;
      let inputProps = null;
      try {
        inputProps = input
          ? JSON.parse(JSON.stringify(input, (k, v) => (v instanceof vscode.Uri ? v.toString() : v)))
          : null;
      } catch {
        inputProps = "<unserialisable>";
      }
      return {
        index: i,
        label: t.label,
        isActive: t.isActive,
        isPreview: t.isPreview,
        inputCtor: input && input.constructor ? input.constructor.name : null,
        viewType: input && input.viewType ? input.viewType : null,
        inputProps,
      };
    }),
  }));
}

/** Q3: does anthropic.claude-code hand anything to other extensions? */
function claudeExtensionReport() {
  const found = vscode.extensions.all
    .filter((e) => /claude|anthropic/i.test(e.id))
    .map((e) => {
      let exportKeys = null;
      try {
        exportKeys = e.isActive && e.exports ? Object.keys(e.exports) : null;
      } catch (err) {
        exportKeys = `<threw: ${err && err.message}>`;
      }
      return { id: e.id, isActive: e.isActive, version: e.packageJSON && e.packageJSON.version, exportKeys };
    });
  return found;
}

async function writeReport(reason) {
  const report = {
    ts: new Date().toISOString(),
    reason,
    // Q1
    extHostPid: process.pid,
    extHostPpid: process.ppid,
    claudeProcesses: claudeChildren(),
    // window identity
    workspaceName: vscode.workspace.name || null,
    workspaceFolders: (vscode.workspace.workspaceFolders || []).map((f) => f.uri.fsPath),
    windowFocused: vscode.window.state && vscode.window.state.focused,
    // Q2
    tabGroups: tabReport(),
    // Q3
    claudeExtensions: claudeExtensionReport(),
    claudeCommands: (await vscode.commands.getCommands(true)).filter((c) => /claude/i.test(c)),
  };
  fs.mkdirSync(OUT_DIR, { recursive: true });
  fs.writeFileSync(path.join(OUT_DIR, `${process.pid}.json`), JSON.stringify(report, null, 2));
  return report;
}

function activate(context) {
  writeReport("activate").catch(() => {});
  context.subscriptions.push(
    vscode.commands.registerCommand("claudedeck.probe.dump", async () => {
      const r = await writeReport("manual");
      vscode.window.showInformationMessage(
        `ClaudeDeck probe: extHost ${r.extHostPid}, ${r.claudeProcesses.filter((p) => p.isOurChild).length} owned chat proc(s).`
      );
    })
  );
  if (vscode.window.tabGroups) {
    context.subscriptions.push(
      vscode.window.tabGroups.onDidChangeTabs(() => writeReport("tabs-changed").catch(() => {}))
    );
  }
}

function deactivate() {}
module.exports = { activate, deactivate };
