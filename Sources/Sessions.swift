import Foundation

/// Category written by the hook (~/.claude/hooks/claude-state.sh)
enum SessionState: String {
    case idle, working, toolError, waiting, done, failed
}

struct SessionRecord: Decodable, Equatable {
    let sessionId: String
    let cwd: String?
    let pid: Int32?
    let tty: String?
    let state: String
    let event: String?
    let tool: String?
    let command: String?
    let signal: String?
    let terminalApp: String?   // bundle id of the app the hook ran in (__CFBundleIdentifier)
    let at: Double
    let stateSince: Double?
}

extension SessionRecord {
    /// Placeholder for a running claude process that has not triggered any hook yet
    init(process: ClaudeProcess) {
        sessionId = "pid-\(process.pid)"
        cwd = process.cwd
        pid = process.pid
        tty = process.tty
        state = SessionState.idle.rawValue
        event = nil
        tool = nil
        command = nil
        signal = nil
        terminalApp = nil
        at = process.startedAt
        stateSince = process.startedAt
    }
}

/// Claude Code's own live status, from its registry ~/.claude/sessions/<pid>.json
struct LiveStatus: Decodable, Equatable {
    let status: String?             // busy | idle | waiting
    let waitingFor: String?         // "permission prompt", "input needed", "dialog open"…
    let statusUpdatedAt: Double?    // milliseconds

    /// "dialog open" is a dialog the user opened (/config, /model…), not Claude waiting
    var isWaitingForUser: Bool { status == "waiting" && waitingFor != "dialog open" }
}

struct Session: Identifiable, Equatable {
    let record: SessionRecord
    var live: LiveStatus?

    /// Keyed by process so a session keeps its face when its first hook arrives or after /clear
    var id: String {
        if let pid = record.pid, pid > 0 { return "pid-\(pid)" }
        return record.sessionId
    }

    /// The hook state, corrected by Claude Code's live status. It knows when a dialog waits for you,
    /// while hooks keep firing for subagents and parallel tools, and when you answered it (no hook fires then).
    var state: SessionState {
        let hookState = SessionState(rawValue: record.state) ?? .idle
        guard let live, let status = live.status else { return hookState }
        if live.isWaitingForUser { return .waiting }
        // Answered after the hook's last event (hook times are whole seconds)
        if hookState == .waiting, let updatedAt = live.statusUpdatedAt, floor(updatedAt / 1000) > record.at {
            return status == "busy" ? .working : .idle
        }
        return hookState
    }

    var project: String {
        guard let cwd = record.cwd, !cwd.isEmpty else { return "Claude" }
        return (cwd as NSString).lastPathComponent
    }

    private static let exploreTools: Set<String> = [
        "Read", "Grep", "Glob", "LS", "WebSearch", "WebFetch", "ToolSearch", "NotebookRead", "Skill",
        "ListMcpResourcesTool", "ReadMcpResourceTool",
    ]
    private static let writeTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]
    private static let agentTools: Set<String> = ["Agent", "Task", "Workflow", "SendMessage"]
    private static let checkPattern = try! NSRegularExpression(
        pattern: #"\b(test|tests|phpunit|pest|jest|vitest|pytest|rspec|phpstan|eslint|tsc|lint)\b"#,
        options: [.caseInsensitive])

    private var isCheckCommand: Bool {
        guard let command = record.command else { return false }
        return Self.checkPattern.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)) != nil
    }

    func mood(at now: Double) -> Mood {
        let prefs = Prefs.shared
        let age = now - record.at
        let sleepAfter = prefs.sleepAfterMinutes * 60

        switch state {
        case .waiting:
            return .waiting
        case .failed:
            return .failed
        case .toolError:
            if age < 6 { return record.event == "PermissionDenied" ? .annoyed : .sad }
            return .thinking
        case .done:
            if age < prefs.doneDuration { return .happy }
            return age > sleepAfter ? .sleepy : .neutral
        case .idle:
            return age > sleepAfter ? .sleepy : .neutral
        case .working:
            return workingMood(age: age)
        }
    }

    private func workingMood(age: Double) -> Mood {
        // Short reactions to what the last tool output revealed
        if record.event == "PostToolUse", age < 4 {
            switch record.signal {
            case "testsFailed", "errorOutput": return .sad
            case "testsPassed": return .happy
            case "bigEdit": return .surprised
            default: break
            }
        }
        if age > 12 { return .thinking }

        switch record.event {
        case "UserPromptSubmit":
            return age < 3 ? .attentive : .thinking
        case "PreCompact":
            return .tired
        case "SubagentStart":
            return .focused
        case "PreToolUse":
            let tool = record.tool ?? ""
            if Self.exploreTools.contains(tool) || tool.hasPrefix("mcp__") { return .curious }
            if Self.writeTools.contains(tool) || Self.agentTools.contains(tool) { return .focused }
            if tool == "Bash" { return isCheckCommand ? .nervous : .focused }
            return .focused
        default:
            return .thinking
        }
    }

    /// Higher wins when several sessions compete for the Dock icon
    func priority(at now: Double) -> Int {
        switch state {
        case .waiting: return 5
        case .failed: return 4
        case .working, .toolError: return 3
        case .done: return now - record.at < Prefs.shared.doneDuration ? 2 : 1
        case .idle: return 1
        }
    }

    func statusText(at now: Double) -> String {
        let mood = mood(at: now)
        switch state {
        case .waiting:
            if live?.waitingFor == "input needed" { return "te pose une question" }
            switch record.tool {
            case "AskUserQuestion" where record.event == "PreToolUse": return "te pose une question"
            case "ExitPlanMode" where record.event == "PreToolUse": return "attend ta validation"
            default: return "attend ta permission"
            }
        case .failed:
            return "erreur d'API"
        case .toolError:
            return mood == .annoyed ? "action refusée" : "un outil a échoué"
        case .done, .idle:
            switch mood {
            case .happy: return "terminé"
            case .sleepy: return "endormi"
            default: return "en attente"
            }
        case .working:
            switch mood {
            case .attentive: return "lit ta demande"
            case .curious:
                return ["WebSearch", "WebFetch"].contains(record.tool ?? "") ? "cherche sur le web" : "explore le code"
            case .focused:
                switch record.tool {
                case "Bash": return "lance une commande"
                case let tool? where Self.agentTools.contains(tool): return "délègue à un agent"
                case nil where record.event == "SubagentStart": return "délègue à un agent"
                default: return "écrit du code"
                }
            case .nervous: return "lance les vérifications"
            case .happy: return "tests réussis"
            case .sad: return record.signal == "testsFailed" ? "tests en échec" : "erreur dans la sortie"
            case .surprised: return "grosse modification"
            case .tired: return "compacte la conversation"
            default: return "réfléchit"
            }
        }
    }
}

/// Watches ~/.claude/eyes/sessions, one JSON file per Claude Code session
final class SessionStore: ObservableObject {
    static let shared = SessionStore()

    @Published private(set) var sessions: [Session] = []

    let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/eyes/sessions")
    private let registryDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions")
    private var cache: [String: (mtime: Date, session: Session)] = [:]
    private var order: [String] = []
    private var timer: Timer?
    private var watcher: DispatchSourceFileSystemObject?
    private var registryWatchers: [Int32: DispatchSourceFileSystemObject] = [:]
    private var processes: [ClaudeProcess] = []
    /// Set in a per-session Dock helper: only this claude process matters
    private var trackedPid: Int32?

    /// The directory is watched for hook writes; a slow timer covers what produces no file event:
    /// dead processes and claude sessions that never triggered a hook
    func start(trackingPid: Int32? = nil) {
        trackedPid = trackingPid
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        scanProcesses()
        reload()
        watchDirectory()

        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            self?.scanProcesses()
            self?.reload()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func watchDirectory() {
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        // The hook writes a temp file then renames it: both modify the directory
        let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        watcher.setEventHandler { [weak self] in self?.reload() }
        watcher.setCancelHandler { close(fd) }
        watcher.resume()
        self.watcher = watcher
    }

    private func scanProcesses() {
        if let pid = trackedPid {
            processes = ClaudeProcess(pid: pid).map { [$0] } ?? []
        } else {
            processes = ClaudeProcess.running()
        }
    }

    func reload() {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
                                                 options: [.skipsHiddenFiles])) ?? []
        let now = Date().timeIntervalSince1970
        var live: [String: Session] = [:]
        let fileIds = Set(files.map { $0.deletingPathExtension().lastPathComponent })
        cache = cache.filter { fileIds.contains($0.key) }

        for file in files where file.pathExtension == "json" {
            let fileId = file.deletingPathExtension().lastPathComponent
            let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast

            let session: Session
            if let cached = cache[fileId], cached.mtime == mtime {
                session = cached.session
            } else {
                guard let data = try? Data(contentsOf: file),
                      let record = try? JSONDecoder().decode(SessionRecord.self, from: data) else { continue }
                session = Session(record: record)
                cache[fileId] = (mtime, session)
            }

            guard Self.isAlive(session, now: now) else {
                try? fm.removeItem(at: file)
                cache[fileId] = nil
                continue
            }
            // After /clear the old file may linger for a moment: keep the freshest one per process
            if let existing = live[session.id], existing.record.at > session.record.at { continue }
            live[session.id] = session
        }

        if let pid = trackedPid {
            live = live.filter { $0.key == "pid-\(pid)" }
        }

        // Claude processes that never triggered a hook (idle since before the app started)
        for process in processes where live["pid-\(process.pid)"] == nil {
            live["pid-\(process.pid)"] = Session(record: SessionRecord(process: process))
        }

        // Keep a stable order: known sessions first, new ones appended by start time
        order = order.filter { live[$0] != nil }
        let newIds = live.keys
            .filter { !order.contains($0) }
            .sorted { (live[$0]?.record.stateSince ?? 0) < (live[$1]?.record.stateSince ?? 0) }
        order += newIds

        var next = order.compactMap { live[$0] }
        for index in next.indices {
            next[index].live = liveStatus(pid: next[index].record.pid)
        }
        watchRegistries(pids: next.compactMap(\.record.pid))
        if next != sessions { sessions = next }
    }

    private func liveStatus(pid: Int32?) -> LiveStatus? {
        guard let pid, pid > 0,
              let data = try? Data(contentsOf: registryDirectory.appendingPathComponent("\(pid).json")) else { return nil }
        return try? JSONDecoder().decode(LiveStatus.self, from: data)
    }

    /// Claude Code rewrites its registry files in place, which the directory watcher does not see
    private func watchRegistries(pids: [Int32]) {
        let wanted = Set(pids)
        for (pid, watcher) in registryWatchers where !wanted.contains(pid) {
            watcher.cancel()
            registryWatchers[pid] = nil
        }
        for pid in wanted where registryWatchers[pid] == nil {
            let fd = open(registryDirectory.appendingPathComponent("\(pid).json").path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main)
            watcher.setEventHandler { [weak self, weak watcher] in
                guard let self, let watcher else { return }
                // Replaced file: watch the new one at the next reload
                if !watcher.data.isDisjoint(with: [.delete, .rename]) {
                    watcher.cancel()
                    self.registryWatchers[pid] = nil
                }
                self.reload()
            }
            watcher.setCancelHandler { close(fd) }
            watcher.resume()
            registryWatchers[pid] = watcher
        }
    }

    private static func isAlive(_ session: Session, now: Double) -> Bool {
        if let pid = session.record.pid, pid > 0 {
            return kill(pid, 0) == 0 || errno == EPERM
        }
        // Unknown process: forget the session after an hour without news
        return now - session.record.at < 3600
    }

    /// The session that matters most right now
    func leading(at now: Double) -> Session? {
        sessions.max { a, b in
            (a.priority(at: now), a.record.at) < (b.priority(at: now), b.record.at)
        }
    }

    var waitingCount: Int { sessions.filter { $0.state == .waiting }.count }
}

/// An interactive `claude` process found in the process table
struct ClaudeProcess {
    let pid: Int32
    let tty: String?
    let cwd: String?
    let startedAt: Double

    static func running() -> [ClaudeProcess] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        return pids.prefix(max(0, count)).compactMap { ClaudeProcess(pid: $0) }
    }

    /// Nil unless pid is an interactive claude process
    init?(pid: pid_t) {
        guard pid > 0 else { return nil }
        var name = [CChar](repeating: 0, count: 256)
        proc_name(pid, &name, UInt32(name.count))
        guard String(cString: name) == "claude" else { return nil }

        var info = proc_bsdinfo()
        let infoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, infoSize) == infoSize else { return nil }
        // Only interactive sessions: skip processes without a terminal (claude -p, scripts)
        guard info.e_tdev != UInt32.max, let device = devname(dev_t(bitPattern: info.e_tdev), S_IFCHR) else { return nil }

        var vnode = proc_vnodepathinfo()
        let vnodeSize = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        if proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnode, vnodeSize) == vnodeSize {
            cwd = withUnsafePointer(to: vnode.pvi_cdir.vip_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
        } else {
            cwd = nil
        }

        self.pid = pid
        tty = "/dev/" + String(cString: device)
        startedAt = Double(info.pbi_start_tvsec)
    }
}
