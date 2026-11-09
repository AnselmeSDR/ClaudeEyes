import AppKit
import QuartzCore

// What a robot holds, wears or gives off on top of its genome, built on demand

/// What a robot holds while its session's tool runs
enum RobotProp: CaseIterable {
    /// Reading, searching the code or the web
    case magnifier
    /// Writing code
    case keyboard
    /// Running a command
    case wrench
    /// Running the tests or the linters
    case testTube

    var label: String {
        switch self {
        case .magnifier: return "loupe"
        case .keyboard: return "clavier"
        case .wrench: return "clé"
        case .testTube: return "éprouvette"
        }
    }
}

/// One-shot effects around the robot
enum RobotBurst: CaseIterable {
    /// Tests passed
    case confetti
    /// Something failed
    case sparks
    /// Petted
    case hearts
}

enum RobotHat: CaseIterable {
    case santa, beanie, pumpkin

    var label: String {
        switch self {
        case .santa: return "bonnet de Noël"
        case .beanie: return "bonnet"
        case .pumpkin: return "citrouille"
        }
    }
}

/// What robots wear at a given time: a hat for the season, a headlamp at night
struct RobotOutfit: Equatable {
    var hat: RobotHat?
    var headlamp = false

    static func at(_ date: Date) -> RobotOutfit {
        let c = Calendar.current.dateComponents([.month, .day, .hour], from: date)
        let month = c.month ?? 1, day = c.day ?? 1, hour = c.hour ?? 12
        var outfit = RobotOutfit()
        if (month == 10 && day >= 24) || (month == 11 && day == 1) {
            outfit.hat = .pumpkin
        } else if month == 12 && day <= 26 {
            outfit.hat = .santa
        } else if month == 12 || month <= 2 {
            outfit.hat = .beanie
        }
        outfit.headlamp = hour >= 20 || hour < 6
        return outfit
    }
}

/// Sessions working in the same repository: their robots carry the same pennant and stick together.
/// key is the repository's root folder.
struct RobotTeam: Equatable {
    let key: String

    var color: RobotColor {
        RobotColor(hue: CGFloat(UInt64(stableHash: key) % 360) / 360, saturation: 0.72, brightness: 0.95)
    }

    /// The first letter of the repository's name, on its pennant
    var initial: String {
        let name = (key as NSString).lastPathComponent
        return name.first.map { String($0).uppercased() } ?? "?"
    }
}

extension RobotRig {
    // MARK: Props

    /// A tool in its raised hand (floating beside it without hands), or a keyboard in front of it.
    /// Tools are cartoon-sized: they must read at a glance.
    func setProp(_ prop: RobotProp?) {
        guard prop != self.prop else { return }
        self.prop = prop
        propLayer?.removeFromSuperlayer()
        propLayer = nil
        armPose = prop == nil ? .rest : prop == .keyboard ? .typing : .hold
        guard let prop else { return }
        let g = genome
        let holder = Self.group()
        let enlarged = Self.group()
        if prop != .keyboard { enlarged.transform = CATransform3DMakeScale(Self.propScale, Self.propScale, 1) }
        holder.addSublayer(enlarged)
        switch prop {
        case .magnifier: enlarged.addSublayer(magnifier())
        case .keyboard: enlarged.addSublayer(keyboard())
        case .wrench: enlarged.addSublayer(wrench())
        case .testTube: enlarged.addSublayer(testTube())
        }
        if prop == .keyboard {
            // Where its hands hang
            let handY = arms.isEmpty ? g.bodySize.height * 0.3 : g.bodySize.height * 0.68 - g.armLength * cos(0.5)
            holder.position = CGPoint(x: 0, y: handY - 3)
            torso.addSublayer(holder)
        } else if let arm = arms.last {
            // Upright in its raised hand
            holder.position = CGPoint(x: 0, y: -g.armLength)
            holder.transform = CATransform3DMakeRotation(-arm.rest, 0, 0, 1)
            arm.layer.addSublayer(holder)
        } else {
            holder.position = CGPoint(x: g.bodySize.width / 2 + 12, y: g.bodySize.height * 0.2)
            torso.addSublayer(holder)
            gearLoop(holder, "transform.translation.y", values: [0, 3, 0], duration: 1.4)
        }
        applyScale(to: holder)
        propLayer = holder
    }

    private static let propScale: CGFloat = 1.7

    private func magnifier() -> CALayer {
        let g = Self.group()
        g.addSublayer(line([CGPoint(x: 0, y: -2), CGPoint(x: 3.4, y: 7.5)], CGColor(srgbRed: 0.25, green: 0.13, blue: 0.06, alpha: 1), width: 4.6))
        g.addSublayer(line([CGPoint(x: 0, y: -2), CGPoint(x: 3.4, y: 7.5)], CGColor(srgbRed: 0.55, green: 0.3, blue: 0.13, alpha: 1), width: 3))
        let center = CGPoint(x: 6.2, y: 14.6), r: CGFloat = 7.4
        let brass = RobotColor(r: 1, g: 0.76, b: 0.2)
        let ring = CGPath(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2), transform: nil)
        g.addSublayer(shape(ring, fill: CGColor(srgbRed: 0.7, green: 0.92, blue: 1, alpha: 0.5), stroke: brass.outline, width: 3.6))
        g.addSublayer(shape(ring, fill: nil, stroke: brass.cg(), width: 2.2))
        let glint = CGMutablePath()
        glint.addArc(center: center, radius: r - 2.8, startAngle: 1.8, endAngle: 2.9, clockwise: false)
        g.addSublayer(shape(glint, fill: nil, stroke: CGColor(gray: 1, alpha: 0.95), width: 1.5))
        // A twinkle on the glass
        let twinkle = shape(Self.star(radius: 2.6), fill: CGColor(gray: 1, alpha: 1))
        twinkle.position = CGPoint(x: center.x + r * 0.45, y: center.y + r * 0.45)
        twinkle.opacity = 0
        g.addSublayer(twinkle)
        gearLoop(twinkle, "opacity", values: [0, 0, 1, 0], duration: 1.6)
        // Sweeps the code, back and forth
        gearLoop(g, "transform.rotation.z", values: [-0.32, 0.25, -0.32], duration: 1.5)
        gearLoop(g, "transform.translation.x", values: [-2, 3, -2], duration: 1.5)
        return g
    }

    private func keyboard() -> CALayer {
        let g = Self.group()
        let w = max(46, genome.bodySize.width + 26), h: CGFloat = 12
        g.addSublayer(shape(roundedRect(CGRect(x: -w / 2, y: -h / 2, width: w, height: h), 3),
                            fill: CGColor(gray: 0.15, alpha: 1), stroke: CGColor(gray: 0.02, alpha: 1), width: 1.2))
        let keys = CGMutablePath()
        var spots: [CGPoint] = []
        for (row, y) in [CGFloat(1.4), -3.4].enumerated() {
            var x = -w / 2 + 3 + CGFloat(row) * 2.2
            while x + 4 <= w / 2 - 3 {
                keys.addRoundedRect(in: CGRect(x: x, y: y, width: 4, height: 3), cornerWidth: 0.8, cornerHeight: 0.8)
                spots.append(CGPoint(x: x + 2, y: y + 1.5))
                x += 5.2
            }
        }
        g.addSublayer(shape(keys, fill: CGColor(gray: 0.7, alpha: 1)))
        // Keys light up as it types, and bits of code fly out
        guard !spots.isEmpty else { return g }
        let lights = [genome.accent.cg(), CGColor(srgbRed: 1, green: 0.85, blue: 0.25, alpha: 1), CGColor(srgbRed: 0.4, green: 1, blue: 0.6, alpha: 1)]
        for (k, color) in lights.enumerated() {
            let lit = shape(CGPath(roundedRect: CGRect(x: -2.1, y: -1.6, width: 4.2, height: 3.2), cornerWidth: 0.8, cornerHeight: 0.8, transform: nil), fill: color)
            lit.shadowColor = color
            lit.shadowOpacity = 1
            lit.shadowRadius = 2.5
            lit.shadowOffset = .zero
            g.addSublayer(lit)
            let typing = CAKeyframeAnimation(keyPath: "position")
            typing.values = (0..<10).map { _ in NSValue(point: spots.randomElement()!) }
            typing.calculationMode = .discrete
            typing.duration = 1.1 + Double(k) * 0.3
            typing.repeatCount = .infinity
            lit.add(typing, forKey: "gear.typing")
        }
        let glyphs = ["{", "}", ";", "</>", "()", "=", "#"]
        for k in 0..<4 {
            let bit = CATextLayer()
            bit.string = glyphs[(k * 3 + Int.random(in: 0..<glyphs.count)) % glyphs.count]
            bit.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .heavy)
            bit.fontSize = 11
            bit.alignmentMode = .center
            bit.foregroundColor = lights[k % lights.count]
            bit.bounds = CGRect(x: 0, y: 0, width: 26, height: 14)
            bit.opacity = 0
            g.addSublayer(bit)
            let x = CGFloat(k) / 3 * (w - 16) - (w - 16) / 2
            let phase = Double(k) / 4
            gearLoop(bit, "position", values: [CGPoint(x: x, y: 2), CGPoint(x: x * 1.3, y: 34)].map { NSValue(point: $0) },
                     duration: 1.6, phase: phase, timing: .easeOut)
            gearLoop(bit, "opacity", values: [0, 1, 1, 0], duration: 1.6, phase: phase, timing: .linear)
        }
        return g
    }

    private func wrench() -> CALayer {
        let g = Self.group()
        let shaft = roundedRect(CGRect(x: -2.2, y: -4, width: 4.4, height: 17), 2.2)
        let jaw = CGPath(ellipseIn: CGRect(x: -6, y: 9.5, width: 12, height: 12), transform: nil)
            .subtracting(CGPath(rect: CGRect(x: -2.2, y: 15, width: 4.4, height: 8), transform: nil))
        g.addSublayer(part(shaft.union(jaw), RobotColor(r: 0.8, g: 0.84, b: 0.9)))
        g.addSublayer(line([CGPoint(x: -0.6, y: -1.5), CGPoint(x: -0.6, y: 10)], CGColor(gray: 1, alpha: 0.8), width: 1))
        // Effort lines by the jaw, at each turn
        let effort = CGMutablePath()
        for (a, b) in [(CGPoint(x: 8, y: 18), CGPoint(x: 12, y: 20)), (CGPoint(x: 8.5, y: 14), CGPoint(x: 13, y: 14)), (CGPoint(x: 8, y: 10), CGPoint(x: 12, y: 8))] {
            effort.move(to: a)
            effort.addLine(to: b)
        }
        let marks = shape(effort, fill: nil, stroke: CGColor(srgbRed: 1, green: 0.8, blue: 0.2, alpha: 1), width: 1.4)
        marks.opacity = 0
        g.addSublayer(marks)
        gearLoop(marks, "opacity", values: [0, 1, 0, 0], duration: 0.55)
        // Cranking hard
        gearLoop(g, "transform.rotation.z", values: [-0.75, 0.45, -0.75], duration: 0.55)
        return g
    }

    private func testTube() -> CALayer {
        let g = Self.group()
        let potion = CGColor(srgbRed: 0.3, green: 1, blue: 0.45, alpha: 0.95)
        g.addSublayer(shape(roundedRect(CGRect(x: -3, y: -1.6, width: 6, height: 11.5), 3), fill: potion))
        // Bubbles in the liquid
        for k in 0..<3 {
            let bubble = shape(CGPath(ellipseIn: CGRect(x: -1, y: -1, width: 2, height: 2), transform: nil), fill: CGColor(gray: 1, alpha: 0.9))
            bubble.position = CGPoint(x: CGFloat(k - 1) * 1.3, y: 0)
            g.addSublayer(bubble)
            gearLoop(bubble, "position.y", values: [0, 9.5], duration: 0.7, phase: Double(k) / 3, timing: .linear)
            gearLoop(bubble, "opacity", values: [1, 1, 0], duration: 0.7, phase: Double(k) / 3, timing: .linear)
        }
        g.addSublayer(shape(roundedRect(CGRect(x: -4, y: -2.6, width: 8, height: 22), 4),
                            fill: CGColor(gray: 1, alpha: 0.18), stroke: CGColor(gray: 1, alpha: 0.95), width: 1.3))
        g.addSublayer(shape(roundedRect(CGRect(x: -4, y: -2.6, width: 8, height: 22), 4), fill: nil, stroke: CGColor(gray: 0, alpha: 0.35), width: 0.5))
        g.addSublayer(line([CGPoint(x: -5.2, y: 19.4), CGPoint(x: 5.2, y: 19.4)], CGColor(gray: 1, alpha: 0.95), width: 1.8))
        // Boiling over: green smoke
        for k in 0..<4 {
            let puff = shape(CGPath(ellipseIn: CGRect(x: -3.5, y: -3.5, width: 7, height: 7), transform: nil),
                             fill: CGColor(srgbRed: 0.75, green: 0.95, blue: 0.75, alpha: 0.75))
            puff.position = CGPoint(x: 0, y: 21)
            puff.opacity = 0
            g.addSublayer(puff)
            let phase = Double(k) / 4
            let drift: CGFloat = k % 2 == 0 ? 5 : -5
            gearLoop(puff, "position", values: [CGPoint(x: 0, y: 21), CGPoint(x: drift * 0.5, y: 30), CGPoint(x: drift, y: 42)].map { NSValue(point: $0) },
                     duration: 1.6, phase: phase, timing: .easeOut)
            gearLoop(puff, "transform.scale", values: [0.5, 1.9], duration: 1.6, phase: phase, timing: .linear)
            gearLoop(puff, "opacity", values: [0.95, 0], duration: 1.6, phase: phase, timing: .linear)
        }
        // Shaken now and then, like a chemist
        gearLoop(g, "transform.rotation.z", values: [0, 0.25, -0.25, 0.2, 0, 0], duration: 1.8)
        return g
    }

    // MARK: Bursts

    func burst(_ kind: RobotBurst) {
        let top = CGPoint(x: Self.foot.x, y: Self.foot.y + headTop)
        switch kind {
        case .confetti:
            let colors = [CGColor(srgbRed: 1, green: 0.3, blue: 0.35, alpha: 1), CGColor(srgbRed: 1, green: 0.82, blue: 0.2, alpha: 1),
                          CGColor(srgbRed: 0.3, green: 0.85, blue: 0.45, alpha: 1), CGColor(srgbRed: 0.3, green: 0.6, blue: 1, alpha: 1),
                          CGColor(srgbRed: 0.95, green: 0.45, blue: 0.9, alpha: 1), genome.accent.cg()]
            for _ in 0..<32 {
                let piece = CALayer()
                piece.bounds = CGRect(x: 0, y: 0, width: 4.6, height: 8)
                piece.backgroundColor = colors.randomElement()!
                piece.cornerRadius = 1
                let dx = CGFloat.random(in: -68...68)
                let peak = CGPoint(x: top.x + dx * 0.5, y: top.y + CGFloat.random(in: 24...62))
                let end = CGPoint(x: top.x + dx, y: Self.foot.y + CGFloat.random(in: -4...18))
                fly(piece, through: [top, peak, end], keyTimes: [0, 0.3, 1], duration: Double.random(in: 1.4...1.9),
                    spin: CGFloat.random(in: -14...14), delay: Double.random(in: 0...0.12))
            }
        case .sparks:
            let side: CGFloat = Bool.random() ? 1 : -1
            for crackle in 0..<3 {
                let center = CGPoint(x: top.x + side * CGFloat(1 - crackle) * genome.headSize.width * 0.35, y: top.y - 3)
                for k in 0..<12 {
                    let angle = CGFloat(k) / 12 * 2 * .pi + CGFloat.random(in: -0.2...0.2)
                    let spark = CAShapeLayer()
                    let path = CGMutablePath()
                    path.move(to: CGPoint(x: -4.5, y: 0))
                    path.addLine(to: CGPoint(x: 4.5, y: 0))
                    spark.path = path
                    spark.strokeColor = k % 2 == 0 ? CGColor(srgbRed: 1, green: 0.9, blue: 0.3, alpha: 1) : CGColor(srgbRed: 1, green: 0.5, blue: 0.12, alpha: 1)
                    spark.lineWidth = 2.4
                    spark.lineCap = .round
                    spark.shadowColor = CGColor(srgbRed: 1, green: 0.8, blue: 0.2, alpha: 1)
                    spark.shadowOpacity = 0.9
                    spark.shadowRadius = 2
                    spark.shadowOffset = .zero
                    spark.transform = CATransform3DMakeRotation(angle, 0, 0, 1)
                    let distance = CGFloat.random(in: 18...36)
                    let end = CGPoint(x: center.x + cos(angle) * distance, y: center.y + sin(angle) * distance)
                    fly(spark, through: [center, end], keyTimes: [0, 1], duration: 0.45, delay: Double(crackle) * 0.28)
                }
            }
            // A cloud of smoke
            for k in 0..<4 {
                let puff = shape(CGPath(ellipseIn: CGRect(x: -5, y: -5, width: 10, height: 10), transform: nil), fill: CGColor(gray: 0.5, alpha: 0.65))
                let dx = CGFloat(k) * 6 - 9
                let start = CGPoint(x: top.x + dx, y: top.y)
                fly(puff, through: [start, CGPoint(x: start.x + dx * 0.8, y: start.y + 44)], keyTimes: [0, 1],
                    duration: 1.5, delay: 0.15 + Double(k) * 0.15, grow: 2.6)
            }
            jolt()
        case .hearts:
            for k in 0..<5 {
                let heart = shape(Self.heart(size: 15), fill: CGColor(srgbRed: 1, green: 0.32, blue: 0.5, alpha: 1),
                                  stroke: CGColor(srgbRed: 0.75, green: 0.12, blue: 0.3, alpha: 1), width: 1)
                let x = top.x + CGFloat(k - 2) * 12
                fly(heart, through: [CGPoint(x: x, y: top.y - 8), CGPoint(x: x + CGFloat.random(in: -10...10), y: top.y + 22),
                                     CGPoint(x: x + CGFloat.random(in: -16...16), y: top.y + 54)],
                    keyTimes: [0, 0.5, 1], duration: 1.7, delay: Double(k) * 0.18, grow: 1.3)
            }
        }
    }

    /// Moves a piece through points while it fades out, then removes it
    private func fly(_ piece: CALayer, through points: [CGPoint], keyTimes: [NSNumber], duration: Double,
                     spin: CGFloat = 0, delay: Double = 0, grow: CGFloat = 0) {
        piece.position = points[points.count - 1]
        piece.opacity = 0
        applyScale(to: piece)
        layer.addSublayer(piece)
        var animations: [CAAnimation] = []
        let move = CAKeyframeAnimation(keyPath: "position")
        move.values = points.map { NSValue(point: $0) }
        move.keyTimes = keyTimes
        move.timingFunctions = (1..<points.count).map { CAMediaTimingFunction(name: $0 == 1 ? .easeOut : .easeIn) }
        animations.append(move)
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.05, 0.7, 1]
        animations.append(fade)
        if spin != 0 {
            let turn = CABasicAnimation(keyPath: "transform.rotation.z")
            turn.fromValue = 0
            turn.toValue = spin
            animations.append(turn)
        }
        if grow > 0 {
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.4
            scale.toValue = grow
            animations.append(scale)
        }
        animations.forEach { $0.duration = duration }
        let group = CAAnimationGroup()
        group.animations = animations
        group.duration = duration
        group.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + delay
        group.fillMode = .backwards
        group.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        piece.add(group, forKey: "burst")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + duration + 0.2) { [weak piece] in
            piece?.removeFromSuperlayer()
        }
    }

    static func heart(size s: CGFloat) -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 0, y: -s * 0.45))
        p.addCurve(to: CGPoint(x: -s * 0.5, y: s * 0.18), control1: CGPoint(x: -s * 0.2, y: -s * 0.18), control2: CGPoint(x: -s * 0.5, y: -s * 0.06))
        p.addArc(center: CGPoint(x: -s * 0.25, y: s * 0.18), radius: s * 0.25, startAngle: .pi, endAngle: 0, clockwise: true)
        p.addArc(center: CGPoint(x: s * 0.25, y: s * 0.18), radius: s * 0.25, startAngle: .pi, endAngle: 0, clockwise: true)
        p.addCurve(to: CGPoint(x: 0, y: -s * 0.45), control1: CGPoint(x: s * 0.5, y: -s * 0.06), control2: CGPoint(x: s * 0.2, y: -s * 0.18))
        p.closeSubpath()
        return p
    }

    static func star(radius r: CGFloat) -> CGPath {
        let p = CGMutablePath()
        for i in 0..<10 {
            let a = CGFloat.pi / 2 + CGFloat(i) * .pi / 5
            let d = i % 2 == 0 ? r : r * 0.45
            let point = CGPoint(x: cos(a) * d, y: sin(a) * d)
            if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
        }
        p.closeSubpath()
        return p
    }

    // MARK: Dizzy

    /// Stars going round its head
    func setStars(_ on: Bool) {
        guard on != (stars.map { !$0.isHidden } ?? false) else { return }
        if on, stars == nil {
            let hw = genome.headSize.width
            let ring = Self.group(at: CGPoint(x: 0, y: genome.headSize.height + 8))
            let rx = hw * 0.45, ry: CGFloat = 5
            let orbit = CGPath(ellipseIn: CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2), transform: nil)
            for k in 0..<3 {
                let star = shape(Self.star(radius: 4.6), fill: CGColor(srgbRed: 1, green: 0.86, blue: 0.25, alpha: 1),
                                 stroke: CGColor(srgbRed: 0.8, green: 0.55, blue: 0.1, alpha: 1), width: 0.8)
                ring.addSublayer(star)
                let round = CAKeyframeAnimation(keyPath: "position")
                round.path = orbit
                round.calculationMode = .paced
                round.duration = 1.3
                round.repeatCount = .infinity
                round.timeOffset = Double(k) / 3 * 1.3
                star.add(round, forKey: "gear.orbit")
            }
            applyScale(to: ring)
            head.addSublayer(ring)
            stars = ring
        }
        stars?.isHidden = !on
    }

    // MARK: Outfit

    func setOutfit(_ outfit: RobotOutfit) {
        guard outfit != self.outfit else { return }
        self.outfit = outfit
        outfitLayers.forEach { $0.removeFromSuperlayer() }
        outfitLayers.removeAll()
        if let hat = outfit.hat {
            let layer = buildHat(hat)
            // A pumpkin covers its antennas, a hat lets them through
            if hat == .pumpkin { head.addSublayer(layer) } else { head.insertSublayer(layer, above: face) }
            outfitLayers.append(layer)
        }
        if outfit.headlamp {
            let hh = genome.headSize.height
            let onHat = outfit.hat == .santa || outfit.hat == .beanie
            let y = onHat ? hh - 6 : hh - 1.5
            // Its light, behind the head, down to the ground in front of it
            let ground = 4 - torso.position.y - head.position.y
            let cone = CGMutablePath()
            cone.move(to: CGPoint(x: 3, y: y))
            cone.addLine(to: CGPoint(x: 64, y: ground + 16))
            cone.addQuadCurve(to: CGPoint(x: 22, y: ground), control: CGPoint(x: 50, y: ground - 5))
            cone.closeSubpath()
            let beam = shape(cone, fill: CGColor(srgbRed: 1, green: 0.9, blue: 0.45, alpha: 0.22))
            gearLoop(beam, "opacity", values: [0.8, 1, 0.8], duration: 2.4)
            head.insertSublayer(beam, at: 0)
            let lamp = Self.group(at: CGPoint(x: 0, y: y))
            lamp.addSublayer(part(roundedRect(CGRect(x: -5, y: -3.2, width: 10, height: 6.4), 2), genome.joint))
            let light = CGColor(srgbRed: 1, green: 0.95, blue: 0.62, alpha: 1)
            let lens = shape(CGPath(ellipseIn: CGRect(x: -2.6, y: -2.6, width: 5.2, height: 5.2), transform: nil), fill: light)
            lens.shadowColor = light
            lens.shadowOpacity = 1
            lens.shadowRadius = 3
            lens.shadowOffset = .zero
            lamp.addSublayer(lens)
            head.addSublayer(lamp)
            outfitLayers += [beam, lamp]
        }
        outfitLayers.forEach { applyScale(to: $0) }
    }

    private func buildHat(_ hat: RobotHat) -> CALayer {
        let g = Self.group()
        let hw = genome.headSize.width, hh = genome.headSize.height
        // A dome is 4 pt higher in its middle
        let top = hh + (genome.headShape == .dome ? 4 : 0)
        let white = RobotColor(r: 0.97, g: 0.97, b: 0.95)
        switch hat {
        case .beanie:
            let wool = genome.accent.shaded(0.85)
            let cap = CGMutablePath()
            cap.move(to: CGPoint(x: -hw / 2 + 2, y: hh - 6))
            cap.addCurve(to: CGPoint(x: hw / 2 - 2, y: hh - 6), control1: CGPoint(x: -hw / 2 + 2, y: top + 17), control2: CGPoint(x: hw / 2 - 2, y: top + 17))
            cap.closeSubpath()
            g.addSublayer(part(cap, wool))
            let ribs = CGMutablePath()
            for k in -2...2 {
                let x = CGFloat(k) * hw * 0.13
                ribs.move(to: CGPoint(x: x, y: hh - 3))
                ribs.addLine(to: CGPoint(x: x * 0.75, y: top + 7))
            }
            g.addSublayer(shape(ribs, fill: nil, stroke: wool.shaded(0.8).cg(), width: 1.2))
            g.addSublayer(part(roundedRect(CGRect(x: -hw / 2 - 1.5, y: hh - 10, width: hw + 3, height: 7.5), 3.5), wool.shaded(0.78)))
            g.addSublayer(part(CGPath(ellipseIn: CGRect(x: -5, y: top + 9.5, width: 10, height: 10), transform: nil), white))
        case .santa:
            let red = RobotColor(r: 0.86, g: 0.15, b: 0.17)
            let cap = CGMutablePath()
            cap.move(to: CGPoint(x: -hw / 2 + 2, y: hh - 6))
            cap.addCurve(to: CGPoint(x: hw / 2 + 9, y: top + 2), control1: CGPoint(x: -hw / 2 + 4, y: top + 21), control2: CGPoint(x: hw * 0.3, y: top + 23))
            cap.addCurve(to: CGPoint(x: hw / 2 - 2, y: hh - 6), control1: CGPoint(x: hw * 0.32, y: top + 12), control2: CGPoint(x: hw / 2 - 4, y: hh + 4))
            cap.closeSubpath()
            g.addSublayer(part(cap, red))
            g.addSublayer(part(roundedRect(CGRect(x: -hw / 2 - 2, y: hh - 10, width: hw + 4, height: 8), 4), white))
            g.addSublayer(part(CGPath(ellipseIn: CGRect(x: hw / 2 + 4.5, y: top - 2.5, width: 9, height: 9), transform: nil), white))
        case .pumpkin:
            let orange = RobotColor(r: 1, g: 0.55, b: 0.1)
            let y = top - 2, w: CGFloat = 27, h: CGFloat = 19
            g.addSublayer(part(roundedRect(CGRect(x: -1.6, y: y + h - 3, width: 3.2, height: 7), 1.5), RobotColor(r: 0.3, g: 0.55, b: 0.2)))
            g.addSublayer(part(CGPath(ellipseIn: CGRect(x: -w / 2, y: y, width: w, height: h), transform: nil), orange))
            for dx: CGFloat in [-6, 6] {
                g.addSublayer(shape(CGPath(ellipseIn: CGRect(x: dx - 4, y: y + 0.5, width: 8, height: h - 1), transform: nil),
                                    fill: nil, stroke: orange.outline, width: 1))
            }
            // Carved face, lit from inside
            let carved = CGMutablePath()
            for side: CGFloat in [-1, 1] {
                carved.addLines(between: [CGPoint(x: side * 7.5, y: y + 10), CGPoint(x: side * 2.8, y: y + 10), CGPoint(x: side * 5.1, y: y + 13.8)])
                carved.closeSubpath()
            }
            carved.addLines(between: [CGPoint(x: -8, y: y + 6.5), CGPoint(x: -5, y: y + 4.8), CGPoint(x: -2.5, y: y + 6.3), CGPoint(x: 0, y: y + 4.8),
                                      CGPoint(x: 2.5, y: y + 6.3), CGPoint(x: 5, y: y + 4.8), CGPoint(x: 8, y: y + 6.5), CGPoint(x: 4.5, y: y + 3),
                                      CGPoint(x: -4.5, y: y + 3)])
            carved.closeSubpath()
            let glow = CGColor(srgbRed: 1, green: 0.88, blue: 0.3, alpha: 1)
            let face = shape(carved, fill: glow)
            face.shadowColor = glow
            face.shadowOpacity = 0.9
            face.shadowRadius = 2
            face.shadowOffset = .zero
            g.addSublayer(face)
        }
        return g
    }

    // MARK: Team

    /// A pennant on a pole behind its head, in its team's color, with its repository's initial
    func setTeam(_ team: RobotTeam?) {
        teamFlag?.removeFromSuperlayer()
        teamFlag = nil
        teamLetter = nil
        guard let team else { return }
        let color = team.color
        let g = Self.group()
        let poleX = -genome.headSize.width * 0.3
        let poleTop = head.position.y + genome.headSize.height + 34
        // From inside the body, behind the head, up above it
        g.addSublayer(line([CGPoint(x: poleX, y: genome.bodySize.height * 0.4), CGPoint(x: poleX, y: poleTop)], CGColor(gray: 0.35, alpha: 1), width: 2.2))
        g.addSublayer(shape(CGPath(ellipseIn: CGRect(x: poleX - 2.6, y: poleTop - 0.5, width: 5.2, height: 5.2), transform: nil),
                            fill: CGColor(srgbRed: 1, green: 0.8, blue: 0.25, alpha: 1), stroke: CGColor(gray: 0.3, alpha: 1), width: 0.8))

        // Flutters behind it, a notch at its free end
        let w: CGFloat = 30, h: CGFloat = 21
        func flag(_ wave: CGFloat) -> CGPath {
            let path = CGMutablePath()
            let top = poleTop - 1, bottom = poleTop - 1 - h, end = poleX - w
            path.move(to: CGPoint(x: poleX, y: top))
            path.addCurve(to: CGPoint(x: end, y: top - wave * 0.6), control1: CGPoint(x: poleX - w * 0.35, y: top + wave),
                          control2: CGPoint(x: poleX - w * 0.7, y: top - wave))
            path.addLine(to: CGPoint(x: end + 6, y: (top + bottom) / 2 - wave * 0.6))
            path.addLine(to: CGPoint(x: end, y: bottom - wave * 0.6))
            path.addCurve(to: CGPoint(x: poleX, y: bottom), control1: CGPoint(x: poleX - w * 0.7, y: bottom - wave),
                          control2: CGPoint(x: poleX - w * 0.35, y: bottom + wave))
            path.closeSubpath()
            return path
        }
        let cloth = shape(flag(2), fill: color.cg(), stroke: color.shaded(0.62).cg(), width: 1.2)
        g.addSublayer(cloth)
        gearLoop(cloth, "path", values: [flag(2), flag(-2), flag(2)], duration: 1.1)

        // The letter stays readable when the robot turns around
        let letter = Self.group(at: CGPoint(x: poleX - w * 0.44, y: poleTop - 1 - h / 2))
        if let glyph = Self.glyphPath(team.initial, size: 15) {
            let box = glyph.boundingBoxOfPath
            var center = CGAffineTransform(translationX: -box.midX, y: -box.midY)
            let path = glyph.copy(using: &center) ?? glyph
            letter.addSublayer(shape(path, fill: CGColor(gray: 1, alpha: 1), stroke: color.shaded(0.45).cg(), width: 0.6))
        }
        letter.transform = CATransform3DMakeScale(facing, 1, 1)
        g.addSublayer(letter)

        torso.insertSublayer(g, at: 0)
        applyScale(to: g)
        teamFlag = g
        teamLetter = letter
    }

    /// The outline of a heavy rounded letter, for drawing it as a shape
    static func glyphPath(_ text: String, size: CGFloat) -> CGPath? {
        let font = NSFont.systemFont(ofSize: size, weight: .black) as CTFont
        let chars = Array(text.utf16.prefix(1))
        var glyphs = [CGGlyph](repeating: 0, count: chars.count)
        guard !chars.isEmpty, CTFontGetGlyphsForCharacters(font, chars, &glyphs, chars.count) else { return nil }
        return CTFontCreatePathForGlyph(font, glyphs[0], nil)
    }

    /// Slaps a teammate's hand on its side (+1: right of the canvas); clap: the little star of the slap
    func highFive(side: CGFloat, clap: Bool) {
        if let arm = arms.last {
            let rest = Double(arm.rest), up = rest + 2.0
            once(arm.layer, "transform.rotation.z", values: [rest, up, up - 0.25, up, rest], duration: 0.9)
        } else {
            once(hopper, "transform.translation.x", values: [0, 7, 0], duration: 0.5, timings: [.easeOut, .easeIn])
        }
        once(hopper, "transform.translation.y", values: [0, 5, 0], duration: 0.5, timings: [.easeOut, .easeIn])
        guard clap else { return }
        let center = CGPoint(x: Self.foot.x + side * (reach + 4), y: Self.foot.y + headTop + 4)
        for k in 0..<10 {
            let angle = CGFloat(k) / 10 * 2 * .pi
            let ray = CAShapeLayer()
            let path = CGMutablePath()
            path.move(to: CGPoint(x: -3.5, y: 0))
            path.addLine(to: CGPoint(x: 3.5, y: 0))
            ray.path = path
            ray.strokeColor = k % 2 == 0 ? CGColor(srgbRed: 1, green: 0.88, blue: 0.3, alpha: 1) : CGColor(gray: 1, alpha: 1)
            ray.lineWidth = 2.4
            ray.lineCap = .round
            ray.transform = CATransform3DMakeRotation(angle, 0, 0, 1)
            let end = CGPoint(x: center.x + cos(angle) * 20, y: center.y + sin(angle) * 20)
            fly(ray, through: [center, end], keyTimes: [0, 1], duration: 0.45, delay: 0.22)
        }
        let star = CAShapeLayer()
        star.path = Self.star(radius: 7)
        star.fillColor = CGColor(srgbRed: 1, green: 0.85, blue: 0.25, alpha: 1)
        star.strokeColor = CGColor(srgbRed: 0.85, green: 0.5, blue: 0.1, alpha: 1)
        star.lineWidth = 1
        fly(star, through: [center, CGPoint(x: center.x, y: center.y + 10)], keyTimes: [0, 1], duration: 0.6, delay: 0.2, grow: 1.6)
    }

    // MARK: Helpers

    func applyScale(to layer: CALayer) {
        layer.contentsScale = contentsScale
        layer.sublayers?.forEach { applyScale(to: $0) }
    }

    /// A repeating animation that stays whatever the motion
    func gearLoop(_ layer: CALayer, _ keyPath: String, values: [Any], duration: Double, phase: Double = 0,
                  timing: CAMediaTimingFunctionName = .easeInEaseOut) {
        let animation = keyframes(keyPath, values: values, keyTimes: nil, duration: duration, timing: timing, timings: nil, fps: 24)
        animation.repeatCount = .infinity
        animation.timeOffset = phase * duration
        layer.add(animation, forKey: "gear." + keyPath)
    }
}

// MARK: - Subagents

/// A running subagent: a small copy of its session's robot, scurrying around it
final class MiniBot {
    static let size: CGFloat = 0.42

    let id: String
    let rig: RobotRig
    private let animator = FaceAnimator(mood: .focused)
    private var lastFace: FaceFrame?
    private var faceAt: CFTimeInterval = 0
    private(set) var x: CGFloat
    private var target: CGFloat
    private var pauseUntil: CFTimeInterval = 0
    /// 0 inside its parent ... 1 out
    private var grow: CGFloat = 0
    var leaving = false
    private(set) var isGone = false

    init(id: String, genome: RobotGenome, x: CGFloat, scale: CGFloat) {
        self.id = id
        rig = RobotRig(genome: genome)
        rig.setContentsScale(scale)
        self.x = x
        target = x
        rig.layer.transform = CATransform3DMakeScale(0.001, 0.001, 1)
    }

    /// Back inside its parent, ready to pop out again
    func reset(at home: CGFloat) {
        x = home
        target = home
        grow = 0
    }

    /// Pops out of its parent at home and runs around within bounds; leaving, runs back and shrinks into it
    func update(now: CFTimeInterval, dt: Double, home: CGFloat, bounds: ClosedRange<CGFloat>, mood: Mood) {
        if leaving {
            target = home
        } else if x == target, now >= pauseUntil {
            let reach = CGFloat.random(in: 50...140) * (Bool.random() ? 1 : -1)
            target = min(max(home + reach, bounds.lowerBound), bounds.upperBound)
        }
        let distance = target - x
        let stride = CGFloat(dt) * rig.genome.speed * 1.6
        if abs(distance) <= stride {
            if x != target { pauseUntil = now + Double.random(in: 0.3...1.6) }
            x = target
        } else {
            x += distance > 0 ? stride : -stride
            rig.facing = distance > 0 ? 1 : -1
        }
        if leaving {
            if abs(home - x) < 4 { grow = max(0, grow - CGFloat(dt) * 3) }
            isGone = grow == 0
        } else {
            grow = min(1, grow + CGFloat(dt) * 2.5)
        }
        rig.setMotion(x == target ? .idle : .walk)
        if now - faceAt > 0.1 {
            faceAt = now
            let face = animator.frame(for: mood, at: now)
            if lastFace.map({ !face.isClose(to: $0) }) ?? true {
                rig.face.apply(face, in: rig.faceRect)
                lastFace = face
            }
        }
    }

    /// Its foot at foot, in its container's coordinates
    func place(foot: CGPoint) {
        let s = max(0.001, Self.size * grow)
        // A little hop on its way out
        let hop = leaving ? 0 : sin(grow * .pi) * 16
        rig.layer.transform = CATransform3DMakeScale(s, s, 1)
        rig.layer.position = CGPoint(x: foot.x - RobotRig.foot.x * s, y: foot.y + hop - RobotRig.foot.y * s)
    }
}
