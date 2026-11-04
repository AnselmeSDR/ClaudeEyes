import AppKit
import QuartzCore

// Build-time helpers to look at the generator: a still sheet and an animated lab window

extension Snapshot {
    /// Random robots on alternating dark and light backgrounds, numbered with their seed
    static func writeRobots(to path: String) {
        let columns = 6, rows = 5, scale: CGFloat = 2
        let cell = CGSize(width: RobotRig.canvasSize.width + 20, height: RobotRig.canvasSize.height + 30)
        let size = NSSize(width: cell.width * CGFloat(columns) * scale, height: cell.height * CGFloat(rows) * scale)
        let moods: [Mood] = [.neutral, .curious, .happy, .focused, .waiting, .thinking]
        let data = png(size: size) { ctx, _ in
            ctx.scaleBy(x: scale, y: scale)
            for i in 0..<(columns * rows) {
                let col = i % columns, row = i / columns
                let origin = CGPoint(x: CGFloat(col) * cell.width, y: CGFloat(rows - 1 - row) * cell.height)
                let dark = (col + row) % 2 == 0
                ctx.setFillColor(dark ? CGColor(srgbRed: 0.13, green: 0.14, blue: 0.17, alpha: 1) : CGColor(srgbRed: 0.86, green: 0.88, blue: 0.9, alpha: 1))
                ctx.fill(CGRect(origin: origin, size: cell))

                let seed = UInt64.random(in: 0..<100_000)
                let rig = RobotRig(genome: RobotGenome(seed: seed))
                rig.face.apply(.still(moods[i % moods.count]), in: rig.faceRect)
                ctx.saveGState()
                ctx.translateBy(x: origin.x + 10, y: origin.y + 22)
                rig.layer.render(in: ctx)
                ctx.restoreGState()

                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
                                                            .foregroundColor: dark ? NSColor(white: 1, alpha: 0.6) : NSColor(white: 0, alpha: 0.5)]
                ("\(seed)" as NSString).draw(at: CGPoint(x: origin.x + 8, y: origin.y + 6), withAttributes: attrs)
            }
        }
        try? data?.write(to: URL(fileURLWithPath: path))
    }
}

/// `--robot-lab` from the command line: the lab alone, quits when its window closes
final class RobotLabDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        RobotLab.shared.show()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// A window of random robots going through every motion. Click to draw new ones.
/// Its timer only runs while the window is open.
final class RobotLab: NSObject, NSWindowDelegate {
    static let shared = RobotLab()

    private final class LabView: NSView {
        var onClick: (() -> Void)?
        override func mouseDown(with event: NSEvent) { onClick?() }
    }

    private struct Robot {
        let rig: RobotRig
        let animator: FaceAnimator
        var lastFace: FaceFrame?
    }

    private static let columns = 6, rows = 3
    private static let cell = CGSize(width: RobotRig.canvasSize.width + 10, height: RobotRig.canvasSize.height + 34)
    private static let steps: [(RobotMotion, Mood, String)] = [
        (.walk, .focused, "marche"), (.idle, .neutral, "repos"), (.cheer, .waiting, "t'attend"),
        (.sleep, .sleepy, "dort"), (.fall, .surprised, "tombe"),
    ]

    private var window: NSWindow?
    private let view = LabView()
    private var robots: [Robot] = []
    private var cells: [CALayer] = []
    private let caption = CATextLayer()
    private var timer: Timer?
    private var step = 0
    private var stepStart: CFTimeInterval = 0

    func show() {
        if window == nil {
            let size = NSSize(width: Self.cell.width * CGFloat(Self.columns), height: Self.cell.height * CGFloat(Self.rows) + 30)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable],
                                  backing: .buffered, defer: false)
            window.title = "Labo des robots (clic : nouveaux robots)"
            window.isReleasedWhenClosed = false
            window.delegate = self
            view.layer = CALayer()
            view.wantsLayer = true
            view.onClick = { [weak self] in self?.reroll() }
            window.contentView = view
            window.center()
            caption.fontSize = 13
            caption.foregroundColor = NSColor.labelColor.cgColor
            caption.frame = CGRect(x: 12, y: size.height - 24, width: size.width - 24, height: 18)
            view.layer?.addSublayer(caption)
            self.window = window
        }
        guard let window else { return }
        caption.contentsScale = window.backingScaleFactor
        if robots.isEmpty { reroll() }
        if timer == nil {
            let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        cells.forEach { $0.removeFromSuperlayer() }
        cells.removeAll()
        robots.removeAll()
    }

    private func reroll() {
        guard let window else { return }
        cells.forEach { $0.removeFromSuperlayer() }
        cells.removeAll()
        robots.removeAll()
        let scale = window.backingScaleFactor
        for i in 0..<(Self.columns * Self.rows) {
            let col = i % Self.columns, row = i / Self.columns
            let cell = CALayer()
            cell.frame = CGRect(x: CGFloat(col) * Self.cell.width, y: CGFloat(Self.rows - 1 - row) * Self.cell.height,
                                width: Self.cell.width, height: Self.cell.height)
            let dark = (col + row) % 2 == 0
            cell.backgroundColor = dark ? CGColor(srgbRed: 0.13, green: 0.14, blue: 0.17, alpha: 1) : CGColor(srgbRed: 0.86, green: 0.88, blue: 0.9, alpha: 1)

            let seed = UInt64.random(in: 0..<100_000)
            let rig = RobotRig(genome: RobotGenome(seed: seed))
            rig.layer.position = CGPoint(x: 5, y: 22)
            rig.setContentsScale(scale)
            cell.addSublayer(rig.layer)

            let label = CATextLayer()
            label.string = "\(seed)"
            label.fontSize = 10
            label.foregroundColor = dark ? NSColor(white: 1, alpha: 0.6).cgColor : NSColor(white: 0, alpha: 0.5).cgColor
            label.contentsScale = scale
            label.frame = CGRect(x: 8, y: 4, width: 80, height: 14)
            cell.addSublayer(label)

            view.layer?.addSublayer(cell)
            cells.append(cell)
            robots.append(Robot(rig: rig, animator: FaceAnimator(mood: .neutral)))
        }
        step = -1
        stepStart = 0
    }

    private func tick() {
        let now = CACurrentMediaTime()
        if now - stepStart > 4 {
            step = (step + 1) % Self.steps.count
            stepStart = now
            caption.string = "Mouvement : \(Self.steps[step].2)"
            for (i, robot) in robots.enumerated() {
                if Self.steps[step].0 == .walk { robot.rig.facing = i % 2 == 0 ? 1 : -1 }
                robot.rig.setMotion(Self.steps[step].0)
            }
        }
        // Idle robots fidget now and then
        if Self.steps[step].0 == .idle, Int(now * 30) % 20 == 0, let robot = robots.randomElement() {
            robot.rig.fidget()
        }

        let mood = Self.steps[step].1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for i in robots.indices {
            let face = robots[i].animator.frame(for: mood, at: now)
            if let last = robots[i].lastFace, face.isClose(to: last) { continue }
            robots[i].rig.face.apply(face, in: robots[i].rig.faceRect)
            robots[i].lastFace = face
        }
        CATransaction.commit()
    }
}
