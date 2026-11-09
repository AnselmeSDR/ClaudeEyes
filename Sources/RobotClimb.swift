import QuartzCore

/// The ways up a window. Each robot knows a few, from its parts, and picks one at random for every climb.
enum ClimbStyle: CaseIterable {
    /// Drives or walks up the wall, turned sideways
    case crawl
    /// Takes off and lands on top: hovering robots and propellers
    case fly
    /// Bounces off the wall, a little higher at every hop: springs
    case bounce
    /// Hand over hand
    case hands
    /// Shoots a hook to the top edge and reels itself up
    case grapple

    var label: String {
        switch self {
        case .crawl: return "roule"
        case .fly: return "vole"
        case .bounce: return "rebondit"
        case .hands: return "escalade"
        case .grapple: return "grappin"
        }
    }
}

extension RobotGenome {
    /// What its parts let it do: every robot has at least one
    var climbStyles: [ClimbStyle] {
        var styles: [ClimbStyle]
        switch locomotion {
        case .hover: styles = [.fly]
        case .spring: styles = [.bounce]
        default: styles = [.crawl]
        }
        if top == .propeller, !styles.contains(.fly) { styles.append(.fly) }
        if [.sticks, .claws, .springs, .noodles].contains(arms) { styles.append(.hands) }
        if !styles.contains(.fly) { styles.append(.grapple) }
        return styles
    }
}

/// A climb as a function of time, from the foot of the wall to the top of the window.
/// The window may move meanwhile: every pose is computed from where its edge is now.
struct Ascent {
    let style: ClimbStyle
    /// +1 when the wall is on the robot's right
    let side: CGFloat
    let baseY: CGFloat
    let start: CFTimeInterval
    let halfWidth: CGFloat
    let height: CGFloat
    let speed: CGFloat

    struct Pose {
        var foot: CGPoint
        var motion: RobotMotion
        /// Rotation around the foot
        var orientation: CGFloat = 0
        /// From the robot to the hook, while a rope holds it
        var rope: (from: CGPoint, to: CGPoint)?
        var done = false
    }

    private static let turn = 0.45, aim = 0.5, shoot = 0.35, takeOff = 0.35, landing = 0.7
    private static let pullUp = 0.45, pullOver = 0.35
    static let hop = 0.5, step = 0.34
    private static let stepHeight: CGFloat = 20

    /// Where the robot stands to start, next to the wall
    static func base(wallX: CGFloat, side: CGFloat, halfWidth: CGFloat, style: ClimbStyle) -> CGFloat {
        wallX - side * halfWidth * (style == .hands ? 0.8 : 1)
    }

    func pose(at now: CFTimeInterval, wallX: CGFloat, top: CGFloat) -> Pose {
        var t = max(0, now - start)
        let x0 = Self.base(wallX: wallX, side: side, halfWidth: halfWidth, style: style)
        let landX = wallX + side * (halfWidth + 6)
        let rise = max(0, top - baseY)

        switch style {
        case .crawl:
            let length = max(0, rise - 2 * halfWidth)
            let climb = Double(length / (speed * 1.8))
            if t < Self.turn {
                let e = eased(t / Self.turn)
                return Pose(foot: CGPoint(x: lerp(x0, wallX, e), y: baseY + halfWidth * e), motion: .walk, orientation: side * .pi / 2 * e)
            }
            t -= Self.turn
            if t < climb {
                return Pose(foot: CGPoint(x: wallX, y: baseY + halfWidth + length * CGFloat(t / climb)), motion: .walk, orientation: side * .pi / 2)
            }
            t -= climb
            let e = eased(t / Self.turn)
            return Pose(foot: CGPoint(x: lerp(wallX, wallX + side * halfWidth, e), y: lerp(top - halfWidth, top, e)),
                        motion: .walk, orientation: side * .pi / 2 * (1 - e), done: t >= Self.turn)

        case .fly:
            let climb = Double(rise + 4) / 130 + 0.3
            if t < Self.takeOff {
                return Pose(foot: CGPoint(x: x0, y: baseY + 12 * eased(t / Self.takeOff)), motion: .fly)
            }
            t -= Self.takeOff
            if t < climb {
                return Pose(foot: CGPoint(x: x0, y: baseY + 12 + (rise + 4) * eased(t / climb)), motion: .fly)
            }
            t -= climb
            let e = eased(t / Self.landing)
            return Pose(foot: CGPoint(x: lerp(x0, landX, e), y: top + 16 * (1 - e * e)), motion: .fly, done: t >= Self.landing)

        case .grapple:
            let anchor = CGPoint(x: wallX, y: top)
            // The winch sits in its body: the rope runs behind the head
            func winch(_ foot: CGPoint) -> CGPoint { CGPoint(x: foot.x + side * 4, y: foot.y + height * 0.5) }
            let ground = CGPoint(x: x0, y: baseY)
            let hangY = max(baseY, top - height * 0.85)
            let reel = Double(hangY - baseY) / 110 + 0.2
            if t < Self.aim { return Pose(foot: ground, motion: .aim) }
            t -= Self.aim
            if t < Self.shoot {
                let from = winch(ground), e = CGFloat(t / Self.shoot)
                return Pose(foot: ground, motion: .aim, rope: (from, CGPoint(x: lerp(from.x, anchor.x, e), y: lerp(from.y, anchor.y, e))))
            }
            t -= Self.shoot
            if t < reel {
                let p = CGFloat(t / reel)
                let foot = CGPoint(x: x0, y: lerp(baseY, hangY, p * p * (3 - 2 * p)))
                return Pose(foot: foot, motion: .hang, orientation: 0.05 * sin(CGFloat(t) * 5), rope: (winch(foot), anchor))
            }
            t -= reel
            var pose = pullOver(t, from: CGPoint(x: x0, y: hangY), wallX: wallX, landX: landX, top: top)
            // Still pulling on the rope until it reaches the edge
            if t < Self.pullUp { pose.rope = (winch(pose.foot), anchor) }
            return pose

        case .hands:
            let hangY = max(baseY, top - height * 0.8)
            let steps = max(1, ceil((hangY - baseY) / Self.stepHeight))
            let climb = Double(steps) * Self.step
            if t < climb {
                let k = floor(t / Self.step), f = (t - k * Self.step) / Self.step
                let y = min(hangY, baseY + Self.stepHeight * (CGFloat(k) + CGFloat(1 - (1 - f) * (1 - f))))
                return Pose(foot: CGPoint(x: x0, y: y), motion: .climb)
            }
            t -= climb
            return pullOver(t, from: CGPoint(x: x0, y: hangY), wallX: wallX, landX: landX, top: top)

        case .bounce:
            let hops = max(1, Int(ceil(rise / 70)))
            let i = min(hops - 1, Int(t / Self.hop))
            let f = CGFloat(min(1, (t - Double(i) * Self.hop) / Self.hop))
            let y0 = baseY + rise * CGFloat(i) / CGFloat(hops), y1 = baseY + rise * CGFloat(i + 1) / CGFloat(hops)
            let last = i == hops - 1
            // Kicks off the wall, arcs out, comes back to it; the last hop clears the edge
            let x = last ? lerp(x0, landX, f) : x0 - side * 28 * sin(.pi * f)
            let y = lerp(y0, y1, f) + (last ? 50 : 26) * 4 * f * (1 - f)
            return Pose(foot: CGPoint(x: x, y: y), motion: .bounce, done: t >= Double(hops) * Self.hop)
        }
    }

    /// Up to the edge, then over it
    private func pullOver(_ t: Double, from: CGPoint, wallX: CGFloat, landX: CGFloat, top: CGFloat) -> Pose {
        if t < Self.pullUp {
            let e = eased(t / Self.pullUp)
            return Pose(foot: CGPoint(x: from.x, y: lerp(from.y, top + 12, e)), motion: .hang)
        }
        let e = eased((t - Self.pullUp) / Self.pullOver)
        return Pose(foot: CGPoint(x: lerp(from.x, landX, e), y: top + 12 * (1 - e)), motion: .hang, done: t >= Self.pullUp + Self.pullOver)
    }
}

/// Ease in and out, clamped to 0...1
func eased(_ p: Double) -> CGFloat {
    let p = min(1, max(0, p))
    return CGFloat(p < 0.5 ? 2 * p * p : 1 - pow(-2 * p + 2, 2) / 2)
}
