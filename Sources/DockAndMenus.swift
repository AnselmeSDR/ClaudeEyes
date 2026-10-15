import AppKit
import QuartzCore

// MARK: - Dock icon

/// Animates the app's Dock icon with a single face.
/// The main app shows the session that matters most, a per-session helper shows its own session.
final class DockTileController {
    private let view = DockTileView()
    private let animator = FaceAnimator(mood: .neutral)
    private let source: () -> (mood: Mood, badge: String?, color: SessionColor?)
    private var lastFace: FaceFrame?
    private var lastBadge: String?
    private var timer: Timer?

    init(source: @escaping () -> (mood: Mood, badge: String?, color: SessionColor?)) {
        self.source = source
        let timer = Timer(timeInterval: 1.0 / 10, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard NSApp.activationPolicy() == .regular else {
            lastFace = nil
            return
        }
        let tile = NSApp.dockTile
        if tile.contentView !== view {
            tile.contentView = view
            lastFace = nil
        }

        let (mood, badge, color) = source()
        if badge != lastBadge {
            tile.badgeLabel = badge
            lastBadge = badge
        }

        let face = animator.frame(for: mood, color: color, at: CACurrentMediaTime())
        // The Dock icon is rendered on the CPU: skip frames where nothing moves
        if let lastFace, face.isClose(to: lastFace), view.frame.size == tile.size { return }

        view.frame = NSRect(origin: .zero, size: tile.size)
        view.face = face
        lastFace = face
        tile.display()
    }
}

final class DockTileView: NSView {
    var face = FaceFrame.still(.sleepy)

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        IconRenderer.draw(face, in: bounds, ctx: ctx)
    }
}

// MARK: - Menus (menu bar and Dock)

final class MenuActions: NSObject {
    static let shared = MenuActions()

    @objc func focusSession(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let session = SessionStore.shared.sessions.first(where: { $0.id == id }) else { return }
        TerminalFocus.focus(session)
    }

    @objc func toggleSound(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        Prefs.shared.setSound(sender.state != .on, for: id)
    }

    @objc func toggleFloating(_ sender: Any?) {
        Prefs.shared.showFloating.toggle()
    }

    @objc func openSettings(_ sender: Any?) {
        SettingsWindow.shared.show()
    }

    @objc func quit(_ sender: Any?) {
        NSApp.terminate(nil)
    }
}

enum MenuFactory {
    static func fill(_ menu: NSMenu, includeQuit: Bool) {
        menu.removeAllItems()
        let actions = MenuActions.shared
        let now = Date().timeIntervalSince1970
        let sessions = SessionStore.shared.sessions

        if sessions.isEmpty {
            let empty = NSMenuItem(title: "Aucune session Claude ouverte", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for session in sessions {
            let mood = session.mood(at: now)
            let item = NSMenuItem(title: session.displayTitle, action: #selector(MenuActions.focusSession(_:)), keyEquivalent: "")
            let title = NSMutableAttributedString(string: session.displayTitle, attributes: [.font: NSFont.menuFont(ofSize: 0)])
            title.append(NSAttributedString(string: "  \(session.statusText(at: now))",
                                            attributes: [.font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.secondaryLabelColor]))
            item.attributedTitle = title
            item.image = Icons.dot(mood.tint)
            item.representedObject = session.id
            item.target = actions
            item.toolTip = "Ouvrir le terminal de cette session"
            menu.addItem(item)
        }

        if !sessions.isEmpty {
            let sounds = NSMenu()
            for session in sessions {
                sounds.addItem(soundItem(for: session, title: session.displayTitle))
            }
            let soundsItem = NSMenuItem(title: "Son des sessions", action: nil, keyEquivalent: "")
            soundsItem.submenu = sounds
            menu.addItem(.separator())
            menu.addItem(soundsItem)
        }

        menu.addItem(.separator())
        let toggle = NSMenuItem(title: "Afficher la fenêtre flottante", action: #selector(MenuActions.toggleFloating(_:)), keyEquivalent: "")
        toggle.state = Prefs.shared.showFloating ? .on : .off
        toggle.target = actions
        menu.addItem(toggle)

        let settings = NSMenuItem(title: "Réglages…", action: #selector(MenuActions.openSettings(_:)), keyEquivalent: ",")
        settings.target = actions
        menu.addItem(settings)

        // The Dock menu already has its own Quit item
        if includeQuit {
            menu.addItem(.separator())
            let quit = NSMenuItem(title: "Quitter Claude Eyes", action: #selector(MenuActions.quit(_:)), keyEquivalent: "q")
            quit.target = actions
            menu.addItem(quit)
        }
    }

    /// Right-click menu of a face in the floating panel
    static func sessionMenu(for session: Session) -> NSMenu {
        let menu = NSMenu()
        let open = NSMenuItem(title: "Ouvrir le terminal", action: #selector(MenuActions.focusSession(_:)), keyEquivalent: "")
        open.representedObject = session.id
        open.target = MenuActions.shared
        menu.addItem(open)
        menu.addItem(soundItem(for: session, title: "Son pour cette session"))
        return menu
    }

    /// Checked when the session plays sounds
    static func soundItem(for session: Session, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(MenuActions.toggleSound(_:)), keyEquivalent: "")
        item.state = Prefs.shared.isSoundOn(for: session.id) ? .on : .off
        item.representedObject = session.id
        item.target = MenuActions.shared
        return item
    }
}

/// Static icon in the menu bar
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()

    override init() {
        super.init()
        item.button?.image = Icons.menuBar()
        item.button?.toolTip = "Claude Eyes"
        menu.delegate = self
        item.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        MenuFactory.fill(menu, includeQuit: true)
    }
}
