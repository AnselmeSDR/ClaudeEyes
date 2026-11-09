import AppKit
import Combine
import QuartzCore

/// One robot per Claude session. They stroll at the bottom of the screens, climb windows that have room on top,
/// come to the screen you are on when their session waits for you.
/// Each robot is a small transparent window: it only moves while the robot does.
final class RobotCrew {
    private static let mascotId = "_mascot"

    private let world = RobotWorld()
    private var agents: [String: RobotAgent] = [:]
    private var leaving: [RobotAgent] = []
    private var timer: Timer?
    private var lastTick = CACurrentMediaTime()
    private var screensAsleep = false
    private var nextSocial: CFTimeInterval = 0
    private var outfit = RobotOutfit.at(Date())
    private var outfitCheckAt: CFTimeInterval = 0
    private var sessionsObserver: AnyCancellable?
    private var observers: [NSObjectProtocol] = []

    init() {
        // A rerolled robot is kept for its session only, like a muted one
        Prefs.shared.forgetRobotSeeds { id in
            guard let pid = Int32(id.replacingOccurrences(of: "pid-", with: "")) else { return true }
            return kill(pid, 0) != 0 && errno != EPERM
        }
        sessionsObserver = SessionStore.shared.$sessions.sink { [weak self] in self?.sync($0) }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in self?.screensChanged() })
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.screensAsleep = true
            self?.updateTimer()
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.screensAsleep = false
            self?.updateTimer()
        })
        apply()
    }

    func apply() {
        sync(SessionStore.shared.sessions)
        for agent in agents.values { agent.setVisible(Prefs.shared.showRobots) }
        updateTimer()
    }

    /// Brings every robot to the bottom of the screen the pointer is on
    func recall() {
        let mouse = NSEvent.mouseLocation
        guard let screen = world.nearestScreen(to: mouse) else { return }
        let ground = world.ground(screen)
        var taken: [CGFloat] = []
        for agent in agents.values {
            let x = freeSpot(on: ground, near: mouse.x, for: agent, taken: taken)
            taken.append(x)
            agent.beam(to: RobotAgent.Destination(support: ground.support, foot: CGPoint(x: x, y: ground.y)))
        }
    }

    /// Draws a new robot for this session
    func reroll(_ id: String) {
        let seed = UInt64.random(in: 0...UInt64.max)
        Prefs.shared.setRobotSeed(seed, for: id)
        agents[id]?.rebuild(seed: seed)
    }

    private func seed(for id: String) -> UInt64 {
        if id == Self.mascotId { return UInt64(stableHash: "Claude Eyes") }
        return Prefs.shared.robotSeed(for: id) ?? UInt64(stableHash: id)
    }

    private func sync(_ sessions: [Session]) {
        var ids = sessions.map(\.id)
        if ids.isEmpty, !Prefs.shared.hideWhenNoSession { ids = [Self.mascotId] }
        let now = CACurrentMediaTime()
        let mouse = NSEvent.mouseLocation

        var delay = 0.0
        for id in ids where agents[id] == nil {
            let agent = RobotAgent(id: id, seed: seed(for: id), crew: self)
            agent.outfit = outfit
            agents[id] = agent
            if let screen = world.nearestScreen(to: mouse) {
                let ground = world.ground(screen)
                let x = freeSpot(on: ground, near: mouse.x, for: agent)
                agent.appear(at: RobotAgent.Destination(support: ground.support, foot: CGPoint(x: x, y: ground.y)), start: now + delay)
            }
            agent.setVisible(Prefs.shared.showRobots)
            delay += 0.25
        }
        for (id, agent) in agents where !ids.contains(id) {
            agents[id] = nil
            agent.leave(now: now)
            leaving.append(agent)
        }
        for session in sessions { agents[session.id]?.session = session }
        updateTeams(sessions)
        updateTimer()
    }

    /// Sessions in the same repository carry the same pennant
    private func updateTeams(_ sessions: [Session]) {
        let roots = Dictionary(grouping: sessions) { ProjectRoot.of($0.record.cwd) ?? "" }
        for (root, members) in roots {
            let team = !root.isEmpty && members.count > 1 ? RobotTeam(key: root) : nil
            for session in members { agents[session.id]?.team = team }
        }
    }

    private func screensChanged() {
        world.refreshScreens()
        // Robots left on a screen that is gone come back to the pointer's screen
        guard let screen = world.nearestScreen(to: NSEvent.mouseLocation) else { return }
        let ground = world.ground(screen)
        for agent in agents.values where world.screen(containing: CGPoint(x: agent.foot.x, y: agent.foot.y + 1)) == nil {
            let x = freeSpot(on: ground, near: nil, for: agent)
            agent.beam(to: RobotAgent.Destination(support: ground.support, foot: CGPoint(x: x, y: ground.y)))
        }
    }

    private func updateTimer() {
        let run = Prefs.shared.showRobots && !screensAsleep && !(agents.isEmpty && leaving.isEmpty)
        if run, timer == nil {
            lastTick = CACurrentMediaTime()
            let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !run, let timer {
            timer.invalidate()
            self.timer = nil
        }
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = min(0.1, now - lastTick)
        lastTick = now
        let all = Array(agents.values) + leaving
        // The window list is only read while a robot stands on a window, climbs or falls
        if all.contains(where: \.needsWindows) { world.refreshWindows(maxAge: 0.25) }
        let tick = RobotAgent.Tick(now: now, dt: dt, wallNow: Date().timeIntervalSince1970, mouse: NSEvent.mouseLocation, world: world)
        // A single commit for every robot
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if now >= nextSocial {
            nextSocial = now + 0.5
            socialize(now)
        }
        // A hat for the season, a headlamp at night
        if now >= outfitCheckAt {
            outfitCheckAt = now + 60
            let current = RobotOutfit.at(Date())
            if current != outfit {
                outfit = current
                for agent in all { agent.outfit = current }
            }
        }
        for agent in all { agent.update(tick) }
        CATransaction.commit()
        leaving.removeAll { agent in
            guard agent.isGone else { return false }
            agent.close()
            return true
        }
        if agents.isEmpty, leaving.isEmpty { updateTimer() }
    }

    // MARK: Robots together

    func agent(_ id: String) -> RobotAgent? { agents[id] }

    /// Two free robots close to each other on the same surface say hello
    private func socialize(_ now: CFTimeInterval) {
        let free = agents.values.filter { $0.isFree && now >= $0.socialAt }
        for (i, a) in free.enumerated() {
            for b in free[(i + 1)...] where a.support == b.support && abs(a.foot.x - b.foot.x) < a.halfWidth + b.halfWidth + 50 {
                guard Double.random(in: 0..<1) < 0.4 else { continue }
                meet(a, b, now)
                return
            }
        }
    }

    private func meet(_ a: RobotAgent, _ b: RobotAgent, _ now: CFTimeInterval) {
        // Teammates slap hands, at the same time
        if a.team != nil, a.team == b.team {
            a.greet(toward: b.foot.x, gesture: .highFive(clap: true), now: now, delay: 0.3)
            b.greet(toward: a.foot.x, gesture: .highFive(clap: false), now: now, delay: 0.3)
            return
        }
        a.greet(toward: b.foot.x, emote: [.exclaim, .heart, .note].randomElement()!, now: now)
        b.greet(toward: a.foot.x, emote: [.heart, .note, .exclaim].randomElement()!, now: now, delay: 0.7)
    }

    /// Its free teammates on its surface walk behind it, in a line
    func lead(_ leader: RobotAgent, to x: CGFloat, on surface: RobotWorld.Surface, now: CFTimeInterval) {
        guard let team = leader.team else { return }
        let direction: CGFloat = x >= leader.foot.x ? 1 : -1
        var behind = x
        var previous = leader
        let followers = agents.values.filter { $0 !== leader && $0.team == team && $0.isFree && $0.support == leader.support
            && abs($0.foot.x - leader.foot.x) < 500 }
        for mate in followers.sorted(by: { abs($0.foot.x - leader.foot.x) < abs($1.foot.x - leader.foot.x) }) {
            behind -= direction * (previous.halfWidth + mate.halfWidth + 14)
            let spot = min(max(behind, surface.minX + mate.halfWidth), surface.maxX - mate.halfWidth)
            mate.follow(previous, to: spot, now: now)
            previous = mate
        }
    }

    /// A robot of the same team, wherever it is
    func teammate(for agent: RobotAgent) -> RobotAgent? {
        guard let team = agent.team else { return nil }
        return agents.values.filter { $0 !== agent && $0.team == team }.randomElement()
    }

    func hasTeammate(of agent: RobotAgent, on support: RobotWorld.Support?) -> Bool {
        guard let team = agent.team else { return false }
        return agents.values.contains { $0 !== agent && $0.team == team && $0.support == support }
    }

    /// Another robot on the same surface, far enough to be worth a walk
    func companion(for agent: RobotAgent) -> RobotAgent? {
        agents.values.filter { other in
            other !== agent && other.support == agent.support && abs(other.foot.x - agent.foot.x) > 150 && (other.isFree || other.isAsleep)
        }.randomElement()
    }

    /// The visitor arrived next to its host
    func visited(_ id: String, by visitor: RobotAgent, now: CFTimeInterval) {
        guard let host = agents[id], host.support == visitor.support,
              abs(host.foot.x - visitor.foot.x) < host.halfWidth + visitor.halfWidth + 60 else { return }
        if host.isAsleep {
            visitor.greet(toward: host.foot.x, emote: .question, now: now)
            host.emote(.sleep, toward: visitor.foot.x)
        } else if host.isFree {
            meet(visitor, host, now)
        }
    }

    /// Plays tag: the runner flees to the end of the surface, the chaser runs after it
    func startChase(by chaser: RobotAgent, of runner: RobotAgent, on surface: RobotWorld.Surface, now: CFTimeInterval) -> Bool {
        guard runner.isFree else { return false }
        let away: CGFloat = runner.foot.x >= chaser.foot.x ? 1 : -1
        let edge = away > 0 ? surface.maxX - runner.halfWidth : surface.minX + runner.halfWidth
        guard abs(edge - runner.foot.x) > 120 else { return false }
        runner.flee(to: edge, now: now)
        chaser.chase(runner, to: edge - away * (runner.halfWidth + chaser.halfWidth + 4), now: now)
        return true
    }

    /// The chaser caught up with its runner
    func tagged(_ id: String, by chaser: RobotAgent, now: CFTimeInterval) {
        guard let runner = agents[id], runner.isFree, runner.support == chaser.support,
              abs(runner.foot.x - chaser.foot.x) < runner.halfWidth + chaser.halfWidth + 30 else { return }
        chaser.greet(toward: runner.foot.x, emote: .heart, now: now, cheer: true)
        runner.greet(toward: chaser.foot.x, emote: .exclaim, now: now, delay: 0.3)
    }

    /// Its session just finished a turn: the robots around cheer along
    func celebrated(_ agent: RobotAgent, now: CFTimeInterval) {
        for other in agents.values where other !== agent && other.isFree && other.support == agent.support && abs(other.foot.x - agent.foot.x) < 400 {
            other.greet(toward: agent.foot.x, emote: .note, now: now, delay: Double.random(in: 0.3...0.9), cheer: true)
        }
    }

    /// A spot on surface away from the other robots, as close to x as possible
    func freeSpot(on surface: RobotWorld.Surface, near x: CGFloat?, for agent: RobotAgent, taken: [CGFloat] = []) -> CGFloat {
        let hw = agent.halfWidth
        let lo = surface.minX + hw, hi = max(lo, surface.maxX - hw)
        let others = agents.values.filter { $0 !== agent && $0.support == surface.support }.map(\.plannedX) + taken
        func clamp(_ v: CGFloat) -> CGFloat { min(max(v, lo), hi) }
        let first = x.map(clamp) ?? CGFloat.random(in: lo...hi)
        var candidate = first
        for attempt in 0..<16 {
            if others.allSatisfy({ abs($0 - candidate) > hw * 2 + 8 }) { return candidate }
            let spread = CGFloat(attempt + 1) * hw
            candidate = x.map { clamp($0 + CGFloat.random(in: -spread...spread)) } ?? CGFloat.random(in: lo...hi)
        }
        return first
    }
}

// MARK: - Robot

final class RobotAgent {
    struct Tick {
        let now: CFTimeInterval
        let dt: Double
        let wallNow: Double
        let mouse: CGPoint
        let world: RobotWorld
    }

    struct Destination {
        let support: RobotWorld.Support
        let foot: CGPoint
    }

    /// What to do at the end of a walk
    private enum Next {
        case rest, cheer, jump(CGFloat), climb(RobotWorld.Wall, ClimbStyle), cross(RobotWorld.Screen)
        /// Knocks on its terminal's window, facing it
        case knock(CGFloat)
        /// Another robot, by id: says hello on arrival, or tags it at the end of a chase
        case visit(String), tag(String)
    }

    /// What it does when it greets another robot
    enum Gesture {
        case wave(RobotRig.Emote), cheer(RobotRig.Emote)
        /// With a teammate; clap: this one shows the slap
        case highFive(clap: Bool)
    }

    private enum State {
        case idle(until: CFTimeInterval)
        case walk(to: CGFloat, then: Next)
        case ascend(Ascent, RobotWorld.Wall)
        /// Faces another robot for a gesture
        case greet(until: CFTimeInterval)
        case fall(CGVector)
        case carried
        case beamOut(start: CFTimeInterval, to: Destination?)
        case beamIn(start: CFTimeInterval)
        case sleep
        case cheer(until: CFTimeInterval)
        /// Sits on a window's edge, legs dangling
        case sit(until: CFTimeInterval)
        /// Knocks on its terminal's window until its session gets an answer
        case knock(until: CFTimeInterval)
        /// Reels after being shaken
        case dizzy(until: CFTimeInterval)
    }

    private static let gravity: CGFloat = 1600
    private static let beamDuration = 0.35
    /// Room on its stage above its head for bursts, and below its foot for its legs when sitting
    private static let headroom: CGFloat = 60, legroom: CGFloat = 34

    let id: String
    var session: Session? {
        didSet { moodAt = 0 }
    }
    private weak var crew: RobotCrew?
    private var rig: RobotRig
    private let panel: RobotPanel
    private let view = RobotView()
    private let bubble = RobotBubble()
    private var animator = FaceAnimator(mood: .neutral)
    private var lastFace: FaceFrame?

    private(set) var foot = CGPoint.zero
    private(set) var support: RobotWorld.Support?
    private var perchFrame: CGRect?
    private var state: State = .beamIn(start: 0)
    private var facing: CGFloat = 1
    private var grab = CGVector.zero
    private var justDropped = false
    private var lastMood: Mood?
    private var mood = Mood.sleepy
    private var moodAt: CFTimeInterval = 0
    private var sessionState: SessionState?
    /// Shows the bubble until then, after its session changed state
    private var bubbleUntil: CFTimeInterval = 0
    /// Walk run by the render server: target and stage origin it was computed for
    private var walkAnimation: (target: CGFloat, origin: CGPoint, pace: CGFloat)?
    private let rope = CAShapeLayer()
    private var ropeEnds: (from: CGPoint, to: CGPoint)?
    private var ascentMotion = RobotMotion.walk
    /// Running after or away from another robot
    private var paceBoost: CGFloat = 1
    /// Not before then for a new encounter
    private(set) var socialAt = CACurrentMediaTime() + Double.random(in: 5...15)
    private var gesture: (at: CFTimeInterval, kind: Gesture)?
    private var pendingSeed: UInt64?
    var team: RobotTeam? {
        didSet { if team != oldValue { rig.setTeam(team) } }
    }
    var outfit = RobotOutfit() {
        didSet { rig.setOutfit(outfit) }
    }
    /// Its session's subagents, running around it
    private var minis: [MiniBot] = []
    private let minisLayer = CALayer()
    private var minisBounds: ClosedRange<CGFloat>?
    private var minisOut = false
    /// The tool in its hand, kept a moment between two tools
    private var shownProp: RobotProp?
    private var propOffAt: CFTimeInterval?
    private var nextKnock: CFTimeInterval = 0
    /// Spiral eyes until then, after a shake
    private var dizzyUntil: CFTimeInterval = 0
    private var shake = ShakeMeter()
    /// Gentle pointer moves over it, up to a petting
    private var pet = PetMeter()
    private var petUntil: CFTimeInterval = 0
    private var visible = true
    private var isLeaving = false
    private(set) var isGone = false
    private var scale: CGFloat = 0

    var halfWidth: CGFloat { max(-rig.extent.minX, rig.extent.maxX) }

    /// Where it will stand once its walk is over
    var plannedX: CGFloat {
        if case .walk(let x, _) = state { return x }
        return foot.x
    }
    private var height: CGFloat { rig.extent.maxY }
    private var speed: CGFloat { rig.genome.speed }
    private var walkPace: CGFloat { speed * (mood == .waiting ? 1.8 : 1) * paceBoost }

    /// Up on a window, climbing or falling: the window frames must be fresh
    var needsWindows: Bool {
        switch state {
        case .fall, .ascend: return true
        default:
            if case .window? = support { return true }
            return false
        }
    }

    init(id: String, seed: UInt64, crew: RobotCrew) {
        self.id = id
        self.crew = crew
        rig = RobotRig(genome: RobotGenome(seed: seed))
        panel = RobotPanel(contentRect: NSRect(origin: .zero, size: RobotRig.canvasSize),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true

        view.frame = NSRect(origin: .zero, size: RobotRig.canvasSize)
        view.autoresizingMask = [.width, .height]
        view.layer = CALayer()
        view.wantsLayer = true
        view.layer?.addSublayer(rig.layer)
        rope.fillColor = nil
        rope.lineWidth = 1.8
        rope.lineCap = .round
        rope.lineJoin = .round
        rope.strokeColor = rig.genome.accent.shaded(0.85).cg()
        rope.isHidden = true
        view.layer?.insertSublayer(rope, below: rig.layer)
        minisLayer.anchorPoint = .zero
        view.layer?.insertSublayer(minisLayer, below: rig.layer)
        view.agent = self
        panel.contentView = view
        rig.beam = 1
    }

    // MARK: Commands

    func appear(at destination: Destination, start: CFTimeInterval) {
        foot = destination.foot
        support = destination.support
        state = .beamIn(start: start)
        rig.beam = 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layout(nil)
        CATransaction.commit()
    }

    func leave(now: CFTimeInterval) {
        isLeaving = true
        state = .beamOut(start: now, to: nil)
        bubble.hide()
    }

    func beam(to destination: Destination) {
        guard !isLeaving else { return }
        endClimb()
        state = .beamOut(start: CACurrentMediaTime(), to: destination)
    }

    /// Beams out, changes into another robot, beams back in at the same place
    func rebuild(seed: UInt64) {
        guard !isLeaving else { return }
        endClimb()
        pendingSeed = seed
        state = .beamOut(start: CACurrentMediaTime(), to: nil)
    }

    func setVisible(_ visible: Bool) {
        self.visible = visible
        if visible {
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
            bubble.hide()
        }
    }

    func close() {
        panel.close()
        bubble.close()
    }

    // MARK: Mouse

    func click() {
        guard let session else { return }
        TerminalFocus.focus(session)
    }

    func showMenu(_ event: NSEvent, in view: NSView) {
        guard let session else { return }
        NSMenu.popUpContextMenu(MenuFactory.sessionMenu(for: session), with: event, for: view)
    }

    func pickUp(at point: CGPoint) {
        guard !isLeaving else { return }
        endClimb()
        grab = CGVector(dx: foot.x - point.x, dy: foot.y - point.y)
        shake.start(at: point)
        support = nil
        perchFrame = nil
        state = .carried
        bubble.hide()
        updateMotion()
    }

    func carry(to point: CGPoint) {
        guard case .carried = state else { return }
        foot = CGPoint(x: point.x + grab.dx, y: point.y + grab.dy)
        let now = CACurrentMediaTime()
        if shake.note(point, now: now) { dizzyUntil = now + 3.5 }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layout(nil)
        CATransaction.commit()
    }

    /// Thrown: keeps a part of the pointer's speed
    func drop(velocity: CGVector) {
        guard case .carried = state else { return }
        func clamp(_ v: CGFloat) -> CGFloat { max(-900, min(900, v)) * 0.6 }
        state = .fall(CGVector(dx: clamp(velocity.dx), dy: clamp(velocity.dy)))
        justDropped = hypot(velocity.dx, velocity.dy) < 300
    }

    // MARK: Other robots

    /// Free for an encounter: standing around, not busy with its session
    var isFree: Bool {
        guard !isLeaving, rig.beam == 0, support != nil, mood != .waiting, mood != .sleepy else { return false }
        switch state {
        case .idle, .walk(_, .rest): return true
        default: return false
        }
    }

    var isAsleep: Bool {
        if case .sleep = state { return !isLeaving }
        return false
    }

    /// Stops and faces another robot, then waves (or cheers) with a little bubble
    func greet(toward x: CGFloat, emote: RobotRig.Emote, now: CFTimeInterval, delay: Double = 0, cheer: Bool = false) {
        greet(toward: x, gesture: cheer ? .cheer(emote) : .wave(emote), now: now, delay: delay)
    }

    func greet(toward x: CGFloat, gesture kind: Gesture, now: CFTimeInterval, delay: Double = 0) {
        facing = x >= foot.x ? 1 : -1
        paceBoost = 1
        state = .greet(until: now + delay + 2)
        gesture = (now + delay, kind)
        socialAt = now + Double.random(in: 25...60)
    }

    /// Walks behind a teammate going somewhere, then greets it there
    func follow(_ leader: RobotAgent, to x: CGFloat, now: CFTimeInterval) {
        facing = x >= foot.x ? 1 : -1
        walk(to: x, then: .visit(leader.id), boost: 1.25)
        socialAt = now + Double.random(in: 10...20)
    }

    func emote(_ emote: RobotRig.Emote, toward x: CGFloat) {
        rig.emote(emote, side: x >= foot.x ? 1 : -1)
    }

    func flee(to x: CGFloat, now: CFTimeInterval) {
        facing = x >= foot.x ? 1 : -1
        rig.emote(.exclaim, side: -facing)
        walk(to: x, then: .rest, boost: 1.5)
        socialAt = now + Double.random(in: 25...60)
    }

    func chase(_ runner: RobotAgent, to x: CGFloat, now: CFTimeInterval) {
        facing = x >= foot.x ? 1 : -1
        rig.emote(.note, side: facing)
        walk(to: x, then: .tag(runner.id), boost: 2.1)
        socialAt = now + Double.random(in: 25...60)
    }

    private func walk(to x: CGFloat, then next: Next, boost: CGFloat = 1) {
        paceBoost = boost
        state = .walk(to: x, then: next)
    }

    // MARK: Update

    /// Runs inside the crew's transaction, with implicit animations off
    func update(_ t: Tick) {
        guard visible else { return }
        // Moods change on a scale of seconds
        if t.now - moodAt > 0.2 {
            mood = session?.mood(at: t.wallNow) ?? .sleepy
            moodAt = t.now
            let newState = session?.state
            if let sessionState, let newState, newState != sessionState { bubbleUntil = t.now + 4 }
            sessionState = newState
            syncMinis(t)
            pickProp(t)
        }
        react(to: mood, t)
        step(mood, t)
        layout(t.world)
        updateMinis(t)
        updateFace(mood, t)
        updateMotion()
        rig.setStars(t.now < dizzyUntil)
        updatePointer(mood, t)
    }

    /// The tool of its session in its hand; between two tools it keeps the last one a moment
    private func pickProp(_ t: Tick) {
        if let wanted = session?.prop {
            shownProp = wanted
            propOffAt = nil
        } else if shownProp != nil {
            if propOffAt == nil { propOffAt = t.now + 1.5 }
            if let off = propOffAt, t.now >= off {
                shownProp = nil
                propOffAt = nil
            }
        }
    }

    private var isStanding: Bool {
        switch state {
        case .idle, .walk, .sleep, .cheer, .greet, .sit, .knock, .dizzy: return true
        default: return false
        }
    }

    private var isSitting: Bool {
        if case .sit = state { return true }
        return false
    }

    private func react(to mood: Mood, _ t: Tick) {
        defer { lastMood = mood }
        guard mood != lastMood else { return }
        // Confetti when the tests pass, sparks when something fails
        if let lastMood, rig.beam == 0 {
            if mood == .happy, session?.record.signal == "testsPassed" { rig.burst(.confetti) }
            if mood.tint == .error, lastMood.tint != .error { rig.burst(.sparks) }
        }
        guard isStanding else { return }
        if mood == .waiting {
            goToUser(t)
        } else if mood == .sleepy {
            state = .sleep
        } else {
            switch state {
            case .sleep, .cheer, .walk(_, .cheer), .sit, .knock, .walk(_, .knock): state = .idle(until: t.now + Double.random(in: 1...3))
            default: break
            }
            if mood == .happy, lastMood != nil {
                rig.celebrate()
                crew?.celebrated(self, now: t.now)
            }
        }
    }

    private func step(_ mood: Mood, _ t: Tick) {
        switch state {
        case .idle(let until):
            guard keepFooting(t) else { return }
            if mood == .waiting {
                goToUser(t)
            } else if mood == .sleepy {
                state = .sleep
            } else if t.now >= until {
                decide(mood, t)
            } else if Double.random(in: 0..<1) < t.dt * 0.12 {
                rig.fidget()
            }

        case .walk(let target, let next):
            guard keepFooting(t) else { return }
            if case .tag(let id) = next, let runner = crew?.agent(id),
               abs(runner.foot.x - foot.x) < halfWidth + runner.halfWidth + 6 {
                return arrive(next, t)
            }
            let distance = target - foot.x
            let stride = CGFloat(t.dt) * walkPace
            facing = distance >= 0 ? 1 : -1
            if abs(distance) <= stride {
                foot.x = target
                arrive(next, t)
            } else {
                foot.x += stride * facing
            }

        case .ascend(let ascent, let wall):
            guard let window = t.world.window(wall.window) else { return dropOffWall(wall, crawling: ascent.style == .crawl) }
            let pose = ascent.pose(at: t.now, wallX: wall.x(in: window.frame), top: window.frame.maxY)
            foot = pose.foot
            if wall.side != 0 { facing = wall.side }
            rig.orientation = pose.orientation
            ascentMotion = pose.motion
            ropeEnds = pose.rope
            if pose.done {
                endClimb()
                support = .window(wall.window)
                perchFrame = window.frame
                state = .idle(until: t.now + Double.random(in: 2...5))
                rig.land()
            }

        case .greet(let until):
            guard keepFooting(t) else { return }
            if let gesture, t.now >= gesture.at {
                self.gesture = nil
                switch gesture.kind {
                case .wave(let emote):
                    rig.wave()
                    rig.emote(emote, side: facing)
                case .cheer(let emote):
                    rig.celebrate()
                    rig.emote(emote, side: facing)
                case .highFive(let clap):
                    rig.highFive(side: facing, clap: clap)
                }
            }
            if t.now >= until { state = .idle(until: t.now + Double.random(in: 1...3)) }

        case .fall(var velocity):
            if justDropped {
                justDropped = false
                // Held by its body, its feet are below the edge it was dropped on: lands on it anyway
                if let floor = t.world.landing(at: foot.x, below: foot.y + height * 0.8, clearance: height + 4, halfWidth: halfWidth),
                   floor.y >= foot.y {
                    land(on: floor, t)
                    return
                }
            }
            velocity.dy -= Self.gravity * CGFloat(t.dt)
            let previousY = foot.y
            foot.x += velocity.dx * CGFloat(t.dt)
            foot.y += velocity.dy * CGFloat(t.dt)
            guard let floor = t.world.landing(at: foot.x, below: max(previousY, foot.y), clearance: height + 4, halfWidth: halfWidth) else {
                // Thrown off every screen: back to the nearest one
                if let screen = t.world.nearestScreen(to: foot) {
                    let ground = t.world.ground(screen)
                    let x = min(max(foot.x, ground.minX + halfWidth), ground.maxX - halfWidth)
                    state = .beamOut(start: t.now, to: Destination(support: ground.support, foot: CGPoint(x: x, y: ground.y)))
                }
                return
            }
            if velocity.dy <= 0, foot.y <= floor.y {
                land(on: floor, t)
            } else {
                state = .fall(velocity)
            }

        case .carried:
            break

        case .beamOut(let start, let destination):
            let p = min(1, max(0, (t.now - start) / Self.beamDuration))
            rig.beam = CGFloat(p)
            guard p >= 1 else { return }
            if isLeaving {
                isGone = true
                return
            }
            if let seed = pendingSeed { swapRig(seed) }
            if let destination {
                foot = destination.foot
                support = destination.support
                perchFrame = nil
            }
            state = .beamIn(start: t.now)

        case .beamIn(let start):
            let p = min(1, max(0, (t.now - start) / Self.beamDuration))
            rig.beam = 1 - CGFloat(p)
            guard p >= 1 else { return }
            if support == nil {
                state = .fall(.zero)
            } else {
                state = mood == .waiting ? .cheer(until: t.now + 2) : .idle(until: t.now + Double.random(in: 1...3))
            }

        case .sleep:
            guard keepFooting(t) else { return }
            if mood != .sleepy { state = .idle(until: t.now + 1) }

        case .cheer(let until):
            guard keepFooting(t) else { return }
            if mood != .waiting {
                state = .idle(until: t.now + 2)
            } else if t.now >= until {
                goToUser(t)
            }

        case .sit(let until):
            guard keepFooting(t) else { return }
            if mood == .waiting {
                goToUser(t)
            } else if mood == .sleepy {
                state = .sleep
            } else if t.now >= until {
                state = .idle(until: t.now + Double.random(in: 1...3))
            } else if Double.random(in: 0..<1) < t.dt * 0.1 {
                rig.fidget()
            }

        case .knock(let until):
            guard keepFooting(t) else { return }
            if mood != .waiting {
                state = .idle(until: t.now + 1)
                return
            }
            if t.now >= nextKnock {
                nextKnock = t.now + RobotRig.knockPeriod
                rig.emote(.knock, side: facing)
            }
            // Follows its window if it moved
            if t.now >= until { goToUser(t) }

        case .dizzy(let until):
            guard keepFooting(t) else { return }
            if t.now >= until { state = .idle(until: t.now + Double.random(in: 0.5...1.5)) }
        }
    }

    private func land(on floor: RobotWorld.Surface, _ t: Tick) {
        foot.y = floor.y
        support = floor.support
        if case .window(let id) = floor.support { perchFrame = t.world.window(id)?.frame }
        if t.now < dizzyUntil {
            dizzyUntil = max(dizzyUntil, t.now + 2.5)
            state = .dizzy(until: dizzyUntil)
        } else {
            state = .idle(until: t.now + Double.random(in: 1...3))
        }
        rig.land()
    }

    /// Follows the window it stands on, starts falling when that place is gone
    private func keepFooting(_ t: Tick) -> Bool {
        switch support {
        case nil:
            startFalling()
            return false
        case .ground(let id)?:
            guard let screen = t.world.screen(id) else {
                startFalling()
                return false
            }
            foot.y = screen.visible.minY
            return true
        case .window(let id)?:
            guard let window = t.world.window(id) else {
                startFalling()
                return false
            }
            // Carried along when the window moves
            if let perchFrame, perchFrame.minX != window.frame.minX { foot.x += window.frame.minX - perchFrame.minX }
            perchFrame = window.frame
            foot.y = window.frame.maxY
            guard t.world.surface(.window(id), at: foot.x, clearance: height + 4, halfWidth: halfWidth) != nil else {
                if !climbCover(over: window, t) { startFalling() }
                return false
            }
            return true
        }
    }

    private func currentSurface(_ world: RobotWorld) -> RobotWorld.Surface? {
        support.flatMap { world.surface($0, at: foot.x, clearance: height + 4, halfWidth: halfWidth) }
    }

    private func startFalling() {
        support = nil
        perchFrame = nil
        state = .fall(.zero)
    }

    private func dropOffWall(_ wall: RobotWorld.Wall, crawling: Bool) {
        endClimb()
        if crawling { foot.x -= wall.side * halfWidth }
        startFalling()
    }

    private func endClimb() {
        rig.orientation = 0
        ropeEnds = nil
    }

    /// Picks what to do next, according to its restlessness and its session's mood
    private func decide(_ mood: Mood, _ t: Tick) {
        guard let crew, let surface = currentSurface(t.world) else { return }
        let working = mood.tint == .working
        let restless = rig.genome.restlessness * (working ? 0.3 : 1)
        if Double.random(in: 0..<1) > restless + 0.1 {
            state = .idle(until: t.now + Double.random(in: 3...9) * (1.4 - restless))
            return
        }
        let world = t.world
        world.refreshWindows(maxAge: 0.5)

        // Goes to see another robot now and then, or plays tag with it
        if t.now >= socialAt, let other = crew.companion(for: self) {
            let roll = Double.random(in: 0..<1)
            if roll < 0.15 {
                let gap = halfWidth + other.halfWidth + 14
                let x = other.foot.x + (foot.x < other.foot.x ? -gap : gap)
                walk(to: min(max(x, surface.minX + halfWidth), surface.maxX - halfWidth), then: .visit(other.id))
                return
            }
            if roll < 0.22, crew.startChase(by: self, of: other, on: surface, now: t.now) { return }
        }

        // Teammates stick together: walks up to one, or beams next to one on another screen
        if let mate = crew.teammate(for: self), Double.random(in: 0..<1) < 0.4 {
            let gap = halfWidth + mate.halfWidth + 14
            if mate.support == support, abs(mate.foot.x - foot.x) > gap + 120 {
                let x = mate.foot.x + (foot.x < mate.foot.x ? -gap : gap)
                walk(to: min(max(x, surface.minX + halfWidth), surface.maxX - halfWidth), then: .visit(mate.id))
                return
            }
            if mate.support != support, case .ground(let id)? = mate.support, let screen = world.screen(id) {
                let ground = world.ground(screen)
                let x = crew.freeSpot(on: ground, near: mate.foot.x + (Bool.random() ? gap : -gap), for: self)
                state = .beamOut(start: t.now, to: Destination(support: ground.support, foot: CGPoint(x: x, y: ground.y)))
                return
            }
        }
        let withTeam = crew.hasTeammate(of: self, on: support)

        if Prefs.shared.robotsClimb, !working, Double.random(in: 0..<1) < 0.4, let (wall, style, x) = pickClimb(from: surface, world) {
            walk(to: Ascent.base(wallX: x, side: wall.side, halfWidth: halfWidth, style: style), then: .climb(wall, style))
            return
        }
        if case .window = surface.support, Double.random(in: 0..<1) < 0.35 {
            state = .sit(until: t.now + Double.random(in: 8...20))
            return
        }
        if case .window = surface.support, Double.random(in: 0..<1) < 0.3 {
            let side: CGFloat = Bool.random() ? 1 : -1
            walk(to: side > 0 ? surface.maxX : surface.minX, then: .jump(side))
            return
        }
        if case .ground(let id) = surface.support, !withTeam, Double.random(in: 0..<1) < 0.2, let screen = world.screen(id) {
            let side: CGFloat = Bool.random() ? 1 : -1
            if let neighbor = world.neighbor(of: screen, side: side) {
                walk(to: side > 0 ? screen.frame.maxX + halfWidth : screen.frame.minX - halfWidth, then: .cross(neighbor))
                return
            }
        }
        // Screens that don't share a ground (one above the other): beams over now and then
        let here = world.screen(containing: CGPoint(x: foot.x, y: foot.y + 1))?.id
        if !withTeam, Double.random(in: 0..<1) < 0.06, let other = world.screens.filter({ $0.id != here }).randomElement() {
            let ground = world.ground(other)
            let x = crew.freeSpot(on: ground, near: nil, for: self)
            state = .beamOut(start: t.now, to: Destination(support: ground.support, foot: CGPoint(x: x, y: ground.y)))
            return
        }
        let x = crew.freeSpot(on: surface, near: nil, for: self)
        if abs(x - foot.x) > 30 {
            walk(to: x, then: .rest)
            crew.lead(self, to: x, on: surface, now: t.now)
        } else {
            state = .idle(until: t.now + Double.random(in: 2...5))
        }
    }

    /// A window to climb, by one of its sides or straight up its face, and how
    private func pickClimb(from surface: RobotWorld.Surface, _ world: RobotWorld) -> (RobotWorld.Wall, ClimbStyle, CGFloat)? {
        let styles = rig.genome.climbStyles
        let sides: [(RobotWorld.Wall, ClimbStyle, CGFloat)] = world.walls(from: surface, halfWidth: halfWidth, height: height).compactMap { wall in
            guard let window = world.window(wall.window), let style = styles.randomElement() else { return nil }
            return (wall, style, wall.x(in: window.frame))
        }
        let faces: [(RobotWorld.Wall, ClimbStyle, CGFloat)] = world.faces(from: surface, halfWidth: halfWidth, height: height).compactMap { face in
            guard let style = faceStyles(touching: face.touches).randomElement() else { return nil }
            return (RobotWorld.Wall(window: face.window.id, side: 0, offset: face.x - face.window.frame.minX), style, face.x)
        }
        // Sides and faces get the same chance, however many of each there are
        return [sides, faces].filter { !$0.isEmpty }.randomElement()?.randomElement()
    }

    /// Straight up a face: no wall to drive on. Hands and springs need the window to come down to them.
    private func faceStyles(touching: Bool) -> [ClimbStyle] {
        rig.genome.climbStyles.filter { $0 == .fly || $0 == .grapple || (touching && ($0 == .hands || $0 == .bounce)) }
    }

    /// A window came in front of the one it stands on: climbs it when there is room on top, rather than falling through
    private func climbCover(over under: RobotWorld.Window, _ t: Tick) -> Bool {
        guard Prefs.shared.robotsClimb,
              let cover = t.world.windows.first(where: { $0.order < under.order && $0.frame.contains(CGPoint(x: foot.x, y: foot.y + 2)) }),
              let top = t.world.tops(of: cover, clearance: height + 8, minWidth: halfWidth * 2 + 10)
                .first(where: { $0.minX - halfWidth <= foot.x && foot.x <= $0.maxX + halfWidth }),
              let style = faceStyles(touching: true).randomElement() else { return false }
        foot.x = min(max(foot.x, top.minX + halfWidth), top.maxX - halfWidth)
        support = nil
        perchFrame = nil
        rig.emote(.exclaim, side: facing)
        let wall = RobotWorld.Wall(window: cover.id, side: 0, offset: foot.x - cover.frame.minX)
        state = .ascend(Ascent(style: style, side: 0, baseY: foot.y, start: t.now, halfWidth: halfWidth, height: height, speed: speed), wall)
        return true
    }

    private func arrive(_ next: Next, _ t: Tick) {
        paceBoost = 1
        switch next {
        case .rest:
            state = .idle(until: t.now + Double.random(in: 2...7))
        case .cheer:
            state = .cheer(until: t.now + 2)
        case .jump(let side):
            support = nil
            perchFrame = nil
            state = .fall(CGVector(dx: side * 60, dy: 200))
        case .climb(let wall, let style):
            if wall.side != 0 { facing = wall.side }
            state = .ascend(Ascent(style: style, side: wall.side, baseY: foot.y, start: t.now, halfWidth: halfWidth, height: height, speed: speed), wall)
        case .visit(let id):
            state = .idle(until: t.now + Double.random(in: 1...3))
            crew?.visited(id, by: self, now: t.now)
        case .tag(let id):
            state = .idle(until: t.now + Double.random(in: 1...3))
            crew?.tagged(id, by: self, now: t.now)
        case .knock(let side):
            startKnocking(facing: side, t)
        case .cross(let screen):
            let ground = t.world.ground(screen)
            support = .ground(screen.id)
            if ground.y < foot.y - 1 {
                support = nil
                state = .fall(CGVector(dx: facing * speed, dy: 0))
                return
            }
            foot.y = ground.y
            let x = crew?.freeSpot(on: ground, near: foot.x + facing * 240, for: self) ?? foot.x
            walk(to: x, then: .rest)
        }
    }

    /// Its session waits for you: knocks on its terminal's window when it is on the screen the pointer is on,
    /// otherwise comes to the pointer
    private func goToUser(_ t: Tick) {
        guard let crew, let screen = t.world.nearestScreen(to: t.mouse) else { return }
        if let (x, side) = knockSpot(on: screen, t) {
            let ground = t.world.ground(screen)
            if support != ground.support {
                state = .beamOut(start: t.now, to: Destination(support: ground.support, foot: CGPoint(x: x, y: ground.y)))
            } else if abs(x - foot.x) < 4 {
                startKnocking(facing: side, t)
            } else {
                walk(to: x, then: .knock(side))
            }
            return
        }
        let here = t.world.screen(containing: CGPoint(x: foot.x, y: foot.y + 1))
        if here?.id == screen.id, let surface = currentSurface(t.world) {
            let x = min(max(t.mouse.x, surface.minX + halfWidth), max(surface.minX + halfWidth, surface.maxX - halfWidth))
            if abs(x - foot.x) < 140 {
                state = .cheer(until: t.now + 2)
            } else {
                walk(to: crew.freeSpot(on: surface, near: x, for: self), then: .cheer)
            }
        } else {
            let ground = t.world.ground(screen)
            let x = crew.freeSpot(on: ground, near: t.mouse.x, for: self)
            state = .beamOut(start: t.now, to: Destination(support: ground.support, foot: CGPoint(x: x, y: ground.y)))
        }
    }

    /// Where to stand to knock on its terminal's frontmost window on that screen, and which way to face:
    /// beside a side that comes down to the ground, otherwise in front of the window
    private func knockSpot(on screen: RobotWorld.Screen, _ t: Tick) -> (CGFloat, CGFloat)? {
        guard let session, let app = TerminalFocus.hostApp(of: session) else { return nil }
        t.world.refreshWindows(maxAge: 0.5)
        guard let window = t.world.windows.first(where: { $0.owner == app.processIdentifier }),
              screen.frame.contains(CGPoint(x: window.frame.midX, y: window.frame.midY)) else { return nil }
        let ground = t.world.ground(screen), f = window.frame
        // Its window must come down to the robot
        guard f.minY <= ground.y + height * 0.5, f.maxY >= ground.y + height else { return nil }
        let lo = ground.minX + halfWidth, hi = ground.maxX - halfWidth
        guard lo < hi else { return nil }
        let sides = [(f.minX - rig.reach, CGFloat(1)), (f.maxX + rig.reach, CGFloat(-1))].filter { lo...hi ~= $0.0 }
        if let side = sides.min(by: { abs($0.0 - foot.x) < abs($1.0 - foot.x) }) { return side }
        // On the glass, near the pointer
        let x = min(max(t.mouse.x, max(lo, f.minX + halfWidth)), min(hi, max(lo, f.maxX - halfWidth)))
        return (x, t.mouse.x >= x ? 1 : -1)
    }

    private func startKnocking(facing side: CGFloat, _ t: Tick) {
        facing = side
        state = .knock(until: t.now + 5)
        if nextKnock < t.now { nextKnock = t.now + 0.15 }
    }

    // MARK: Subagents

    /// One small robot per running subagent of its session, at most six
    private func syncMinis(_ t: Tick) {
        if isStanding, let surface = currentSurface(t.world) {
            let margin = halfWidth * MiniBot.size + 4
            minisBounds = (surface.minX + margin)...max(surface.minX + margin, surface.maxX - margin)
        }
        let running = (session?.agents ?? []).prefix(6).map(\.id)
        for mini in minis where !running.contains(mini.id) { mini.leaving = true }
        for id in running where !minis.contains(where: { $0.id == id }) {
            let mini = MiniBot(id: id, genome: rig.genome, x: foot.x, scale: scale)
            minisLayer.addSublayer(mini.rig.layer)
            minis.append(mini)
        }
    }

    /// They run around it while it stands; climbing, falling or carried, they hide inside it
    private func updateMinis(_ t: Tick) {
        guard !minis.isEmpty else { return }
        let out = isStanding && rig.beam < 1 && !isLeaving
        if !out {
            if minisOut {
                minisOut = false
                minisLayer.isHidden = true
                minis.removeAll { mini in
                    mini.reset(at: foot.x)
                    if mini.leaving { mini.rig.layer.removeFromSuperlayer() }
                    return mini.leaving
                }
            }
            return
        }
        minisOut = true
        minisLayer.isHidden = false
        minisLayer.opacity = Float(1 - rig.beam)
        let origin = panel.frame.origin
        let bounds = minisBounds ?? (foot.x - 100)...(foot.x + 100)
        let mood: Mood = self.mood == .happy || self.mood.tint == .error ? self.mood : .focused
        for mini in minis {
            mini.update(now: t.now, dt: t.dt, home: foot.x, bounds: bounds, mood: mood)
            mini.place(foot: CGPoint(x: mini.x - origin.x, y: foot.y - origin.y))
        }
        minis.removeAll { mini in
            if mini.isGone { mini.rig.layer.removeFromSuperlayer() }
            return mini.isGone
        }
    }

    private func swapRig(_ seed: UInt64) {
        pendingSeed = nil
        rig.layer.removeFromSuperlayer()
        rig = RobotRig(genome: RobotGenome(seed: seed))
        rig.beam = 1
        rig.setContentsScale(scale)
        view.layer?.addSublayer(rig.layer)
        rope.strokeColor = rig.genome.accent.shaded(0.85).cg()
        lastFace = nil
        animator = FaceAnimator(mood: lastMood ?? .neutral)
        rig.setOutfit(outfit)
        rig.setTeam(team)
        // Its subagents change too
        minis.forEach { $0.rig.layer.removeFromSuperlayer() }
        minis.removeAll()
    }

    // MARK: Drawing

    private var squareRadius: CGFloat { ceil(max(height, halfWidth) + 12) }

    /// The robot's window is a stage covering the stretch it can move along: walking only moves a layer
    /// inside it, the window itself moves when the robot changes surface, falls or is carried.
    private func layout(_ world: RobotWorld?) {
        let r = squareRadius
        // Climbing, the robot turns around its foot
        var needed = abs(rig.orientation) > 0.1
            ? CGRect(x: foot.x - r, y: foot.y - r, width: r * 2, height: r * 2)
            : CGRect(x: foot.x - RobotRig.foot.x, y: foot.y - RobotRig.foot.y - Self.legroom,
                     width: RobotRig.canvasSize.width, height: RobotRig.canvasSize.height + Self.legroom + Self.headroom)
        // The hook's anchor must be on stage too
        if let world, case .ascend(_, let wall) = state, let window = world.window(wall.window) {
            needed = needed.union(CGRect(x: wall.x(in: window.frame) - 6, y: window.frame.maxY - 6, width: 12, height: 12))
        }
        if !panel.frame.contains(needed) {
            var stage = needed
            if let world, isStanding, let surface = currentSurface(world) {
                stage = CGRect(x: surface.minX - RobotRig.foot.x, y: surface.y - RobotRig.foot.y - Self.legroom,
                               width: surface.maxX - surface.minX + RobotRig.canvasSize.width,
                               height: RobotRig.canvasSize.height + Self.legroom + Self.headroom).union(needed)
            } else if let world, case .ascend(_, let wall) = state, let window = world.window(wall.window) {
                // The whole way up: beside the wall, over it, on top of it
                let x = wall.x(in: window.frame)
                stage = CGRect(x: x - 170, y: foot.y - r, width: 340, height: max(0, window.frame.maxY - foot.y) + r + 160).union(needed)
            }
            panel.setFrame(stage.integral, display: false)
        }
        let origin = panel.frame.origin
        let position = CGPoint(x: foot.x - origin.x - RobotRig.foot.x, y: foot.y - origin.y - RobotRig.foot.y)
        if case .walk(let target, _) = state {
            // The whole walk is one animation: no work per frame while it lasts
            if walkAnimation?.target != target || walkAnimation?.origin != origin || walkAnimation?.pace != walkPace {
                let end = CGPoint(x: target - origin.x - RobotRig.foot.x, y: position.y)
                let animation = CABasicAnimation(keyPath: "position")
                animation.fromValue = position
                animation.toValue = end
                animation.duration = Double(abs(target - foot.x) / walkPace)
                animation.timingFunction = CAMediaTimingFunction(name: .linear)
                animation.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
                rig.layer.position = end
                rig.layer.add(animation, forKey: "walk")
                walkAnimation = (target, origin, walkPace)
            }
        } else {
            if walkAnimation != nil {
                rig.layer.removeAnimation(forKey: "walk")
                walkAnimation = nil
            }
            if rig.layer.position != position { rig.layer.position = position }
        }
        if case .ascend = state, let ropeEnds {
            let a = CGPoint(x: ropeEnds.from.x - origin.x, y: ropeEnds.from.y - origin.y)
            let b = CGPoint(x: ropeEnds.to.x - origin.x, y: ropeEnds.to.y - origin.y)
            let path = CGMutablePath()
            path.move(to: a)
            path.addLine(to: b)
            // The hook, gripping the edge
            path.move(to: CGPoint(x: b.x - 4.5, y: b.y + 3.5))
            path.addQuadCurve(to: CGPoint(x: b.x + 4.5, y: b.y + 3.5), control: CGPoint(x: b.x, y: b.y - 5))
            rope.path = path
            rope.isHidden = false
        } else if !rope.isHidden {
            rope.isHidden = true
        }
        if panel.backingScaleFactor != scale {
            scale = panel.backingScaleFactor
            rig.setContentsScale(scale)
            rope.contentsScale = scale
            minis.forEach { $0.rig.setContentsScale(scale) }
        }
    }

    private func updateFace(_ mood: Mood, _ t: Tick) {
        guard panel.occlusionState.contains(.visible) else { return }
        animator.lookAt = gaze(toward: t.mouse)
        animator.dizzyUntil = dizzyUntil
        // Petted, it squints with pleasure
        let shown = t.now < petUntil && mood != .waiting && mood != .sleepy ? Mood.happy : mood
        let face = animator.frame(for: shown, color: session?.look.color, at: t.now)
        if let lastFace, face.isClose(to: lastFace) { return }
        rig.face.apply(face, in: rig.faceRect)
        lastFace = face
    }

    /// Its eyes follow the pointer when it comes close, in face units
    private func gaze(toward mouse: CGPoint) -> CGPoint? {
        guard isStanding, mood != .sleepy, abs(rig.orientation) < 0.1, rig.beam == 0 else { return nil }
        return rig.gaze(at: mouse, foot: foot, facing: facing, sitting: isSitting)
    }

    /// Turning around and pose changes are animated
    private func updateMotion() {
        CATransaction.begin()
        CATransaction.setDisableActions(false)
        defer { CATransaction.commit() }
        if rig.facing != facing { rig.facing = facing }
        let motion: RobotMotion
        switch state {
        case .walk: motion = .walk
        case .ascend: motion = ascentMotion
        case .fall, .carried: motion = .fall
        case .cheer: motion = .cheer
        case .sleep: motion = .sleep
        case .sit: motion = .sit
        case .knock: motion = .knock
        case .dizzy: motion = .dizzy
        default: motion = .idle
        }
        // Tools only in its hands while it stands awake
        rig.setProp(isStanding && !isAsleep ? shownProp : nil)
        rig.setMotion(motion)
        let shadow = isStanding && !isSitting
        if rig.showsShadow != shadow { rig.showsShadow = shadow }
    }

    /// The robot's drawn area on screen
    private var worldBounds: CGRect {
        rig.bounds(foot: foot, facing: facing, sitting: isSitting)
    }

    /// Slow pointer moves over it add up to a petting: hearts, a wiggle and a happy face.
    /// A quick pass doesn't count.
    private func notePetting(over: Bool, _ t: Tick) {
        guard pet.note(t.mouse, over: over && isStanding && rig.beam == 0, dt: t.dt, now: t.now) else { return }
        petUntil = t.now + 2.2
        rig.burst(.hearts)
        rig.wiggle()
    }

    /// Clicks only land on the robot itself: the rest of its window lets them through.
    /// Hovering it, waiting for you or a new state of its session shows its bubble.
    private func updatePointer(_ mood: Mood, _ t: Tick) {
        let bounds = worldBounds
        let carried: Bool = { if case .carried = state { return true } else { return false } }()
        let over = bounds.contains(t.mouse)
        let ignores = isLeaving || !(over || carried)
        if panel.ignoresMouseEvents != ignores { panel.ignoresMouseEvents = ignores }
        notePetting(over: over && !carried, t)

        guard let session, !isLeaving, !carried, rig.beam == 0, over || mood == .waiting || t.now < bubbleUntil else {
            bubble.hide()
            return
        }
        bubble.show(title: session.displayTitle, status: session.statusText(at: t.wallNow), color: mood.tint.color,
                    above: bounds, screen: t.world.nearestScreen(to: CGPoint(x: bounds.midX, y: bounds.midY)))
    }
}

// MARK: - Pointer

/// Back-and-forth moves of the pointer while a robot is carried: four turns within 1.2 s make it dizzy
struct ShakeMeter {
    private var from: CGPoint?
    private var direction = CGVector.zero
    private var turns: [CFTimeInterval] = []

    mutating func start(at point: CGPoint) {
        from = point
        direction = .zero
        turns = []
    }

    /// True once the pointer has turned back often enough
    mutating func note(_ point: CGPoint, now: CFTimeInterval) -> Bool {
        guard let from else { return false }
        let move = CGVector(dx: point.x - from.x, dy: point.y - from.y)
        let length = hypot(move.dx, move.dy)
        guard length > 12 else { return false }
        if move.dx * direction.dx + move.dy * direction.dy < 0 { turns.append(now) }
        direction = CGVector(dx: move.dx / length, dy: move.dy / length)
        self.from = point
        turns.removeAll { now - $0 > 1.2 }
        return turns.count >= 4
    }
}

/// Slow pointer moves over a robot add up to a petting. A quick pass (over 900 pt/s) doesn't count.
struct PetMeter {
    private var amount: CGFloat = 0
    private var last: CGPoint?
    private var nextAt: CFTimeInterval = 0

    /// True when the moves add up to a petting, at most every 3 s
    mutating func note(_ mouse: CGPoint, over: Bool, dt: Double, now: CFTimeInterval) -> Bool {
        let moved = last.map { hypot(mouse.x - $0.x, mouse.y - $0.y) } ?? 0
        last = mouse
        if moved / CGFloat(max(dt, 0.001)) > 900 {
            amount = 0
        } else if over {
            amount += moved
        } else {
            amount = max(0, amount - CGFloat(dt) * 300)
        }
        guard amount > 300, now >= nextAt else { return false }
        amount = 0
        nextAt = now + 3
        return true
    }
}

extension RobotRig {
    /// Where its eyes look for a pointer at mouse (face units), nil when the pointer is over 260 pt away
    func gaze(at mouse: CGPoint, foot: CGPoint, facing: CGFloat, sitting: Bool) -> CGPoint? {
        let dx = mouse.x - foot.x
        let dy = mouse.y - (foot.y + faceCenterY - (sitting ? sitDrop : 0))
        guard hypot(dx, dy) < 260 else { return nil }
        // The face is mirrored with the robot
        return CGPoint(x: max(-1, min(1, dx / 150)) * 0.85 * facing, y: max(-1, min(1, dy / 150)) * 0.6)
    }

    /// Its drawn area, for its foot at foot in the same coordinates
    func bounds(foot: CGPoint, facing: CGFloat, sitting: Bool) -> CGRect {
        var e = extent
        if facing < 0 { e = CGRect(x: -e.maxX, y: e.minY, width: e.width, height: e.height) }
        if sitting { e = e.offsetBy(dx: 0, dy: -sitDrop) }
        let angle = orientation
        guard abs(angle) > 0.01 else { return e.offsetBy(dx: foot.x, dy: foot.y) }
        let c = cos(angle), s = sin(angle)
        let corners = [CGPoint(x: e.minX, y: e.minY), CGPoint(x: e.maxX, y: e.minY), CGPoint(x: e.minX, y: e.maxY), CGPoint(x: e.maxX, y: e.maxY)]
            .map { CGPoint(x: foot.x + $0.x * c - $0.y * s, y: foot.y + $0.x * s + $0.y * c) }
        let xs = corners.map(\.x), ys = corners.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }
}

// MARK: - Windows

final class RobotPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    // A stage can hang over another screen's menu bar: AppKit would push it below the bar, out of reach of its robot
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Click: the session's terminal. Drag: picks the robot up. Right click: its menu.
final class RobotView: NSView {
    weak var agent: RobotAgent?
    private var downAt: CGPoint?
    private var dragging = false
    private var trail: [(point: CGPoint, time: CFTimeInterval)] = []

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            agent?.showMenu(event, in: self)
            return
        }
        downAt = NSEvent.mouseLocation
        dragging = false
        trail = []
    }

    override func mouseDragged(with event: NSEvent) {
        guard let downAt else { return }
        let point = NSEvent.mouseLocation
        if !dragging, hypot(point.x - downAt.x, point.y - downAt.y) > 3 {
            dragging = true
            agent?.pickUp(at: downAt)
        }
        guard dragging else { return }
        let now = CACurrentMediaTime()
        trail.append((point, now))
        trail.removeAll { now - $0.time > 0.1 }
        agent?.carry(to: point)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            downAt = nil
            dragging = false
        }
        guard downAt != nil else { return }
        guard dragging else {
            agent?.click()
            return
        }
        var velocity = CGVector.zero
        if let first = trail.first, let last = trail.last, last.time - first.time > 0.01 {
            let dt = CGFloat(last.time - first.time)
            velocity = CGVector(dx: (last.point.x - first.point.x) / dt, dy: (last.point.y - first.point.y) / dt)
        }
        agent?.drop(velocity: velocity)
    }

    override func rightMouseDown(with event: NSEvent) {
        agent?.showMenu(event, in: self)
    }
}

/// The session's name and what it is doing, above its robot
final class RobotBubble {
    private var panel: NSPanel?
    private let view = BubbleView()

    func show(title: String, status: String, color: NSColor, above robot: CGRect, screen: RobotWorld.Screen?) {
        let panel = self.panel ?? makePanel()
        view.update(title: title, status: status, color: color)
        let size = view.preferredSize
        var origin = CGPoint(x: robot.midX - size.width / 2, y: robot.maxY + 4)
        if let screen {
            origin.x = min(max(origin.x, screen.visible.minX + 4), screen.visible.maxX - size.width - 4)
            origin.y = min(origin.y, screen.visible.maxY - size.height - 2)
        }
        let frame = NSRect(origin: CGPoint(x: origin.x.rounded(), y: origin.y.rounded()), size: size)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func hide() {
        if panel?.isVisible == true { panel?.orderOut(nil) }
    }

    func close() {
        panel?.close()
    }

    private func makePanel() -> NSPanel {
        let panel = RobotPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = view
        self.panel = panel
        return panel
    }
}

final class BubbleView: NSView {
    private static let titleFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    private static let statusFont = NSFont.systemFont(ofSize: 10, weight: .medium)
    private static let maxTextWidth: CGFloat = 220

    private var title = ""
    private var status = ""
    private var color = NSColor.white
    private(set) var preferredSize = NSSize(width: 40, height: 36)

    func update(title: String, status: String, color: NSColor) {
        guard title != self.title || status != self.status || color != self.color else { return }
        self.title = title
        self.status = status
        self.color = color
        let width = max((title as NSString).size(withAttributes: [.font: Self.titleFont]).width,
                        (status as NSString).size(withAttributes: [.font: Self.statusFont]).width)
        preferredSize = NSSize(width: ceil(min(width, Self.maxTextWidth)) + 20, height: 36)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 9, yRadius: 9)
        NSColor(white: 0.07, alpha: 0.9).setFill()
        path.fill()
        NSColor(white: 1, alpha: 0.14).setStroke()
        path.stroke()

        let truncating = NSMutableParagraphStyle()
        truncating.lineBreakMode = .byTruncatingTail
        truncating.alignment = .center
        let width = bounds.width - 20
        (title as NSString).draw(in: NSRect(x: 10, y: 18, width: width, height: 14),
                                 withAttributes: [.font: Self.titleFont, .foregroundColor: NSColor(white: 1, alpha: 0.92), .paragraphStyle: truncating])
        (status as NSString).draw(in: NSRect(x: 10, y: 5, width: width, height: 13),
                                  withAttributes: [.font: Self.statusFont, .foregroundColor: color, .paragraphStyle: truncating])
    }
}
