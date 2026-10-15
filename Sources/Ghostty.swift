import Foundation

/// Brings the Ghostty terminal running a given Claude session to the front.
///
/// Ghostty's AppleScript API knows terminal titles but not ttys, so the session's tty
/// briefly gets a unique title to identify its terminal, then the original title is restored.
enum GhosttyFocus {
    private static var terminalIds: [String: String] = [:]   // sessionId -> Ghostty terminal id

    private static let script = #"""
    function run(argv) {
      const [tty, marker, cwd, cachedId] = argv;
      const app = Application("Ghostty");
      const se = Application.currentApplication();
      se.includeStandardAdditions = true;

      const quote = s => "'" + String(s).replace(/'/g, "'\\''") + "'";
      const setTitle = title => se.doShellScript("printf '\\033]2;%s\\007' " + quote(title) + " > " + quote(tty));
      const focusId = id => {
        for (const t of app.terminals()) {
          if (t.id() === id) { t.focus(); app.activate(); return true; }
        }
        return false;
      };

      if (cachedId && focusId(cachedId)) return cachedId;

      if (tty) {
        const ids = app.terminals.id();
        const names = app.terminals.name();
        setTitle(marker);
        let index = -1;
        for (let i = 0; i < 10 && index < 0; i++) {
          delay(0.05);
          index = app.terminals.name().indexOf(marker);
        }
        if (index >= 0) {
          const id = app.terminals.id()[index];
          const before = ids.indexOf(id);
          setTitle(before >= 0 ? names[before] : "");
          focusId(id);
          return id;
        }
      }

      // Fallback: first terminal in the session's directory
      const dirs = app.terminals.workingDirectory();
      const match = dirs.indexOf(cwd);
      if (match >= 0) {
        const id = app.terminals.id()[match];
        focusId(id);
        return id;
      }
      app.activate();
      return "";
    }
    """#

    static func focus(_ session: Session) {
        let sessionId = session.id
        let arguments = [
            session.record.tty ?? "",
            "claude-eyes-\(UUID().uuidString.prefix(8))",
            session.record.cwd ?? "",
            terminalIds[sessionId] ?? "",
        ]

        DispatchQueue.global(qos: .userInitiated).async {
            let terminalId = TerminalFocus.run("/usr/bin/osascript", ["-l", "JavaScript", "-e", script] + arguments)
            DispatchQueue.main.async {
                terminalIds[sessionId] = terminalId.isEmpty ? nil : terminalId
            }
        }
    }
}
