import AppKit
import QuartzCore

// MARK: - Random

/// SplitMix64: the same seed always builds the same robot
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

extension UInt64 {
    /// FNV-1a: stable across launches, unlike hashValue
    init(stableHash string: String) {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in string.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01B3 }
        self = hash
    }
}

// MARK: - Colors

struct RobotColor {
    var r: CGFloat
    var g: CGFloat
    var b: CGFloat

    init(r: CGFloat, g: CGFloat, b: CGFloat) {
        self.r = r
        self.g = g
        self.b = b
    }

    init(hue: CGFloat, saturation s: CGFloat, brightness v: CGFloat) {
        let h = (hue - floor(hue)) * 6
        let c = v * s
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let (r, g, b): (CGFloat, CGFloat, CGFloat)
        switch Int(h) {
        case 0: (r, g, b) = (c, x, 0)
        case 1: (r, g, b) = (x, c, 0)
        case 2: (r, g, b) = (0, c, x)
        case 3: (r, g, b) = (0, x, c)
        case 4: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        let m = v - c
        self.init(r: r + m, g: g + m, b: b + m)
    }

    func cg(alpha: CGFloat = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: alpha) }

    /// Below 1 darkens, above 1 mixes towards white
    func shaded(_ k: CGFloat) -> RobotColor {
        if k <= 1 { return RobotColor(r: r * k, g: g * k, b: b * k) }
        let t = min(1, k - 1)
        return RobotColor(r: lerp(r, 1, t), g: lerp(g, 1, t), b: lerp(b, 1, t))
    }

    var outline: CGColor { shaded(0.55).cg() }
}

// MARK: - Genome

/// Every part that varies from one robot to another, drawn from a seed
struct RobotGenome {
    enum Locomotion: CaseIterable { case tracks, wheels, unicycle, legs, quadruped, spring, hover, ball }
    enum BodyShape: CaseIterable { case box, barrel, egg, trapezoid, round, capsule }
    enum HeadShape: CaseIterable { case rounded, capsule, chamfer, crt, dome }
    enum Neck: CaseIterable { case none, post, spring, twin }
    enum Top: CaseIterable { case none, antenna, twinAntenna, springAntenna, propeller, crest, bulb }
    enum Sides: CaseIterable { case none, roundEars, catEars, headphones, dishes, bolts }
    enum Arms: CaseIterable { case none, sticks, claws, springs, noodles, fins }
    enum Chest: CaseIterable { case none, buttons, grille, light, gauge, panel }

    let seed: UInt64
    let locomotion: Locomotion
    let bodyShape: BodyShape
    let headShape: HeadShape
    let neck: Neck
    let top: Top
    let sides: Sides
    let arms: Arms
    let chest: Chest

    let headSize: CGSize
    let bodySize: CGSize
    /// Frame around the screen
    let bezel: CGFloat
    let armLength: CGFloat
    let antennaLength: CGFloat
    let antennaOffset: CGFloat
    let gaugeAngle: CGFloat

    let headColor: RobotColor
    let bodyColor: RobotColor
    let accent: RobotColor
    let joint: RobotColor
    let chestColors: [RobotColor]

    /// Points per second on the move
    let speed: CGFloat
    /// 0 stays put ... 1 always wandering
    let restlessness: Double

    init(seed: UInt64) {
        self.seed = seed
        var rng = SeededRandom(seed: seed)
        func r(_ range: ClosedRange<CGFloat>) -> CGFloat { CGFloat.random(in: range, using: &rng) }
        func chance(_ p: Double) -> Bool { Double.random(in: 0..<1, using: &rng) < p }
        func pick<T>(_ options: [(T, Double)]) -> T {
            var x = Double.random(in: 0..<options.reduce(0) { $0 + $1.1 }, using: &rng)
            for (value, weight) in options {
                if x < weight { return value }
                x -= weight
            }
            return options[0].0
        }

        locomotion = pick(Locomotion.allCases.map { ($0, 1) })
        bodyShape = pick(BodyShape.allCases.map { ($0, 1) })
        headShape = pick([(.rounded, 1.4), (.capsule, 1), (.chamfer, 1), (.crt, 0.8), (.dome, 0.8)])
        neck = pick([(.none, 1.2), (.post, 1), (.spring, 0.8), (.twin, 0.6)])
        sides = pick([(.none, 1.6), (.roundEars, 1), (.catEars, 0.7), (.headphones, 0.6), (.dishes, 0.6), (.bolts, 0.8)])
        // Headphones go over the head: only an antenna still fits
        top = sides == .headphones
            ? pick([(.none, 1), (.antenna, 1)])
            : pick([(.none, 1), (.antenna, 1.3), (.twinAntenna, 0.9), (.springAntenna, 0.8), (.propeller, 0.6), (.crest, 0.5), (.bulb, 0.6)])
        arms = pick([(.none, 1), (.sticks, 1.2), (.claws, 0.9), (.springs, 0.7), (.noodles, 0.8), (.fins, 0.7)])
        chest = pick([(.none, 0.8), (.buttons, 1), (.grille, 1), (.light, 1), (.gauge, 0.7), (.panel, 0.8)])

        let hh = r(40...45)
        let hw = r(56...63) + (headShape == .capsule ? 4 : 0)
        headSize = CGSize(width: hw, height: hh)
        bezel = r(4...5.5)
        let bh = r(22...30)
        switch bodyShape {
        case .round: bodySize = CGSize(width: bh + 4, height: bh + 4)
        case .capsule: bodySize = CGSize(width: bh * 0.95, height: bh + 4)
        default: bodySize = CGSize(width: r(36...min(50, hw - 6)), height: bh)
        }
        armLength = r(13...17)
        antennaLength = r(9...14)
        antennaOffset = chance(0.35) ? r(-hw * 0.25...hw * 0.25) : 0
        gaugeAngle = r(0.3...2.8)

        // Colors: a pleasant range rather than any RGB value
        let hue = r(0...1)
        if chance(0.28) {
            switch Int(r(0...2.99)) {
            case 0: headColor = RobotColor(hue: hue, saturation: 0.04, brightness: 0.95)
            case 1: headColor = RobotColor(hue: hue, saturation: 0.08, brightness: 0.78)
            default: headColor = RobotColor(hue: hue, saturation: 0.14, brightness: 0.38)
            }
            accent = RobotColor(hue: r(0...1), saturation: r(0.7...0.9), brightness: r(0.92...1))
        } else {
            headColor = RobotColor(hue: hue, saturation: r(0.35...0.7), brightness: r(0.78...0.95))
            let shift = pick([(0.5, 1.0), (0.42, 0.7), (0.58, 0.7), (0.33, 0.6), (-0.33, 0.6), (0.1, 0.5)]) as CGFloat
            accent = RobotColor(hue: hue + shift, saturation: r(0.7...0.9), brightness: r(0.92...1))
        }
        bodyColor = pick([(headColor, 2.4), (headColor.shaded(0.82), 1), (accent.shaded(0.88), 0.6)])
        joint = RobotColor(hue: hue, saturation: 0.15, brightness: r(0.2...0.28))
        chestColors = [accent,
                       RobotColor(hue: r(0...1), saturation: 0.8, brightness: 1),
                       RobotColor(hue: r(0...1), saturation: 0.8, brightness: 1)]

        switch locomotion {
        case .tracks: speed = r(22...30)
        case .wheels, .ball: speed = r(32...44)
        case .unicycle, .spring: speed = r(30...38)
        case .legs, .quadruped, .hover: speed = r(24...34)
        }
        restlessness = Double(r(0.2...0.9))
    }
}

// MARK: - Rig

enum RobotMotion {
    case idle, walk, cheer, sleep, fall
    /// Climbing: flying up, hanging from a rope, aiming the hook, hand over hand, bouncing off a wall
    case fly, hang, aim, climb, bounce
}

/// Core Animation layers built once from a genome. Motions are repeating CA animations
/// run by the render server: the app only computes the face.
final class RobotRig {
    static let canvasSize = CGSize(width: 140, height: 140)
    /// Ground contact point, centered, in the canvas
    static let foot = CGPoint(x: 70, y: 10)

    let genome: RobotGenome
    let layer = CALayer()
    let face = FaceLayer()
    private(set) var faceRect = CGRect.zero

    /// Everything the robot draws, in foot coordinates (upright)
    private(set) var extent = CGRect.zero

    private let shadow = CAShapeLayer()
    private let mount = RobotRig.group()
    private let bot = RobotRig.group()
    private let hopper = RobotRig.group()
    private let torso = RobotRig.group()
    private let head = RobotRig.group()
    private var spinners: [(layer: CALayer, radius: CGFloat)] = []
    private var treads: [CAShapeLayer] = []
    private var legs: [(layer: CALayer, phase: Double, rest: CGFloat)] = []
    private var arms: [(layer: CALayer, rest: CGFloat)] = []
    private var antennas: [CALayer] = []
    private var blade: CALayer?
    private var coil: CALayer?
    private var thruster: CALayer?
    private var motionKeys: [(CALayer, String)] = []
    private(set) var motion: RobotMotion = .idle
    private let emoteBubble = CALayer()
    private let emoteText = CATextLayer()
    /// Top of the head, in foot coordinates
    private var headTop: CGFloat = 0

    /// 1 faces right, -1 faces left. The flip is animated: the robot turns around
    var facing: CGFloat = 1 {
        didSet { bot.transform = CATransform3DMakeScale(facing, 1, 1) }
    }

    /// Rotation around the foot: 0 upright, π/2 climbing a wall on its right, -π/2 on its left
    var orientation: CGFloat = 0 {
        didSet { updateMount() }
    }

    /// 0 visible ... 1 beamed away
    var beam: CGFloat = 0 {
        didSet { updateMount() }
    }

    var showsShadow = true {
        didSet { shadow.opacity = showsShadow ? 1 : 0 }
    }

    init(genome: RobotGenome) {
        self.genome = genome
        layer.bounds = CGRect(origin: .zero, size: Self.canvasSize)
        layer.anchorPoint = .zero
        build()
        extent = Self.drawnBounds(of: bot, in: bot)
        headTop = head.convert(CGPoint(x: 0, y: genome.headSize.height), to: bot).y
        buildEmote()
    }

    private func updateMount() {
        mount.transform = CATransform3DScale(CATransform3DMakeRotation(orientation, 0, 0, 1), 1 - 0.8 * beam, 1 + 0.5 * beam, 1)
        mount.opacity = Float(1 - beam)
    }

    private static func drawnBounds(of layer: CALayer, in root: CALayer) -> CGRect {
        var rect = CGRect.null
        if let shape = layer as? CAShapeLayer, let path = shape.path {
            let box = path.boundingBoxOfPath.insetBy(dx: -shape.lineWidth / 2, dy: -shape.lineWidth / 2)
            rect = layer.convert(box, to: root)
        }
        for sublayer in layer.sublayers ?? [] {
            rect = rect.union(drawnBounds(of: sublayer, in: root))
        }
        return rect
    }

    // MARK: Building

    private static func group(at p: CGPoint = .zero) -> CALayer {
        let layer = CALayer()
        // Tiny bounds centered on the origin: the anchor point is the local origin, so the layer rotates around it
        layer.bounds = CGRect(x: -1, y: -1, width: 2, height: 2)
        layer.position = p
        return layer
    }

    private func shape(_ path: CGPath, fill: CGColor?, stroke: CGColor? = nil, width: CGFloat = 1.4,
                       at p: CGPoint = .zero) -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.bounds = CGRect(x: -1, y: -1, width: 2, height: 2)
        layer.position = p
        layer.path = path
        layer.fillColor = fill
        layer.strokeColor = stroke
        layer.lineWidth = stroke == nil ? 0 : width
        layer.lineCap = .round
        layer.lineJoin = .round
        return layer
    }

    /// Light from above: lighter top, darker bottom, drawn once into a bitmap clipped to the part
    private func shading(_ path: CGPath) -> CALayer {
        let box = path.boundingBoxOfPath
        let layer = CALayer()
        layer.frame = box
        let scale: CGFloat = 3
        guard let ctx = CGContext(data: nil, width: Int(ceil(box.width * scale)), height: Int(ceil(box.height * scale)), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return layer }
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -box.minX, y: -box.minY)
        ctx.addPath(path)
        ctx.clip()
        let colors = [CGColor(gray: 1, alpha: 0.28), CGColor(gray: 1, alpha: 0), CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 0.2)] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 0.45, 0.55, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: box.maxY), end: CGPoint(x: 0, y: box.minY), options: [])
        }
        layer.contents = ctx.makeImage()
        return layer
    }

    /// Filled part with a darker outline
    private func part(_ path: CGPath, _ color: RobotColor, at p: CGPoint = .zero) -> CAShapeLayer {
        shape(path, fill: color.cg(), stroke: color.outline, at: p)
    }

    private func line(_ points: [CGPoint], _ color: CGColor, width: CGFloat) -> CAShapeLayer {
        let path = CGMutablePath()
        path.addLines(between: points)
        return shape(path, fill: nil, stroke: color, width: width)
    }

    private func build() {
        let g = genome
        layer.addSublayer(shadow)
        mount.position = Self.foot
        layer.addSublayer(mount)
        mount.addSublayer(bot)
        bot.addSublayer(hopper)

        let bodyY = buildLocomotion()
        shadow.position = Self.foot
        let shadowWidth = max(g.bodySize.width, 40) * (g.locomotion == .hover ? 0.7 : 1.05)
        shadow.path = CGPath(ellipseIn: CGRect(x: -shadowWidth / 2, y: -3, width: shadowWidth, height: 6), transform: nil)
        shadow.fillColor = CGColor(gray: 0, alpha: g.locomotion == .hover ? 0.16 : 0.24)
        shadow.bounds = CGRect(x: -1, y: -1, width: 2, height: 2)

        torso.position = CGPoint(x: 0, y: bodyY)
        hopper.addSublayer(torso)
        let bh = g.bodySize.height

        buildArms()
        let neckHeight: CGFloat
        switch g.neck {
        case .none: neckHeight = -3
        case .post:
            neckHeight = 6
            torso.addSublayer(part(CGPath(rect: CGRect(x: -4.5, y: bh - 3, width: 9, height: neckHeight + 6), transform: nil), g.joint))
        case .spring:
            neckHeight = 9
            torso.addSublayer(shape(zigzag(from: CGPoint(x: 0, y: bh - 2), to: CGPoint(x: 0, y: bh + neckHeight + 2), width: 11, turns: 3),
                                    fill: nil, stroke: g.joint.cg(), width: 2.2))
        case .twin:
            neckHeight = 6
            for x: CGFloat in [-8, 8] {
                torso.addSublayer(part(CGPath(rect: CGRect(x: x - 2, y: bh - 3, width: 4, height: neckHeight + 6), transform: nil), g.joint))
            }
        }

        let body = bodyPath()
        torso.addSublayer(part(body, g.bodyColor))
        torso.addSublayer(shading(body))
        buildChest()

        head.position = CGPoint(x: 0, y: bh + neckHeight)
        torso.addSublayer(head)
        buildHead()
    }

    /// Adds the wheels, legs... and returns the height of the body's bottom
    private func buildLocomotion() -> CGFloat {
        let g = genome
        let bw = g.bodySize.width
        switch g.locomotion {
        case .tracks:
            let width = max(bw + 8, 46), height: CGFloat = 15
            let rect = CGRect(x: -width / 2, y: 0, width: width, height: height)
            hopper.addSublayer(part(capsule(rect), g.joint))
            for x in [rect.minX + 7.5, 0, rect.maxX - 7.5] {
                let wheel = Self.group(at: CGPoint(x: x, y: height / 2))
                wheel.addSublayer(shape(CGPath(ellipseIn: CGRect(x: -4.5, y: -4.5, width: 9, height: 9), transform: nil), fill: g.bodyColor.shaded(0.7).cg()))
                wheel.addSublayer(shape(CGPath(ellipseIn: CGRect(x: 1, y: -1, width: 2, height: 2), transform: nil), fill: g.joint.cg()))
                hopper.addSublayer(wheel)
                spinners.append((wheel, 4.5))
            }
            let tread = shape(capsule(rect.insetBy(dx: 1.2, dy: 1.2)), fill: nil, stroke: CGColor(gray: 0, alpha: 0.55), width: 2.4)
            tread.lineDashPattern = [2.5, 2.5]
            tread.lineCap = .butt
            hopper.addSublayer(tread)
            treads.append(tread)
            return 12

        case .wheels:
            for x in [-(bw / 2 - 3), bw / 2 - 3] {
                hopper.addSublayer(wheel(at: CGPoint(x: x, y: 9), radius: 9))
            }
            hopper.addSublayer(line([CGPoint(x: -(bw / 2 - 3), y: 9), CGPoint(x: bw / 2 - 3, y: 9)], g.joint.cg(), width: 3))
            return 11

        case .unicycle:
            hopper.addSublayer(line([CGPoint(x: -5, y: 11), CGPoint(x: -3, y: 26), CGPoint(x: 3, y: 26), CGPoint(x: 5, y: 11)], g.joint.cg(), width: 2.6))
            hopper.addSublayer(wheel(at: CGPoint(x: 0, y: 11), radius: 11))
            return 23

        case .legs:
            let hipX = min(bw / 2 - 8, 12)
            for (i, x) in [-hipX, hipX].enumerated() {
                let leg = Self.group(at: CGPoint(x: x, y: 19))
                leg.addSublayer(part(roundedRect(CGRect(x: -2.6, y: -15, width: 5.2, height: 17), 2.6), g.joint))
                leg.addSublayer(part(roundedRect(CGRect(x: -6.5, y: -19, width: 13, height: 6), 3), g.bodyColor.shaded(0.85)))
                hopper.addSublayer(leg)
                legs.append((leg, Double(i) * 0.5, 0))
            }
            return 16

        case .quadruped:
            for (i, x) in [-bw * 0.4, -bw * 0.15, bw * 0.15, bw * 0.4].enumerated() {
                let leg = Self.group(at: CGPoint(x: x, y: 12))
                leg.addSublayer(line([CGPoint(x: 0, y: 2), CGPoint(x: 0, y: -8)], g.joint.cg(), width: 3.4))
                leg.addSublayer(shape(CGPath(ellipseIn: CGRect(x: -3.2, y: -12, width: 6.4, height: 5), transform: nil), fill: g.accent.cg(), stroke: g.accent.outline, width: 1))
                let rest: CGFloat = x < 0 ? -0.18 : 0.18
                leg.transform = CATransform3DMakeRotation(rest, 0, 0, 1)
                hopper.addSublayer(leg)
                legs.append((leg, i % 2 == 0 ? 0 : 0.5, rest))
            }
            return 10

        case .spring:
            hopper.addSublayer(shape(CGPath(ellipseIn: CGRect(x: -11, y: 0, width: 22, height: 6), transform: nil), fill: g.joint.cg(), stroke: g.joint.outline, width: 1))
            let spring = Self.group(at: CGPoint(x: 0, y: 4))
            spring.addSublayer(shape(zigzag(from: .zero, to: CGPoint(x: 0, y: 17), width: 12, turns: 3), fill: nil, stroke: g.accent.shaded(0.8).cg(), width: 2.4))
            hopper.addSublayer(spring)
            coil = spring
            return 19

        case .hover:
            let glow = shape(CGPath(ellipseIn: CGRect(x: -7, y: 6, width: 14, height: 9), transform: nil), fill: g.accent.cg(alpha: 0.8))
            glow.shadowColor = g.accent.cg()
            glow.shadowOpacity = 0.9
            glow.shadowRadius = 4
            glow.shadowOffset = .zero
            hopper.addSublayer(glow)
            thruster = glow
            let nozzle = CGMutablePath()
            nozzle.addLines(between: [CGPoint(x: -9, y: 20), CGPoint(x: 9, y: 20), CGPoint(x: 6, y: 12), CGPoint(x: -6, y: 12)])
            nozzle.closeSubpath()
            hopper.addSublayer(part(nozzle, g.joint))
            return 18

        case .ball:
            let ball = Self.group(at: CGPoint(x: 0, y: 13))
            ball.addSublayer(part(CGPath(ellipseIn: CGRect(x: -13, y: -13, width: 26, height: 26), transform: nil), g.accent.shaded(0.92)))
            let stripe = CGMutablePath()
            stripe.addArc(center: .zero, radius: 8, startAngle: 0.4, endAngle: 2.2, clockwise: false)
            stripe.move(to: CGPoint(x: 8 * cos(3.5), y: 8 * sin(3.5)))
            stripe.addArc(center: .zero, radius: 8, startAngle: 3.5, endAngle: 5.3, clockwise: false)
            ball.addSublayer(shape(stripe, fill: nil, stroke: g.bodyColor.cg(), width: 3))
            hopper.addSublayer(ball)
            spinners.append((ball, 13))
            return 22
        }
    }

    private func wheel(at center: CGPoint, radius: CGFloat) -> CALayer {
        let g = genome
        let wheel = Self.group(at: center)
        wheel.addSublayer(part(CGPath(ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2), transform: nil), g.joint))
        let rim = radius * 0.55
        wheel.addSublayer(shape(CGPath(ellipseIn: CGRect(x: -rim, y: -rim, width: rim * 2, height: rim * 2), transform: nil), fill: g.bodyColor.cg()))
        let spokes = CGMutablePath()
        for k in 0..<3 {
            let a = CGFloat(k) * 2 * .pi / 3
            spokes.move(to: .zero)
            spokes.addLine(to: CGPoint(x: cos(a) * rim, y: sin(a) * rim))
        }
        wheel.addSublayer(shape(spokes, fill: nil, stroke: g.joint.cg(), width: 1.6))
        wheel.addSublayer(shape(CGPath(ellipseIn: CGRect(x: -1.8, y: -1.8, width: 3.6, height: 3.6), transform: nil), fill: g.accent.cg()))
        spinners.append((wheel, radius))
        return wheel
    }

    private func buildArms() {
        let g = genome
        guard g.arms != .none else { return }
        let bw = g.bodySize.width, bh = g.bodySize.height, len = g.armLength
        // Shoulders on the body's edge, whatever its shape
        let shoulderY = bh * 0.68
        let edge: CGFloat
        switch g.bodyShape {
        case .egg, .round:
            let dy = (shoulderY - bh / 2) / (bh / 2)
            edge = bw / 2 * sqrt(1 - dy * dy)
        case .trapezoid: edge = lerp(bw / 2, bw * 0.36, shoulderY / bh)
        default: edge = bw / 2
        }
        for side: CGFloat in [-1, 1] {
            let arm = Self.group(at: CGPoint(x: side * (edge - 1.5), y: shoulderY))
            let hand = CGPoint(x: 0, y: -len)
            switch g.arms {
            case .none: break
            case .sticks:
                arm.addSublayer(line([.zero, hand], g.joint.cg(), width: 3))
                arm.addSublayer(shape(CGPath(ellipseIn: CGRect(x: -3.4, y: -len - 3.4, width: 6.8, height: 6.8), transform: nil), fill: g.accent.cg(), stroke: g.accent.outline, width: 1))
            case .claws:
                arm.addSublayer(line([.zero, hand], g.joint.cg(), width: 3))
                let claw = CGMutablePath()
                claw.addArc(center: CGPoint(x: 0, y: -len - 3.2), radius: 3.8, startAngle: -0.25 * .pi, endAngle: 1.25 * .pi, clockwise: false)
                arm.addSublayer(shape(claw, fill: nil, stroke: g.accent.cg(), width: 2.4))
            case .springs:
                arm.addSublayer(shape(zigzag(from: .zero, to: hand, width: 5, turns: 3), fill: nil, stroke: g.joint.cg(), width: 1.7))
                arm.addSublayer(shape(CGPath(ellipseIn: CGRect(x: -3, y: -len - 3, width: 6, height: 6), transform: nil), fill: g.accent.cg(), stroke: g.accent.outline, width: 1))
            case .noodles:
                let noodle = CGMutablePath()
                noodle.move(to: .zero)
                noodle.addCurve(to: hand, control1: CGPoint(x: 5, y: -len * 0.35), control2: CGPoint(x: -5, y: -len * 0.65))
                arm.addSublayer(shape(noodle, fill: nil, stroke: g.bodyColor.outline, width: 5.6))
                arm.addSublayer(shape(noodle, fill: nil, stroke: g.bodyColor.cg(), width: 3.4))
                arm.addSublayer(part(CGPath(ellipseIn: CGRect(x: -3.6, y: -len - 3.6, width: 7.2, height: 7.2), transform: nil), g.bodyColor))
            case .fins:
                arm.addSublayer(part(roundedRect(CGRect(x: -3.2, y: -len, width: 6.4, height: len + 2), 3.2), g.bodyColor.shaded(0.8)))
            }
            if side < 0 { arm.sublayerTransform = CATransform3DMakeScale(-1, 1, 1) }
            let rest = side * 0.5
            arm.transform = CATransform3DMakeRotation(rest, 0, 0, 1)
            torso.addSublayer(arm)
            arms.append((arm, rest))
        }
    }

    private func buildChest() {
        let g = genome
        let bh = g.bodySize.height, bw = g.bodySize.width
        let c = CGPoint(x: 0, y: bh * 0.42)
        switch g.chest {
        case .none: break
        case .buttons:
            for (i, color) in g.chestColors.enumerated() {
                let x = c.x + CGFloat(i - 1) * 6.5
                torso.addSublayer(shape(CGPath(ellipseIn: CGRect(x: x - 2.2, y: c.y - 2.2, width: 4.4, height: 4.4), transform: nil),
                                        fill: color.cg(), stroke: color.outline, width: 0.8))
            }
        case .grille:
            let w = min(bw * 0.5, 22)
            for k in 0..<3 {
                let y = c.y - 3.5 + CGFloat(k) * 3.5
                torso.addSublayer(line([CGPoint(x: -w / 2, y: y), CGPoint(x: w / 2, y: y)], g.joint.cg(alpha: 0.75), width: 1.6))
            }
        case .light:
            let light = shape(CGPath(ellipseIn: CGRect(x: c.x - 3.6, y: c.y - 3.6, width: 7.2, height: 7.2), transform: nil),
                              fill: g.accent.cg(), stroke: g.accent.outline, width: 0.8)
            light.shadowColor = g.accent.cg()
            light.shadowOpacity = 0.9
            light.shadowRadius = 3
            light.shadowOffset = .zero
            torso.addSublayer(light)
            torso.addSublayer(shape(CGPath(ellipseIn: CGRect(x: c.x - 2, y: c.y + 0.4, width: 2, height: 2), transform: nil), fill: CGColor(gray: 1, alpha: 0.8)))
        case .gauge:
            torso.addSublayer(shape(CGPath(ellipseIn: CGRect(x: c.x - 5.5, y: c.y - 5.5, width: 11, height: 11), transform: nil),
                                    fill: CGColor(srgbRed: 0.05, green: 0.06, blue: 0.09, alpha: 1), stroke: g.bodyColor.outline, width: 1.2))
            let tip = CGPoint(x: c.x + cos(g.gaugeAngle) * 4, y: c.y + sin(g.gaugeAngle) * 4)
            torso.addSublayer(line([c, tip], g.accent.cg(), width: 1.4))
        case .panel:
            torso.addSublayer(shape(roundedRect(CGRect(x: c.x - 8, y: c.y - 4.5, width: 16, height: 9), 2.5),
                                    fill: CGColor(srgbRed: 0.05, green: 0.06, blue: 0.09, alpha: 1), stroke: g.bodyColor.outline, width: 1))
            for (k, w) in [CGFloat(9), 5].enumerated() {
                let y = c.y + 1 - CGFloat(k) * 3.4
                torso.addSublayer(line([CGPoint(x: c.x - 5, y: y), CGPoint(x: c.x - 5 + w, y: y)], g.chestColors[k].cg(), width: 1.6))
            }
        }
    }

    private func buildHead() {
        let g = genome
        let hw = g.headSize.width, hh = g.headSize.height, t = g.bezel

        // Behind the shell: ears, crest, bulb base
        switch g.sides {
        case .roundEars:
            for side: CGFloat in [-1, 1] {
                let c = CGPoint(x: side * (hw / 2 + 1), y: hh * 0.55)
                head.addSublayer(part(CGPath(ellipseIn: CGRect(x: c.x - 6.5, y: c.y - 6.5, width: 13, height: 13), transform: nil), g.headColor.shaded(0.82)))
                head.addSublayer(shape(CGPath(ellipseIn: CGRect(x: c.x - 2.8, y: c.y - 2.8, width: 5.6, height: 5.6), transform: nil), fill: g.accent.cg()))
            }
        case .catEars:
            for side: CGFloat in [-1, 1] {
                let points = [CGPoint(x: side * hw * 0.46, y: hh - 6), CGPoint(x: side * hw * 0.14, y: hh - 2), CGPoint(x: side * hw * 0.36, y: hh + 10)]
                head.addSublayer(part(roundedPolygon(points, radius: 2), g.headColor))
                let inner = points.map { CGPoint(x: lerp($0.x, side * hw * 0.32, 0.45), y: lerp($0.y, hh + 1, 0.45)) }
                head.addSublayer(shape(roundedPolygon(inner, radius: 1), fill: g.accent.cg(alpha: 0.85)))
            }
        case .headphones:
            let band = CGMutablePath()
            band.addArc(center: CGPoint(x: 0, y: hh * 0.5), radius: hw / 2 + 3, startAngle: 0.12 * .pi, endAngle: 0.88 * .pi, clockwise: false)
            head.addSublayer(shape(band, fill: nil, stroke: g.joint.cg(), width: 3.6))
        case .dishes:
            for side: CGFloat in [-1, 1] {
                let c = CGPoint(x: side * (hw / 2 + 5), y: hh * 0.56)
                head.addSublayer(line([CGPoint(x: side * hw / 2, y: c.y), c], g.joint.cg(), width: 2.4))
                let dish = CGMutablePath()
                let start: CGFloat = side > 0 ? -0.45 * .pi : 0.55 * .pi
                dish.addArc(center: CGPoint(x: c.x - side * 4, y: c.y), radius: 7, startAngle: start, endAngle: start + 0.9 * .pi, clockwise: false)
                head.addSublayer(shape(dish, fill: nil, stroke: g.headColor.shaded(0.8).cg(), width: 2.6))
                head.addSublayer(shape(CGPath(ellipseIn: CGRect(x: c.x - 1.8, y: c.y - 1.8, width: 3.6, height: 3.6), transform: nil), fill: g.accent.cg()))
            }
        case .bolts:
            for side: CGFloat in [-1, 1] {
                let c = CGPoint(x: side * (hw / 2 + 1.5), y: hh * 0.5)
                head.addSublayer(part(roundedRect(CGRect(x: c.x - 3, y: c.y - 5, width: 6, height: 10), 1.6), g.joint))
            }
        case .none: break
        }

        let tip = CGPoint(x: g.antennaOffset, y: hh)
        switch g.top {
        case .crest:
            let fin = CGMutablePath()
            fin.move(to: CGPoint(x: -11, y: hh - 3))
            fin.addCurve(to: CGPoint(x: 6, y: hh + 12), control1: CGPoint(x: -8, y: hh + 8), control2: CGPoint(x: 0, y: hh + 12))
            fin.addCurve(to: CGPoint(x: 11, y: hh - 3), control1: CGPoint(x: 10, y: hh + 9), control2: CGPoint(x: 12, y: hh + 4))
            fin.closeSubpath()
            head.addSublayer(part(fin, g.accent))
        case .bulb:
            let bulb = shape(CGPath(ellipseIn: CGRect(x: tip.x - 5.5, y: hh - 1, width: 11, height: 11), transform: nil),
                             fill: g.accent.cg(), stroke: g.accent.outline, width: 1)
            bulb.shadowColor = g.accent.cg()
            bulb.shadowOpacity = 0.8
            bulb.shadowRadius = 4
            bulb.shadowOffset = .zero
            head.addSublayer(bulb)
            head.addSublayer(part(roundedRect(CGRect(x: tip.x - 6.5, y: hh - 2, width: 13, height: 4.5), 1.5), g.joint))
        default: break
        }

        let shell = headPath(CGRect(x: -hw / 2, y: 0, width: hw, height: hh), inset: 0)
        head.addSublayer(part(shell, g.headColor))
        head.addSublayer(shading(shell))

        let extraBottom: CGFloat = g.headShape == .crt ? 4 : 0
        let screenRect = CGRect(x: -hw / 2 + t, y: t + extraBottom, width: hw - 2 * t, height: hh - 2 * t - extraBottom)
        head.addSublayer(shape(headPath(screenRect, inset: t), fill: CGColor(srgbRed: 0.035, green: 0.045, blue: 0.07, alpha: 1),
                               stroke: CGColor(gray: 0, alpha: 0.5), width: 1))
        if g.headShape == .crt {
            for k in 0..<2 {
                let x = hw / 2 - t - 3 - CGFloat(k) * 6
                head.addSublayer(shape(CGPath(ellipseIn: CGRect(x: x - 1.6, y: t / 2 + 0.6, width: 3.2, height: 3.2), transform: nil), fill: k == 0 ? g.accent.cg() : g.joint.cg()))
            }
        }
        faceRect = screenRect.insetBy(dx: 2.5, dy: 2)
        face.bounds = CGRect(x: -1, y: -1, width: 2, height: 2)
        face.position = .zero
        head.addSublayer(face)

        // In front: headphone cups, antennas
        if g.sides == .headphones {
            for side: CGFloat in [-1, 1] {
                let c = CGPoint(x: side * (hw / 2 + 2), y: hh * 0.5)
                head.addSublayer(part(roundedRect(CGRect(x: c.x - 4, y: c.y - 8.5, width: 8, height: 17), 3.5), g.accent))
            }
        }
        switch g.top {
        case .antenna:
            let antenna = Self.group(at: tip)
            antenna.addSublayer(line([CGPoint(x: 0, y: -1), CGPoint(x: 0, y: g.antennaLength)], g.joint.cg(), width: 2))
            antenna.addSublayer(ball(at: CGPoint(x: 0, y: g.antennaLength + 2), radius: 3.3))
            head.addSublayer(antenna)
            antennas.append(antenna)
        case .twinAntenna:
            for side: CGFloat in [-1, 1] {
                let antenna = Self.group(at: CGPoint(x: side * 7, y: hh))
                let end = CGPoint(x: side * g.antennaLength * 0.38, y: g.antennaLength)
                antenna.addSublayer(line([CGPoint(x: 0, y: -1), end], g.joint.cg(), width: 1.8))
                antenna.addSublayer(ball(at: CGPoint(x: end.x * 1.1, y: end.y + 1.6), radius: 2.7))
                head.addSublayer(antenna)
                antennas.append(antenna)
            }
        case .springAntenna:
            let antenna = Self.group(at: tip)
            antenna.addSublayer(shape(zigzag(from: CGPoint(x: 0, y: -1), to: CGPoint(x: 0, y: g.antennaLength + 2), width: 5, turns: 3),
                                      fill: nil, stroke: g.joint.cg(), width: 1.6))
            antenna.addSublayer(ball(at: CGPoint(x: 0, y: g.antennaLength + 4.5), radius: 3.6))
            head.addSublayer(antenna)
            antennas.append(antenna)
        case .propeller:
            head.addSublayer(line([CGPoint(x: tip.x, y: hh - 1), CGPoint(x: tip.x, y: hh + 6)], g.joint.cg(), width: 2.6))
            let propeller = Self.group(at: CGPoint(x: tip.x, y: hh + 7))
            propeller.addSublayer(part(capsule(CGRect(x: -12, y: -1.6, width: 24, height: 3.2)), g.accent))
            head.addSublayer(propeller)
            head.addSublayer(shape(CGPath(ellipseIn: CGRect(x: tip.x - 2.2, y: hh + 4.8, width: 4.4, height: 4.4), transform: nil), fill: g.joint.cg()))
            blade = propeller
        default: break
        }
    }

    private func ball(at c: CGPoint, radius: CGFloat) -> CAShapeLayer {
        let ball = shape(CGPath(ellipseIn: CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2), transform: nil),
                         fill: genome.accent.cg(), stroke: genome.accent.outline, width: 1)
        ball.shadowColor = genome.accent.cg()
        ball.shadowOpacity = 0.7
        ball.shadowRadius = 2.5
        ball.shadowOffset = .zero
        return ball
    }

    // MARK: Paths

    private func bodyPath() -> CGPath {
        let w = genome.bodySize.width, h = genome.bodySize.height
        let rect = CGRect(x: -w / 2, y: 0, width: w, height: h)
        switch genome.bodyShape {
        case .box: return roundedRect(rect, 7)
        case .barrel: return roundedRect(rect, min(w, h) * 0.42)
        case .egg: return CGPath(ellipseIn: rect, transform: nil)
        case .trapezoid:
            return roundedPolygon([CGPoint(x: -w / 2, y: 0), CGPoint(x: w / 2, y: 0), CGPoint(x: w * 0.36, y: h), CGPoint(x: -w * 0.36, y: h)], radius: 5)
        case .round: return CGPath(ellipseIn: rect, transform: nil)
        case .capsule: return roundedRect(rect, w / 2)
        }
    }

    /// Head shell (inset 0) or the screen inside it (inset = bezel)
    private func headPath(_ rect: CGRect, inset: CGFloat) -> CGPath {
        switch genome.headShape {
        case .rounded: return roundedRect(rect, max(4, 12 - inset))
        case .capsule: return roundedRect(rect, rect.height / 2 * (inset > 0 ? 0.85 : 1))
        case .crt: return roundedRect(rect, inset > 0 ? 8 : 7)
        case .chamfer:
            let c = max(4, 10 - inset * 0.5)
            return roundedPolygon([
                CGPoint(x: rect.minX + c, y: rect.minY), CGPoint(x: rect.maxX - c, y: rect.minY),
                CGPoint(x: rect.maxX, y: rect.minY + c), CGPoint(x: rect.maxX, y: rect.maxY - c),
                CGPoint(x: rect.maxX - c, y: rect.maxY), CGPoint(x: rect.minX + c, y: rect.maxY),
                CGPoint(x: rect.minX, y: rect.maxY - c), CGPoint(x: rect.minX, y: rect.minY + c),
            ], radius: 2.5)
        case .dome:
            guard inset == 0 else { return roundedRect(rect, 9) }
            let p = CGMutablePath()
            let hw = rect.width / 2, h = rect.height, x = rect.midX, y = rect.minY
            p.move(to: CGPoint(x: x, y: y))
            p.addArc(tangent1End: CGPoint(x: x + hw, y: y), tangent2End: CGPoint(x: x + hw, y: y + h), radius: 6)
            p.addLine(to: CGPoint(x: x + hw, y: y + h * 0.5))
            p.addCurve(to: CGPoint(x: x, y: y + h + 4), control1: CGPoint(x: x + hw, y: y + h * 0.95), control2: CGPoint(x: x + hw * 0.55, y: y + h + 4))
            p.addCurve(to: CGPoint(x: x - hw, y: y + h * 0.5), control1: CGPoint(x: x - hw * 0.55, y: y + h + 4), control2: CGPoint(x: x - hw, y: y + h * 0.95))
            p.addArc(tangent1End: CGPoint(x: x - hw, y: y), tangent2End: CGPoint(x: x, y: y), radius: 6)
            p.closeSubpath()
            return p
        }
    }

    private func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
        let r = min(radius, rect.width / 2, rect.height / 2)
        return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
    }

    /// Clockwise capsule, so a dash phase animation runs its top forwards
    private func capsule(_ rect: CGRect) -> CGPath {
        let r = rect.height / 2
        let p = CGMutablePath()
        p.move(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.maxY))
        p.addArc(center: CGPoint(x: rect.maxX - r, y: rect.midY), radius: r, startAngle: .pi / 2, endAngle: -.pi / 2, clockwise: true)
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.minY))
        p.addArc(center: CGPoint(x: rect.minX + r, y: rect.midY), radius: r, startAngle: -.pi / 2, endAngle: .pi / 2, clockwise: true)
        p.closeSubpath()
        return p
    }

    private func roundedPolygon(_ points: [CGPoint], radius: CGFloat) -> CGPath {
        let p = CGMutablePath()
        let last = points[points.count - 1]
        p.move(to: CGPoint(x: (last.x + points[0].x) / 2, y: (last.y + points[0].y) / 2))
        for i in points.indices {
            p.addArc(tangent1End: points[i], tangent2End: points[(i + 1) % points.count], radius: radius)
        }
        p.closeSubpath()
        return p
    }

    private func zigzag(from a: CGPoint, to b: CGPoint, width: CGFloat, turns: Int) -> CGPath {
        let length = hypot(b.x - a.x, b.y - a.y)
        let u = CGPoint(x: (b.x - a.x) / length, y: (b.y - a.y) / length)
        let n = CGPoint(x: -u.y, y: u.x)
        let p = CGMutablePath()
        p.move(to: a)
        let count = turns * 2
        for i in 1...count {
            let t = (CGFloat(i) - 0.5) / CGFloat(count) * length
            let side: CGFloat = i % 2 == 0 ? -1 : 1
            p.addLine(to: CGPoint(x: a.x + u.x * t + n.x * width / 2 * side, y: a.y + u.y * t + n.y * width / 2 * side))
        }
        p.addLine(to: b)
        return p
    }

    // MARK: Motions

    func setContentsScale(_ scale: CGFloat) {
        func apply(_ layer: CALayer) {
            layer.contentsScale = scale
            layer.sublayers?.forEach(apply)
        }
        apply(layer)
    }

    func setMotion(_ next: RobotMotion) {
        guard next != motion else { return }
        motion = next
        for (layer, key) in motionKeys { layer.removeAnimation(forKey: key) }
        motionKeys.removeAll()

        // Resting pose, animated by the implicit actions
        head.transform = next == .sleep ? CATransform3DTranslate(CATransform3DMakeRotation(-0.1, 0, 0, 1), 0, -2, 0) : CATransform3DIdentity
        for arm in arms {
            arm.layer.transform = CATransform3DMakeRotation(armAngle(arm.rest, next), 0, 0, 1)
        }

        if next == .aim, let arm = arms.last {
            arm.layer.transform = CATransform3DMakeRotation(arm.rest + 2.2, 0, 0, 1)
        }

        switch next {
        case .idle, .aim: break
        case .walk: walk()
        case .cheer: cheer()
        case .fly: fly()
        case .hang:
            for (i, arm) in arms.enumerated() {
                let up = Double(armAngle(arm.rest, .hang))
                loop(arm.layer, "transform.rotation.z", values: [up - 0.08, up + 0.08, up - 0.08], duration: 0.9, phase: Double(i) * 0.5)
            }
            dangleLegs(amount: 0.3, duration: 1)
            swayAntennas(amount: 0.15, duration: 0.8)
        case .climb:
            // One arm reaches up while the other pulls, legs push
            let period = 2 * Ascent.step
            for (i, arm) in arms.enumerated() {
                let up = Double(arm.rest + (arm.rest > 0 ? 2.6 : -2.6)), mid = Double(arm.rest + (arm.rest > 0 ? 1.4 : -1.4))
                loop(arm.layer, "transform.rotation.z", values: [up, mid, up], duration: period, phase: Double(i) * 0.5)
            }
            dangleLegs(amount: 0.4, duration: period)
            loop(hopper, "transform.translation.y", values: [0, 2, 0], duration: Ascent.step)
            swayAntennas(amount: 0.15, duration: 0.5)
        case .bounce:
            // Squashed when it touches the wall, stretched in the air: one cycle per hop
            if let coil {
                loop(coil, "transform.scale.y", values: [0.6, 1.2, 1.1, 0.6], keyTimes: [0, 0.2, 0.8, 1], duration: Ascent.hop, timing: .linear)
            }
            for arm in arms {
                let rest = Double(arm.rest), out = rest + (rest > 0 ? 1.2 : -1.2)
                loop(arm.layer, "transform.rotation.z", values: [rest, out, rest], duration: Ascent.hop)
            }
            swayAntennas(amount: 0.25, duration: Ascent.hop)
        case .sleep:
            loop(torso, "transform.scale.y", values: [1, 1.035, 1], duration: 4.4, fps: 10)
        case .fall:
            // Arms up, legs dangling
            for (i, arm) in arms.enumerated() {
                let up = Double(armAngle(arm.rest, .fall))
                loop(arm.layer, "transform.rotation.z", values: [up - 0.15, up + 0.15, up - 0.15], duration: 0.35, phase: Double(i) * 0.5)
            }
            for leg in legs {
                let rest = Double(leg.rest)
                loop(leg.layer, "transform.rotation.z", values: [rest - 0.25, rest + 0.25, rest - 0.25], duration: 0.4, phase: leg.phase)
            }
            swayAntennas(amount: 0.25, duration: 0.3)
            spinBlade()
        }
    }

    private func armAngle(_ rest: CGFloat, _ motion: RobotMotion) -> CGFloat {
        switch motion {
        case .sleep: return rest * 0.4
        case .fall: return rest + (rest > 0 ? 2.3 : -2.3)
        case .hang: return rest + (rest > 0 ? 2.75 : -2.75)
        case .fly: return rest * 2.2
        default: return rest
        }
    }

    /// Squashes on landing
    func land() {
        once(hopper, "transform.scale.y", values: [0.75, 1.08, 0.97, 1], duration: 0.4, timing: .easeOut)
    }

    /// Two little jumps of joy
    func celebrate() {
        once(hopper, "transform.translation.y", values: [0, 10, 0, 6, 0], duration: 0.8,
             timings: [.easeOut, .easeIn, .easeOut, .easeIn])
        if let arm = arms.last {
            let up = Double(arm.rest) + 2.3
            once(arm.layer, "transform.rotation.z", values: [Double(arm.rest), up, up - 0.3, up, Double(arm.rest)], duration: 1)
        }
    }

    /// Waves at another robot, or hops when it has no arm
    func wave() {
        guard let arm = arms.last else {
            once(hopper, "transform.translation.y", values: [0, 6, 0], duration: 0.45, timings: [.easeOut, .easeIn])
            return
        }
        let rest = Double(arm.rest), up = rest + 2.3
        once(arm.layer, "transform.rotation.z", values: [rest, up, up - 0.45, up, up - 0.45, up, rest], duration: 1.4)
    }

    enum Emote {
        case exclaim, question, heart, note, sleep

        var text: String {
            switch self {
            case .exclaim: return "!"
            case .question: return "?"
            case .heart: return "♥"
            case .note: return "♪"
            case .sleep: return "z"
            }
        }

        var color: CGColor {
            switch self {
            case .exclaim: return CGColor(srgbRed: 1, green: 0.55, blue: 0.1, alpha: 1)
            case .question: return CGColor(srgbRed: 0.2, green: 0.55, blue: 1, alpha: 1)
            case .heart: return CGColor(srgbRed: 1, green: 0.25, blue: 0.45, alpha: 1)
            case .note: return CGColor(srgbRed: 0.15, green: 0.72, blue: 0.4, alpha: 1)
            case .sleep: return CGColor(srgbRed: 0.5, green: 0.45, blue: 0.9, alpha: 1)
            }
        }
    }

    private func buildEmote() {
        emoteBubble.bounds = CGRect(x: 0, y: 0, width: 20, height: 18)
        emoteBubble.backgroundColor = CGColor(gray: 1, alpha: 0.94)
        emoteBubble.cornerRadius = 9
        emoteBubble.borderColor = CGColor(gray: 0, alpha: 0.25)
        emoteBubble.borderWidth = 0.8
        emoteBubble.opacity = 0
        emoteText.frame = CGRect(x: 0, y: 0, width: 20, height: 17)
        emoteText.alignmentMode = .center
        emoteText.font = NSFont.systemFont(ofSize: 13, weight: .heavy)
        emoteText.fontSize = 13
        emoteBubble.addSublayer(emoteText)
        layer.addSublayer(emoteBubble)
    }

    /// A little bubble next to its head, on the given side, for a couple of seconds
    func emote(_ emote: Emote, side: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        emoteText.string = emote.text
        emoteText.foregroundColor = emote.color
        emoteBubble.position = CGPoint(x: Self.foot.x + side * (genome.headSize.width / 2 + 9), y: Self.foot.y + headTop - 2)
        CATransaction.commit()
        let fade = keyframes("opacity", values: [0, 1, 1, 0], keyTimes: [0, 0.08, 0.85, 1], duration: 1.9, timing: .linear, timings: nil, fps: 24)
        emoteBubble.add(fade, forKey: "emote.opacity")
        let pop = keyframes("transform.scale", values: [0.2, 1.15, 1, 1], keyTimes: [0, 0.1, 0.18, 1], duration: 1.9, timing: .easeOut, timings: nil, fps: 24)
        emoteBubble.add(pop, forKey: "emote.scale")
    }

    private func fly() {
        loop(hopper, "transform.translation.y", values: [0, 2.5, 0], duration: 0.7)
        if let thruster {
            loop(thruster, "opacity", values: [0.75, 1, 0.75], duration: 0.12)
            loop(thruster, "transform.scale.x", values: [1.1, 1.4, 1.1], duration: 0.12)
        }
        for (i, arm) in arms.enumerated() {
            let out = Double(armAngle(arm.rest, .fly))
            let flap = genome.arms == .fins ? 0.35 : 0.12
            loop(arm.layer, "transform.rotation.z", values: [out - flap, out + flap, out - flap], duration: genome.arms == .fins ? 0.3 : 0.6,
                 phase: Double(i) * 0.5)
        }
        dangleLegs(amount: 0.2, duration: 0.8)
        swayAntennas(amount: 0.2, duration: 0.5)
        if let blade {
            loop(blade, "transform.scale.x", values: [1, 0.12, -1, 0.12, 1], duration: 0.12, timing: .linear, fps: 30)
        }
    }

    private func dangleLegs(amount: Double, duration: Double) {
        for leg in legs {
            let rest = Double(leg.rest)
            loop(leg.layer, "transform.rotation.z", values: [rest - amount, rest + amount, rest - amount], duration: duration, phase: leg.phase)
        }
    }

    private func walk() {
        let g = genome
        let speed = Double(g.speed)
        // One stride: legs swing, arms follow
        let stride = 2 * 11 / speed
        for spinner in spinners {
            loop(spinner.layer, "transform.rotation.z", values: [0, -2 * Double.pi], duration: 2 * .pi * Double(spinner.radius) / speed, timing: .linear)
        }
        for tread in treads {
            loop(tread, "lineDashPhase", values: [0, -5], duration: 5 / speed, timing: .linear)
        }
        for leg in legs {
            let swing = g.locomotion == .quadruped ? 0.28 : 0.34
            let rest = Double(leg.rest)
            loop(leg.layer, "transform.rotation.z", values: [rest - swing, rest + swing, rest - swing], duration: stride, phase: leg.phase)
        }
        switch g.locomotion {
        case .legs, .quadruped:
            loop(hopper, "transform.translation.y", values: [0, 1.6, 0], duration: stride / 2)
        case .spring:
            hop(height: 9, duration: 0.5, pause: 0)
            if let coil { loop(coil, "transform.scale.y", values: [0.7, 1.15, 0.7], duration: 0.5) }
        case .hover:
            loop(hopper, "transform.translation.y", values: [0, 3, 0], duration: 1.6)
            if let thruster { loop(thruster, "opacity", values: [0.55, 1, 0.55], duration: 0.4) }
        case .unicycle:
            loop(hopper, "transform.rotation.z", values: [-0.05, 0.05, -0.05], duration: 1.1)
        default: break
        }
        for (i, arm) in arms.enumerated() {
            let rest = Double(arm.rest)
            loop(arm.layer, "transform.rotation.z", values: [rest - 0.22, rest + 0.22, rest - 0.22], duration: stride, phase: Double(i) * 0.5)
        }
        swayAntennas(amount: 0.12, duration: 0.7)
        spinBlade()
    }

    private func cheer() {
        hop(height: genome.locomotion == .hover ? 6 : 8, duration: 1.1, pause: 0.6)
        if let arm = arms.last {
            let up = Double(arm.rest) + 2.35
            loop(arm.layer, "transform.rotation.z", values: [up - 0.25, up + 0.25, up - 0.25], duration: 0.5)
        }
        swayAntennas(amount: 0.2, duration: 0.4)
        spinBlade()
    }

    /// Jumps then rests for `pause` of the cycle; the shadow shrinks while in the air
    private func hop(height: Double, duration: Double, pause: Double) {
        let up = (1 - pause) / 2
        let keyTimes: [NSNumber] = [0, NSNumber(value: up), NSNumber(value: up * 2), 1]
        loop(hopper, "transform.translation.y", values: [0, height, 0, 0], keyTimes: keyTimes, duration: duration,
             timings: [.easeOut, .easeIn, .linear])
        loop(shadow, "transform.scale", values: [1, 0.72, 1, 1], keyTimes: keyTimes, duration: duration,
             timings: [.easeOut, .easeIn, .linear])
    }

    private func swayAntennas(amount: Double, duration: Double) {
        let spring = genome.top == .springAntenna ? 2.0 : 1
        for (i, antenna) in antennas.enumerated() {
            loop(antenna, "transform.rotation.z", values: [-amount * spring, amount * spring, -amount * spring], duration: duration, phase: Double(i) * 0.3)
        }
    }

    private func spinBlade() {
        guard let blade else { return }
        loop(blade, "transform.scale.x", values: [1, 0.12, -1, 0.12, 1], duration: 0.24, timing: .linear, fps: 30)
    }

    /// Short one-shot gesture while idle: keeps the robot alive without a running animation
    func fidget() {
        guard motion == .idle else { return }
        var options: [() -> Void] = [
            { self.once(self.head, "transform.rotation.z", values: [0, 0.12, 0.12, 0], duration: 1.4) },
            { self.once(self.hopper, "transform.translation.y", values: [0, 5, 0], duration: 0.42, timings: [.easeOut, .easeIn]) },
        ]
        if !antennas.isEmpty {
            options.append {
                for antenna in self.antennas {
                    self.once(antenna, "transform.rotation.z", values: [0, 0.35, -0.25, 0.15, -0.07, 0], duration: 1)
                }
            }
        }
        if let arm = arms.last {
            let rest = Double(arm.rest)
            options.append { self.once(arm.layer, "transform.rotation.z", values: [rest, rest + 1.3, rest + 0.9, rest + 1.3, rest], duration: 1.3) }
        }
        if let blade {
            options.append { self.once(blade, "transform.scale.x", values: [1, 0.12, -1, 0.12, 1, 0.12, -1, 0.12, 1], duration: 0.6, timing: .linear) }
        }
        options.randomElement()?()
    }

    // MARK: Animation helpers

    private func keyframes(_ keyPath: String, values: [Any], keyTimes: [NSNumber]?, duration: Double,
                           timing: CAMediaTimingFunctionName, timings: [CAMediaTimingFunctionName]?, fps: Float) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.keyTimes = keyTimes
        animation.duration = duration
        if let timings {
            animation.timingFunctions = timings.map { CAMediaTimingFunction(name: $0) }
        } else {
            animation.timingFunction = CAMediaTimingFunction(name: timing)
        }
        // A tiny robot doesn't need 120 Hz
        animation.preferredFrameRateRange = CAFrameRateRange(minimum: min(10, fps), maximum: fps, preferred: fps)
        return animation
    }

    private func loop(_ layer: CALayer, _ keyPath: String, values: [Any], keyTimes: [NSNumber]? = nil, duration: Double,
                      phase: Double = 0, timing: CAMediaTimingFunctionName = .easeInEaseOut,
                      timings: [CAMediaTimingFunctionName]? = nil, fps: Float = 24) {
        let animation = keyframes(keyPath, values: values, keyTimes: keyTimes, duration: duration, timing: timing, timings: timings, fps: fps)
        animation.repeatCount = .infinity
        animation.timeOffset = phase * duration
        let key = "motion." + keyPath
        layer.add(animation, forKey: key)
        motionKeys.append((layer, key))
    }

    private func once(_ layer: CALayer, _ keyPath: String, values: [Any], duration: Double,
                      timing: CAMediaTimingFunctionName = .easeInEaseOut, timings: [CAMediaTimingFunctionName]? = nil) {
        let animation = keyframes(keyPath, values: values, keyTimes: nil, duration: duration, timing: timing, timings: timings, fps: 24)
        layer.add(animation, forKey: "fidget." + keyPath)
    }
}
