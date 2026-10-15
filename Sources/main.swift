import AppKit
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) static weak var shared: AppDelegate?

    private(set) var floating: FloatingController!
    private var dock: DockTileController!
    private var dockHelpers: DockHelperManager!
    private var status: StatusMenuController!
    private var prefsObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        applyActivationPolicy()
        applyProgressBar()
        SessionStore.shared.start()
        Sounds.shared.start()
        SessionLookStore.shared.start { SessionStore.shared.sessions.compactMap(\.record.pid) }
        floating = FloatingController()
        dock = DockTileController {
            let store = SessionStore.shared
            let now = Date().timeIntervalSince1970
            let waiting = store.waitingCount
            let leader = store.leading(at: now)
            return (leader?.mood(at: now) ?? .sleepy, waiting > 0 ? "\(waiting)" : nil, leader?.look.color)
        }
        dockHelpers = DockHelperManager()
        status = StatusMenuController()

        // objectWillChange fires before the new value is stored
        prefsObserver = Prefs.shared.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.applyPrefs() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        dockHelpers.terminateAll()
    }

    private func applyPrefs() {
        applyActivationPolicy()
        applyProgressBar()
        floating.apply()
        dockHelpers.sync()
    }

    /// The hook reads this flag: no file, no tab progress bar
    private func applyProgressBar() {
        let flag = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/eyes/progress-disabled")
        if Prefs.shared.progressBar {
            try? FileManager.default.removeItem(at: flag)
        } else {
            try? FileManager.default.createDirectory(at: flag.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: flag.path, contents: nil)
        }
    }

    /// The main icon is hidden when each session has its own
    private func applyActivationPolicy() {
        let prefs = Prefs.shared
        let policy: NSApplication.ActivationPolicy = prefs.showDockIcon && !prefs.dockPerSession ? .regular : .accessory
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }

    // Clicking the Dock icon shows or hides the floating eyes
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Prefs.shared.showFloating.toggle()
        return false
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        MenuFactory.fill(menu, includeQuit: false)
        return menu
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

func argument(after flag: String) -> String? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

// Build-time helpers: render the app icon, a still gallery of every expression or the sounds
if let dir = argument(after: "--render-iconset") {
    Snapshot.writeIconset(to: dir)
    exit(0)
}
if let path = argument(after: "--render-gallery") {
    Snapshot.writeGallery(to: path)
    exit(0)
}
if let path = argument(after: "--render-color-tiles") {
    Snapshot.writeColorTiles(to: path)
    exit(0)
}
if let dir = argument(after: "--render-sounds") {
    Sounds.write(to: dir)
    exit(0)
}

let app = NSApplication.shared
let delegate: NSApplicationDelegate
if let sessionId = argument(after: "--dock-session") {
    // Per-session Dock icon helper
    delegate = SessionDockDelegate(sessionId: sessionId, parentPid: pid_t(argument(after: "--parent") ?? "") ?? 0)
} else {
    delegate = AppDelegate()
}
app.delegate = delegate
app.run()
