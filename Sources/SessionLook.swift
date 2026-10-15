import AppKit

/// Colors offered by Claude Code's /color, with the RGB values of its dark theme
enum SessionColor: String, CaseIterable {
    case red, blue, green, yellow, purple, orange, pink, cyan

    var components: (r: CGFloat, g: CGFloat, b: CGFloat) {
        switch self {
        case .red: return (220, 38, 38)
        case .blue: return (106, 155, 204)
        case .green: return (22, 163, 74)
        case .yellow: return (202, 138, 4)
        case .purple: return (130, 125, 189)
        case .orange: return (217, 119, 87)
        case .pink: return (196, 102, 134)
        case .cyan: return (8, 145, 178)
        }
    }

    /// Light variant of the same palette in Claude Code, bright enough to glow on a dark background
    var eyeComponents: (r: CGFloat, g: CGFloat, b: CGFloat) {
        switch self {
        case .red: return (1, 0.4, 0.4)
        case .blue: return (0.4, 0.7, 1)
        case .green: return (0.4, 1, 0.4)
        case .yellow: return (1, 1, 0.4)
        case .purple: return (0.7, 0.4, 1)
        case .orange: return (1, 0.7, 0.4)
        case .pink: return (1, 0.6, 0.8)
        case .cyan: return (0.4, 0.8, 0.8)
        }
    }
}

/// What the user chose for a session: name from /rename, color from /color
struct SessionLook: Equatable {
    var title: String?
    var color: SessionColor?
}

/// Reads session looks from Claude Code's own files:
/// - ~/.claude/sessions/<pid>.json: live registry with the session name (`nameSource` is "user" after /rename)
/// - the session transcript: `custom-title` and `agent-color` entries, scanned incrementally
final class SessionLookStore {
    static let shared = SessionLookStore()

    private(set) var looks: [Int32: SessionLook] = [:]
    /// True once the first refresh is done
    private(set) var isReady = false

    private let home = FileManager.default.homeDirectoryForCurrentUser
    private let queue = DispatchQueue(label: "claude-eyes.looks", qos: .utility)
    private var scans: [String: TranscriptScan] = [:]        // by session id, queue only
    private var timer: Timer?
    private var refreshing = false

    func start(pids: @escaping () -> [Int32]) {
        refresh(pids())
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.refresh(pids()) }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func look(pid: Int32?) -> SessionLook {
        guard let pid else { return SessionLook() }
        return looks[pid] ?? SessionLook()
    }

    private func refresh(_ pids: [Int32]) {
        guard !refreshing else { return }
        refreshing = true
        queue.async {
            var result: [Int32: SessionLook] = [:]
            var activeSessions = Set<String>()
            for pid in pids {
                guard let entry = self.registryEntry(pid: pid) else { continue }
                activeSessions.insert(entry.sessionId)
                var look = SessionLook()
                if entry.nameSource != "derived", let name = entry.name, !name.isEmpty {
                    look.title = name
                }
                if let scan = self.scan(sessionId: entry.sessionId) {
                    scan.update()
                    look.title = look.title ?? scan.title
                    look.color = scan.color
                }
                result[pid] = look
            }
            self.scans = self.scans.filter { activeSessions.contains($0.key) }

            DispatchQueue.main.async {
                self.looks = result
                self.refreshing = false
                self.isReady = true
            }
        }
    }

    private struct RegistryEntry: Decodable {
        let sessionId: String
        let name: String?
        let nameSource: String?
    }

    private func registryEntry(pid: Int32) -> RegistryEntry? {
        let url = home.appendingPathComponent(".claude/sessions/\(pid).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RegistryEntry.self, from: data)
    }

    private func scan(sessionId: String) -> TranscriptScan? {
        if let scan = scans[sessionId] { return scan }
        // Transcripts live in ~/.claude/projects/<encoded cwd>/<session id>.jsonl
        let projects = home.appendingPathComponent(".claude/projects")
        let dirs = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        for dir in dirs {
            let url = dir.appendingPathComponent("\(sessionId).jsonl")
            if FileManager.default.fileExists(atPath: url.path) {
                let scan = TranscriptScan(url: url)
                scans[sessionId] = scan
                return scan
            }
        }
        return nil
    }
}

/// Follows a transcript as it grows: only new bytes are read after the first pass
final class TranscriptScan {
    let url: URL
    private(set) var title: String?
    private(set) var color: SessionColor?
    private var offset: UInt64 = 0

    private static let titleMarker = Data(#""type":"custom-title""#.utf8)
    private static let colorMarker = Data(#""type":"agent-color""#.utf8)

    init(url: URL) {
        self.url = url
    }

    func update() {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return }
        if size < offset {
            // Rewritten transcript: start over
            offset = 0
            title = nil
            color = nil
        }
        guard size > offset, (try? handle.seek(toOffset: offset)) != nil else { return }

        var pending = Data()
        while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            pending.append(chunk)
            // Only complete lines: a line being written is read again next time
            guard let lastNewline = pending.lastIndex(of: 0x0A) else { continue }
            let complete = pending[pending.startIndex...lastNewline]
            parse(complete)
            offset += UInt64(complete.count)
            pending = Data(pending[(lastNewline + 1)...])
        }
    }

    private func parse(_ data: Data) {
        for line in data.split(separator: 0x0A) {
            // Title and color entries are short: skip message lines quickly
            guard line.count < 4096 else { continue }
            let isTitle = line.range(of: Self.titleMarker) != nil
            let isColor = !isTitle && line.range(of: Self.colorMarker) != nil
            guard isTitle || isColor,
                  let entry = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if isTitle, let value = entry["customTitle"] as? String {
                title = value.isEmpty ? nil : value
            }
            if isColor {
                color = (entry["agentColor"] as? String).flatMap(SessionColor.init(rawValue:))
            }
        }
    }
}

extension Session {
    var look: SessionLook { SessionLookStore.shared.look(pid: record.pid) }

    /// Name given with /rename, otherwise the project folder
    var displayTitle: String { look.title ?? project }
}
