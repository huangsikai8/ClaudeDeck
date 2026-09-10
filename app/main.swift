import SwiftUI
import AppKit
import UserNotifications
import ApplicationServices
import Darwin

// MARK: - Status

/// Every case here is something that was *observed*. There is deliberately no
/// case meaning "probably finished": a status that cannot be established is
/// `.unknown`, and a chat that was running when its process died is `.ended`,
/// never `.finished`.
enum Status: String, CaseIterable {
    case running, background, question, permission, newResult, finished, interrupted, rateLimited, idle, ended, unknown

    var label: String {
        switch self {
        case .running: return "Running"
        case .background: return "Background"
        case .question: return "Question"
        case .permission: return "Permission"
        case .newResult: return "New"
        case .finished: return "Finished"
        case .interrupted: return "Interrupted"
        case .rateLimited: return "Rate limited"
        case .idle: return "Idle"
        case .ended: return "Ended"
        case .unknown: return "Unknown"
        }
    }

    var color: Color {
        switch self {
        case .running: return .blue
        case .background: return .teal
        case .question: return .orange
        case .permission: return .purple
        case .newResult: return .green
        case .finished: return .secondary
        case .interrupted: return .secondary
        case .rateLimited: return .yellow
        case .idle: return .secondary
        case .ended: return .pink
        case .unknown: return .secondary
        }
    }

    /// Shown under the row so the status is never a bare assertion.
    var basis: String {
        switch self {
        case .running: return "hook reported a turn in progress"
        case .background: return "turn ended; a backgrounded task has not reported back"
        case .question: return "hook reported a question awaiting an answer"
        case .permission: return "hook reported a permission request"
        case .newResult: return "finished since you last looked"
        case .finished: return "finished, and you have seen it"
        case .interrupted: return "transcript shows an interrupt after the last event"
        case .rateLimited: return "the account rate limit was hit; Claude is not running"
        case .idle: return "tab open, no process running"
        case .ended: return "process gone before any completion was reported"
        case .unknown: return "no status could be established"
        }
    }

    /// Same wording as Claude Notify's hooks, so the two apps' banners read
    /// alike when both are running.
    var bannerLabel: String? {
        switch self {
        case .newResult: return "✅ Finished"
        case .question: return "❓ Question"
        case .permission: return "❗ Needs Permission"
        default: return nil
        }
    }

    /// The system sound Claude Notify plays for this event. It plays them with
    /// afplay rather than as a notification sound, so we do the same — a
    /// UNNotificationSound would be a different sound at a different moment.
    var bannerSound: String? {
        switch self {
        case .newResult: return "Hero"
        case .question: return "Funk"
        case .permission: return "Glass"
        default: return nil
        }
    }

    var needsAttention: Bool { self == .question || self == .permission || self == .newResult }
}

// MARK: - Settings

/// A visual treatment for a status row. Some act on the leading dot, some on
/// the pill; `still` does neither. Any status can use any of them.
enum PillStyle: String, CaseIterable, Identifiable {
    // dot treatments
    case still, breathing, ping, blink, bounce, spinner
    // pill treatments
    case shimmer, glow, outline, ellipsis

    var id: String { rawValue }

    var actsOnDot: Bool {
        switch self {
        case .breathing, .ping, .blink, .bounce, .spinner: return true
        default: return false
        }
    }

    var actsOnPill: Bool {
        switch self {
        case .shimmer, .glow, .outline, .ellipsis: return true
        default: return false
        }
    }

    var label: String {
        switch self {
        case .still: return "None"
        case .breathing: return "Breathing dot"
        case .ping: return "Radar ping"
        case .blink: return "Blink"
        case .bounce: return "Bounce"
        case .spinner: return "Spinner"
        case .shimmer: return "Shimmer sweep"
        case .glow: return "Glow"
        case .outline: return "Outline pulse"
        case .ellipsis: return "Ellipsis"
        }
    }

    var blurb: String {
        switch self {
        case .still: return "Static, like plain text."
        case .breathing: return "Dot pulses softly. Calm in a long list."
        case .ping: return "Ring expands from the dot and fades."
        case .blink: return "Dot blinks hard on and off. Loud."
        case .bounce: return "Dot bobs up and down."
        case .spinner: return "Dot becomes a rotating arc."
        case .shimmer: return "Highlight sweeps across the pill."
        case .glow: return "Pill glows in and out."
        case .outline: return "A ring around the pill pulses."
        case .ellipsis: return "Trailing dots cycle in the label."
        }
    }
}

/// Per-status visual treatment, remembered between runs.
final class Settings: ObservableObject {
    static let shared = Settings()

    /// Only Running moves by default. Everything else is opt-in, so the list
    /// stays quiet until you ask it not to be.
    static let defaults: [Status: PillStyle] = [.running: .breathing]

    @Published private(set) var styles: [Status: PillStyle] = [:]

    /// On: ClaudeDeck is expected to stand alone. If Claude Notify's hooks are
    /// re-enabled alongside it, turn this off — both play the same three files
    /// for the same events and you get the chime twice.
    @Published var playSound: Bool = true {
        didSet { save() }
    }

    private init() {
        let raw = Store.read("config.json")
        var loaded: [Status: PillStyle] = Settings.defaults
        if let map = raw["styles"] as? [String: String] {
            for (k, v) in map {
                if let st = Status(rawValue: k), let sty = PillStyle(rawValue: v) { loaded[st] = sty }
            }
        } else if let legacy = raw["runningStyle"] as? String {
            // Carried over from when only Running could be styled.
            if let sty = PillStyle(rawValue: legacy == "still" ? "still" : legacy) { loaded[.running] = sty }
        }
        styles = loaded
        playSound = (raw["playSound"] as? Bool) ?? true
    }

    func style(for status: Status) -> PillStyle { styles[status] ?? .still }

    func set(_ style: PillStyle, for status: Status) {
        styles[status] = style
        save()
    }

    func resetToDefaults() {
        styles = Settings.defaults
        save()
    }

    private func save() {
        var map: [String: String] = [:]
        for (k, v) in styles { map[k.rawValue] = v.rawValue }
        Store.write("config.json", ["styles": map, "playSound": playSound])
    }
}

// MARK: - Models

struct Chat: Identifiable {
    let id: String
    let title: String
    let status: Status
    let basis: String
    let eventTs: Double
    let detail: String?
    let sessionId: String?
    let pid: Int32?
    let viewColumn: Int?
    let tabIndex: Int?
    let isActiveTab: Bool
}

struct WindowRow: Identifiable {
    let id: Int32           // extension-host pid
    let name: String
    /// nil when the window has no folder open. `name` falls back to a label for
    /// display; this says whether there is a real project name to match on.
    let workspaceName: String?
    /// VS Code titles a folderless window with just its active tab, so this is
    /// the only handle on such a window.
    let activeTab: String?
    let folders: [String]
    let focused: Bool
    let chats: [Chat]
}

// MARK: - Small helpers

let deckDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".claude/claudedeck")
let projectsDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".claude/projects")

func pidAlive(_ pid: Int32) -> Bool {
    if pid <= 0 { return false }
    if kill(pid, 0) == 0 { return true }
    return errno == EPERM
}

func readJSON(_ url: URL) -> [String: Any]? {
    guard let d = try? Data(contentsOf: url) else { return nil }
    return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
}

/// Last `bytes` of a file, split into lines. Transcripts reach tens of MB;
/// only the tail is ever relevant.
func tailLines(_ path: String, bytes: Int = 131_072) -> [String] {
    guard let fh = FileHandle(forReadingAtPath: path) else { return [] }
    defer { try? fh.close() }
    let size = (try? fh.seekToEnd()).map { Int($0) } ?? 0
    let start = max(0, size - bytes)
    try? fh.seek(toOffset: UInt64(start))
    guard let d = try? fh.readToEnd(), let s = String(data: d, encoding: .utf8) else { return [] }
    return s.components(separatedBy: "\n")
}

/// First `bytes` of a file, split into lines.
func headLines(_ path: String, bytes: Int = 262_144) -> [String] {
    guard let fh = FileHandle(forReadingAtPath: path) else { return [] }
    defer { try? fh.close() }
    guard let d = try? fh.read(upToCount: bytes), let s = String(data: d, encoding: .utf8)
    else { return [] }
    return s.components(separatedBy: "\n")
}

/// Which finishes you have already looked at, and the order you dragged the
/// windows into. Both are yours, so both outlive a restart.
enum Store {
    static func read(_ name: String) -> [String: Any] {
        readJSON(deckDir.appendingPathComponent(name)) ?? [:]
    }
    static func write(_ name: String, _ value: Any) {
        try? FileManager.default.createDirectory(at: deckDir, withIntermediateDirectories: true)
        guard let d = try? JSONSerialization.data(withJSONObject: value) else { return }
        try? d.write(to: deckDir.appendingPathComponent(name))
    }
    static func readArray(_ name: String) -> [String] {
        let url = deckDir.appendingPathComponent(name)
        guard let d = try? Data(contentsOf: url),
              let a = (try? JSONSerialization.jsonObject(with: d)) as? [String] else { return [] }
        return a
    }
}

// MARK: - Collector

struct SessionState {
    let status: String
    let statusTs: Double
    let ts: Double
    let event: String?
    let claudePid: Int32?
    let transcriptPath: String?
    /// Body text for the banner, written by the hook in Claude Notify's wording.
    let detail: String?
}

struct TranscriptInfo {
    let sessionId: String
    let aiTitles: Set<String>
    let path: String
    /// File mtime — only for cache invalidation. Never as an activity time:
    /// transcripts are appended by background bookkeeping records
    /// (artifact ledgers, bridge-session, queue-operation) long after the last
    /// turn, so mtime can read minutes old for a chat that finished yesterday.
    let mtime: Double
    /// When the last actual message was written. This is the conversation's
    /// real clock, and what every age comparison must use.
    let activityTs: Double
    let derived: Status
    let derivedBasis: String
    /// Running with no tool outstanding: the model owes us a reply. A long gap
    /// here means something is wrong (a usage limit, an error, a dead session),
    /// unlike a gap while a tool is genuinely running.
    let awaitingAssistant: Bool
}

final class Collector: ObservableObject {
    @Published var windows: [WindowRow] = []
    @Published var lastRefresh = Date()
    @Published var axTrusted = AXIsProcessTrusted()
    @Published var bridgeMissing = false
    /// Reordering is a mode, not something you can trip into by dragging a row
    /// you meant to click. Auto-refresh pauses while it is on.
    @Published var isEditing = false
    @Published var dragIndex: Int?
    @Published var dragOffset: CGFloat = 0

    /// Titles found so far per file, with how far we have read.
    ///
    /// `ai-title` records sit wherever the title happened to be regenerated —
    /// often mid-file — so a head+tail scan misses them in anything larger than
    /// the two windows combined. Scanning the whole file each refresh would
    /// mean re-reading tens of megabytes every two seconds, so each file is
    /// read once and then only its newly appended bytes.
    private var titleScan: [String: (offset: UInt64, titles: Set<String>, sid: String?)] = [:]

    private func titles(in path: String) -> (titles: Set<String>, sid: String?) {
        var state = titleScan[path] ?? (offset: 0, titles: [], sid: nil)
        guard let fh = FileHandle(forReadingAtPath: path) else { return (state.titles, state.sid) }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()).map { UInt64($0) } ?? 0
        // Truncated or replaced: start over rather than read from a stale offset.
        if size < state.offset { state = (0, [], nil) }
        guard size > state.offset else { return (state.titles, state.sid) }

        try? fh.seek(toOffset: state.offset)
        guard let data = try? fh.readToEnd(), let chunk = String(data: data, encoding: .utf8) else {
            return (state.titles, state.sid)
        }
        // Stop at the last complete line; the file may end mid-write.
        guard let lastNewline = chunk.lastIndex(of: "\n") else { return (state.titles, state.sid) }
        let complete = chunk[chunk.startIndex..<lastNewline]

        for line in complete.components(separatedBy: "\n") {
            guard line.contains("\"ai-title\""),
                  let d = line.data(using: .utf8),
                  let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
            else { continue }
            if let t = j["aiTitle"] as? String { state.titles.insert(t) }
            if state.sid == nil { state.sid = j["sessionId"] as? String }
        }
        state.offset += UInt64(complete.utf8.count + 1)
        titleScan[path] = state
        return (state.titles, state.sid)
    }

    private var titleCache: [String: (mtime: Double, info: TranscriptInfo?)] = [:]
    private var seen: [String: Double] = (Store.read("seen.json") as? [String: Double])
        ?? Store.read("seen.json").compactMapValues { ($0 as? NSNumber)?.doubleValue }
    private var order: [String] = Store.readArray("order.json")

    /// Stable across restarts, unlike the extension-host pid.
    func key(_ w: WindowRow) -> String { w.folders.first ?? w.name }

    /// Open the chat a banner refers to: raise its window, select its tab, and
    /// mark the result seen so the badge and the New pill clear together.
    func openBySession(_ sessionId: String) {
        for w in windows {
            for c in w.chats where c.sessionId == sessionId {
                markSeen(c)
                Focus.go(window: w, chat: c)
                return
            }
        }
        // The tab is gone but we still know which window it was.
        if let r = Notifier.shared.route(for: sessionId) { Focus.raise(needle: r.windowName) }
    }

    func markSeen(_ chat: Chat) {
        guard let sid = chat.sessionId else { return }
        seen[sid] = max(seen[sid] ?? 0, chat.eventTs)
        Store.write("seen.json", seen)
        refresh()
    }

    func moveWindow(from: Int, to: Int) {
        var keys = windows.map { key($0) }
        guard from != to, keys.indices.contains(from), keys.indices.contains(to) else { return }
        let item = keys.remove(at: from)
        keys.insert(item, at: to)
        applyOrder(keys)
    }

    /// Keyboard/menu equivalent, so reordering never depends on a drag landing.
    func nudge(_ w: WindowRow, by delta: Int) {
        var keys = windows.map { key($0) }
        guard let i = keys.firstIndex(of: key(w)) else { return }
        let j = min(max(0, i + delta), keys.count - 1)
        guard i != j else { return }
        keys.swapAt(i, j)
        applyOrder(keys)
    }

    private func applyOrder(_ keys: [String]) {
        order = keys
        Store.write("order.json", keys)
        let rank = Dictionary(uniqueKeysWithValues: keys.enumerated().map { ($0.element, $0.offset) })
        windows.sort { (rank[key($0)] ?? Int.max) < (rank[key($1)] ?? Int.max) }
    }

    func refresh() {
        let states = loadSessionStates()
        let procs = loadClaudeProcesses()
        let files = loadWindowFiles()
        bridgeMissing = files.isEmpty

        // A live process's session id, when argv did not carry one. Hooks
        // record the owning pid, so this covers sessions started fresh.
        var pidToSession: [Int32: String] = [:]
        var pidClaimTs: [Int32: Double] = [:]
        for (sid, st) in states {
            guard let p = st.claudePid, pidAlive(p) else { continue }
            if st.ts >= (pidClaimTs[p] ?? 0) {
                pidToSession[p] = sid
                pidClaimTs[p] = st.ts
            }
        }

        var seenChanged = false
        var rows: [WindowRow] = []
        for wf in files {
            let extPid = wf.extHostPid
            let owned = procs.filter { $0.ppid == extPid }

            // A window opened with no folder has no workspaceFolders at all, so
            // everything keyed off them — transcripts, storage, memento — comes
            // up empty and every chat reads Unknown. The chats themselves still
            // know where they are: fall back to their own working directory.
            let folders = wf.folders.isEmpty
                ? Array(Set(owned.compactMap { cwd(of: $0.pid) })).sorted()
                : wf.folders
            let transcripts = transcriptsFor(folders: folders)

            // Pass 1 — the exact link first: VS Code's own record of which
            // session each tab holds. Title matching is only the fallback for a
            // tab the memento has not caught up with yet.
            let storageDir = wf.storageDir ?? folders.first.flatMap { storageDirFor(folder: $0) }
            let storageHash = storageDir.map { ($0 as NSString).lastPathComponent }
            let rateLimitTs = storageHash.flatMap { lastRateLimit(storageHash: $0) }
            var memento = mementoSessions(storageDir: storageDir)
            var tabSession: [String?] = []
            for tab in wf.tabs {
                if let k = memento.firstIndex(where: { $0.title == tab.label }) {
                    tabSession.append(memento.remove(at: k).sessionId)
                } else {
                    tabSession.append(resolveSession(label: tab.label, among: transcripts))
                }
            }
            var claimed = Set(tabSession.compactMap { $0 })

            // Session id for each owned process, from argv or from the hooks.
            var ownedSids: [String?] = owned.map { $0.sessionId ?? pidToSession[$0.pid] }

            // Pass 2 — elimination. Not every session has an `ai-title` record
            // (long-running ones can have none at all), so a title match can
            // fail outright. When exactly one tab and exactly one live process
            // are left over, the pairing is forced, not guessed. Any other
            // count stays unmatched.
            let freeTabs = tabSession.indices.filter { tabSession[$0] == nil }
            let freeProcs = ownedSids.indices.filter { i in
                guard let s = ownedSids[i] else { return false }
                return !claimed.contains(s)
            }
            if freeTabs.count == 1, freeProcs.count == 1, let sid = ownedSids[freeProcs[0]] {
                tabSession[freeTabs[0]] = sid
                claimed.insert(sid)
            }

            // Pass 3 — a tab that matched a session but has no process, next to
            // a process with no session, in the same window. One of each makes
            // the pairing forced rather than chosen.
            let tabsWithoutProc = tabSession.indices.filter { i in
                guard let sid = tabSession[i] else { return false }
                return !ownedSids.contains(sid)
            }
            let procsWithoutSid = ownedSids.indices.filter { ownedSids[$0] == nil }
            if tabsWithoutProc.count == 1, procsWithoutSid.count == 1 {
                ownedSids[procsWithoutSid[0]] = tabSession[tabsWithoutProc[0]]
            }

            // What is still unaccounted for after all three passes.
            claimed = Set(tabSession.compactMap { $0 })
            let unmatchedTabs = tabSession.indices.filter { tabSession[$0] == nil }
            let unmatchedProcs = ownedSids.indices.filter { i in
                guard let s = ownedSids[i] else { return true }
                return !claimed.contains(s)
            }

            // A live process we could not name is almost always one of the
            // tabs we could not name. Listing it separately invents a chat that
            // is not there — two tabs became four rows. Only a genuine surplus
            // of processes over tabs is an extra chat.
            let surplus = max(0, unmatchedProcs.count - unmatchedTabs.count)

            // Any live process still unaccounted for after all three passes.
            let unclaimedProcesses = !unmatchedProcs.isEmpty

            var chats: [Chat] = []
            for (i, tab) in wf.tabs.enumerated() {
                let sid = tabSession[i]
                let st = sid.flatMap { states[$0] }
                let proc = owned.enumerated().first { (j, p) in
                    guard let sid = sid else { return false }
                    return ownedSids[j] == sid || st?.claudePid == p.pid
                }?.element
                var (status, basis, eventTs) = resolveStatus(sessionId: sid, state: st, proc: proc,
                                                             transcripts: transcripts,
                                                             windowHasUnclaimedProcess: unclaimedProcesses,
                                                             rateLimitTs: rateLimitTs)
                // First sight of a session: adopt whatever state it is already
                // in as the baseline. A chat that finished before ClaudeDeck
                // ever saw it is history, not news — without this, opening a
                // window full of old chats announces every one of them.
                //
                // Recorded for every status, not only finished: a session first
                // seen while running must still be able to announce the finish
                // that follows, so the baseline has to be laid down before it.
                if let sid = sid, seen[sid] == nil {
                    seen[sid] = eventTs
                    seenChanged = true
                }
                // A finish you have not seen is the thing worth noticing; one
                // you have already read is just history. Looking at the tab in
                // the focused window counts as seeing it.
                if status == .finished, let sid = sid {
                    if tab.isActive && wf.focused {
                        if (seen[sid] ?? 0) < eventTs { seen[sid] = eventTs; seenChanged = true }
                    } else if (seen[sid] ?? 0) < eventTs {
                        status = .newResult
                        basis = "finished since you last looked"
                    }
                }
                // Say *why* it is unidentified. A chat opened seconds ago has no
                // transcript and no title yet, which is not the same problem as
                // a titled chat we failed to match.
                if sid == nil {
                    if !unmatchedProcs.isEmpty {
                        basis = "live chat in this window; its session is not yet identifiable"
                    } else {
                        basis = "no session could be matched to this tab"
                    }
                }
                chats.append(Chat(id: "\(extPid)-\(tab.viewColumn ?? 0)-\(tab.index)",
                                  title: tab.label,
                                  status: status,
                                  basis: basis,
                                  eventTs: eventTs,
                                  detail: st?.detail,
                                  sessionId: sid,
                                  pid: proc?.pid ?? st?.claudePid,
                                  viewColumn: tab.viewColumn,
                                  tabIndex: tab.index,
                                  isActiveTab: tab.isActive))
            }

            // Only the surplus gets its own row.
            for j in unmatchedProcs.suffix(surplus) {
                let p = owned[j]
                if chats.contains(where: { $0.pid == p.pid }) { continue }
                // A surplus process with no session id from any source — no
                // --resume, no hook has ever seen it — has never taken a turn.
                // That is a spare process the extension keeps warm, or the
                // remains of a tab opened and closed, not a chat you can open.
                // A surplus process that *does* have an id is a real chat whose
                // tab we failed to match, and still belongs in the list.
                guard let sid = ownedSids[j] else { continue }
                chats.append(Chat(id: "\(extPid)-proc-\(p.pid)",
                                  title: "Session \(sid.prefix(8))",
                                  status: .unknown,
                                  basis: "live process with no tab of its own",
                                  eventTs: 0,
                                  detail: nil,
                                  sessionId: sid, pid: p.pid,
                                  viewColumn: nil, tabIndex: nil, isActiveTab: false))
            }

            rows.append(WindowRow(id: extPid, name: wf.name,
                                  workspaceName: wf.workspaceName,
                                  activeTab: wf.tabs.first(where: { $0.isActive })?.label,
                                  folders: folders,
                                  focused: wf.focused, chats: chats))
        }

        // Sorted by the order you dragged them into, then alphabetically for
        // anything new. Deliberately not by focus: that changes as you switch
        // windows, which is what made the list jump under the cursor.
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
        rows.sort { a, b in
            let ia = rank[key(a)] ?? Int.max
            let ib = rank[key(b)] ?? Int.max
            if ia != ib { return ia < ib }
            return a.name.lowercased() < b.name.lowercased()
        }
        if seenChanged { Store.write("seen.json", seen) }
        windows = rows
        Notifier.shared.sync(windows: rows)
        lastRefresh = Date()
        axTrusted = AXIsProcessTrusted()
    }

    // MARK: Sources

    struct WindowFile {
        let extHostPid: Int32
        let name: String
        let folders: [String]
        let focused: Bool
        let workspaceName: String?
        let storageDir: String?
        let tabs: [(label: String, isActive: Bool, viewColumn: Int?, index: Int)]
    }

    private func loadWindowFiles() -> [WindowFile] {
        let dir = deckDir.appendingPathComponent("windows")
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir,
                                                                       includingPropertiesForKeys: nil)
        else { return [] }
        var out: [WindowFile] = []
        for url in items where url.pathExtension == "json" {
            guard let j = readJSON(url) else { continue }
            guard let pid = (j["extHostPid"] as? NSNumber)?.int32Value else { continue }
            let ts = (j["ts"] as? NSNumber)?.doubleValue ?? 0
            // Stale heartbeat or dead host: the window is gone, drop it rather
            // than listing a window that no longer exists.
            let fresh = Date().timeIntervalSince1970 * 1000 - ts < 20_000
            guard pidAlive(pid), fresh else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            let folders = (j["workspaceFolders"] as? [String]) ?? []
            let name = (j["workspaceName"] as? String) ?? folders.first.map {
                URL(fileURLWithPath: $0).lastPathComponent
            } ?? "Untitled window"
            var tabs: [(String, Bool, Int?, Int)] = []
            for t in (j["tabs"] as? [[String: Any]]) ?? [] {
                tabs.append(((t["label"] as? String) ?? "",
                             (t["isActive"] as? Bool) ?? false,
                             (t["viewColumn"] as? NSNumber)?.intValue,
                             (t["index"] as? NSNumber)?.intValue ?? 0))
            }
            out.append(WindowFile(extHostPid: pid, name: name, folders: folders,
                                  focused: (j["focused"] as? Bool) ?? false,
                                  workspaceName: j["workspaceName"] as? String,
                                  storageDir: j["storageDir"] as? String, tabs: tabs))
        }
        return out
    }

    private func loadSessionStates() -> [String: SessionState] {
        let dir = deckDir.appendingPathComponent("sessions")
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir,
                                                                       includingPropertiesForKeys: nil)
        else { return [:] }
        var out: [String: SessionState] = [:]
        for url in items where url.pathExtension == "json" {
            guard let j = readJSON(url), let sid = j["sessionId"] as? String else { continue }
            out[sid] = SessionState(status: (j["status"] as? String) ?? "unknown",
                                    statusTs: (j["statusTs"] as? NSNumber)?.doubleValue ?? 0,
                                    ts: (j["ts"] as? NSNumber)?.doubleValue ?? 0,
                                    event: j["event"] as? String,
                                    claudePid: (j["claudePid"] as? NSNumber)?.int32Value,
                                    transcriptPath: j["transcriptPath"] as? String,
                                    detail: j["detail"] as? String)
        }
        return out
    }

    struct ClaudeProc { let pid: Int32; let ppid: Int32; let sessionId: String? }

    /// Working directory of a chat process, cached — it never changes for the
    /// life of the process, and lsof is too costly to run every refresh.
    private var pidCwd: [Int32: String?] = [:]

    private func cwd(of pid: Int32) -> String? {
        if let c = pidCwd[pid] { return c }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-a", "-p", String(pid), "-d", "cwd", "-Fn"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        var result: String? = nil
        if (try? p.run()) != nil {
            let d = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if let out = String(data: d, encoding: .utf8) {
                result = out.components(separatedBy: "\n")
                    .first { $0.hasPrefix("n") }
                    .map { String($0.dropFirst()) }
            }
        }
        pidCwd[pid] = result
        return result
    }

    private func loadClaudeProcesses() -> [ClaudeProc] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-eo", "pid,ppid,command"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let out = String(data: data, encoding: .utf8) else { return [] }

        var rows: [ClaudeProc] = []
        for line in out.components(separatedBy: "\n") {
            guard line.contains("native-binary/claude") else { continue }
            let t = line.trimmingCharacters(in: .whitespaces)
            let parts = t.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = Int32(parts[0]), let ppid = Int32(parts[1]) else { continue }
            var sid: String? = nil
            if let r = parts[2].range(of: "--resume=") {
                let rest = parts[2][r.upperBound...]
                sid = String(rest.prefix { !$0.isWhitespace })
            }
            rows.append(ClaudeProc(pid: pid, ppid: ppid, sessionId: sid))
        }
        return rows
    }

    // MARK: Rate limits
    //
    // A usage limit never reaches the transcript — the turn simply stops, and
    // the last assistant record still reads `stop_reason: tool_use`, so the
    // session looks busy forever. The extension does record it, per window:
    //
    //   [ERROR] API rate_limit after retries: This request would exceed your
    //           account's rate limit. Please try again later.
    //
    // The log directory identifies its workspace through the storage hash in
    // its sibling exthost.log, which is the same hash we already resolve from a
    // folder — so a window's log can be found exactly rather than guessed at.

    private var logPathCache: [String: (resolvedAt: Double, path: String?)] = [:]
    private var rateLimitCache: [String: (mtime: Double, ts: Double?)] = [:]

    private func claudeLogPath(storageHash: String) -> String? {
        // VS Code writes a fresh log directory per launch, so the same
        // workspace appears in every past session's logs. Taking the first
        // match returns a log from weeks ago; the newest is the live one.
        // Re-resolved periodically because it changes when VS Code restarts.
        let now = Date().timeIntervalSince1970
        if let c = logPathCache[storageHash], now - c.resolvedAt < 60 { return c.path }

        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Code/logs")
        var best: (path: String, mtime: Double)? = nil
        for session in (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? [] {
            for win in (try? FileManager.default.contentsOfDirectory(at: session, includingPropertiesForKeys: nil)) ?? []
            where win.lastPathComponent.hasPrefix("window") {
                let exthost = win.appendingPathComponent("exthost/exthost.log").path
                // The workspace lock line sits near the top of the file.
                guard headLines(exthost, bytes: 65_536).contains(where: { $0.contains(storageHash) })
                else { continue }
                let log = win.appendingPathComponent("exthost/Anthropic.claude-code/Claude VSCode.log").path
                guard let m = (try? FileManager.default.attributesOfItem(atPath: log)[.modificationDate]) as? Date
                else { continue }
                let t = m.timeIntervalSince1970
                if best == nil || t > best!.mtime { best = (log, t) }
            }
        }
        logPathCache[storageHash] = (now, best?.path)
        return best?.path
    }

    /// When the account rate limit was last hit in this window, if ever.
    private func lastRateLimit(storageHash: String) -> Double? {
        guard let log = claudeLogPath(storageHash: storageHash) else { return nil }
        let mtime = ((try? FileManager.default.attributesOfItem(atPath: log)[.modificationDate]) as? Date
            ?? .distantPast).timeIntervalSince1970
        if let c = rateLimitCache[log], c.mtime == mtime { return c.ts }

        var newest: Double? = nil
        for line in tailLines(log, bytes: 524_288) {
            guard line.contains("rate_limit") else { continue }
            if let t = logTimestamp(line) { newest = max(newest ?? 0, t) }
        }
        rateLimitCache[log] = (mtime, newest)
        return newest
    }

    /// "2026-09-09T18:03:00.341Z" as an epoch.
    private func isoTime(_ s: String) -> Double? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d.timeIntervalSince1970 }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)?.timeIntervalSince1970
    }

    /// Lines carry either a local "yyyy-MM-dd HH:mm:ss.SSS" prefix or an inline
    /// ISO instant; take whichever is there.
    private func logTimestamp(_ line: String) -> Double? {
        let local = DateFormatter()
        local.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        if line.count > 23 {
            let head = String(line.prefix(23))
            if let d = local.date(from: head) { return d.timeIntervalSince1970 }
        }
        if let r = line.range(of: #"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z"#, options: .regularExpression) {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = iso.date(from: String(line[r])) { return d.timeIntervalSince1970 }
        }
        return nil
    }

    // MARK: Tab -> session, exactly

    private var wsDirCache: [String: String] = [:]

    /// The workspace-storage directory for a folder, found by matching VS
    /// Code's own `workspace.json`. The bridge publishes this too, but only
    /// after a window reload — resolving it here means the mapping works
    /// immediately, and keeps working if the extension is not up to date.
    private func storageDirFor(folder: String) -> String? {
        if let c = wsDirCache[folder] { return c }
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Code/User/workspaceStorage")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: base, includingPropertiesForKeys: nil) else { return nil }
        var best: (path: String, mtime: Double)? = nil
        for e in entries {
            guard let j = readJSON(e.appendingPathComponent("workspace.json")),
                  let f = j["folder"] as? String,
                  URL(string: f)?.path == folder else { continue }
            let db = e.appendingPathComponent("state.vscdb").path
            let m = ((try? FileManager.default.attributesOfItem(atPath: db)[.modificationDate]) as? Date
                ?? .distantPast).timeIntervalSince1970
            // A folder can have several stale storage dirs; the live one is the
            // one VS Code is still writing to.
            if best == nil || m > best!.mtime { best = (e.path, m) }
        }
        if let b = best { wsDirCache[folder] = b.path }
        return best?.path
    }

    private var mementoCache: [String: (mtime: Double, pairs: [(title: String, sessionId: String)])] = [:]

    /// Every Claude tab's `sessionID`, in tab order, straight out of the
    /// window's own VS Code state.
    ///
    /// This is the authoritative tab -> session link. The extension API exposes
    /// none — `tab.input` carries only a viewType shared by every chat tab — but
    /// VS Code persists each webview's state, and Claude Code puts the session
    /// id in it. Title matching is only a fallback for when this is stale.
    private func mementoSessions(storageDir: String?) -> [(title: String, sessionId: String)] {
        guard let dir = storageDir else { return [] }
        let db = (dir as NSString).appendingPathComponent("state.vscdb")
        let mtime = ((try? FileManager.default.attributesOfItem(atPath: db)[.modificationDate]) as? Date
            ?? .distantPast).timeIntervalSince1970
        if let c = mementoCache[db], c.mtime == mtime { return c.pairs }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        // Read-only: VS Code holds this open, and we must never write to it.
        p.arguments = ["-readonly", db,
                       "select value from ItemTable where key='memento/workbench.parts.editor';"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()

        var pairs: [(title: String, sessionId: String)] = []
        if let root = try? JSONSerialization.jsonObject(with: data) {
            collectWebviews(root, into: &pairs)
        }
        mementoCache[db] = (mtime, pairs)
        return pairs
    }

    private func collectWebviews(_ node: Any, into pairs: inout [(title: String, sessionId: String)]) {
        if let dict = node as? [String: Any] {
            if (dict["id"] as? String) == "workbench.editors.webviewInput",
               let raw = dict["value"] as? String,
               let d = raw.data(using: .utf8),
               let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
               (j["viewType"] as? String) == "mainThreadWebview-claudeVSCodePanel",
               let title = j["title"] as? String,
               let stateRaw = j["state"] as? String,
               let sd = stateRaw.data(using: .utf8),
               let st = (try? JSONSerialization.jsonObject(with: sd)) as? [String: Any],
               let sid = st["sessionID"] as? String {
                pairs.append((title, sid))
            }
            for v in dict.values { collectWebviews(v, into: &pairs) }
        } else if let arr = node as? [Any] {
            for v in arr { collectWebviews(v, into: &pairs) }
        }
    }

    // MARK: Tab -> session

    private func slug(_ folder: String) -> String {
        folder.replacingOccurrences(of: "/", with: "-")
    }

    private func transcriptsFor(folders: [String]) -> [TranscriptInfo] {
        var out: [TranscriptInfo] = []
        let cutoff = Date().timeIntervalSince1970 - 60 * 60 * 24 * 30
        for folder in folders {
            let dir = projectsDir.appendingPathComponent(slug(folder))
            guard let items = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for url in items where url.pathExtension == "jsonl" {
                let mtime = ((try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast).timeIntervalSince1970
                guard mtime > cutoff else { continue }
                if let cached = titleCache[url.path], cached.mtime == mtime {
                    if let i = cached.info { out.append(i) }
                    continue
                }
                let info = parseTranscript(url.path, mtime: mtime)
                titleCache[url.path] = (mtime, info)
                if let i = info { out.append(i) }
            }
        }
        return out
    }

    /// Derives what the session is doing, from the transcript alone.
    ///
    /// `stop_reason` is the field that makes this sound. A finished turn and a
    /// turn still working look identical at the record-type level — both end
    /// in an `assistant` record — but `end_turn` and `tool_use` tell them
    /// apart. Ranked below the hooks, above guessing.
    func parseTranscript(_ path: String, mtime: Double) -> TranscriptInfo? {
        // Every title in the file, wherever it sits. A tab keeps whichever
        // title was current when it was last labelled — often the first — so
        // all of them have to be matchable, not just the newest.
        let scanned = titles(in: path)
        var titles = scanned.titles
        var sid: String? = scanned.sid

        var lastMessageTs: Double? = nil
        var openToolUses = Set<String>()   // tool_use with no tool_result yet
        var pendingLaunches = Set<String>() // backgrounded work not yet notified
        var sawRealPrompt = false
        var state: Status = .unknown
        var basis = ""

        for line in tailLines(path, bytes: 1_048_576) {
            guard let d = line.data(using: .utf8),
                  let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
            else { continue }
            let type = (j["type"] as? String) ?? ""

            if type == "ai-title" {
                if let t = j["aiTitle"] as? String { titles.insert(t) }
                sid = (j["sessionId"] as? String) ?? sid
                continue
            }
            if sid == nil { sid = j["sessionId"] as? String }
            guard type == "assistant" || type == "user" else { continue }
            if let iso = j["timestamp"] as? String, let t = isoTime(iso) {
                lastMessageTs = max(lastMessageTs ?? 0, t)
            }

            let msg = j["message"] as? [String: Any]
            let content = msg?["content"]
            let blocks = content as? [[String: Any]] ?? []
            let flat = flatten(content)

            if type == "assistant" {
                for b in blocks where (b["type"] as? String) == "tool_use" {
                    if let id = b["id"] as? String { openToolUses.insert(id) }
                }
                switch msg?["stop_reason"] as? String {
                case "end_turn":
                    state = .finished
                    basis = "transcript: turn ended (end_turn)"
                case "tool_use":
                    state = .running
                    basis = "transcript: tool call in flight"
                case .some:
                    state = .unknown
                    basis = "transcript: turn ended for an unrecognised reason"
                case nil:
                    break
                }
                continue
            }

            // type == "user"
            //
            // The marker is itself a plain user text block — "[Request
            // interrupted by user for tool use]" — so the real-prompt check
            // below accepts it and overwrites this with .running. It has to
            // claim the record and stop.
            if flat.contains("Request interrupted by user") {
                state = .interrupted
                basis = "transcript: interrupted by you"
                // The tool you interrupted will never return a result, so it is
                // not "in flight". Leaving it open makes the next stall wait the
                // long tool timeout instead of the short awaiting-reply one.
                openToolUses.removeAll()
                continue
            }
            for b in blocks where (b["type"] as? String) == "tool_result" {
                guard let id = b["tool_use_id"] as? String else { continue }
                openToolUses.remove(id)
                if isLaunchAnnouncement(b["content"]) { pendingLaunches.insert(id) }
            }
            if flat.contains("<task-notification>"), let id = toolUseId(in: flat) {
                pendingLaunches.remove(id)
            }
            if isRealUserPrompt(type: type, content: content) {
                // A new prompt retires the old stage entirely — both its
                // backgrounded work and any tool call left unresolved by it.
                pendingLaunches.removeAll()
                openToolUses.removeAll()
                sawRealPrompt = true
                state = .running
                basis = "transcript: prompt submitted, response pending"
            }
        }

        // A tool_use whose result has already arrived is not "in flight". The
        // last assistant record still says stop_reason=tool_use, so without
        // this the session reads as busy long after it stopped being able to
        // do anything — which is exactly what a usage limit looks like.
        var awaiting = false
        if state == .running {
            awaiting = openToolUses.isEmpty
            if awaiting, basis == "transcript: tool call in flight" {
                basis = "transcript: waiting for Claude to reply"
            }
        }

        if state == .finished {
            if !openToolUses.isEmpty {
                state = .running
                basis = "transcript: tool call in flight"
            } else if !pendingLaunches.isEmpty {
                // The turn genuinely ended, but the session is parked on work it
                // backgrounded and will be re-invoked. Calling that Finished is
                // the mistake this rule exists to prevent — and calling it
                // Running is the one that put a finished chat in blue.
                state = .background
                basis = "transcript: turn ended, background work still outstanding"
            } else if !sawRealPrompt {
                // No stage boundary in the window read, so an earlier launch
                // could be missed. Decline rather than risk a false Finished.
                state = .unknown
                basis = "transcript window too short to confirm"
            }
        }

        guard let s = sid ?? Optional(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
        else { return nil }
        return TranscriptInfo(sessionId: s, aiTitles: titles, path: path, mtime: mtime,
                              activityTs: lastMessageTs ?? mtime,
                              derived: state, derivedBasis: basis, awaitingAssistant: awaiting)
    }

    /// Any content shape as one searchable string.
    private func flatten(_ content: Any?) -> String {
        if let s = content as? String { return s }
        guard let obj = content,
              let d = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: d, encoding: .utf8) else { return "" }
        return s
    }

    /// A tool_result that *is* a backgrounding announcement, not output that
    /// merely quotes one — hence the anchoring to the start of the text.
    private func isLaunchAnnouncement(_ content: Any?) -> Bool {
        var text = ""
        if let s = content as? String { text = s }
        else if let arr = content as? [[String: Any]] {
            text = arr.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("Async agent launched successfully") { return true }
        guard text.hasPrefix("Command") else { return false }
        let head = String(text.prefix(140))
        return head.contains("running in background with ID:")
            || head.contains("moved to the background (ID:")
    }

    private func toolUseId(in text: String) -> String? {
        guard let open = text.range(of: "<tool-use-id>"),
              let close = text.range(of: "</tool-use-id>", range: open.upperBound..<text.endIndex)
        else { return nil }
        return String(text[open.upperBound..<close.lowerBound])
    }

    /// A message the human actually typed. Tool results and injected blocks are
    /// also recorded as "user" and would otherwise reset the stage constantly.
    private func isRealUserPrompt(type: String, content: Any?) -> Bool {
        guard type == "user" else { return false }
        if let s = content as? String {
            let t = s.trimmingCharacters(in: .whitespaces)
            return !t.isEmpty && !t.hasPrefix("<")
        }
        guard let blocks = content as? [[String: Any]] else { return false }
        if blocks.contains(where: { ($0["type"] as? String) == "tool_result" }) { return false }
        return blocks.contains { b in
            guard (b["type"] as? String) == "text", let t = b["text"] as? String else { return false }
            let s = t.trimmingCharacters(in: .whitespaces)
            // "[Request interrupted by user…]" is written as a user text block
            // but is not something you typed.
            if s.hasPrefix("[Request interrupted by user") { return false }
            return !s.isEmpty && !s.hasPrefix("<")
        }
    }

    /// VS Code truncates tab labels (~24 chars) with a trailing ellipsis, so an
    /// exact compare only works for short titles. Ambiguity is reported as no
    /// match — showing the wrong chat's status is the one outcome to avoid.
    private func resolveSession(label: String, among transcripts: [TranscriptInfo]) -> String? {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let isTruncated = trimmed.hasSuffix("…")
        let needle = isTruncated ? String(trimmed.dropLast()) : trimmed

        let matches = transcripts.filter { info in
            info.aiTitles.contains { isTruncated ? $0.hasPrefix(needle) : $0 == needle }
        }
        if matches.count == 1 { return matches[0].sessionId }
        if matches.count > 1 {
            // Several sessions share this prefix; the newest is a guess, so
            // decline instead.
            return nil
        }
        return nil
    }

    // MARK: Status

    /// Ranked: a hook event beats a transcript reading of the same moment,
    /// the transcript beats nothing, and process liveness overrides both — a
    /// session that was running when its process died did not finish.
    private func resolveStatus(sessionId: String?, state st: SessionState?,
                               proc: ClaudeProc?, transcripts: [TranscriptInfo],
                               windowHasUnclaimedProcess: Bool,
                               rateLimitTs: Double? = nil) -> (Status, String, Double) {
        guard let sid = sessionId else {
            return (.unknown, "no session could be matched to this tab", 0)
        }
        let ti = transcripts.first { $0.sessionId == sid }
        let alive = (proc != nil) || (st?.claudePid.map { pidAlive($0) } ?? false)

        var status: Status = .unknown
        var basis = "no status could be established"

        let hookTs = st?.statusTs ?? -1
        let tranTs = (ti?.activityTs ?? -1) * 1000

        // Best-known "last activity" for this chat, reported on every path so
        // a row can always say how old its information is.
        let evTs = max(max(hookTs, 0), max(tranTs, 0))
        var fromTranscript = false
        if let st = st, hookTs >= tranTs {
            status = Status(rawValue: st.status) ?? .unknown
            // Records written before "background" existed say running+stop.
            if status == .running, st.event == "stop" { status = .background }
            basis = status == .background
                ? "turn ended; a backgrounded task has not reported back"
                : "hook reported \(st.status)"
        } else if let ti = ti, ti.derived != .unknown {
            status = ti.derived
            basis = ti.derivedBasis
            fromTranscript = true
        } else if let st = st {
            status = Status(rawValue: st.status) ?? .unknown
            basis = "hook reported \(st.status)"
        } else if let ti = ti, !ti.derivedBasis.isEmpty {
            basis = ti.derivedBasis
        }

        // A turn the transcript last touched hours ago is not evidence that it
        // is still running — an abandoned tool call looks identical to a live
        // one. Only the hooks can assert "running" over a long gap.
        // A rate limit is recorded, so it can be reported outright rather than
        // inferred from silence — but only for a session actually waiting on a
        // reply. A tool still running is unaffected by it.
        if status == .running, let ti = ti, ti.awaitingAssistant,
           let rl = rateLimitTs, rl > ti.activityTs {
            return (.rateLimited, "account rate limit hit \(relativeText(rl * 1000)) — Claude is not running", evTs)
        }

        if status == .background {
            let age = Date().timeIntervalSince1970 - max(ti?.activityTs ?? 0, hookTs / 1000)
            // Backgrounded precisely because it runs long, so the bound is
            // generous — but not unbounded.
            if age > 1800 {
                return (.unknown, "backgrounded task has not reported back for \(ageText(age))", evTs)
            }
        }

        if fromTranscript, status == .running, let ti = ti {
            let age = Date().timeIntervalSince1970 - ti.activityTs
            // A reply is owed within seconds; a tool can legitimately run for
            // half an hour. One threshold for both would either call a long
            // build dead or call a blocked session busy.
            let limit: TimeInterval = ti.awaitingAssistant ? 90 : 1800
            if age > limit {
                let why = ti.awaitingAssistant
                    ? "no reply for \(ageText(age)) — stalled, rate-limited or errored"
                    : "no transcript activity for \(ageText(age)) — cannot confirm"
                return (.unknown, why, evTs)
            }
        }

        // An in-progress status is only credible while something is running it.
        if status == .running || status == .question || status == .permission, !alive {
            if windowHasUnclaimedProcess {
                return (.unknown, "a live process here could not be tied to a tab", evTs)
            }
            return (.ended, "process gone before the turn completed", evTs)
        }

        if status == .unknown {
            // A session with a live process but no transcript at all has never
            // taken a turn — that is a chat you have just opened, not one whose
            // state we failed to read.
            if alive, ti == nil, st == nil {
                return (.idle, "new chat, nothing sent yet", 0)
            }
            if alive { return (.unknown, "running, but nothing has reported a status", evTs) }
            return windowHasUnclaimedProcess
                ? (.unknown, "a live process here could not be tied to a tab", evTs)
                : (.idle, basis.isEmpty ? "tab open, no process running" : basis, evTs)
        }
        return (status, basis, evTs)
    }
}

/// "3m ago" / "13h ago" for a millisecond epoch; empty when nothing is known.
func relativeText(_ msEpoch: Double) -> String {
    guard msEpoch > 0 else { return "" }
    let age = Date().timeIntervalSince1970 - msEpoch / 1000
    if age < 45 { return "just now" }
    return ageText(age) + " ago"
}

/// The exact moment, for the tooltip — a relative label alone hides whether
/// "2h ago" means today or a stale reading from a restart.
func absoluteText(_ msEpoch: Double) -> String {
    guard msEpoch > 0 else { return "no timestamp available" }
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .medium
    return f.string(from: Date(timeIntervalSince1970: msEpoch / 1000))
}

func ageText(_ seconds: Double) -> String {
    if seconds < 3600 { return "\(Int(seconds / 60))m" }
    if seconds < 86400 { return "\(Int(seconds / 3600))h" }
    return "\(Int(seconds / 86400))d"
}

// MARK: - Notifications

/// Posts a banner when a chat starts wanting something, withdraws it when it
/// stops, and badges the Dock with how many are outstanding.
///
/// Deliberately additive: Claude Notify and the extension keep posting their
/// own. Duplicates are expected.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// sessionId -> the eventTs already announced, so a status that merely
    /// persists across refreshes is not re-posted every two seconds.
    ///
    /// Persisted: an unseen finish stays in an attention state indefinitely, so
    /// without this every relaunch re-announced every one of them — which is
    /// what duplicate banners actually were.
    private var announced: [String: Double] =
        Store.read("announced.json").compactMapValues { ($0 as? NSNumber)?.doubleValue }
    private var authorised = false

    /// Where a click should land: sessionId -> (window key, tab coordinates).
    private var routes: [String: (windowName: String, extHostPid: Int32, viewColumn: Int?, tabIndex: Int?)] = [:]

    var onOpen: ((String) -> Void)?

    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // Deliberately not clearing delivered notifications here. Doing so
        // discarded banners this app had already posted, and with an empty
        // announced map the next sync posted every one of them again.
        log("start")
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            DispatchQueue.main.async { self.authorised = granted }
        }
    }

    func sync(windows: [WindowRow]) {
        var live = Set<String>()
        var attention = 0
        var announcedChanged = false

        for w in windows {
            for c in w.chats {
                guard let sid = c.sessionId else { continue }
                guard c.status.needsAttention, let label = c.status.bannerLabel else { continue }
                attention += 1
                live.insert(sid)
                routes[sid] = (w.name, w.id, c.viewColumn, c.tabIndex)

                // Post once per distinct event, not once per refresh.
                if announced[sid] == c.eventTs { continue }
                announced[sid] = c.eventTs
                // "Untitled window | ✅ Finished" says nothing. With no project
                // name, the chat's own title is the useful handle.
                post(sessionId: sid, project: w.workspaceName ?? c.title,
                     label: label, chat: c)
            }
        }

        // Anything no longer asking for attention has its banner taken back —
        // opening the chat in VS Code clears it without touching ClaudeDeck.
        let stale = Set(announced.keys).subtracting(live)
        if !stale.isEmpty {
            UNUserNotificationCenter.current()
                .removeDeliveredNotifications(withIdentifiers: Array(stale))
            for k in stale { announced.removeValue(forKey: k) }
            announcedChanged = true
        }
        if announcedChanged { Store.write("announced.json", announced) }

        // Two things can badge this app: the Dock tile we set, and Notification
        // Centre's own unread count. Set both to the same number so they cannot
        // disagree — and clear both together when nothing is waiting.
        NSApp.dockTile.badgeLabel = attention > 0 ? "\(attention)" : nil
        UNUserNotificationCenter.current().setBadgeCount(attention)
    }

    /// The extension's status-bar mute. Claude Notify's hooks honour it, so
    /// silencing from VS Code must silence this too.
    ///
    /// Checked here rather than in the hook: the hook also records state for the
    /// list, and muting should stop the banner, not blind the GUI.
    private var muted: Bool {
        FileManager.default.fileExists(atPath:
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/hooks/claude-notifier-muted").path)
    }

    private func log(_ line: String) {
        let f = deckDir.appendingPathComponent("notify.log")
        let stamp = ISO8601DateFormatter().string(from: Date())
        guard let d = "\(stamp) \(line)\n".data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: f) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: d)
        } else {
            try? FileManager.default.createDirectory(at: deckDir, withIntermediateDirectories: true)
            try? d.write(to: f)
        }
    }

    private func post(sessionId: String, project: String, label: String, chat: Chat) {
        guard authorised, !muted else {
            log("skip \(sessionId.prefix(8)) \(label) authorised=\(authorised) muted=\(muted)")
            return
        }
        log("post \(sessionId.prefix(8)) \(label) eventTs=\(Int(chat.eventTs)) — \(chat.title)")
        let content = UNMutableNotificationContent()
        content.title = "\(project) | \(label)"
        // Claude Notify's wording, supplied by the hook; the chat title is only
        // a fallback for a status the hooks never reported.
        content.body = chat.detail ?? chat.title
        // No UNNotificationSound either way: when this is on, the sound is
        // played exactly as Claude Notify plays it, so the two match rather
        // than chiming differently.
        if Settings.shared.playSound, let name = chat.status.bannerSound {
            let path = "/System/Library/Sounds/\(name).aiff"
            if FileManager.default.fileExists(atPath: path) {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
                p.arguments = [path]
                try? p.run()
            }
        }
        // Grouped by project, exactly as Claude Notify threads its own.
        content.threadIdentifier = project
        content.userInfo = ["sessionId": sessionId]
        // sessionId as the identifier: re-posting replaces rather than stacks,
        // and withdrawal above can name it.
        let request = UNNotificationRequest(identifier: sessionId, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    func route(for sessionId: String) -> (windowName: String, extHostPid: Int32, viewColumn: Int?, tabIndex: Int?)? {
        routes[sessionId]
    }

    // Show the banner even when ClaudeDeck itself is frontmost — the point is
    // the VS Code window behind it, not this one.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler handler: @escaping (UNNotificationPresentationOptions) -> Void) {
        handler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler handler: @escaping () -> Void) {
        let sid = response.notification.request.identifier
        DispatchQueue.main.async { self.onOpen?(sid) }
        center.removeDeliveredNotifications(withIdentifiers: [sid])
        announced.removeValue(forKey: sid)
        handler()
    }
}

// MARK: - Focus

enum Focus {
    /// Ask the bridge in that window to activate the tab, then raise the window.
    /// What a VS Code window can be recognised by, best first.
    ///
    /// A foldered window is titled "<editor> — <project>". A folderless one is
    /// titled with its active tab and nothing else, so the project suffix that
    /// works everywhere else matches nothing at all there.
    static func needles(for window: WindowRow, chat: Chat?) -> [String] {
        var out: [String] = []
        if let ws = window.workspaceName { out.append(ws) }
        if let tab = chat?.title, !tab.isEmpty { out.append(tab) }
        if let active = window.activeTab, !active.isEmpty { out.append(active) }
        return out
    }

    static func go(window: WindowRow, chat: Chat?) {
        if let chat = chat, let idx = chat.tabIndex {
            let req: [String: Any] = [
                "ts": Date().timeIntervalSince1970 * 1000,
                "extHostPid": Int(window.id),
                "viewColumn": chat.viewColumn ?? 1,
                "index": idx,
            ]
            let url = deckDir.appendingPathComponent("focus-request.json")
            try? FileManager.default.createDirectory(at: deckDir, withIntermediateDirectories: true)
            if let d = try? JSONSerialization.data(withJSONObject: req) {
                try? d.write(to: url)
            }
        }
        raise(needles: needles(for: window, chat: chat))
    }

    /// Reused from Claude Notify: VS Code titles folder windows
    /// "<editor> — <project>", so a suffix match picks the right one.
    @discardableResult
    static func raise(needle: String) -> Bool { raise(needles: [needle]) }

    @discardableResult
    static func raise(needles: [String]) -> Bool {
        guard !needles.isEmpty else { return false }
        guard AXIsProcessTrusted() else { return false }
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.microsoft.VSCode").first else { return false }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        func attr(_ e: AXUIElement, _ n: String) -> CFTypeRef? {
            var v: CFTypeRef?
            guard AXUIElementCopyAttributeValue(e, n as CFString, &v) == .success else { return nil }
            return v
        }
        func target() -> AXUIElement? {
            guard let ws = attr(axApp, kAXWindowsAttribute as String) as? [AXUIElement] else { return nil }
            let titles: [(AXUIElement, String)] = ws.compactMap { w in
                (attr(w, kAXTitleAttribute as String) as? String).map { (w, $0) }
            }
            // Exact handles first, across all needles, before any loose match —
            // a substring hit on an early needle must not beat an exact hit on
            // a later one.
            for n in needles {
                for (w, t) in titles where t.hasSuffix("— \(n)") || t == n { return w }
            }
            for n in needles {
                for (w, t) in titles where t.localizedCaseInsensitiveContains(n) { return w }
            }
            return nil
        }

        app.activate()
        for attempt in 0..<8 {
            guard let w = target() else { Thread.sleep(forTimeInterval: 0.15); continue }
            AXUIElementPerformAction(w, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, w)
            Thread.sleep(forTimeInterval: 0.12)
            if attempt > 1, let m = attr(w, kAXMainAttribute as String) as? Bool, m { break }
        }
        return true
    }
}

// MARK: - UI

// Animations are derived from the clock, not from `withAnimation`.
//
// The list rebuilds every couple of seconds as statuses refresh, and a
// `repeatForever` animation started in `onAppear` is cancelled when its view is
// re-evaluated — it stops wherever it happened to be and looks frozen. A phase
// computed from the current time cannot freeze: any rebuild simply re-derives
// it from the clock.

/// 0…1, restarting each period.
private func sawtooth(_ t: Double, _ period: Double) -> Double {
    (t.truncatingRemainder(dividingBy: period)) / period
}

/// 0…1…0 across the period, eased so the turn-around is not abrupt.
private func pulse(_ t: Double, _ period: Double) -> Double {
    let x = sawtooth(t, period)
    let tri = x < 0.5 ? x * 2 : (1 - x) * 2
    return tri * tri * (3 - 2 * tri)   // smoothstep
}

private let tickSchedule = AnimationTimelineSchedule(minimumInterval: 1.0 / 30.0, paused: false)

/// The leading dot. Carries the dot-side treatments; ignores the pill ones.
struct StatusDot: View {
    let status: Status
    let style: PillStyle

    var body: some View {
        if style.actsOnDot {
            TimelineView(tickSchedule) { ctx in
                dot(at: ctx.date.timeIntervalSinceReferenceDate)
            }
        } else {
            dot(at: 0)
        }
    }

    @ViewBuilder
    private func dot(at t: Double) -> some View {
        let live = style.actsOnDot
        ZStack {
            if live && style == .ping {
                let p = sawtooth(t, 2.0)
                Circle()
                    .stroke(status.color, lineWidth: 1.5)
                    .frame(width: 7, height: 7)
                    .scaleEffect(1 + p * 1.4)
                    .opacity(0.5 * (1 - p))
            }
            if live && style == .spinner {
                Circle()
                    .trim(from: 0, to: 0.7)
                    .stroke(status.color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    .frame(width: 9, height: 9)
                    .rotationEffect(.degrees(sawtooth(t, 1.1) * 360))
            } else {
                Circle()
                    .fill(status.color)
                    .frame(width: 7, height: 7)
                    .scaleEffect(live && style == .breathing ? 1 - pulse(t, 2.8) * 0.25 : 1)
                    .opacity(opacity(at: t))
                    .offset(y: live && style == .bounce ? -pulse(t, 1.0) * 2.5 : 0)
            }
        }
        .frame(width: 12, height: 12)
    }

    private func opacity(at t: Double) -> Double {
        guard style.actsOnDot else { return 1 }
        switch style {
        case .breathing: return 1 - pulse(t, 2.8) * 0.45
        case .blink: return 1 - pulse(t, 1.2) * 0.85
        default: return 1
        }
    }
}

struct StatusPill: View {
    let status: Status
    var style: PillStyle = .still

    var body: some View {
        if style.actsOnPill {
            TimelineView(tickSchedule) { ctx in
                pill(at: ctx.date.timeIntervalSinceReferenceDate)
            }
        } else {
            pill(at: 0)
        }
    }

    @ViewBuilder
    private func pill(at t: Double) -> some View {
        let live = style.actsOnPill
        let breathe = live && (style == .glow || style == .outline) ? pulse(t, 2.6) : 0
        HStack(spacing: 0) {
            Text(status.label)
            if live && style == .ellipsis {
                // Fixed width so the pill never resizes as the dots cycle.
                Text(String(repeating: ".", count: Int(t / 0.45) % 4))
                    .frame(width: 10, alignment: .leading)
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(
            ZStack {
                status.color.opacity(0.16)
                if live && style == .shimmer {
                    LinearGradient(colors: [.clear, status.color.opacity(0.38), .clear],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: 34)
                        .offset(x: (sawtooth(t, 1.8) * 2 - 1) * 60)
                }
            }
        )
        .foregroundColor(status.color)
        .clipShape(Capsule())
        .overlay(
            Capsule().stroke(status.color.opacity(style == .outline ? 0.15 + breathe * 0.65 : 0),
                             lineWidth: 1)
        )
        .shadow(color: status.color.opacity(style == .glow ? 0.15 + breathe * 0.45 : 0),
                radius: style == .glow ? 3 + breathe * 5 : 0)
    }
}

struct ChatRowView: View {
    let window: WindowRow
    let chat: Chat
    let onOpen: () -> Void
    @ObservedObject private var settings = Settings.shared
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(status: chat.status, style: settings.style(for: chat.status))
            VStack(alignment: .leading, spacing: 2) {
                Text(chat.title).font(.system(size: 13))
                    .lineLimit(1)
                Text(chat.basis)
                    .font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(relativeText(chat.eventTs))
                .font(.system(size: 10)).foregroundColor(.secondary)
                .help(absoluteText(chat.eventTs))
            if chat.tabIndex == nil {
                Image(systemName: "questionmark.circle")
                    .foregroundColor(.secondary).font(.system(size: 10))
                    .help("No tab could be matched to this chat")
            }
            StatusPill(status: chat.status, style: settings.style(for: chat.status))
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(hovering ? Color.primary.opacity(0.06) : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onOpen)
    }
}

struct ContentView: View {
    @StateObject private var collector = Collector()
    @ObservedObject private var settings = Settings.shared
    @State private var timer: Timer?
    @State private var showSettings = false

    private var attention: Int {
        collector.windows.flatMap(\.chats).filter(\.status.needsAttention).count
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if collector.bridgeMissing {
                notice("ClaudeDeck bridge extension is not reporting. Windows and chats cannot be listed.",
                       systemImage: "puzzlepiece.extension", color: .orange)
            }
            if !collector.axTrusted {
                notice("Accessibility not granted — clicking a row cannot raise the VS Code window.",
                       systemImage: "lock", color: .orange)
            }
            if collector.isEditing {
                editList
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(collector.windows) { w in windowSection(w) }
                    }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 380)
        .onAppear {
            Notifier.shared.onOpen = { sid in collector.openBySession(sid) }
            collector.refresh()
            timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
                guard !collector.isEditing else { return }
                collector.refresh()
            }
        }
        .onDisappear { timer?.invalidate() }
    }

    private var header: some View {
        HStack {
            Text(collector.isEditing ? "Editing order" : "ClaudeDeck")
                .font(.system(size: 14, weight: .semibold))
            if attention > 0 && !collector.isEditing {
                Text("\(attention) waiting on you")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.orange.opacity(0.18))
                    .foregroundColor(.orange).clipShape(Capsule())
            }
            Spacer()
            if collector.isEditing {
                Button("Done") { collector.isEditing = false; collector.refresh() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            } else {
                Text(collector.lastRefresh, style: .time)
                    .font(.system(size: 10)).foregroundColor(.secondary)
                Button { collector.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                Button { showSettings.toggle() } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless)
                    .popover(isPresented: $showSettings, arrowEdge: .bottom) { settingsPopover }
                if collector.windows.count > 1 {
                    Button("Edit") { collector.isEditing = true }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    // MARK: Edit mode
    //
    // Only the windows, one uniform row each. Collapsing the chats keeps the
    // drop maths honest — a row height that varies with chat count would make
    // "how many rows have I moved past" unanswerable — and it puts the thing
    // being reordered on its own, which is the point of a mode.

    private static let editRowHeight: CGFloat = 40

    private var editList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(collector.windows.enumerated()), id: \.element.id) { index, w in
                    editRow(w, index: index)
                        .zIndex(collector.dragIndex == index ? 1 : 0)
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// How far a row is pushed aside by the one being dragged over it, so the
    /// list previews the result rather than rearranging only on release.
    private func shift(for index: Int) -> CGFloat {
        guard let dragIndex = collector.dragIndex, dragIndex != index else { return 0 }
        let target = dropTarget(from: dragIndex, offset: collector.dragOffset)
        if dragIndex < index && index <= target { return -ContentView.editRowHeight }
        if target <= index && index < dragIndex { return ContentView.editRowHeight }
        return 0
    }

    private func dropTarget(from index: Int, offset: CGFloat) -> Int {
        let steps = Int((offset / ContentView.editRowHeight).rounded())
        return min(max(index + steps, 0), max(collector.windows.count - 1, 0))
    }

    private func dragGesture(index: Int) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                collector.dragIndex = index
                collector.dragOffset = value.translation.height
            }
            .onEnded { value in
                let target = dropTarget(from: index, offset: value.translation.height)
                collector.dragIndex = nil
                collector.dragOffset = 0
                if target != index { collector.moveWindow(from: index, to: target) }
            }
    }

    private func editRow(_ w: WindowRow, index: Int) -> some View {
        let isDragging = collector.dragIndex == index
        return HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 14)
            Text("\(index + 1)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary).frame(width: 18, alignment: .trailing)
            Image(systemName: "macwindow").font(.system(size: 11)).foregroundColor(.secondary)
            Text(w.name).font(.system(size: 12, weight: .semibold))
            Text(w.folders.first.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "")
                .font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
            Spacer(minLength: 8)
            Text("\(w.chats.count) chat\(w.chats.count == 1 ? "" : "s")")
                .font(.system(size: 10)).foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(height: ContentView.editRowHeight)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(isDragging ? 0.10 : 0.04))
                .padding(.horizontal, 6).padding(.vertical, 2)
        )
        .shadow(color: .black.opacity(isDragging ? 0.20 : 0), radius: 6, y: 3)
        .offset(y: isDragging ? collector.dragOffset : shift(for: index))
        .animation(.easeOut(duration: 0.12), value: collector.dragOffset)
        .contentShape(Rectangle())
        .gesture(dragGesture(index: index))
    }

    /// One row per status, each with its own treatment. Every row previews the
    /// choice live, so it is picked by watching rather than by reading a name.
    private var settingsPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Appearance").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("Reset") { settings.resetToDefaults() }
                    .buttonStyle(.borderless).controlSize(.small)
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 4)

            Text("Each status can animate differently. Only Running moves by default.")
                .font(.system(size: 10)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14).padding(.bottom, 8)

            Toggle(isOn: Binding(get: { settings.playSound },
                                 set: { settings.playSound = $0 })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Play sound").font(.system(size: 11))
                    Text("Turn off only if Claude Notify's hooks are running too — both play the same file and you would hear it twice.")
                        .font(.system(size: 9)).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(.horizontal, 14).padding(.bottom, 10)

            Divider()

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Status.allCases, id: \.rawValue) { st in
                        HStack(spacing: 10) {
                            StatusDot(status: st, style: settings.style(for: st))
                            StatusPill(status: st, style: settings.style(for: st))
                                .frame(width: 96, alignment: .leading)
                            Spacer(minLength: 6)
                            Picker("", selection: Binding(
                                get: { settings.style(for: st) },
                                set: { settings.set($0, for: st) }
                            )) {
                                ForEach(PillStyle.allCases) { style in
                                    Text(style.label).tag(style)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 150)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        Divider().opacity(0.4)
                    }
                }
            }
            .frame(maxHeight: 340)

            Text(PillStyle.allCases.filter { $0 != .still }
                .map(\.label).joined(separator: " · "))
                .font(.system(size: 9)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .frame(width: 430)
    }

    private func notice(_ text: String, systemImage: String, color: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage).foregroundColor(color)
            Text(text).font(.system(size: 11)).foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(color.opacity(0.08))
    }

    private func windowSection(_ w: WindowRow) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: w.focused ? "macwindow.badge.plus" : "macwindow")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                Text(w.name).font(.system(size: 12, weight: .semibold))
                Text(w.folders.first.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "")
                    .font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
                Spacer()
                let newest = w.chats.map(\.eventTs).max() ?? 0
                Text(relativeText(newest))
                    .font(.system(size: 10)).foregroundColor(.secondary)
                    .help(absoluteText(newest))
                Text("\(w.chats.count)").font(.system(size: 10)).foregroundColor(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color.primary.opacity(0.04))
            .contentShape(Rectangle())
            .onTapGesture { Focus.go(window: w, chat: nil) }
            .contextMenu {
                Button("Move Up") { collector.nudge(w, by: -1) }
                Button("Move Down") { collector.nudge(w, by: 1) }
            }

            if w.chats.isEmpty {
                Text("No Claude chats open in this window")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 8)
            } else {
                ForEach(w.chats) { c in
                    ChatRowView(window: w, chat: c) {
                        // Opening a chat is how you see it; a New result
                        // becomes plain Finished from here on.
                        collector.markSeen(c)
                        Focus.go(window: w, chat: c)
                    }
                }
            }
        }
    }
}

// MARK: - Validation
//
// Claude Notify ships hooks/validate.js, which replays real transcripts through
// the shipped scanner rather than a copy of it. This is the same idea: it calls
// the same `parseTranscript` the app uses, so a rule cannot pass here and fail
// in the app.
//
// Every case is a bug that actually shipped.

enum Validate {
    static func run(surveyAll: Bool) -> Int32 {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let casesURL = root.appendingPathComponent("tests/cases.json")
        guard let d = try? Data(contentsOf: casesURL),
              let cases = (try? JSONSerialization.jsonObject(with: d)) as? [String: [String: Any]]
        else {
            print("cannot read tests/cases.json — run from the repo root")
            return 2
        }

        let collector = Collector()
        var failures = 0
        let names = cases.keys.sorted()
        for name in names {
            let expect = cases[name]!
            let path = root.appendingPathComponent("tests/fixtures/\(name).jsonl").path
            guard let info = collector.parseTranscript(path, mtime: Date().timeIntervalSince1970) else {
                print("FAIL \(name): transcript did not parse")
                failures += 1
                continue
            }
            var problems: [String] = []
            if let want = expect["derived"] as? String, info.derived.rawValue != want {
                problems.append("derived=\(info.derived.rawValue) want \(want)")
            }
            if let want = expect["awaiting"] as? Bool, info.awaitingAssistant != want {
                problems.append("awaiting=\(info.awaitingAssistant) want \(want)")
            }
            if let want = expect["title"] as? String, !info.aiTitles.contains(want) {
                problems.append("titles=\(info.aiTitles.sorted()) missing \(want)")
            }
            if let want = expect["activity"] as? String {
                let f = ISO8601DateFormatter()
                f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let t = f.date(from: want)?.timeIntervalSince1970,
                   abs(info.activityTs - t) > 1 {
                    problems.append("activityTs is not the last message time")
                }
            }
            if problems.isEmpty {
                print("PASS \(name)  [\(info.derived.rawValue)]")
            } else {
                print("FAIL \(name): \(problems.joined(separator: ", "))")
                failures += 1
            }
        }

        if surveyAll { survey(collector) }

        print("\n\(names.count - failures)/\(names.count) passed")
        return failures == 0 ? 0 : 1
    }

    /// Replay every real transcript on this machine. Not pass/fail — a
    /// distribution, so an implausible one (everything Unknown, say) shows up.
    private static func survey(_ collector: Collector) {
        print("\n--- survey of real transcripts ---")
        var counts: [String: Int] = [:]
        var scanned = 0
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        for dir in (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? [] {
            for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            where f.pathExtension == "jsonl" {
                let m = ((try? FileManager.default.attributesOfItem(atPath: f.path)[.modificationDate]) as? Date
                    ?? .distantPast).timeIntervalSince1970
                guard let info = collector.parseTranscript(f.path, mtime: m) else { continue }
                counts[info.derived.rawValue, default: 0] += 1
                scanned += 1
            }
        }
        for (k, v) in counts.sorted(by: { $0.value > $1.value }) {
            print(String(format: "  %-12s %4d", (k as NSString).utf8String!, v))
        }
        print("  scanned \(scanned)")
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        if CommandLine.arguments.contains("--validate") {
            exit(Validate.run(surveyAll: CommandLine.arguments.contains("--survey")))
        }
        if CommandLine.arguments.contains("--check") {
            runCheck()
            return
        }
        if CommandLine.arguments.contains("--test-banner") {
            runBannerTest()
            return
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        Notifier.shared.start()
    }

    // Closing the window must not quit: the badge and the banners are the
    // point of leaving it running.
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }

    /// Says where the permissions actually stand, rather than leaving a silent
    /// notification failure to be guessed at.
    private func runCheck() {
        NSApp.setActivationPolicy(.accessory)
        let center = UNUserNotificationCenter.current()
        print("bundle id:      \(Bundle.main.bundleIdentifier ?? "nil")")
        print("accessibility:  \(AXIsProcessTrusted() ? "TRUSTED" : "NOT trusted")")
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            print("requestAuth:    granted=\(granted) error=\(error.map { String(describing: $0) } ?? "none")")
            center.getNotificationSettings { s in
                print("authorisation:  \(s.authorizationStatus.rawValue) (2 = authorised)")
                print("alert style:    \(s.alertStyle.rawValue)")
                print("badge setting:  \(s.badgeSetting.rawValue)")
                exit(0)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            print("timed out waiting for the notification centre")
            exit(1)
        }
    }

    /// Posts one banner and sets the Dock badge, so the notification path can
    /// be exercised without waiting for a real chat to finish.
    private func runBannerTest() {
        NSApp.setActivationPolicy(.regular)
        let center = UNUserNotificationCenter.current()
        center.delegate = Notifier.shared
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { print("not authorised"); exit(1) }
            let c = UNMutableNotificationContent()
            c.title = "ClaudeDeck | ✅ Finished"
            c.body = "Test banner — notification path check"
            c.sound = .default
            c.threadIdentifier = "ClaudeDeck"
            let r = UNNotificationRequest(identifier: "claudedeck-test", content: c, trigger: nil)
            center.add(r) { err in
                print("add error: \(err.map { String(describing: $0) } ?? "none")")
                DispatchQueue.main.async { NSApp.dockTile.badgeLabel = "3" }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    center.getDeliveredNotifications { delivered in
                        let ids = delivered.map(\.request.identifier)
                        print("delivered: \(ids)")
                        print("badge set to: \(NSApp.dockTile.badgeLabel ?? "nil")")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { exit(0) }
                    }
                }
            }
        }
    }

    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { s.windows.first?.makeKeyAndOrderFront(nil) }
        return true
    }
}

@main
struct ClaudeDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup("ClaudeDeck") {
            ContentView()
        }
        .defaultSize(width: 620, height: 520)
    }
}
