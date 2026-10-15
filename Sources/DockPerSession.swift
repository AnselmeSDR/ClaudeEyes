import AppKit
import QuartzCore

/// Notification a session's Dock icon sends to the main app to focus its terminal.
/// The main app does the AppleScript call, so the terminal permission is asked only once.
let focusRequestNotification = Notification.Name("com.anselme.claude-eyes.focus")

// MARK: - Main app side

/// "One Dock icon per session": each session runs in its own small process, launched from a
/// copy of this app named after the session, so that hovering the Dock shows its /rename title
final class DockHelperManager {
    private var launched: [String: (app: NSRunningApplication, title: String)] = [:]
    private var pending: Set<String> = []
    private var dismissed: Set<String> = []
    private var timer: Timer?

    init() {
        // Helpers of a previous run are gone (they quit with the main app): drop their bundles
        DockHelperBundle.removeAll()

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.sync() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        DistributedNotificationCenter.default().addObserver(forName: focusRequestNotification, object: nil, queue: .main) { note in
            guard let id = note.object as? String,
                  let session = SessionStore.shared.sessions.first(where: { $0.id == id }) else { return }
            TerminalFocus.focus(session)
        }
    }

    private var isEnabled: Bool { Prefs.shared.showDockIcon && Prefs.shared.dockPerSession }

    func sync() {
        // Wait for the /rename titles, otherwise every icon would be relaunched once they arrive
        guard SessionLookStore.shared.isReady else { return }
        let sessions = SessionStore.shared.sessions
        let liveIds = Set(sessions.map(\.id))

        for (id, entry) in launched where entry.app.isTerminated {
            launched[id] = nil
            // Quit from its Dock menu while the session still runs: don't bring it back
            if isEnabled, liveIds.contains(id) { dismissed.insert(id) }
        }
        dismissed.formIntersection(liveIds)

        guard isEnabled else {
            terminateAll()
            return
        }
        for (id, entry) in launched {
            // Gone, or renamed: the Dock name comes from the bundle, so relaunch under the new one
            let title = sessions.first { $0.id == id }?.displayTitle
            if title != entry.title {
                entry.app.terminate()
                launched[id] = nil
            }
        }
        for session in sessions where launched[session.id] == nil && !pending.contains(session.id) && !dismissed.contains(session.id) {
            launch(session)
        }
    }

    func terminateAll() {
        launched.values.forEach { $0.app.terminate() }
        launched = [:]
    }

    private func launch(_ session: Session) {
        let id = session.id
        let title = session.displayTitle
        pending.insert(id)

        // Building a helper bundle copies and signs the binary: keep it off the main thread
        DispatchQueue.global(qos: .utility).async {
            guard let url = try? DockHelperBundle.url(for: title) else {
                DispatchQueue.main.async { self.pending.remove(id) }
                return
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            configuration.activates = false
            configuration.addsToRecentItems = false
            configuration.arguments = ["--dock-session", id, "--parent", "\(getpid())"]
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, _ in
                DispatchQueue.main.async {
                    self.pending.remove(id)
                    if let app { self.launched[id] = (app, title) }
                }
            }
        }
    }
}

/// Copies of the app named after each session, in ~/Library/Application Support/Claude Eyes/Docks
enum DockHelperBundle {
    private static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Claude Eyes/Docks")
    }

    static func removeAll() {
        try? FileManager.default.removeItem(at: root)
    }

    static func url(for project: String) throws -> URL {
        let fm = FileManager.default
        let name = sanitized(project)
        let app = root.appendingPathComponent("\(name).app")
        let executable = app.appendingPathComponent("Contents/MacOS/ClaudeEyes")
        guard let mainExecutable = Bundle.main.executableURL else { throw CocoaError(.fileNoSuchFile) }

        // Up to date when built after the current binary
        if let built = modificationDate(executable), let source = modificationDate(mainExecutable), built >= source {
            return app
        }

        try? fm.removeItem(at: app)
        let resources = app.appendingPathComponent("Contents/Resources")
        try fm.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)
        try fm.copyItem(at: mainExecutable, to: executable)
        if let icon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") {
            try? fm.copyItem(at: icon, to: resources.appendingPathComponent("AppIcon.icns"))
        }

        let identifier = name.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" }
        let info: [String: Any] = [
            "CFBundleName": project,
            "CFBundleDisplayName": project,
            "CFBundleIdentifier": "com.anselme.claude-eyes.dock.\(identifier.isEmpty ? "session" : identifier)",
            "CFBundleExecutable": "ClaudeEyes",
            "CFBundleIconFile": "AppIcon",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "LSMinimumSystemVersion": "14.0",
            "NSHighResolutionCapable": true,
        ]
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: app.appendingPathComponent("Contents/Info.plist"))

        // The copied binary still carries the main app's signature: re-sign for this bundle
        let codesign = Process()
        codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        codesign.arguments = ["--force", "--sign", "-", app.path]
        codesign.standardOutput = FileHandle.nullDevice
        codesign.standardError = FileHandle.nullDevice
        try codesign.run()
        codesign.waitUntilExit()

        return app
    }

    private static func sanitized(_ project: String) -> String {
        let cleaned = project.map { $0.isLetter || $0.isNumber || " ._-".contains($0) ? $0 : "-" }
        let name = String(cleaned).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Claude" : name
    }

    private static func modificationDate(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}

// MARK: - Helper side

/// Runs inside a per-session helper: one animated Dock icon for one session.
/// Quits when the session or the main app goes away.
final class SessionDockDelegate: NSObject, NSApplicationDelegate {
    private let sessionId: String
    private let parentPid: pid_t
    private var dock: DockTileController!
    private var watchdog: Timer?
    private var missingSince: Double?

    init(sessionId: String, parentPid: pid_t) {
        self.sessionId = sessionId
        self.parentPid = parentPid
    }

    private var session: Session? {
        SessionStore.shared.sessions.first { $0.id == sessionId }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // Watch only this session's claude process
        let pid = Int32(sessionId.replacingOccurrences(of: "pid-", with: ""))
        SessionStore.shared.start(trackingPid: pid)
        SessionLookStore.shared.start { pid.map { [$0] } ?? [] }
        dock = DockTileController { [weak self] in
            let now = Date().timeIntervalSince1970
            guard let session = self?.session else { return (.sleepy, nil, nil) }
            return (session.mood(at: now), session.state == .waiting ? "!" : nil, session.look.color)
        }

        let watchdog = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.checkAlive() }
        RunLoop.main.add(watchdog, forMode: .common)
        self.watchdog = watchdog
    }

    private func checkAlive() {
        guard kill(parentPid, 0) == 0 || errno == EPERM else {
            NSApp.terminate(nil)
            return
        }
        let now = Date().timeIntervalSince1970
        if session != nil {
            missingSince = nil
        } else if let since = missingSince {
            if now - since > 3 { NSApp.terminate(nil) }
        } else {
            missingSince = now
        }
    }

    // Clicking the Dock icon opens the session's terminal
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        requestFocus()
        return false
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        if let session {
            let status = NSMenuItem(title: "\(session.displayTitle) : \(session.statusText(at: Date().timeIntervalSince1970))",
                                    action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
        }
        let open = NSMenuItem(title: "Ouvrir le terminal", action: #selector(openTerminal(_:)), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        // The main app plays the sounds and reads this setting from the shared defaults
        let sound = NSMenuItem(title: "Son pour cette session", action: #selector(toggleSound(_:)), keyEquivalent: "")
        sound.state = Prefs.shared.isSoundOn(for: sessionId) ? .on : .off
        sound.target = self
        menu.addItem(sound)
        return menu
    }

    @objc private func openTerminal(_ sender: Any?) {
        requestFocus()
    }

    @objc private func toggleSound(_ sender: NSMenuItem) {
        Prefs.shared.setSound(sender.state != .on, for: sessionId)
    }

    private func requestFocus() {
        DistributedNotificationCenter.default().postNotificationName(focusRequestNotification, object: sessionId,
                                                                     userInfo: nil, deliverImmediately: true)
    }
}
