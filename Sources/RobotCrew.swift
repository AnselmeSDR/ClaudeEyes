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
        updateTimer()
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
        for agent in all { agent.update(tick) }
        CATransaction.commit()
        leaving.removeAll { agent in
            guard agent.isGone else { return false }
            agent.close()
            return true
        }
        if agents.isEmpty, leaving.isEmpty { updateTimer() }
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
        case rest, cheer, jump(CGFloat), climb(RobotWorld.Wall), cross(RobotWorld.Screen)
    }

    private enum State {
        case idle(until: CFTimeInterval)
        case walk(to: CGFloat, then: Next)
        case mount(RobotWorld.Wall, start: CFTimeInterval, from: CGPoint)
        case climb(RobotWorld.Wall)
        case dismount(RobotWorld.Wall, start: CFTimeInterval)
        case fall(CGVector)
        case carried
        case beamOut(start: CFTimeInterval, to: Destination?)
        case beamIn(start: CFTimeInterval)
        case sleep
        case cheer(until: CFTimeInterval)
    }

    private static let gravity: CGFloat = 1600
    private static let beamDuration = 0.35
    private static let turnDuration = 0.45

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
    private var walkAnimation: (target: CGFloat, origin: CGPoint)?
    private var pendingSeed: UInt64?
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
    private var walkPace: CGFloat { speed * (mood == .waiting ? 1.8 : 1) }

    /// Up on a window, climbing or falling: the window frames must be fresh
    var needsWindows: Bool {
        switch state {
        case .fall, .mount, .climb, .dismount: return true
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
        support = nil
        perchFrame = nil
        state = .carried
        bubble.hide()
        updateMotion()
    }

    func carry(to point: CGPoint) {
        guard case .carried = state else { return }
        foot = CGPoint(x: point.x + grab.dx, y: point.y + grab.dy)
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
        }
        react(to: mood, t)
        step(mood, t)
        layout(t.world)
        updateFace(mood, t.now)
        updateMotion()
        updatePointer(mood, t)
    }

    private var isStanding: Bool {
        switch state {
        case .idle, .walk, .sleep, .cheer: return true
        default: return false
        }
    }

    private var isClimbing: Bool {
        switch state {
        case .mount, .climb, .dismount: return true
        default: return false
        }
    }

    private func react(to mood: Mood, _ t: Tick) {
        defer { lastMood = mood }
        guard mood != lastMood, isStanding else { return }
        if mood == .waiting {
            goToUser(t)
        } else if mood == .sleepy {
            state = .sleep
        } else {
            switch state {
            case .sleep, .cheer, .walk(_, .cheer): state = .idle(until: t.now + Double.random(in: 1...3))
            default: break
            }
            if mood == .happy, lastMood != nil { rig.celebrate() }
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
            let distance = target - foot.x
            let stride = CGFloat(t.dt) * walkPace
            facing = distance >= 0 ? 1 : -1
            if abs(distance) <= stride {
                foot.x = target
                arrive(next, t)
            } else {
                foot.x += stride * facing
            }

        case .mount(let wall, let start, let from):
            guard let window = t.world.window(wall.window) else { return dropOffWall(wall) }
            let x = wall.side > 0 ? window.frame.minX : window.frame.maxX
            let e = eased(t.now - start)
            foot = CGPoint(x: lerp(from.x, x, e), y: lerp(from.y, from.y + halfWidth, e))
            rig.orientation = wall.side * .pi / 2 * e
            if e >= 1 { state = .climb(wall) }

        case .climb(let wall):
            guard let window = t.world.window(wall.window) else { return dropOffWall(wall) }
            foot.x = wall.side > 0 ? window.frame.minX : window.frame.maxX
            foot.y += speed * 0.75 * CGFloat(t.dt)
            if foot.y >= window.frame.maxY - halfWidth {
                foot.y = window.frame.maxY - halfWidth
                state = .dismount(wall, start: t.now)
            }

        case .dismount(let wall, let start):
            guard let window = t.world.window(wall.window) else { return dropOffWall(wall) }
            let x = wall.side > 0 ? window.frame.minX : window.frame.maxX
            let e = eased(t.now - start)
            foot = CGPoint(x: lerp(x, x + wall.side * halfWidth, e), y: lerp(window.frame.maxY - halfWidth, window.frame.maxY, e))
            rig.orientation = wall.side * .pi / 2 * (1 - e)
            if e >= 1 {
                endClimb()
                support = .window(wall.window)
                perchFrame = window.frame
                state = .idle(until: t.now + Double.random(in: 2...5))
                rig.land()
            }

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
        }
    }

    private func land(on floor: RobotWorld.Surface, _ t: Tick) {
        foot.y = floor.y
        support = floor.support
        if case .window(let id) = floor.support { perchFrame = t.world.window(id)?.frame }
        state = .idle(until: t.now + Double.random(in: 1...3))
        rig.land()
    }

    private func eased(_ elapsed: Double) -> CGFloat {
        let p = min(1, max(0, elapsed / Self.turnDuration))
        return CGFloat(p < 0.5 ? 2 * p * p : 1 - pow(-2 * p + 2, 2) / 2)
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
                startFalling()
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

    private func dropOffWall(_ wall: RobotWorld.Wall) {
        endClimb()
        foot.x -= wall.side * halfWidth
        startFalling()
    }

    private func endClimb() {
        rig.orientation = 0
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

        if Prefs.shared.robotsClimb, !working, Double.random(in: 0..<1) < 0.4,
           let wall = world.walls(from: surface, halfWidth: halfWidth, height: height).randomElement(),
           let window = world.window(wall.window) {
            let x = wall.side > 0 ? window.frame.minX : window.frame.maxX
            state = .walk(to: x - wall.side * halfWidth, then: .climb(wall))
            return
        }
        if case .window = surface.support, Double.random(in: 0..<1) < 0.3 {
            let side: CGFloat = Bool.random() ? 1 : -1
            state = .walk(to: side > 0 ? surface.maxX : surface.minX, then: .jump(side))
            return
        }
        if case .ground(let id) = surface.support, Double.random(in: 0..<1) < 0.2, let screen = world.screen(id) {
            let side: CGFloat = Bool.random() ? 1 : -1
            if let neighbor = world.neighbor(of: screen, side: side) {
                state = .walk(to: side > 0 ? screen.frame.maxX + halfWidth : screen.frame.minX - halfWidth, then: .cross(neighbor))
                return
            }
        }
        // Screens that don't share a ground (one above the other): beams over now and then
        let here = world.screen(containing: CGPoint(x: foot.x, y: foot.y + 1))?.id
        if Double.random(in: 0..<1) < 0.06, let other = world.screens.filter({ $0.id != here }).randomElement() {
            let ground = world.ground(other)
            let x = crew.freeSpot(on: ground, near: nil, for: self)
            state = .beamOut(start: t.now, to: Destination(support: ground.support, foot: CGPoint(x: x, y: ground.y)))
            return
        }
        let x = crew.freeSpot(on: surface, near: nil, for: self)
        state = abs(x - foot.x) > 30 ? .walk(to: x, then: .rest) : .idle(until: t.now + Double.random(in: 2...5))
    }

    private func arrive(_ next: Next, _ t: Tick) {
        switch next {
        case .rest:
            state = .idle(until: t.now + Double.random(in: 2...7))
        case .cheer:
            state = .cheer(until: t.now + 2)
        case .jump(let side):
            support = nil
            perchFrame = nil
            state = .fall(CGVector(dx: side * 60, dy: 200))
        case .climb(let wall):
            facing = wall.side
            state = .mount(wall, start: t.now, from: foot)
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
            state = .walk(to: x, then: .rest)
        }
    }

    /// Its session waits for you: comes to the screen the pointer is on
    private func goToUser(_ t: Tick) {
        guard let crew, let screen = t.world.nearestScreen(to: t.mouse) else { return }
        let here = t.world.screen(containing: CGPoint(x: foot.x, y: foot.y + 1))
        if here?.id == screen.id, let surface = currentSurface(t.world) {
            let x = min(max(t.mouse.x, surface.minX + halfWidth), max(surface.minX + halfWidth, surface.maxX - halfWidth))
            if abs(x - foot.x) < 140 {
                state = .cheer(until: t.now + 2)
            } else {
                state = .walk(to: crew.freeSpot(on: surface, near: x, for: self), then: .cheer)
            }
        } else {
            let ground = t.world.ground(screen)
            let x = crew.freeSpot(on: ground, near: t.mouse.x, for: self)
            state = .beamOut(start: t.now, to: Destination(support: ground.support, foot: CGPoint(x: x, y: ground.y)))
        }
    }

    private func swapRig(_ seed: UInt64) {
        pendingSeed = nil
        rig.layer.removeFromSuperlayer()
        rig = RobotRig(genome: RobotGenome(seed: seed))
        rig.beam = 1
        rig.setContentsScale(scale)
        view.layer?.addSublayer(rig.layer)
        lastFace = nil
        animator = FaceAnimator(mood: lastMood ?? .neutral)
    }

    // MARK: Drawing

    private var squareRadius: CGFloat { ceil(max(height, halfWidth) + 12) }

    /// The robot's window is a stage covering the stretch it can move along: walking only moves a layer
    /// inside it, the window itself moves when the robot changes surface, falls or is carried.
    private func layout(_ world: RobotWorld?) {
        let r = squareRadius
        // Climbing, the robot turns around its foot
        let needed = isClimbing
            ? CGRect(x: foot.x - r, y: foot.y - r, width: r * 2, height: r * 2)
            : CGRect(origin: CGPoint(x: foot.x - RobotRig.foot.x, y: foot.y - RobotRig.foot.y), size: RobotRig.canvasSize)
        if !panel.frame.contains(needed) {
            var stage = needed
            if let world, isStanding, let surface = currentSurface(world) {
                stage = CGRect(x: surface.minX - RobotRig.foot.x, y: surface.y - RobotRig.foot.y,
                               width: surface.maxX - surface.minX + RobotRig.canvasSize.width, height: RobotRig.canvasSize.height).union(needed)
            } else if let world, case .mount(let wall, _, _) = state, let window = world.window(wall.window) {
                let x = wall.side > 0 ? window.frame.minX : window.frame.maxX
                stage = CGRect(x: x - r - halfWidth, y: foot.y - r, width: (r + halfWidth) * 2, height: window.frame.maxY - foot.y + r * 2).union(needed)
            }
            panel.setFrame(stage.integral, display: false)
        }
        let origin = panel.frame.origin
        let position = CGPoint(x: foot.x - origin.x - RobotRig.foot.x, y: foot.y - origin.y - RobotRig.foot.y)
        if case .walk(let target, _) = state {
            // The whole walk is one animation: no work per frame while it lasts
            if walkAnimation?.target != target || walkAnimation?.origin != origin {
                let end = CGPoint(x: target - origin.x - RobotRig.foot.x, y: position.y)
                let animation = CABasicAnimation(keyPath: "position")
                animation.fromValue = position
                animation.toValue = end
                animation.duration = Double(abs(target - foot.x) / walkPace)
                animation.timingFunction = CAMediaTimingFunction(name: .linear)
                animation.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
                rig.layer.position = end
                rig.layer.add(animation, forKey: "walk")
                walkAnimation = (target, origin)
            }
        } else {
            if walkAnimation != nil {
                rig.layer.removeAnimation(forKey: "walk")
                walkAnimation = nil
            }
            if rig.layer.position != position { rig.layer.position = position }
        }
        if panel.backingScaleFactor != scale {
            scale = panel.backingScaleFactor
            rig.setContentsScale(scale)
        }
    }

    private func updateFace(_ mood: Mood, _ now: CFTimeInterval) {
        guard panel.occlusionState.contains(.visible) else { return }
        let face = animator.frame(for: mood, color: session?.look.color, at: now)
        if let lastFace, face.isClose(to: lastFace) { return }
        rig.face.apply(face, in: rig.faceRect)
        lastFace = face
    }

    /// Turning around and pose changes are animated
    private func updateMotion() {
        CATransaction.begin()
        CATransaction.setDisableActions(false)
        defer { CATransaction.commit() }
        if rig.facing != facing { rig.facing = facing }
        let motion: RobotMotion
        switch state {
        case .walk, .mount, .climb, .dismount: motion = .walk
        case .fall, .carried: motion = .fall
        case .cheer: motion = .cheer
        case .sleep: motion = .sleep
        default: motion = .idle
        }
        rig.setMotion(motion)
        if rig.showsShadow != isStanding { rig.showsShadow = isStanding }
    }

    /// The robot's drawn area on screen
    private var worldBounds: CGRect {
        var e = rig.extent
        if facing < 0 { e = CGRect(x: -e.maxX, y: e.minY, width: e.width, height: e.height) }
        let angle = rig.orientation
        guard abs(angle) > 0.01 else { return e.offsetBy(dx: foot.x, dy: foot.y) }
        let c = cos(angle), s = sin(angle)
        let corners = [CGPoint(x: e.minX, y: e.minY), CGPoint(x: e.maxX, y: e.minY), CGPoint(x: e.minX, y: e.maxY), CGPoint(x: e.maxX, y: e.maxY)]
            .map { CGPoint(x: foot.x + $0.x * c - $0.y * s, y: foot.y + $0.x * s + $0.y * c) }
        let xs = corners.map(\.x), ys = corners.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    /// Clicks only land on the robot itself: the rest of its window lets them through.
    /// Hovering it, waiting for you or a new state of its session shows its bubble.
    private func updatePointer(_ mood: Mood, _ t: Tick) {
        let bounds = worldBounds
        let carried: Bool = { if case .carried = state { return true } else { return false } }()
        let over = bounds.contains(t.mouse)
        let ignores = isLeaving || !(over || carried)
        if panel.ignoresMouseEvents != ignores { panel.ignoresMouseEvents = ignores }

        guard let session, !isLeaving, !carried, rig.beam == 0, over || mood == .waiting || t.now < bubbleUntil else {
            bubble.hide()
            return
        }
        bubble.show(title: session.displayTitle, status: session.statusText(at: t.wallNow), color: mood.tint.color,
                    above: bounds, screen: t.world.nearestScreen(to: CGPoint(x: bounds.midX, y: bounds.midY)))
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
