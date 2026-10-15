import AppKit
import QuartzCore
import ServiceManagement
import SwiftUI

final class Prefs: ObservableObject {
    static let shared = Prefs()

    private let defaults: UserDefaults = {
        let mainId = "com.anselme.claude-eyes"
        // Per-session Dock helpers have their own bundle id but share the main app settings
        if Bundle.main.bundleIdentifier == mainId { return .standard }
        return UserDefaults(suiteName: mainId) ?? .standard
    }()

    @Published var showFloating: Bool { didSet { defaults.set(showFloating, forKey: "showFloating") } }
    @Published var clickThrough: Bool { didSet { defaults.set(clickThrough, forKey: "clickThrough") } }
    @Published var faceScale: Double { didSet { defaults.set(faceScale, forKey: "faceScale") } }
    @Published var showLabels: Bool { didSet { defaults.set(showLabels, forKey: "showLabels") } }
    @Published var hideWhenNoSession: Bool { didSet { defaults.set(hideWhenNoSession, forKey: "hideWhenNoSession") } }
    @Published var showDockIcon: Bool { didSet { defaults.set(showDockIcon, forKey: "showDockIcon") } }
    @Published var doneDuration: Double { didSet { defaults.set(doneDuration, forKey: "doneDuration") } }
    @Published var sleepAfterMinutes: Double { didSet { defaults.set(sleepAfterMinutes, forKey: "sleepAfterMinutes") } }
    @Published var backgroundBlur: Bool { didSet { defaults.set(backgroundBlur, forKey: "backgroundBlur") } }
    @Published var backgroundOpacity: Double { didSet { defaults.set(backgroundOpacity, forKey: "backgroundOpacity") } }
    @Published var dockPerSession: Bool { didSet { defaults.set(dockPerSession, forKey: "dockPerSession") } }
    @Published var progressBar: Bool { didSet { defaults.set(progressBar, forKey: "progressBar") } }
    @Published var soundWhenWaiting: Bool { didSet { defaults.set(soundWhenWaiting, forKey: "soundWhenWaiting") } }
    @Published var soundWhenDone: Bool { didSet { defaults.set(soundWhenDone, forKey: "soundWhenDone") } }
    @Published var soundWhenFailed: Bool { didSet { defaults.set(soundWhenFailed, forKey: "soundWhenFailed") } }
    @Published var soundVolume: Double { didSet { defaults.set(soundVolume, forKey: "soundVolume") } }

    // Muted sessions are read and written straight from the defaults: Dock helpers change them too
    func isSoundOn(for sessionId: String) -> Bool {
        !(defaults.stringArray(forKey: "mutedSessions") ?? []).contains(sessionId)
    }

    func setSound(_ on: Bool, for sessionId: String) {
        var muted = (defaults.stringArray(forKey: "mutedSessions") ?? []).filter { $0 != sessionId }
        if !on { muted.append(sessionId) }
        defaults.set(muted, forKey: "mutedSessions")
    }

    func forgetMutedSessions(where isGone: (String) -> Bool) {
        let muted = defaults.stringArray(forKey: "mutedSessions") ?? []
        defaults.set(muted.filter { !isGone($0) }, forKey: "mutedSessions")
    }

    private init() {
        defaults.register(defaults: [
            "showFloating": true,
            "clickThrough": false,
            "faceScale": 1.0,
            "showLabels": true,
            "hideWhenNoSession": false,
            "showDockIcon": true,
            "doneDuration": 8.0,
            "sleepAfterMinutes": 10.0,
            "backgroundBlur": false,
            "backgroundOpacity": 0.7,
            "dockPerSession": false,
            "progressBar": true,
            "soundWhenWaiting": true,
            "soundWhenDone": true,
            "soundWhenFailed": true,
            "soundVolume": 0.5,
        ])
        showFloating = defaults.bool(forKey: "showFloating")
        clickThrough = defaults.bool(forKey: "clickThrough")
        faceScale = defaults.double(forKey: "faceScale")
        showLabels = defaults.bool(forKey: "showLabels")
        hideWhenNoSession = defaults.bool(forKey: "hideWhenNoSession")
        showDockIcon = defaults.bool(forKey: "showDockIcon")
        doneDuration = defaults.double(forKey: "doneDuration")
        sleepAfterMinutes = defaults.double(forKey: "sleepAfterMinutes")
        backgroundBlur = defaults.bool(forKey: "backgroundBlur")
        backgroundOpacity = defaults.double(forKey: "backgroundOpacity")
        dockPerSession = defaults.bool(forKey: "dockPerSession")
        progressBar = defaults.bool(forKey: "progressBar")
        soundWhenWaiting = defaults.bool(forKey: "soundWhenWaiting")
        soundWhenDone = defaults.bool(forKey: "soundWhenDone")
        soundWhenFailed = defaults.bool(forKey: "soundWhenFailed")
        soundVolume = defaults.double(forKey: "soundVolume")
    }
}

final class SettingsWindow {
    static let shared = SettingsWindow()

    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            window.title = "Claude Eyes"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 620, height: 760))
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject private var prefs = Prefs.shared
    @ObservedObject private var store = SessionStore.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError: String?

    var body: some View {
        Form {
            Section("Fenêtre flottante") {
                Toggle("Afficher la fenêtre flottante", isOn: $prefs.showFloating)
                Toggle("Laisser passer les clics", isOn: $prefs.clickThrough)
                LabeledContent("Taille") {
                    Slider(value: $prefs.faceScale, in: 0.6...1.8, step: 0.05)
                        .frame(maxWidth: 220)
                }
                Toggle("Fond flouté derrière les yeux", isOn: $prefs.backgroundBlur)
                if prefs.backgroundBlur {
                    LabeledContent("Assombrissement du fond") {
                        Slider(value: $prefs.backgroundOpacity, in: 0.2...1, step: 0.05)
                            .frame(maxWidth: 220)
                    }
                }
                Toggle("Afficher le projet et l'activité sous les yeux", isOn: $prefs.showLabels)
                Toggle("Masquer quand aucune session n'est ouverte", isOn: $prefs.hideWhenNoSession)
                Button("Replacer en bas à droite de l'écran") {
                    AppDelegate.shared?.floating.resetPosition()
                }
            }

            Section("Dock") {
                Toggle("Icône animée dans le Dock", isOn: $prefs.showDockIcon)
                Picker("Icônes", selection: $prefs.dockPerSession) {
                    Text("Une seule : la session la plus importante").tag(false)
                    Text("Une icône par session").tag(true)
                }
                .pickerStyle(.radioGroup)
                .disabled(!prefs.showDockIcon)
                Text(prefs.dockPerSession
                     ? "Un clic sur l'icône d'une session ouvre son terminal. Un « ! » signale qu'elle attend ta réponse."
                     : "Un clic sur l'icône affiche ou masque la fenêtre flottante. La pastille compte les sessions qui attendent ta réponse.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Comportement") {
                Stepper("Reste content \(Int(prefs.doneDuration)) s après une réponse", value: $prefs.doneDuration, in: 2...60)
                Stepper("S'endort après \(Int(prefs.sleepAfterMinutes)) min sans activité", value: $prefs.sleepAfterMinutes, in: 1...60)
            }

            Section("Sons") {
                soundToggle("Quand une session attend ta réponse", isOn: $prefs.soundWhenWaiting, chirp: .waiting)
                soundToggle("Quand une session a fini", isOn: $prefs.soundWhenDone, chirp: .done)
                soundToggle("Quand une réponse s'arrête sur une erreur", isOn: $prefs.soundWhenFailed, chirp: .failed)
                LabeledContent("Volume") {
                    Slider(value: $prefs.soundVolume, in: 0.05...1, step: 0.05) { editing in
                        if !editing { Sounds.shared.play(.waiting) }
                    }
                    .frame(maxWidth: 220)
                }
                Text("Le son d'une session se coupe depuis la barre des menus (Son des sessions), un clic droit sur ses yeux ou son icône du Dock.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Terminal") {
                LabeledContent("Terminaux détectés", value: detectedTerminals)
                Toggle("Barre de progression dans l'onglet", isOn: $prefs.progressBar)
                Text("Seulement dans Ghostty 1.2+ et iTerm2 3.6.6+, les terminaux où Claude Code l'active aussi. Elle remplace la barre de Claude Code, qui disparaît pendant les longues réflexions. Dans Ghostty, progress-style = false masque toutes les barres, quelle que soit l'app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Système") {
                Toggle("Lancer à l'ouverture de session", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                if let launchError {
                    Text(launchError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Expressions") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 16) {
                    ForEach(Mood.allCases, id: \.self) { mood in
                        VStack(spacing: 4) {
                            FacePreview(mood: mood)
                                .frame(height: 72)
                                .background(RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.08)))
                            Text(mood.label)
                                .font(.callout.weight(.semibold))
                            Text(mood.trigger)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, idealWidth: 620, minHeight: 500, idealHeight: 760)
    }

    private func soundToggle(_ title: String, isOn: Binding<Bool>, chirp: Chirp) -> some View {
        HStack {
            Toggle(title, isOn: isOn)
            Spacer()
            Button {
                Sounds.shared.play(chirp)
            } label: {
                Image(systemName: "play.circle")
            }
            .buttonStyle(.borderless)
            .help("Écouter")
        }
    }

    /// "Ghostty (4), Terminal (1)", found from each session's process tree
    private var detectedTerminals: String {
        var counts: [String: Int] = [:]
        for session in store.sessions {
            counts[TerminalFocus.hostApp(of: session)?.localizedName ?? "inconnu", default: 0] += 1
        }
        guard !counts.isEmpty else { return "aucune session" }
        return counts.sorted { $0.value > $1.value }.map { "\($0.key) (\($0.value))" }.joined(separator: ", ")
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchError = nil
        } catch {
            launchError = "Impossible de modifier le lancement automatique : \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

/// Live animated face for the expressions gallery
struct FacePreview: NSViewRepresentable {
    let mood: Mood

    func makeNSView(context: Context) -> PreviewFaceView { PreviewFaceView(mood: mood) }
    func updateNSView(_ view: PreviewFaceView, context: Context) { view.mood = mood }
}

final class PreviewFaceView: NSView {
    var mood: Mood
    private let animator: FaceAnimator
    private let face = FaceLayer()
    private var timer: Timer?

    init(mood: Mood) {
        self.mood = mood
        animator = FaceAnimator(mood: mood)
        super.init(frame: .zero)
        layer = CALayer()
        wantsLayer = true
        layer?.addSublayer(face)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidMoveToWindow() {
        timer?.invalidate()
        timer = nil
        guard window != nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        face.frame = bounds
        face.apply(animator.frame(for: mood, at: CACurrentMediaTime()), in: bounds.insetBy(dx: 18, dy: 12))
        CATransaction.commit()
    }
}
