import AppKit
import CryptoKit
import Foundation

/// A version like "1.2" or "v1.10.1", compared number by number ("1.1" == "1.1.0")
struct AppVersion: Comparable, CustomStringConvertible {
    let parts: [Int]

    init?(_ text: String) {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, !parts.contains(nil) else { return nil }
        self.parts = parts.compactMap { $0 }
    }

    static let current = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init) ?? AppVersion("0")!

    var description: String { parts.map(String.init).joined(separator: ".") }

    private func part(_ index: Int) -> Int { index < parts.count ? parts[index] : 0 }

    static func == (a: AppVersion, b: AppVersion) -> Bool {
        (0..<max(a.parts.count, b.parts.count)).allSatisfy { a.part($0) == b.part($0) }
    }

    static func < (a: AppVersion, b: AppVersion) -> Bool {
        for index in 0..<max(a.parts.count, b.parts.count) where a.part(index) != b.part(index) {
            return a.part(index) < b.part(index)
        }
        return false
    }
}

struct UpdateError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

enum Shell {
    /// Runs a tool and returns its output; a failure carries the last line it printed
    @discardableResult
    static func run(_ tool: String, _ arguments: [String], environment: [String: String]? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus != 0 else { return output }
        let lastLine = output.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines).last ?? ""
        throw UpdateError(lastLine.isEmpty ? "\((tool as NSString).lastPathComponent) a échoué (\(process.terminationStatus))" : lastLine)
    }
}

/// Looks for a newer release on GitHub (shortly after launch, then once a day), downloads its zip, checks it and
/// swaps the app for it: a detached script waits for this process to quit, moves the new bundle in place and
/// relaunches it with --updated-from. The feed can be pointed elsewhere for tests (defaults key updateFeedURL).
final class Updater: ObservableObject {
    static let shared = Updater()

    struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadUrl: URL
        }

        let tagName: String
        let htmlUrl: URL
        let body: String?
        let assets: [Asset]
    }

    struct Update {
        let version: AppVersion
        let page: URL
        let notes: [String]
        /// The app zip and its SHA-256, nil for a release without them (to build from source)
        let archive: (zip: URL, checksum: URL)?
    }

    enum Phase: Equatable { case idle, checking, downloading, installing }

    @Published private(set) var phase = Phase.idle
    @Published private(set) var available: Update?
    /// Outcome of the last check or install, shown in the settings
    @Published private(set) var status: String?
    @Published private(set) var failed = false

    private var timer: Timer?
    private var lastCheck: Date?
    private let defaults = UserDefaults.standard

    private var feed: URL {
        defaults.string(forKey: "updateFeedURL").flatMap(URL.init(string:))
            ?? URL(string: "https://api.github.com/repos/AnselmeSDR/ClaudeEyes/releases/latest")!
    }

    func start() {
        // Once launch has settled, then whenever a day has gone by (the Mac may sleep through a timer)
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.checkIfDue() }
        let timer = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in self?.checkIfDue() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func checkIfDue() {
        guard Prefs.shared.checkUpdates else { return }
        if let lastCheck, Date().timeIntervalSince(lastCheck) < 86_400 { return }
        check(manual: false)
    }

    func check(manual: Bool) {
        guard phase == .idle else { return }
        phase = .checking
        var request = URLRequest(url: feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ClaudeEyes/\(AppVersion.current)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, error in
            let result = Result { try Self.parse(data, response, error) }
            DispatchQueue.main.async { self.checked(result, manual: manual) }
        }.resume()
    }

    private static func parse(_ data: Data?, _ response: URLResponse?, _ error: Error?) throws -> Update? {
        if let error { throw error }
        guard let data else { throw UpdateError("réponse vide") }
        try ensureOK(response)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let release = try decoder.decode(Release.self, from: data)
        guard let version = AppVersion(release.tagName) else { throw UpdateError("version illisible : \(release.tagName)") }
        guard version > AppVersion.current else { return nil }
        let zip = release.assets.first { $0.name.hasPrefix("ClaudeEyes-") && $0.name.hasSuffix(".zip") }
        let checksum = zip.flatMap { zip in release.assets.first { $0.name == zip.name + ".sha256" } }
        var archive: (URL, URL)?
        if let zip, let checksum { archive = (zip.browserDownloadUrl, checksum.browserDownloadUrl) }
        return Update(version: version, page: release.htmlUrl, notes: notes(release.body ?? ""), archive: archive)
    }

    /// The release's bullet points, bold lead only ("- **Teams**: …" → "Teams")
    static func notes(_ body: String) -> [String] {
        let lines = body.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("- ") || $0.hasPrefix("* ") }
            .map { line -> String in
                let text = String(line.dropFirst(2))
                if let bold = text.range(of: #"\*\*(.+?)\*\*"#, options: .regularExpression) {
                    return text[bold].replacingOccurrences(of: "**", with: "")
                }
                return text.count > 90 ? text.prefix(89) + "…" : text
            }
        return Array(lines.prefix(8))
    }

    private static func ensureOK(_ response: URLResponse?) throws {
        guard let http = response as? HTTPURLResponse, http.statusCode != 200 else { return }
        throw UpdateError("le serveur a répondu \(http.statusCode)")
    }

    private func checked(_ result: Result<Update?, Error>, manual: Bool) {
        phase = .idle
        switch result {
        case .failure(let error):
            // lastCheck stays: the next hourly tick tries again
            failed = true
            status = "Impossible de vérifier : \(error.localizedDescription)"
        case .success(nil):
            lastCheck = Date()
            available = nil
            failed = false
            status = "Claude Eyes est à jour."
        case .success(let update?):
            lastCheck = Date()
            available = update
            failed = false
            status = "La version \(update.version) est disponible."
            // Unasked, each version is offered once; it stays in the menus
            let key = "updateOfferedVersion"
            if !manual, defaults.string(forKey: key) != update.version.description {
                defaults.set(update.version.description, forKey: key)
                offer()
            }
        }
    }

    func offer() {
        guard let update = available, phase == .idle else { return }
        let alert = NSAlert()
        alert.messageText = "Claude Eyes \(update.version) est disponible"
        var text = "Tu as la version \(AppVersion.current)."
        if !update.notes.isEmpty {
            text += "\n\nNouveautés :\n" + update.notes.map { "• \($0)" }.joined(separator: "\n")
        }
        if update.archive == nil {
            text += "\n\nCette version s'installe depuis les sources : sa page explique comment."
        }
        alert.informativeText = text
        alert.addButton(withTitle: update.archive == nil ? "Ouvrir la page" : "Mettre à jour")
        alert.addButton(withTitle: "Plus tard").keyEquivalent = "\u{1b}"
        if update.archive != nil { alert.addButton(withTitle: "Voir les nouveautés") }
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if update.archive == nil { NSWorkspace.shared.open(update.page) } else { install(update) }
        case .alertThirdButtonReturn:
            NSWorkspace.shared.open(update.page)
        default:
            break
        }
    }

    private func install(_ update: Update) {
        guard let archive = update.archive else { return }
        let app = Bundle.main.bundleURL
        if let problem = Self.cannotReplace(app) {
            fail(problem)
            return
        }
        phase = .downloading
        failed = false
        status = "Téléchargement de la version \(update.version)…"
        let report: (String) -> Void = { message in
            DispatchQueue.main.async {
                self.phase = .installing
                self.status = message
            }
        }
        Task.detached(priority: .userInitiated) {
            do {
                let (newApp, staging) = try await Self.prepare(update, archive: archive, replacing: app, report: report)
                DispatchQueue.main.async { Updater.shared.relaunch(into: newApp, staging: staging, replacing: app) }
            } catch {
                DispatchQueue.main.async { Updater.shared.fail("La mise à jour a échoué : \(error.localizedDescription)") }
            }
        }
    }

    /// Why this copy can't replace itself, if so
    private static func cannotReplace(_ app: URL) -> String? {
        if app.path.contains("/AppTranslocation/") {
            return "macOS lance Claude Eyes depuis un emplacement temporaire : range-la dans le dossier Applications, relance-la puis réessaie."
        }
        let folder = app.deletingLastPathComponent()
        let fm = FileManager.default
        guard fm.isWritableFile(atPath: folder.path), fm.isWritableFile(atPath: app.path) else {
            return "Pas le droit de remplacer \(app.path) : télécharge la nouvelle version depuis sa page."
        }
        return nil
    }

    /// Downloads and checks the new app next to the current one: returns it and its staging folder
    private static func prepare(_ update: Update, archive: (zip: URL, checksum: URL), replacing app: URL,
                                report: (String) -> Void) async throws -> (URL, URL) {
        let fm = FileManager.default
        // Same volume as the app, so the swap is a plain rename
        let staging = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app, create: true)
        do {
            let (sumData, sumResponse) = try await URLSession.shared.data(from: archive.checksum)
            try ensureOK(sumResponse)
            guard let expected = String(decoding: sumData, as: UTF8.self).split(whereSeparator: \.isWhitespace).first?.lowercased(),
                  expected.count == 64 else { throw UpdateError("empreinte SHA-256 illisible") }
            let (download, response) = try await URLSession.shared.download(from: archive.zip)
            try ensureOK(response)
            let zip = staging.appendingPathComponent("update.zip")
            try fm.moveItem(at: download, to: zip)
            let digest = SHA256.hash(data: try Data(contentsOf: zip, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
            guard digest == expected else { throw UpdateError("le fichier téléchargé ne correspond pas à son empreinte SHA-256") }

            report("Installation de la version \(update.version)…")
            let unpacked = staging.appendingPathComponent("unpacked")
            try Shell.run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
            let apps = try fm.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil).filter { $0.pathExtension == "app" }
            guard apps.count == 1, let newApp = apps.first, let bundle = Bundle(url: newApp) else {
                throw UpdateError("l'archive ne contient pas l'app")
            }
            guard bundle.bundleIdentifier == Bundle.main.bundleIdentifier else {
                throw UpdateError("l'archive contient une autre app (\(bundle.bundleIdentifier ?? "?"))")
            }
            guard (bundle.infoDictionary?["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init) == update.version else {
                throw UpdateError("l'archive ne contient pas la version \(update.version)")
            }
            try Shell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path])
            return (newApp, staging)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    /// A detached script waits for this process to quit, puts the new bundle in place of the old one (put back if
    /// that fails) and opens the result, which learns from --updated-from how it went
    private func relaunch(into newApp: URL, staging: URL, replacing app: URL) {
        let script = """
        pid=$1 old=$2 new=$3 staging=$4 from=$5
        for _ in $(seq 1 100); do kill -0 "$pid" 2> /dev/null || break; sleep 0.1; done
        if mv "$old" "$staging/previous.app"; then
          if mv "$new" "$old"; then
            rm -rf "$staging"
          elif mv "$staging/previous.app" "$old"; then
            rm -rf "$staging"
          fi
        else
          rm -rf "$staging"
        fi
        xattr -dr com.apple.quarantine "$old" 2> /dev/null
        for _ in 1 2 3 4 5 6 7 8 9 10; do open "$old" --args --updated-from "$from" && break; sleep 0.5; done
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script, "claude-eyes-update", "\(getpid())", app.path, newApp.path, staging.path,
                             AppVersion.current.description]
        do {
            try process.run()
        } catch {
            try? FileManager.default.removeItem(at: staging)
            fail("La mise à jour a échoué : \(error.localizedDescription)")
            return
        }
        NSApp.terminate(nil)
    }

    /// At launch with --updated-from: the robots celebrate, or the user learns the old version stayed
    func relaunched(from previous: AppVersion) {
        guard AppVersion.current > previous else {
            fail("La nouvelle version n'a pas pu remplacer l'app : la version \(previous) est restée en place.")
            return
        }
        status = "Mise à jour de la version \(previous) à la version \(AppVersion.current) faite."
        // Once the robots have beamed in
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { AppDelegate.shared?.robots.celebrateUpdate() }
    }

    private func fail(_ message: String) {
        phase = .idle
        failed = true
        status = message
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Mise à jour impossible"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        let page = available?.page
        if page != nil { alert.addButton(withTitle: "Ouvrir sa page") }
        NSApp.activate()
        if alert.runModal() == .alertSecondButtonReturn, let page { NSWorkspace.shared.open(page) }
    }
}

/// The Claude Code hook the app ships with (Contents/Resources/hooks): installed by copy for those who don't build
/// from source, refreshed when the app brings a newer one. A link to a clone (hooks/install.sh) is left alone,
/// git pull updates it, unless the app itself was just updated.
final class HookSetup: ObservableObject {
    static let shared = HookSetup()

    enum Status: Equatable {
        case missing
        /// Linked to a clone of the repository by hooks/install.sh
        case linked
        case installed(current: Bool)
    }

    @Published private(set) var status = Status.missing
    @Published private(set) var busy = false
    @Published private(set) var error: String?

    private let home = FileManager.default.homeDirectoryForCurrentUser
    private var target: URL { home.appendingPathComponent(".claude/hooks/claude-state.sh") }
    private var bundled: URL? { Bundle.main.url(forResource: "hooks", withExtension: nil) }

    private init() { reload() }

    func reload() {
        let status = currentStatus()
        if status != self.status { self.status = status }
    }

    private func currentStatus() -> Status {
        let fm = FileManager.default
        let settings = home.appendingPathComponent(".claude/settings.json").resolvingSymlinksInPath()
        // fileExists follows a link: a broken one counts as missing
        guard let text = try? String(contentsOf: settings, encoding: .utf8), text.contains("claude-state.sh"),
              fm.fileExists(atPath: target.path) else { return .missing }
        if (try? fm.destinationOfSymbolicLink(atPath: target.path)) != nil { return .linked }
        return .installed(current: !differsFromBundled)
    }

    private var differsFromBundled: Bool {
        guard let source = bundled?.appendingPathComponent("claude-state.sh") else { return false }
        // contentsEqual compares a link itself, not the file it points to
        return !FileManager.default.contentsEqual(atPath: target.resolvingSymlinksInPath().path, andPath: source.path)
    }

    /// At launch: brings an installed copy up to date with the app's. After an update from the app, a link to a
    /// clone that differs is replaced too: updates now come from the app.
    func refresh(afterUpdate: Bool) {
        reload()
        switch status {
        case .installed(current: false): install(quietly: true)
        case .linked where afterUpdate && differsFromBundled: install(quietly: true)
        default: break
        }
    }

    func install(quietly: Bool) {
        guard !busy, let script = bundled?.appendingPathComponent("install.sh") else { return }
        busy = true
        var environment = ProcessInfo.processInfo.environment
        // An app opened from the Finder gets a minimal PATH, and jq usually comes from Homebrew
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try Shell.run("/bin/bash", [script.path, "--copy"], environment: environment) }
            DispatchQueue.main.async { self.installed(result, quietly: quietly) }
        }
    }

    private func installed(_ result: Result<String, Error>, quietly: Bool) {
        busy = false
        reload()
        let alert = NSAlert()
        switch result {
        case .success:
            error = nil
            // install.sh turns Claude Code's own bar off: back to what the settings say
            ClaudeSettings.syncProgressBar(oursEnabled: Prefs.shared.progressBar)
            alert.messageText = "Hook Claude Code installé"
            alert.informativeText = "Les sessions Claude Code lancées à partir de maintenant ont leur robot. Relance celles déjà ouvertes pour qu'elles le prennent en compte."
        case .failure(let failure):
            error = failure.localizedDescription
            alert.alertStyle = .warning
            alert.messageText = "Le hook n'a pas pu être installé"
            alert.informativeText = failure.localizedDescription
        }
        guard !quietly else { return }
        NSApp.activate()
        alert.runModal()
    }

    /// Asked once per launch while the hook is missing, unless the user said never again
    func offerIfMissing() {
        let declinedKey = "hookOfferDeclined"
        reload()
        guard status == .missing, bundled != nil, !UserDefaults.standard.bool(forKey: declinedKey) else { return }
        let alert = NSAlert()
        alert.messageText = "Installer le hook Claude Code ?"
        alert.informativeText = """
        Claude Eyes suit tes sessions grâce à un hook que Claude Code lance à chaque événement. Il sera copié dans \
        ~/.claude/hooks et déclaré dans ~/.claude/settings.json (sauvegarde : settings.json.bak-claude-eyes). \
        Il faut jq (brew install jq).
        """
        alert.addButton(withTitle: "Installer")
        alert.addButton(withTitle: "Plus tard").keyEquivalent = "\u{1b}"
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Ne plus demander"
        NSApp.activate()
        let answer = alert.runModal()
        if alert.suppressionButton?.state == .on { UserDefaults.standard.set(true, forKey: declinedKey) }
        if answer == .alertFirstButtonReturn { install(quietly: false) }
    }
}
