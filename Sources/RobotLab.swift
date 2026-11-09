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
/// Its bar picks the step, stops on it, sets their mood and eye color and draws new robots. Robots can be
/// picked up, thrown, shaken, petted, clicked or sent somewhere. Its timer only runs while the window is open.
final class RobotLab: NSObject, NSWindowDelegate {
    static let shared = RobotLab()

    /// Layer-hosting view of the cells: mouse and right clicks go to the lab
    private final class LabView: NSView {
        weak var lab: RobotLab?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            guard !event.modifierFlags.contains(.control) else {
                lab?.showMenu(event, at: point(event), in: self)
                return
            }
            lab?.mouseDown(at: point(event))
        }
        override func mouseDragged(with event: NSEvent) { lab?.mouseDragged(to: point(event)) }
        override func mouseUp(with event: NSEvent) { lab?.mouseUp(at: point(event)) }
        override func rightMouseDown(with event: NSEvent) { lab?.showMenu(event, at: point(event), in: self) }

        private func point(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }
    }

    /// What a robot is doing apart from the step
    private enum Hand {
        /// Follows the step
        case step
        case carried
        case falling(CGVector)
        /// Reels after a shake
        case dizzy(until: CFTimeInterval)
        /// Walks along its floor; rejoin: back to the step on arrival, else rests there a moment
        case walk(to: CGFloat, rejoin: Bool)
        case rest(until: CFTimeInterval)
        case beamOut(start: CFTimeInterval, to: CGPoint, rejoin: Bool)
        case beamIn(start: CFTimeInterval, rejoin: Bool)
    }

    /// A cell and its robot
    private final class Bot {
        let index: Int
        let cell: CALayer
        let wall: CAShapeLayer
        let rope: CAShapeLayer
        let label: CATextLayer
        var seed: UInt64 = 0
        var rig: RobotRig
        var animator = FaceAnimator(mood: .neutral)
        var lastFace: FaceFrame?
        /// In its cell's coordinates
        var foot = CGPoint.zero
        var hand = Hand.step
        var kept = false
        /// What the step shows it with: its tool, its way up, its outfit
        var tag: String?
        var ascent: Ascent?
        /// Side of the window, or the middle of its face
        var climbX: CGFloat = 0
        var climbs = 0
        var restartAt: CFTimeInterval?
        var minis: [MiniBot] = []
        var pokes = 0
        var grab = CGVector.zero
        var shake = ShakeMeter()
        var pet = PetMeter()
        var petUntil: CFTimeInterval = 0
        var dizzyUntil: CFTimeInterval = 0

        init(index: Int, cell: CALayer, wall: CAShapeLayer, rope: CAShapeLayer, label: CATextLayer, rig: RobotRig) {
            self.index = index
            self.cell = cell
            self.wall = wall
            self.rope = rope
            self.label = label
            self.rig = rig
        }

        var halfWidth: CGFloat { max(-rig.extent.minX, rig.extent.maxX) }
        var showsWindow: Bool { !wall.isHidden }
    }

    private enum Step {
        case motion(RobotMotion, Mood, String)
        case climb, greet
        case props, bursts, dizzy, sit, knock, outfits, teams, minis

        var title: String {
            switch self {
            case .motion(_, _, let title): return title
            case .climb: return "grimpe"
            case .greet: return "se saluent"
            case .props: return "outils"
            case .bursts: return "effets"
            case .dizzy: return "vertige"
            case .sit: return "assis"
            case .knock: return "toque"
            case .outfits: return "saisons"
            case .teams: return "équipes"
            case .minis: return "sous-agents"
            }
        }

        var mood: Mood {
            switch self {
            case .motion(_, let mood, _): return mood
            case .climb, .props, .minis: return .focused
            case .greet, .bursts, .teams: return .happy
            case .dizzy: return .surprised
            case .sit, .outfits: return .neutral
            case .knock: return .waiting
            }
        }

        var duration: Double {
            switch self {
            case .motion: return 4
            case .climb: return 12
            case .greet: return 7.5
            default: return 6
            }
        }

        /// The cell's window is there to climb, sit on or knock at
        var showsWindow: Bool {
            switch self {
            case .climb, .sit, .knock: return true
            default: return false
            }
        }
    }

    private static let columns = 6, rows = 2
    private static let cell = CGSize(width: 200, height: 330)
    private static let barHeight: CGFloat = 58
    private static let ground: CGFloat = 32
    private static let gravity: CGFloat = 1600
    private static let beamDuration = 0.35
    /// The window robots climb in the lab: its left edge and its top, in cell coordinates
    private static let wallX: CGFloat = 116, wallTop: CGFloat = 182
    private static let wallMaxX = cell.width - 6
    /// The top of the cell's window, in the middle: where robots sit
    private static let perch = CGPoint(x: (wallX + wallMaxX) / 2, y: wallTop)
    private static let steps: [Step] = [
        .motion(.walk, .focused, "marche"), .motion(.idle, .neutral, "repos"), .motion(.cheer, .waiting, "t'attend"),
        .motion(.sleep, .sleepy, "dort"), .motion(.fall, .surprised, "tombe"), .climb, .greet,
        .props, .bursts, .dizzy, .sit, .knock, .outfits, .teams, .minis,
    ]
    private static let emotes: [RobotRig.Emote] = [.exclaim, .heart, .note, .question, .sleep]
    /// Repositories of the teams step: two neighboring cells each
    private static let teams = ["ClaudeEyes", "dolibarr", "site-web"]
    private static let colorNames: [SessionColor: String] = [
        .red: "rouges", .blue: "bleus", .green: "verts", .yellow: "jaunes",
        .purple: "violets", .orange: "orange", .pink: "roses", .cyan: "cyan",
    ]

    private var window: NSWindow?
    private let view = LabView()
    private let progress = CALayer()
    private let stepPopup = NSPopUpButton()
    private let moodPopup = NSPopUpButton()
    private let colorPopup = NSPopUpButton()
    private let autoBox = NSButton(checkboxWithTitle: "Enchaîner les étapes", target: nil, action: nil)
    private var robots: [Bot] = []
    private var timer: Timer?
    private var keyMonitor: Any?
    private var lastTick: CFTimeInterval = 0
    private var step = 0
    private var firstStep = 0
    private var stepStart: CFTimeInterval = 0
    private var pausedAt: CFTimeInterval?
    private var moodOverride: Mood?
    private var color: SessionColor?
    private var greetAt: CFTimeInterval = 0
    private var answerAt: CFTimeInterval?
    private var greetRound = 0
    private var nextBurst: CFTimeInterval = 0
    private var burstRound = 0
    private var nextKnock: CFTimeInterval = 0
    /// The robot under a press, until it is a click or a drag
    private var pressed: (bot: Bot, at: CGPoint, onRobot: Bool)?
    private var dragging = false
    private var trail: [(point: CGPoint, time: CFTimeInterval)] = []

    private var current: Step { Self.steps[step] }

    /// startingAt: the title of a step to begin with ("grimpe", "se saluent"…)
    func show(startingAt title: String? = nil) {
        let index = title.flatMap { title in Self.steps.firstIndex { $0.title == title } }
        if let index { firstStep = index }
        if window == nil { makeWindow() }
        guard let window else { return }
        if robots.isEmpty {
            build(scale: window.backingScaleFactor)
        } else if let index {
            select(index, CACurrentMediaTime())
        }
        if timer == nil {
            lastTick = CACurrentMediaTime()
            let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === self.window, self.key(event) else { return event }
                return nil
            }
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        robots.forEach { $0.cell.removeFromSuperlayer() }
        robots.removeAll()
        pressed = nil
    }

    // MARK: Window

    private func makeWindow() {
        let cellsHeight = Self.cell.height * CGFloat(Self.rows)
        let size = NSSize(width: Self.cell.width * CGFloat(Self.columns), height: cellsHeight + Self.barHeight)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Labo des robots"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        view.frame = NSRect(x: 0, y: 0, width: size.width, height: cellsHeight)
        view.layer = CALayer()
        view.wantsLayer = true
        view.lab = self
        content.addSubview(view)
        content.addSubview(makeBar(frame: NSRect(x: 0, y: cellsHeight, width: size.width, height: Self.barHeight)))
        window.contentView = content
        window.center()
        self.window = window
    }

    private func makeBar(frame: NSRect) -> NSView {
        let bar = NSView(frame: frame)
        func button(_ symbol: String, _ title: String, _ tip: String, _ action: Selector) -> NSButton {
            let button = NSButton(title: title, target: self, action: action)
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
            button.toolTip = tip
            button.refusesFirstResponder = true
            return button
        }

        stepPopup.removeAllItems()
        stepPopup.addItems(withTitles: Self.steps.map(\.title))
        stepPopup.target = self
        stepPopup.action = #selector(stepPicked)
        stepPopup.toolTip = "Étape (←/→)"

        moodPopup.removeAllItems()
        moodPopup.addItem(withTitle: "Humeur de l'étape")
        moodPopup.menu?.addItem(.separator())
        for mood in Mood.allCases {
            moodPopup.addItem(withTitle: mood.label)
            moodPopup.lastItem?.representedObject = mood.rawValue
        }
        moodPopup.target = self
        moodPopup.action = #selector(moodPicked)
        moodPopup.toolTip = "Humeur de tous les robots"

        colorPopup.removeAllItems()
        colorPopup.addItem(withTitle: "Yeux sans couleur")
        for color in SessionColor.allCases {
            colorPopup.addItem(withTitle: "Yeux \(Self.colorNames[color] ?? color.rawValue)")
            colorPopup.lastItem?.representedObject = color.rawValue
            colorPopup.lastItem?.image = dot(color)
        }
        colorPopup.target = self
        colorPopup.action = #selector(colorPicked)
        colorPopup.toolTip = "Couleur de session (/color)"
        [stepPopup, moodPopup, colorPopup].forEach { $0.refusesFirstResponder = true }

        autoBox.target = self
        autoBox.action = #selector(autoToggled)
        autoBox.state = pausedAt == nil ? .on : .off
        autoBox.toolTip = "Passer seul à l'étape suivante (espace)"
        autoBox.refusesFirstResponder = true
        let row = NSStackView(views: [
            button("chevron.left", "", "Étape précédente (←)", #selector(previousStep)), stepPopup,
            button("chevron.right", "", "Étape suivante (→)", #selector(nextStep)), autoBox,
            moodPopup, colorPopup, button("dice", "Nouveaux robots", "Nouveaux robots (R)", #selector(rerollAll)),
        ])
        row.orientation = .horizontal
        row.spacing = 8
        let hint = NSTextField(labelWithString: "Glisse, lance ou secoue un robot · caresse-le doucement · clic dessus : il réagit · "
            + "clic par terre : il y va · clic droit : graine, garder · ←/→ étapes · espace : enchaîner ou non · R : nouveaux robots")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byTruncatingTail
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [row, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: bar.trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
        return bar
    }

    private func dot(_ color: SessionColor) -> NSImage {
        let c = color.components
        return NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            NSColor(srgbRed: c.r / 255, green: c.g / 255, blue: c.b / 255, alpha: 1).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
    }

    /// The cells, their window, rope and label, and a robot in each
    private func build(scale: CGFloat) {
        for i in 0..<(Self.columns * Self.rows) {
            let col = i % Self.columns, row = i / Self.columns
            let cell = CALayer()
            cell.frame = CGRect(x: CGFloat(col) * Self.cell.width, y: CGFloat(Self.rows - 1 - row) * Self.cell.height,
                                width: Self.cell.width, height: Self.cell.height)
            let dark = (col + row) % 2 == 0
            cell.backgroundColor = dark ? CGColor(srgbRed: 0.13, green: 0.14, blue: 0.17, alpha: 1) : CGColor(srgbRed: 0.86, green: 0.88, blue: 0.9, alpha: 1)

            let wall = CAShapeLayer()
            let frame = CGRect(x: Self.wallX, y: Self.ground, width: Self.wallMaxX - Self.wallX, height: Self.wallTop - Self.ground)
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

            let rope = CAShapeLayer()
            rope.fillColor = nil
            rope.lineWidth = 1.8
            rope.lineCap = .round
            rope.contentsScale = scale
            rope.isHidden = true
            cell.addSublayer(rope)

            let label = CATextLayer()
            label.fontSize = 10
            label.foregroundColor = dark ? NSColor(white: 1, alpha: 0.6).cgColor : NSColor(white: 0, alpha: 0.5).cgColor
            label.contentsScale = scale
            label.frame = CGRect(x: 8, y: 4, width: 184, height: 14)
            cell.addSublayer(label)

            let seed = UInt64.random(in: 0..<100_000)
            let rig = RobotRig(genome: RobotGenome(seed: seed))
            rig.setContentsScale(scale)
            rope.strokeColor = rig.genome.accent.shaded(0.85).cg()
            cell.insertSublayer(rig.layer, above: rope)
            view.layer?.addSublayer(cell)
            let bot = Bot(index: i, cell: cell, wall: wall, rope: rope, label: label, rig: rig)
            bot.seed = seed
            place(bot, CGPoint(x: Self.cell.width / 2, y: Self.ground))
            robots.append(bot)
        }
        progress.anchorPoint = .zero
        progress.backgroundColor = NSColor.controlAccentColor.cgColor
        view.layer?.addSublayer(progress)
        select(firstStep, CACurrentMediaTime())
    }

    /// Puts a new robot in its cell, beaming in where the step wants it
    private func setRobot(_ bot: Bot, seed: UInt64, now: CFTimeInterval) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let rig = RobotRig(genome: RobotGenome(seed: seed))
        rig.setContentsScale(bot.rig.contentsScale)
        bot.cell.replaceSublayer(bot.rig.layer, with: rig.layer)
        bot.minis.forEach { $0.rig.layer.removeFromSuperlayer() }
        bot.minis.removeAll()
        bot.rig = rig
        bot.seed = seed
        bot.animator = FaceAnimator(mood: .neutral)
        bot.lastFace = nil
        bot.ascent = nil
        bot.restartAt = nil
        bot.climbs = 0
        bot.dizzyUntil = 0
        bot.petUntil = 0
        bot.tag = nil
        bot.rope.isHidden = true
        bot.rope.strokeColor = rig.genome.accent.shaded(0.85).cg()
        place(bot, spot(current, bot) ?? CGPoint(x: bot.foot.x, y: Self.ground))
        dressUp(bot, current)
        rig.beam = 1
        rig.showsShadow = false
        bot.hand = .beamIn(start: now, rejoin: true)
        updateLabel(bot)
    }

    private func place(_ bot: Bot, _ foot: CGPoint) {
        bot.foot = foot
        bot.rig.layer.position = CGPoint(x: foot.x - RobotRig.foot.x, y: foot.y - RobotRig.foot.y)
    }

    private func updateLabel(_ bot: Bot) {
        bot.label.string = (["\(bot.seed)", bot.tag, bot.kept ? "gardé" : nil] as [String?]).compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: Steps

    private func select(_ index: Int, _ now: CFTimeInterval) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let old = current
        for bot in robots {
            undress(bot, old)
            if case .step = bot.hand { unpose(bot, old) }
            // On its way back to the old step: goes to the new one instead
            if case .walk(_, true) = bot.hand { bot.hand = .step }
        }
        step = index
        stepStart = now
        if pausedAt != nil { pausedAt = now }
        stepPopup.selectItem(at: index)
        greetAt = now + 0.4
        answerAt = nil
        nextBurst = now + 0.3
        nextKnock = now + 0.2
        for bot in robots {
            dressUp(bot, current)
            if case .step = bot.hand { rejoin(bot, now) }
            updateLabel(bot)
        }
    }

    /// What the step puts on a robot, wherever it is
    private func dressUp(_ bot: Bot, _ step: Step) {
        let rig = bot.rig
        bot.wall.isHidden = !step.showsWindow
        switch step {
        case .props:
            let prop = RobotProp.allCases[bot.index % RobotProp.allCases.count]
            rig.setProp(prop)
            bot.tag = prop.label
        case .outfits:
            let hats: [RobotHat?] = RobotHat.allCases + [nil]
            let outfit = RobotOutfit(hat: hats[bot.index % hats.count], headlamp: bot.index >= Self.columns)
            rig.setOutfit(outfit)
            let worn = [outfit.hat?.label, outfit.headlamp ? "lampe" : nil].compactMap { $0 }
            bot.tag = worn.isEmpty ? nil : worn.joined(separator: ", ")
        case .teams:
            let name = Self.teams[(bot.index % Self.columns) / 2]
            rig.setTeam(RobotTeam(key: name))
            bot.tag = name
        case .minis:
            for k in 0..<(2 + bot.index % 2) {
                let mini = MiniBot(id: "\(k)", genome: rig.genome, x: bot.foot.x, scale: rig.contentsScale)
                bot.cell.insertSublayer(mini.rig.layer, below: rig.layer)
                bot.minis.append(mini)
            }
        default:
            break
        }
    }

    private func undress(_ bot: Bot, _ step: Step) {
        switch step {
        case .props: bot.rig.setProp(nil)
        case .outfits: bot.rig.setOutfit(RobotOutfit())
        case .teams: bot.rig.setTeam(nil)
        case .minis:
            bot.minis.forEach { $0.rig.layer.removeFromSuperlayer() }
            bot.minis.removeAll()
        default: break
        }
        bot.tag = nil
    }

    /// The step's motion, for a robot at its spot
    private func pose(_ bot: Bot, _ step: Step, _ now: CFTimeInterval) {
        let rig = bot.rig
        switch step {
        case .motion(let motion, _, _):
            if motion == .walk { turn(bot, bot.index % 2 == 0 ? 1 : -1) }
            animate { rig.setMotion(motion) }
        case .climb:
            bot.ascent = nil
            bot.restartAt = nil
        case .greet:
            turn(bot, bot.index % 2 == 0 ? 1 : -1)
            animate { rig.setMotion(.idle) }
        case .props:
            turn(bot, 1)
            animate { rig.setMotion(bot.index >= Self.columns ? .walk : .idle) }
        case .dizzy:
            animate { rig.setMotion(.dizzy) }
        case .sit:
            rig.showsShadow = false
            animate { rig.setMotion(.sit) }
        case .knock:
            turn(bot, 1)
            animate { rig.setMotion(.knock) }
        case .teams:
            turn(bot, bot.index % 2 == 0 ? 1 : -1)
            animate { rig.setMotion(.idle) }
        case .bursts, .outfits, .minis:
            animate { rig.setMotion(.idle) }
        }
    }

    /// Leaves the step's motion where it is
    private func unpose(_ bot: Bot, _ step: Step) {
        let rig = bot.rig
        switch step {
        case .climb:
            bot.ascent = nil
            bot.restartAt = nil
            bot.rope.isHidden = true
            rig.orientation = 0
        case .sit:
            // Stands up on the edge
            animate { rig.setMotion(.idle) }
        default:
            break
        }
        rig.showsShadow = true
    }

    /// Where the step wants it; nil when anywhere on the ground will do
    private func spot(_ step: Step, _ bot: Bot) -> CGPoint? {
        switch step {
        case .climb:
            let next = nextClimb(bot)
            return CGPoint(x: Ascent.base(wallX: next.x, side: next.face ? 0 : 1, halfWidth: bot.halfWidth, style: next.style), y: Self.ground)
        case .sit:
            return Self.perch
        case .knock:
            return CGPoint(x: Self.wallX - bot.rig.reach, y: Self.ground)
        case .teams:
            // Close to the border with its teammate's cell, their hands meet over it
            let room = max(bot.halfWidth, bot.rig.reach) + 4
            return CGPoint(x: bot.index % 2 == 0 ? Self.cell.width - room : room, y: Self.ground)
        default:
            return bot.foot.y > Self.ground + 0.5 ? CGPoint(x: Self.cell.width / 2, y: Self.ground) : nil
        }
    }

    /// Back to the step: walks or beams to its spot first
    private func rejoin(_ bot: Bot, _ now: CFTimeInterval) {
        if let target = spot(current, bot), hypot(target.x - bot.foot.x, target.y - bot.foot.y) > 2 {
            go(bot, to: target, rejoin: true, now)
            return
        }
        bot.hand = .step
        pose(bot, current, now)
    }

    /// Walks there on its floor, beams there from another one
    private func go(_ bot: Bot, to target: CGPoint, rejoin: Bool, _ now: CFTimeInterval) {
        if abs(bot.foot.y - target.y) < 1, abs(bot.rig.orientation) < 0.01 {
            bot.hand = .walk(to: target.x, rejoin: rejoin)
        } else {
            bot.rig.showsShadow = false
            bot.hand = .beamOut(start: now, to: target, rejoin: rejoin)
        }
    }

    private func turn(_ bot: Bot, _ facing: CGFloat) {
        guard bot.rig.facing != facing else { return }
        animate { bot.rig.facing = facing }
    }

    /// Pose changes and turning around are animated
    private func animate(_ change: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(false)
        change()
        CATransaction.commit()
    }

    // MARK: Controls

    @objc private func previousStep() { select((step + Self.steps.count - 1) % Self.steps.count, CACurrentMediaTime()) }
    @objc private func nextStep() { select((step + 1) % Self.steps.count, CACurrentMediaTime()) }
    @objc private func stepPicked() { select(max(0, stepPopup.indexOfSelectedItem), CACurrentMediaTime()) }

    @objc private func autoToggled() { setAuto(autoBox.state == .on) }

    /// Off: stays on the current step
    private func setAuto(_ on: Bool) {
        let now = CACurrentMediaTime()
        if on, let pausedAt {
            stepStart += now - pausedAt
            self.pausedAt = nil
        } else if !on, pausedAt == nil {
            pausedAt = now
        }
        autoBox.state = on ? .on : .off
    }

    @objc private func moodPicked() {
        moodOverride = (moodPopup.selectedItem?.representedObject as? String).flatMap(Mood.init(rawValue:))
    }

    @objc private func colorPicked() {
        color = (colorPopup.selectedItem?.representedObject as? String).flatMap(SessionColor.init(rawValue:))
    }

    @objc private func rerollAll() {
        let now = CACurrentMediaTime()
        for bot in robots where !bot.kept {
            setRobot(bot, seed: UInt64.random(in: 0..<100_000), now: now)
        }
    }

    /// ←/→ steps, space stops or resumes the steps, R draws new robots
    private func key(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        switch event.keyCode {
        case 123: previousStep()
        case 124: nextStep()
        case 49: setAuto(pausedAt != nil)
        default:
            guard event.charactersIgnoringModifiers?.lowercased() == "r" else { return false }
            rerollAll()
        }
        return true
    }

    // MARK: Mouse

    private func bot(at point: CGPoint) -> Bot? {
        robots.first { $0.cell.frame.contains(point) }
    }

    private func local(_ point: CGPoint, _ bot: Bot) -> CGPoint {
        CGPoint(x: point.x - bot.cell.frame.minX, y: point.y - bot.cell.frame.minY)
    }

    private func isSitting(_ bot: Bot) -> Bool {
        if case .step = bot.hand, case .sit = current { return true }
        return false
    }

    private func bounds(_ bot: Bot) -> CGRect {
        bot.rig.bounds(foot: bot.foot, facing: bot.rig.facing, sitting: isSitting(bot)).insetBy(dx: -3, dy: -3)
    }

    fileprivate func mouseDown(at point: CGPoint) {
        guard let bot = bot(at: point) else { return }
        let p = local(point, bot)
        pressed = (bot, p, bounds(bot).contains(p) && bot.rig.beam == 0)
        dragging = false
        trail = []
    }

    fileprivate func mouseDragged(to point: CGPoint) {
        guard let pressed, pressed.onRobot else { return }
        let bot = pressed.bot, p = local(point, bot)
        if !dragging {
            guard hypot(p.x - pressed.at.x, p.y - pressed.at.y) > 3 else { return }
            dragging = true
            pickUp(bot, at: pressed.at)
        }
        let now = CACurrentMediaTime()
        trail.append((p, now))
        trail.removeAll { now - $0.time > 0.1 }
        carry(bot, to: p, now)
    }

    fileprivate func mouseUp(at point: CGPoint) {
        defer {
            pressed = nil
            dragging = false
        }
        guard let pressed else { return }
        let bot = pressed.bot, now = CACurrentMediaTime()
        if dragging {
            // Replaced by a new robot meanwhile
            guard case .carried = bot.hand else { return }
            var velocity = CGVector.zero
            if let first = trail.first, let last = trail.last, last.time - first.time > 0.01 {
                let dt = CGFloat(last.time - first.time)
                velocity = CGVector(dx: (last.point.x - first.point.x) / dt, dy: (last.point.y - first.point.y) / dt)
            }
            func clamp(_ v: CGFloat) -> CGFloat { max(-900, min(900, v)) * 0.6 }
            bot.hand = .falling(CGVector(dx: clamp(velocity.dx), dy: clamp(velocity.dy)))
        } else if pressed.onRobot {
            poke(bot, toward: pressed.at.x, now)
        } else {
            send(bot, to: pressed.at, now)
        }
    }

    private func pickUp(_ bot: Bot, at point: CGPoint) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if case .step = bot.hand { unpose(bot, current) }
        bot.rig.beam = 0
        bot.rig.orientation = 0
        bot.rope.isHidden = true
        bot.rig.showsShadow = false
        CATransaction.commit()
        bot.grab = CGVector(dx: bot.foot.x - point.x, dy: bot.foot.y - point.y)
        bot.shake.start(at: point)
        bot.hand = .carried
        animate { bot.rig.setMotion(.fall) }
    }

    private func carry(_ bot: Bot, to point: CGPoint, _ now: CFTimeInterval) {
        guard case .carried = bot.hand else { return }
        if bot.shake.note(point, now: now) { bot.dizzyUntil = now + 3.5 }
        let hw = bot.halfWidth
        let foot = CGPoint(x: min(max(point.x + bot.grab.dx, hw), Self.cell.width - hw),
                           y: min(max(point.y + bot.grab.dy, Self.ground), Self.cell.height - bot.rig.extent.maxY - 6))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        place(bot, foot)
        CATransaction.commit()
    }

    /// A click on it: a little show, a different one every time
    private func poke(_ bot: Bot, toward x: CGFloat, _ now: CFTimeInterval) {
        let rig = bot.rig, side: CGFloat = x >= bot.foot.x ? 1 : -1
        switch bot.pokes % 5 {
        case 0:
            rig.celebrate()
            rig.emote(.note, side: side)
        case 1:
            rig.wave()
            rig.emote(.heart, side: side)
        case 2:
            rig.burst(.confetti)
        case 3:
            rig.jolt()
            rig.emote(.exclaim, side: side)
        default:
            rig.fidget()
            rig.emote(.question, side: side)
        }
        bot.pokes += 1
    }

    /// A click on its floor, or on the window's top: goes there and stays a moment
    private func send(_ bot: Bot, to point: CGPoint, _ now: CFTimeInterval) {
        switch bot.hand {
        case .step, .walk, .rest: break
        default: return
        }
        let onWindow = bot.showsWindow && point.y >= Self.wallTop - 6 && point.x > Self.wallX && point.x < Self.wallMaxX
        let hw = bot.halfWidth
        let x = onWindow ? min(max(point.x, Self.wallX + hw * 0.6), Self.wallMaxX - hw * 0.6) : min(max(point.x, hw), Self.cell.width - hw)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if case .step = bot.hand { unpose(bot, current) }
        CATransaction.commit()
        go(bot, to: CGPoint(x: x, y: onWindow ? Self.wallTop : Self.ground), rejoin: false, now)
    }

    fileprivate func showMenu(_ event: NSEvent, at point: CGPoint, in view: NSView) {
        guard let bot = bot(at: point) else { return }
        let menu = NSMenu()
        let title = NSMenuItem(title: "Robot \(bot.seed)", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        func item(_ title: String, _ action: Selector, on: Bool = false) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.tag = bot.index
            item.state = on ? .on : .off
            menu.addItem(item)
        }
        item("Nouveau robot", #selector(rerollOne))
        item("Garder ce robot", #selector(toggleKept), on: bot.kept)
        menu.addItem(.separator())
        item("Copier la graine", #selector(copySeed))
        item("Choisir une graine…", #selector(askSeed))
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    @objc private func rerollOne(_ sender: NSMenuItem) {
        guard robots.indices.contains(sender.tag) else { return }
        setRobot(robots[sender.tag], seed: UInt64.random(in: 0..<100_000), now: CACurrentMediaTime())
    }

    @objc private func toggleKept(_ sender: NSMenuItem) {
        guard robots.indices.contains(sender.tag) else { return }
        let bot = robots[sender.tag]
        bot.kept.toggle()
        updateLabel(bot)
    }

    @objc private func copySeed(_ sender: NSMenuItem) {
        guard robots.indices.contains(sender.tag) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("\(robots[sender.tag].seed)", forType: .string)
    }

    @objc private func askSeed(_ sender: NSMenuItem) {
        guard robots.indices.contains(sender.tag), let window else { return }
        let bot = robots[sender.tag]
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 180, height: 24))
        field.stringValue = "\(bot.seed)"
        let alert = NSAlert()
        alert.messageText = "Graine du robot"
        alert.informativeText = "Le même nombre donne toujours le même robot."
        alert.accessoryView = field
        alert.addButton(withTitle: "Afficher")
        alert.addButton(withTitle: "Annuler")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn,
                  let seed = UInt64(field.stringValue.trimmingCharacters(in: .whitespaces)) else { return }
            self.setRobot(bot, seed: seed, now: CACurrentMediaTime())
        }
    }

    // MARK: Tick

    private func tick() {
        guard let window else { return }
        let now = CACurrentMediaTime()
        let dt = min(0.1, max(0.001, now - lastTick))
        lastTick = now
        if pausedAt == nil, now - stepStart > current.duration {
            select((step + 1) % Self.steps.count, now)
        }
        let mouse = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let elapsed = (pausedAt ?? now) - stepStart
        progress.frame = CGRect(x: 0, y: view.bounds.height - 3, width: view.bounds.width * CGFloat(min(1, elapsed / current.duration)), height: 3)
        progress.opacity = pausedAt == nil ? 0.9 : 0.35

        stepTick(now)
        for bot in robots {
            handle(bot, now, dt)
            if case .step = bot.hand, case .climb = current {
                // The climb sets its shadow
            } else {
                let shadow: Bool
                switch bot.hand {
                case .step: shadow = !isSitting(bot)
                case .walk, .rest, .dizzy: shadow = true
                default: shadow = false
                }
                if bot.rig.showsShadow != shadow { bot.rig.showsShadow = shadow }
            }
            for mini in bot.minis {
                mini.update(now: now, dt: dt, home: bot.foot.x, bounds: 24...(Self.cell.width - 24), mood: .focused)
                mini.place(foot: CGPoint(x: mini.x, y: Self.ground))
            }
            updateFace(bot, mouse: local(mouse, bot), now, dt)
        }
    }

    /// What the step does over time, for the robots following it
    private func stepTick(_ now: CFTimeInterval) {
        let following = robots.filter { if case .step = $0.hand { return true } else { return false } }
        switch current {
        case .motion(.idle, _, _):
            // Idle robots fidget now and then
            if Int(now * 30) % 20 == 0, let bot = following.randomElement() { bot.rig.fidget() }
        case .climb:
            following.forEach { climb($0, now) }
        case .greet:
            greet(following, now)
        case .bursts:
            guard now >= nextBurst else { break }
            nextBurst = now + 1.9
            for bot in following {
                bot.rig.burst(RobotBurst.allCases[(bot.index + burstRound) % RobotBurst.allCases.count])
            }
            burstRound += 1
        case .teams:
            guard now >= greetAt else { break }
            greetAt = now + 2.4
            // The right one shows the slap: its cell is drawn over its neighbor's
            following.forEach { $0.rig.highFive(side: $0.rig.facing, clap: $0.index % 2 == 1) }
        case .knock:
            guard now >= nextKnock else { break }
            nextKnock = now + RobotRig.knockPeriod
            following.forEach { $0.rig.emote(.knock, side: 1) }
        default:
            break
        }
    }

    /// Carried, thrown, reeling, walking or beaming
    private func handle(_ bot: Bot, _ now: CFTimeInterval, _ dt: Double) {
        let rig = bot.rig
        switch bot.hand {
        case .step, .carried:
            break

        case .falling(var velocity):
            velocity.dy -= Self.gravity * CGFloat(dt)
            let hw = bot.halfWidth
            var next = CGPoint(x: bot.foot.x + velocity.dx * CGFloat(dt), y: bot.foot.y + velocity.dy * CGFloat(dt))
            // Bounces off the cell's sides and ceiling
            if next.x < hw || next.x > Self.cell.width - hw {
                next.x = min(max(next.x, hw), Self.cell.width - hw)
                velocity.dx = -velocity.dx * 0.5
            }
            let ceiling = Self.cell.height - rig.extent.maxY - 6
            if next.y > ceiling {
                next.y = ceiling
                velocity.dy = min(0, velocity.dy)
            }
            let onWindow = bot.showsWindow && velocity.dy < 0 && bot.foot.y >= Self.wallTop && next.y <= Self.wallTop
                && next.x > Self.wallX && next.x < Self.wallMaxX
            if onWindow || next.y <= Self.ground {
                place(bot, CGPoint(x: next.x, y: onWindow ? Self.wallTop : Self.ground))
                land(bot, now)
            } else {
                place(bot, next)
                bot.hand = .falling(velocity)
            }

        case .dizzy(let until):
            if now >= until { rejoin(bot, now) }

        case .walk(let x, let rejoin):
            let distance = x - bot.foot.x
            let stride = CGFloat(dt) * rig.genome.speed * 1.8
            if abs(distance) <= stride {
                place(bot, CGPoint(x: x, y: bot.foot.y))
                if rejoin {
                    self.rejoin(bot, now)
                } else {
                    bot.hand = .rest(until: now + 2.5)
                    animate { rig.setMotion(.idle) }
                }
            } else {
                place(bot, CGPoint(x: bot.foot.x + (distance > 0 ? stride : -stride), y: bot.foot.y))
                turn(bot, distance > 0 ? 1 : -1)
                animate { rig.setMotion(.walk) }
            }

        case .rest(let until):
            if now >= until { rejoin(bot, now) }

        case .beamOut(let start, let target, let rejoin):
            let p = CGFloat(min(1, (now - start) / Self.beamDuration))
            rig.beam = p
            guard p >= 1 else { break }
            rig.orientation = 0
            bot.rope.isHidden = true
            place(bot, target)
            animate { rig.setMotion(.idle) }
            bot.hand = .beamIn(start: now, rejoin: rejoin)

        case .beamIn(let start, let rejoin):
            let p = CGFloat(min(1, (now - start) / Self.beamDuration))
            rig.beam = 1 - p
            guard p >= 1 else { break }
            if rejoin {
                self.rejoin(bot, now)
            } else {
                bot.hand = .rest(until: now + 2.5)
            }
        }
    }

    /// Lands from a throw or a jump: reels a while if it was shaken
    private func land(_ bot: Bot, _ now: CFTimeInterval) {
        bot.rig.land()
        guard now < bot.dizzyUntil else {
            rejoin(bot, now)
            return
        }
        bot.dizzyUntil = max(bot.dizzyUntil, now + 2.5)
        bot.hand = .dizzy(until: bot.dizzyUntil)
        animate { bot.rig.setMotion(.dizzy) }
    }

    /// Mood, eye color, pointer, petting and dizziness
    private func updateFace(_ bot: Bot, mouse: CGPoint, _ now: CFTimeInterval, _ dt: Double) {
        let rig = bot.rig
        let mood = moodOverride ?? current.mood
        var standing: Bool
        switch bot.hand {
        case .step, .walk, .rest, .dizzy: standing = rig.beam == 0 && abs(rig.orientation) < 0.1
        default: standing = false
        }
        if case .motion(.sleep, _, _) = current, case .step = bot.hand { standing = false }

        if bot.pet.note(mouse, over: standing && bounds(bot).contains(mouse), dt: dt, now: now) {
            bot.petUntil = now + 2.2
            rig.burst(.hearts)
            rig.wiggle()
        }
        let stepDizzy: Bool = { if case .dizzy = current { return true } else { return false } }()
        rig.setStars(stepDizzy || now < bot.dizzyUntil)
        bot.animator.dizzyUntil = stepDizzy ? .greatestFiniteMagnitude : bot.dizzyUntil
        bot.animator.lookAt = standing && mood != .sleepy ? rig.gaze(at: mouse, foot: bot.foot, facing: rig.facing, sitting: isSitting(bot)) : nil
        // Petted, it squints with pleasure
        let shown = now < bot.petUntil && mood != .waiting && mood != .sleepy ? Mood.happy : mood
        let face = bot.animator.frame(for: shown, color: color, at: now)
        if let last = bot.lastFace, face.isClose(to: last) { return }
        rig.face.apply(face, in: rig.faceRect)
        bot.lastFace = face
    }

    // MARK: Climbing

    /// The next way up: a different one each time when it knows several, every other one up the window's face
    private func nextClimb(_ bot: Bot) -> (style: ClimbStyle, face: Bool, x: CGFloat) {
        let styles = bot.rig.genome.climbStyles
        let style = styles[(bot.climbs / 2 + bot.index) % styles.count]
        let face = bot.climbs % 2 == 1 && style != .crawl
        return (style, face, face ? Self.perch.x : Self.wallX)
    }

    /// Climbs the cell's window, then jumps off it and walks back to climb again
    private func climb(_ bot: Bot, _ now: CFTimeInterval) {
        let rig = bot.rig
        if bot.ascent == nil {
            let next = nextClimb(bot)
            bot.climbs += 1
            bot.climbX = next.x
            bot.ascent = Ascent(style: next.style, side: next.face ? 0 : 1, baseY: Self.ground, start: now,
                                halfWidth: bot.halfWidth, height: rig.extent.maxY, speed: rig.genome.speed)
            bot.tag = "\(next.style.label)\(next.face ? " (façade)" : "")"
            updateLabel(bot)
        }
        guard let ascent = bot.ascent else { return }
        if let restartAt = bot.restartAt, now >= restartAt {
            // Jumps off, back to the ground
            bot.ascent = nil
            bot.restartAt = nil
            bot.rope.isHidden = true
            turn(bot, -1)
            animate { rig.setMotion(.fall) }
            bot.hand = .falling(CGVector(dx: -170, dy: 280))
            return
        }
        let pose = ascent.pose(at: now, wallX: bot.climbX, top: Self.wallTop)
        place(bot, pose.foot)
        rig.facing = 1
        rig.orientation = pose.orientation
        rig.showsShadow = pose.done
        animate { rig.setMotion(pose.done ? .idle : pose.motion) }
        if let ends = pose.rope {
            let path = CGMutablePath()
            path.move(to: ends.from)
            path.addLine(to: ends.to)
            path.move(to: CGPoint(x: ends.to.x - 4.5, y: ends.to.y + 3.5))
            path.addQuadCurve(to: CGPoint(x: ends.to.x + 4.5, y: ends.to.y + 3.5), control: CGPoint(x: ends.to.x, y: ends.to.y - 5))
            bot.rope.path = path
            bot.rope.isHidden = false
        } else {
            bot.rope.isHidden = true
        }
        if pose.done, bot.restartAt == nil {
            bot.restartAt = now + 1.2
            rig.land()
        }
    }

    // MARK: Hellos

    /// Left robots wave first, their neighbors answer
    private func greet(_ following: [Bot], _ now: CFTimeInterval) {
        if now >= greetAt {
            let emote = Self.emotes[greetRound % Self.emotes.count]
            for bot in following where bot.index % 2 == 0 {
                bot.rig.wave()
                bot.rig.emote(emote, side: 1)
            }
            greetRound += 1
            greetAt = now + 2.4
            answerAt = now + 0.7
        }
        if let answerAt, now >= answerAt {
            self.answerAt = nil
            let emote = Self.emotes[(greetRound + 1) % Self.emotes.count]
            for bot in following where bot.index % 2 == 1 {
                if greetRound % 2 == 0 { bot.rig.celebrate() } else { bot.rig.wave() }
                bot.rig.emote(emote, side: -1)
            }
        }
    }
}
