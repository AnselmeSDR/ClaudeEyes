import AppKit

/// Brings the terminal tab running a Claude session to the front, whatever the terminal app.
/// Ghostty, Terminal, iTerm2 and WezTerm target the exact tab; other apps are just activated.
enum TerminalFocus {
    static func focus(_ session: Session) {
        guard let app = hostApp(of: session) else { return }

        switch app.bundleIdentifier {
        case "com.mitchellh.ghostty":
            GhosttyFocus.focus(session)
        case "com.apple.Terminal":
            focusByTty(session, script: terminalScript, app: app)
        case "com.googlecode.iterm2":
            focusByTty(session, script: itermScript, app: app)
        case "com.github.wez.wezterm":
            focusWezTerm(session, app: app)
        default:
            app.activate()
        }
    }

    /// The terminal app hosting the session: its closest GUI ancestor process, otherwise the app
    /// the hook was started from (tmux sessions are detached from the terminal process tree)
    static func hostApp(of session: Session) -> NSRunningApplication? {
        if let pid = session.record.pid, pid > 0, let app = guiAncestor(of: pid) { return app }
        guard let bundleId = session.record.terminalApp else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first
    }

    private static func guiAncestor(of pid: pid_t) -> NSRunningApplication? {
        var current = pid
        for _ in 0..<24 {
            guard let parent = parentPid(of: current), parent > 1 else { return nil }
            // Skip helper processes (VS Code's pty host, etc.) up to the real app
            if let app = NSRunningApplication(processIdentifier: parent), app.activationPolicy == .regular { return app }
            current = parent
        }
        return nil
    }

    /// sysctl works for every process, unlike proc_pidinfo which fails on root-owned ones (login)
    private static func parentPid(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    // MARK: - Terminal and iTerm2: tabs know their tty

    private static let terminalScript = """
    on run argv
      set targetTty to item 1 of argv
      tell application id "com.apple.Terminal"
        repeat with w in windows
          repeat with t in tabs of w
            if tty of t is targetTty then
              set selected tab of w to t
              set index of w to 1
              activate
              return "ok"
            end if
          end repeat
        end repeat
        activate
      end tell
      return ""
    end run
    """

    private static let itermScript = """
    on run argv
      set targetTty to item 1 of argv
      tell application id "com.googlecode.iterm2"
        repeat with w in windows
          repeat with t in tabs of w
            repeat with s in sessions of t
              if tty of s is targetTty then
                select w
                select t
                select s
                activate
                return "ok"
              end if
            end repeat
          end repeat
        end repeat
        activate
      end tell
      return ""
    end run
    """

    private static func focusByTty(_ session: Session, script: String, app: NSRunningApplication) {
        guard let tty = session.record.tty else {
            app.activate()
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            run("/usr/bin/osascript", ["-e", script, tty])
        }
    }

    // MARK: - WezTerm: its CLI lists panes with their tty

    private static func focusWezTerm(_ session: Session, app: NSRunningApplication) {
        guard let tty = session.record.tty,
              let cli = app.bundleURL?.appendingPathComponent("Contents/MacOS/wezterm").path else {
            app.activate()
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let list = run(cli, ["cli", "list", "--format", "json"])
            let panes = (try? JSONSerialization.jsonObject(with: Data(list.utf8))) as? [[String: Any]] ?? []
            if let pane = panes.first(where: { $0["tty_name"] as? String == tty }), let paneId = pane["pane_id"] as? Int {
                run(cli, ["cli", "activate-pane", "--pane-id", "\(paneId)"])
            }
            DispatchQueue.main.async { app.activate() }
        }
    }

    @discardableResult
    static func run(_ executable: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
