import AppKit
import QuartzCore

/// Borderless transparent panel: only the eyes and their labels are visible,
/// optionally over a frosted glass backdrop
final class FloatingController {
    let panel: NSPanel
    private let crew = CrewView()
    private let backdrop = NSVisualEffectView()
    private let tint = NSView()
    private var backdropRadius: CGFloat = 0
    private let prefs = Prefs.shared
    private let store = SessionStore.shared
    private var timer: Timer?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        // Always dark so the glowing eyes keep their contrast
        backdrop.material = .hudWindow
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.appearance = NSAppearance(named: .darkAqua)
        // Dark veil over the blur: its opacity is the "intensity" setting
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.black.cgColor
        tint.layer?.masksToBounds = true

        let container = NSView(frame: panel.contentLayoutRect)
        for view in [backdrop, tint, crew] {
            view.frame = container.bounds
            view.autoresizingMask = [.width, .height]
            container.addSubview(view)
        }
        panel.contentView = container

        crew.onClick = { TerminalFocus.focus($0) }
        crew.onMoved = { [weak self] in self?.saveAnchor() }

        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        apply()
    }

    func apply() {
        panel.ignoresMouseEvents = prefs.clickThrough
        backdrop.isHidden = !prefs.backgroundBlur
        tint.isHidden = !prefs.backgroundBlur
        tint.layer?.opacity = Float(prefs.backgroundOpacity * 0.55)
        let radius = (16 * CGFloat(prefs.faceScale)).rounded()
        if radius != backdropRadius {
            backdrop.maskImage = Self.roundedMask(radius: radius)
            tint.layer?.cornerRadius = radius
            backdropRadius = radius
        }
        layout(force: true)
        updateVisibility()
    }

    /// Stretchable mask giving the backdrop rounded corners
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let size = NSSize(width: radius * 2 + 1, height: radius * 2 + 1)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    func resetPosition() {
        UserDefaults.standard.removeObject(forKey: "anchorX")
        UserDefaults.standard.removeObject(forKey: "anchorY")
        layout(force: true)
    }

    private var shouldShow: Bool {
        prefs.showFloating && !(prefs.hideWhenNoSession && store.sessions.isEmpty)
    }

    private func updateVisibility() {
        if shouldShow {
            if !panel.isVisible {
                layout(force: true)
                panel.orderFrontRegardless()
            }
        } else if panel.isVisible {
            panel.orderOut(nil)
        }
    }

    private func tick() {
        updateVisibility()
        guard panel.isVisible, panel.occlusionState.contains(.visible) else { return }
        if !crew.isDragging { layout(force: false) }
        crew.update()
    }

    /// Grows leftwards from the bottom-right anchor when sessions are added
    private func layout(force: Bool) {
        let size = crew.preferredSize(count: max(1, store.sessions.count))
        let sizeChanged = abs(panel.frame.width - size.width) > 0.5 || abs(panel.frame.height - size.height) > 0.5
        guard force || sizeChanged else { return }
        let anchor = anchorPoint()
        panel.setFrame(NSRect(x: anchor.x - size.width, y: anchor.y, width: size.width, height: size.height), display: true)
    }

    private func anchorPoint() -> NSPoint {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "anchorX") != nil {
            let saved = NSPoint(x: defaults.double(forKey: "anchorX"), y: defaults.double(forKey: "anchorY"))
            // Ignore positions left on a disconnected display
            if NSScreen.screens.contains(where: { $0.frame.insetBy(dx: -40, dy: -40).contains(saved) }) { return saved }
        }
        // NSScreen.main follows the key window: prefer the screen the eyes are already on
        let visible = (panel.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: visible.maxX - 16, y: visible.minY + 16)
    }

    private func saveAnchor() {
        UserDefaults.standard.set(panel.frame.maxX, forKey: "anchorX")
        UserDefaults.standard.set(panel.frame.minY, forKey: "anchorY")
    }
}


/// One face per Claude session, with the project name and what it is doing underneath.
/// Layer-hosting view: faces and labels are Core Animation layers composited on the GPU.
final class CrewView: NSView {
    var onClick: ((Session) -> Void)?
    var onMoved: (() -> Void)?
    private(set) var isDragging = false

    private final class Slot {
        let animator: FaceAnimator
        let face = FaceLayer()
        let title = CATextLayer()
        let status = CATextLayer()
        var fontScale: CGFloat = 0
        var lastFace: FaceFrame?
        var lastFaceRect: CGRect = .zero

        init(mood: Mood, now: CFTimeInterval) {
            animator = FaceAnimator(mood: mood, now: now)
        }

        var layers: [CALayer] { [face, title, status] }
    }

    private var slots: [String: Slot] = [:]
    private static let emptyKey = "_empty"

    private var scale: CGFloat { CGFloat(Prefs.shared.faceScale) }
    private var slotWidth: CGFloat { 112 * scale }
    private var faceHeight: CGFloat { 64 * scale }
    private var labelHeight: CGFloat { Prefs.shared.showLabels ? 34 * scale : 0 }
    private var padding: CGFloat { 10 * scale }
    private var lineHeight: CGFloat { 15 * scale }

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = CALayer()
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func preferredSize(count: Int) -> NSSize {
        // Whole points: a fractional size never matches the frame AppKit actually applies
        NSSize(width: ceil(CGFloat(count) * slotWidth + padding * 2), height: ceil(faceHeight + labelHeight + padding * 2))
    }

    private func slotRect(_ index: Int) -> CGRect {
        CGRect(x: padding + CGFloat(index) * slotWidth, y: padding, width: slotWidth, height: faceHeight + labelHeight)
    }

    func update() {
        guard let root = layer else { return }
        let now = CACurrentMediaTime()
        let wallNow = Date().timeIntervalSince1970
        let sessions = SessionStore.shared.sessions
        let keys = sessions.isEmpty ? [Self.emptyKey] : sessions.map(\.id)
        let contentsScale = window?.backingScaleFactor ?? 2

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        for (key, slot) in slots where !keys.contains(key) {
            slot.layers.forEach { $0.removeFromSuperlayer() }
            slots[key] = nil
        }

        for (index, key) in keys.enumerated() {
            let session = sessions.first { $0.id == key }
            let mood = session?.mood(at: wallNow) ?? .sleepy
            let slot = slots[key] ?? {
                let slot = Slot(mood: mood, now: now)
                slot.layers.forEach { root.addSublayer($0) }
                slots[key] = slot
                return slot
            }()

            let rect = slotRect(index)
            let faceRect = CGRect(x: rect.minX, y: rect.maxY - faceHeight, width: rect.width, height: faceHeight)
            let face = slot.animator.frame(for: mood, color: session?.look.color, at: now)
            let drawRect = faceRect.insetBy(dx: 14 * scale, dy: 10 * scale)
            // Rebuilding the eyes path is the costly part: skip still faces
            if let last = slot.lastFace, face.isClose(to: last), drawRect == slot.lastFaceRect {
                // unchanged
            } else {
                slot.face.frame = bounds
                slot.face.apply(face, in: drawRect)
                slot.lastFace = face
                slot.lastFaceRect = drawRect
            }

            let showLabels = Prefs.shared.showLabels
            slot.title.isHidden = !showLabels
            slot.status.isHidden = !showLabels
            guard showLabels else { continue }

            if slot.fontScale != scale || slot.title.contentsScale != contentsScale {
                configure(slot.title, size: 11 * scale, weight: .semibold, contentsScale: contentsScale)
                configure(slot.status, size: 9.5 * scale, weight: .medium, contentsScale: contentsScale)
                slot.fontScale = scale
            }
            setText(slot.title, session?.displayTitle ?? "Aucune session", color: NSColor.white.withAlphaComponent(0.92).cgColor)
            setText(slot.status, session?.statusText(at: wallNow) ?? "endormi", color: mood.tint.color.cgColor)
            slot.title.frame = CGRect(x: rect.minX + 4, y: rect.minY + lineHeight + 2 * scale, width: rect.width - 8, height: lineHeight)
            slot.status.frame = CGRect(x: rect.minX + 4, y: rect.minY + 2 * scale, width: rect.width - 8, height: lineHeight)
        }

        CATransaction.commit()
    }

    private func configure(_ text: CATextLayer, size: CGFloat, weight: NSFont.Weight, contentsScale: CGFloat) {
        text.font = NSFont.systemFont(ofSize: size, weight: weight)
        text.fontSize = size
        text.alignmentMode = .center
        text.truncationMode = .end
        text.contentsScale = contentsScale
        text.shadowColor = NSColor.black.cgColor
        text.shadowOpacity = 0.85
        text.shadowRadius = 2.5 * scale
        text.shadowOffset = .zero
    }

    // Setting the string re-renders the text, so only do it on change
    private func setText(_ text: CATextLayer, _ value: String, color: CGColor) {
        if (text.string as? String) != value { text.string = value }
        if text.foregroundColor != color { text.foregroundColor = color }
    }

    // Right-click or control-click on a face: its menu (terminal, sound)
    override func rightMouseDown(with event: NSEvent) {
        showMenu(for: event)
    }

    private func showMenu(for event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let sessions = SessionStore.shared.sessions
        guard let index = sessions.indices.first(where: { slotRect($0).contains(location) }) else { return }
        NSMenu.popUpContextMenu(MenuFactory.sessionMenu(for: sessions[index]), with: event, for: self)
    }

    // Click focuses the session's terminal, drag moves the panel
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            showMenu(for: event)
            return
        }
        guard let window else { return }
        let start = NSEvent.mouseLocation
        let origin = window.frame.origin
        var dragged = false

        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            let point = NSEvent.mouseLocation
            if !dragged, hypot(point.x - start.x, point.y - start.y) > 3 {
                dragged = true
                isDragging = true
            }
            if dragged {
                window.setFrameOrigin(NSPoint(x: origin.x + point.x - start.x, y: origin.y + point.y - start.y))
            }
        }
        isDragging = false

        if dragged {
            onMoved?()
            return
        }
        let location = convert(event.locationInWindow, from: nil)
        let sessions = SessionStore.shared.sessions
        guard let index = sessions.indices.first(where: { slotRect($0).contains(location) }) else { return }
        onClick?(sessions[index])
    }
}
