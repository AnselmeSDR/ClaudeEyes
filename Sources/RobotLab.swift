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

/// `--robot-lab [step]` from the command line: the lab alone, quits when its window closes
final class RobotLabDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        RobotLab.shared.show(startingAt: argument(after: "--robot-lab"))
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// A window of random robots going through every motion, every way up a window and a round of hellos.
/// Click to draw new ones. Its timer only runs while the window is open.
final class RobotLab: NSObject, NSWindowDelegate {
    static let shared = RobotLab()

    private final class LabView: NSView {
        var onClick: (() -> Void)?
        override func mouseDown(with event: NSEvent) { onClick?() }
    }

    private struct Robot {
        let seed: UInt64
        let rig: RobotRig
        let animator: FaceAnimator
        let label: CATextLayer
        let wall: CAShapeLayer
        let rope: CAShapeLayer
        var lastFace: FaceFrame?
        var ascent: Ascent?
        /// Side of the window, or the middle of its face
        var climbX: CGFloat = 0
        var climbs = 0
        var restartAt: CFTimeInterval?
    }

    private enum Step {
        case motion(RobotMotion, Mood, String)
        case climb, greet

        var title: String {
            switch self {
            case .motion(_, _, let title): return title
            case .climb: return "grimpe"
            case .greet: return "se saluent"
            }
        }

        var mood: Mood {
            switch self {
            case .motion(_, let mood, _): return mood
            case .climb: return .focused
            case .greet: return .happy
            }
        }

        var duration: Double {
            switch self {
            case .motion: return 4
            case .climb: return 12
            case .greet: return 7.5
            }
        }
    }

    private static let columns = 6, rows = 2
    private static let cell = CGSize(width: 200, height: 330)
    private static let ground: CGFloat = 32
    /// The window robots climb in the lab: its left edge and its top, in cell coordinates
    private static let wallX: CGFloat = 116, wallTop: CGFloat = 182
    private static let steps: [Step] = [
        .motion(.walk, .focused, "marche"), .motion(.idle, .neutral, "repos"), .motion(.cheer, .waiting, "t'attend"),
        .motion(.sleep, .sleepy, "dort"), .motion(.fall, .surprised, "tombe"), .climb, .greet,
    ]
    private static let emotes: [RobotRig.Emote] = [.exclaim, .heart, .note, .question, .sleep]

    private var window: NSWindow?
    private let view = LabView()
    private var robots: [Robot] = []
    private var cells: [CALayer] = []
    private let caption = CATextLayer()
    private var timer: Timer?
    private var step = 0
    private var firstStep = 0
    private var stepStart: CFTimeInterval = 0
    private var greetAt: CFTimeInterval = 0
    private var answerAt: CFTimeInterval?
    private var greetRound = 0

    /// startingAt: the title of a step to begin with ("grimpe", "se saluent"…)
    func show(startingAt title: String? = nil) {
        if let title, let index = Self.steps.firstIndex(where: { $0.title == title }) {
            firstStep = index
        }
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

            let wall = CAShapeLayer()
            let frame = CGRect(x: Self.wallX, y: Self.ground, width: Self.cell.width - 6 - Self.wallX, height: Self.wallTop - Self.ground)
            let path = CGMutablePath()
            path.addRoundedRect(in: frame, cornerWidth: 6, cornerHeight: 6)
            path.move(to: CGPoint(x: frame.minX, y: frame.maxY - 14))
            path.addLine(to: CGPoint(x: frame.maxX, y: frame.maxY - 14))
            wall.path = path
            wall.fillColor = dark ? CGColor(gray: 0.3, alpha: 1) : CGColor(gray: 0.98, alpha: 1)
            wall.strokeColor = dark ? CGColor(gray: 0.45, alpha: 1) : CGColor(gray: 0.7, alpha: 1)
            wall.lineWidth = 1
            wall.isHidden = true
            cell.addSublayer(wall)

            let seed = UInt64.random(in: 0..<100_000)
            let rig = RobotRig(genome: RobotGenome(seed: seed))
            rig.setContentsScale(scale)
            let rope = CAShapeLayer()
            rope.fillColor = nil
            rope.lineWidth = 1.8
            rope.lineCap = .round
            rope.strokeColor = rig.genome.accent.shaded(0.85).cg()
            rope.contentsScale = scale
            rope.isHidden = true
            cell.addSublayer(rope)
            cell.addSublayer(rig.layer)

            let label = CATextLayer()
            label.string = "\(seed)"
            label.fontSize = 10
            label.foregroundColor = dark ? NSColor(white: 1, alpha: 0.6).cgColor : NSColor(white: 0, alpha: 0.5).cgColor
            label.contentsScale = scale
            label.frame = CGRect(x: 8, y: 4, width: 180, height: 14)
            cell.addSublayer(label)

            view.layer?.addSublayer(cell)
            cells.append(cell)
            robots.append(Robot(seed: seed, rig: rig, animator: FaceAnimator(mood: .neutral), label: label, wall: wall, rope: rope))
            place(robots[i].rig, foot: CGPoint(x: Self.cell.width / 2, y: Self.ground))
        }
        step = -1
        stepStart = 0
    }

    private func place(_ rig: RobotRig, foot: CGPoint) {
        rig.layer.position = CGPoint(x: foot.x - RobotRig.foot.x, y: foot.y - RobotRig.foot.y)
    }

    private func tick() {
        let now = CACurrentMediaTime()
        if step < 0 || now - stepStart > Self.steps[step].duration {
            leave(Self.steps[max(0, step)])
            step = step < 0 ? firstStep : (step + 1) % Self.steps.count
            stepStart = now
            enter(Self.steps[step], now)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch Self.steps[step] {
        case .motion(.idle, _, _):
            // Idle robots fidget now and then
            if Int(now * 30) % 20 == 0, let robot = robots.randomElement() { robot.rig.fidget() }
        case .climb:
            for i in robots.indices { climb(i, now) }
        case .greet:
            greet(now)
        default: break
        }
        let mood = Self.steps[step].mood
        for i in robots.indices {
            let face = robots[i].animator.frame(for: mood, at: now)
            if let last = robots[i].lastFace, face.isClose(to: last) { continue }
            robots[i].rig.face.apply(face, in: robots[i].rig.faceRect)
            robots[i].lastFace = face
        }
        CATransaction.commit()
    }

    private func enter(_ step: Step, _ now: CFTimeInterval) {
        caption.string = "Mouvement : \(step.title)"
        switch step {
        case .motion(let motion, _, _):
            for (i, robot) in robots.enumerated() {
                if motion == .walk { robot.rig.facing = i % 2 == 0 ? 1 : -1 }
                robot.rig.setMotion(motion)
            }
        case .climb:
            for i in robots.indices {
                robots[i].wall.isHidden = false
                robots[i].ascent = nil
            }
        case .greet:
            // Pairs face each other
            for (i, robot) in robots.enumerated() {
                robot.rig.facing = i % 2 == 0 ? 1 : -1
                robot.rig.setMotion(.idle)
            }
            greetAt = now + 0.4
            answerAt = nil
        }
    }

    private func leave(_ step: Step) {
        guard case .climb = step else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for i in robots.indices {
            let robot = robots[i]
            robot.wall.isHidden = true
            robot.rope.isHidden = true
            robot.rig.orientation = 0
            robot.rig.showsShadow = true
            robot.label.string = "\(robot.seed)"
            place(robot.rig, foot: CGPoint(x: Self.cell.width / 2, y: Self.ground))
            robots[i].ascent = nil
        }
        CATransaction.commit()
    }

    /// Climbs the cell's window again and again, a different way each time when it knows several
    private func climb(_ i: Int, _ now: CFTimeInterval) {
        var robot = robots[i]
        let rig = robot.rig
        if robot.ascent == nil || robot.restartAt.map({ now >= $0 }) == true {
            let styles = rig.genome.climbStyles
            let style = styles[(robot.climbs / 2 + i) % styles.count]
            // Every other climb goes straight up the window's face, for the styles that can
            let face = robot.climbs % 2 == 1 && style != .crawl
            robot.climbs += 1
            robot.restartAt = nil
            robot.climbX = face ? (Self.wallX + Self.cell.width - 6) / 2 : Self.wallX
            robot.ascent = Ascent(style: style, side: face ? 0 : 1, baseY: Self.ground, start: now,
                                  halfWidth: max(-rig.extent.minX, rig.extent.maxX), height: rig.extent.maxY, speed: rig.genome.speed)
            robot.label.string = "\(robot.seed) · \(style.label)\(face ? " (façade)" : "")"
        }
        guard let ascent = robot.ascent else { return }
        let pose = ascent.pose(at: now, wallX: robot.climbX, top: Self.wallTop)
        place(rig, foot: pose.foot)
        rig.facing = 1
        rig.orientation = pose.orientation
        rig.showsShadow = pose.done
        CATransaction.begin()
        CATransaction.setDisableActions(false)
        rig.setMotion(pose.done ? .idle : pose.motion)
        CATransaction.commit()
        if let ends = pose.rope {
            let path = CGMutablePath()
            path.move(to: ends.from)
            path.addLine(to: ends.to)
            path.move(to: CGPoint(x: ends.to.x - 4.5, y: ends.to.y + 3.5))
            path.addQuadCurve(to: CGPoint(x: ends.to.x + 4.5, y: ends.to.y + 3.5), control: CGPoint(x: ends.to.x, y: ends.to.y - 5))
            robot.rope.path = path
            robot.rope.isHidden = false
        } else {
            robot.rope.isHidden = true
        }
        if pose.done, robot.restartAt == nil {
            robot.restartAt = now + 1.2
            rig.land()
        }
        robots[i] = robot
    }

    /// Left robots wave first, their neighbors answer
    private func greet(_ now: CFTimeInterval) {
        if now >= greetAt {
            let emote = Self.emotes[greetRound % Self.emotes.count]
            for (i, robot) in robots.enumerated() where i % 2 == 0 {
                robot.rig.wave()
                robot.rig.emote(emote, side: 1)
            }
            greetRound += 1
            greetAt = now + 2.4
            answerAt = now + 0.7
        }
        if let answerAt, now >= answerAt {
            self.answerAt = nil
            let emote = Self.emotes[(greetRound + 1) % Self.emotes.count]
            for (i, robot) in robots.enumerated() where i % 2 == 1 {
                if greetRound % 2 == 0 { robot.rig.celebrate() } else { robot.rig.wave() }
                robot.rig.emote(emote, side: -1)
            }
        }
    }
}
