import AppKit
import QuartzCore

// MARK: - Colors

enum Tint {
    case idle, working, waiting, error, done, sleep

    var components: (r: CGFloat, g: CGFloat, b: CGFloat) {
        switch self {
        case .idle: return (0.84, 0.95, 1.0)
        case .working: return (0.30, 0.79, 1.0)
        case .waiting: return (1.0, 0.65, 0.24)
        case .error: return (1.0, 0.37, 0.37)
        case .done: return (0.36, 0.89, 0.61)
        case .sleep: return (0.49, 0.59, 0.66)
        }
    }

    var color: NSColor {
        let c = components
        return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
    }
}

// MARK: - Moods

enum GazeStyle {
    case wander, center, upward, dart, scan, down, jitter
}

enum Mood: String, CaseIterable {
    case neutral, attentive, thinking, curious, focused, nervous, surprised
    case happy, waiting, sad, annoyed, failed, tired, sleepy

    var tint: Tint {
        switch self {
        case .neutral: return .idle
        case .attentive, .thinking, .curious, .focused, .nervous, .surprised, .tired: return .working
        case .happy: return .done
        case .waiting: return .waiting
        case .sad, .annoyed, .failed: return .error
        case .sleepy: return .sleep
        }
    }

    var label: String {
        switch self {
        case .neutral: return "Neutre"
        case .attentive: return "Attentif"
        case .thinking: return "Réfléchit"
        case .curious: return "Curieux"
        case .focused: return "Concentré"
        case .nervous: return "Nerveux"
        case .surprised: return "Surpris"
        case .happy: return "Content"
        case .waiting: return "Attend ta réponse"
        case .sad: return "Triste"
        case .annoyed: return "Contrarié"
        case .failed: return "En erreur"
        case .tired: return "Fatigué"
        case .sleepy: return "Endormi"
        }
    }

    var trigger: String {
        switch self {
        case .neutral: return "Session ouverte, rien en cours"
        case .attentive: return "Tu viens d'envoyer un message"
        case .thinking: return "Aucun événement depuis quelques secondes"
        case .curious: return "Lit des fichiers, cherche dans le code ou sur le web"
        case .focused: return "Écrit du code, lance une commande ou un agent"
        case .nervous: return "Lance les tests ou l'analyse du code"
        case .surprised: return "Vient d'écrire une grosse modification"
        case .happy: return "Réponse terminée ou tests réussis"
        case .waiting: return "Demande une permission ou te pose une question"
        case .sad: return "Un outil a échoué ou des tests sont rouges"
        case .annoyed: return "Le mode auto a refusé une action"
        case .failed: return "La réponse s'est arrêtée sur une erreur d'API"
        case .tired: return "Résume la conversation pour libérer du contexte"
        case .sleepy: return "Aucune activité depuis un moment"
        }
    }

    var params: FaceParams {
        switch self {
        case .neutral:
            return FaceParams(tint: .idle)
        case .attentive:
            return FaceParams(left: EyeParams(w: 1.08, h: 1.12), tint: .working)
        case .thinking:
            return FaceParams(left: EyeParams(h: 0.92), right: EyeParams(h: 0.82, lidTop: 0.08), tint: .working)
        case .curious:
            return FaceParams(left: EyeParams(w: 1.1, h: 1.18), right: EyeParams(w: 0.92, h: 0.86, lidTop: 0.12), tint: .working)
        case .focused:
            return FaceParams(left: EyeParams(h: 0.6), tint: .working)
        case .nervous:
            return FaceParams(left: EyeParams(w: 0.86, h: 0.86), tint: .working)
        case .surprised:
            return FaceParams(left: EyeParams(w: 1.16, h: 1.3), tint: .working)
        case .happy:
            return FaceParams(left: EyeParams(lidBottom: 0.5), tint: .done)
        case .waiting:
            return FaceParams(left: EyeParams(w: 1.1, h: 1.14, dy: 0.04), right: EyeParams(w: 1.1, h: 1.14, dy: -0.04), tint: .waiting)
        case .sad:
            return FaceParams(left: EyeParams(h: 0.86, lidTop: 0.28, lidTilt: 0.55), tint: .error)
        case .annoyed:
            return FaceParams(left: EyeParams(h: 0.82, lidTop: 0.3, lidTilt: -0.65), tint: .error)
        case .failed:
            return FaceParams(left: EyeParams(h: 0.78, lidTop: 0.36, lidTilt: 0.6), tint: .error)
        case .tired:
            return FaceParams(left: EyeParams(lidTop: 0.46, lidTilt: 0.12), tint: .working)
        case .sleepy:
            return FaceParams(left: EyeParams(lidTop: 0.84, lidTilt: 0.1), tint: .sleep, alpha: 0.85)
        }
    }

    var gaze: GazeStyle {
        switch self {
        case .neutral: return .wander
        case .attentive, .happy, .waiting, .annoyed, .surprised: return .center
        case .thinking: return .upward
        case .curious: return .dart
        case .focused: return .scan
        case .nervous: return .jitter
        case .sad, .failed, .tired, .sleepy: return .down
        }
    }

    var blinks: Bool { self != .sleepy }

    /// States that need you keep their own color, whatever the session's /color
    var isAlert: Bool {
        switch self {
        case .waiting, .sad, .annoyed, .failed, .happy: return true
        default: return false
        }
    }

    /// Gaze used for still renderings (icon, gallery)
    var stillGaze: CGPoint {
        switch self {
        case .thinking: return CGPoint(x: 0.5, y: 0.55)
        case .curious: return CGPoint(x: -0.5, y: 0.2)
        case .focused: return CGPoint(x: 0.1, y: -0.25)
        case .sad, .failed, .tired: return CGPoint(x: 0, y: -0.5)
        case .sleepy: return CGPoint(x: 0, y: -0.3)
        default: return .zero
        }
    }
}

// MARK: - Parameters

@inline(__always) func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

/// One eye, in units relative to the base eye size
struct EyeParams {
    var w: CGFloat = 1
    var h: CGFloat = 1
    var dy: CGFloat = 0
    var lidTop: CGFloat = 0      // 0...1 coverage from the top
    var lidTilt: CGFloat = 0     // + outer corner lower (sad), - inner corner lower (angry)
    var lidBottom: CGFloat = 0   // 0...1 curved coverage from the bottom (happy)

    func mixed(_ o: EyeParams, _ t: CGFloat) -> EyeParams {
        EyeParams(w: lerp(w, o.w, t), h: lerp(h, o.h, t), dy: lerp(dy, o.dy, t),
                  lidTop: lerp(lidTop, o.lidTop, t), lidTilt: lerp(lidTilt, o.lidTilt, t),
                  lidBottom: lerp(lidBottom, o.lidBottom, t))
    }
}

struct FaceParams {
    var left: EyeParams
    var right: EyeParams
    var r: CGFloat
    var g: CGFloat
    var b: CGFloat
    var alpha: CGFloat

    init(left: EyeParams = EyeParams(), right: EyeParams? = nil, tint: Tint, alpha: CGFloat = 1) {
        self.left = left
        self.right = right ?? left
        let c = tint.components
        r = c.r
        g = c.g
        b = c.b
        self.alpha = alpha
    }

    func mixed(_ o: FaceParams, _ t: CGFloat) -> FaceParams {
        var m = self
        m.left = left.mixed(o.left, t)
        m.right = right.mixed(o.right, t)
        m.r = lerp(r, o.r, t)
        m.g = lerp(g, o.g, t)
        m.b = lerp(b, o.b, t)
        m.alpha = lerp(alpha, o.alpha, t)
        return m
    }
}

struct FaceFrame {
    var params: FaceParams
    var gaze: CGPoint = .zero
    var blink: CGFloat = 0   // 0 open ... 1 closed
    var lift: CGFloat = 0    // vertical offset in face units (bounce, breathing)

    static func still(_ mood: Mood) -> FaceFrame {
        FaceFrame(params: mood.params, gaze: mood.stillGaze)
    }
}

// MARK: - Animation

/// Eases a face towards the current mood and adds life: blinks, saccades, bounces
final class FaceAnimator {
    private var params: FaceParams
    private var mood: Mood
    private var moodSince: CFTimeInterval
    private var lastTime: CFTimeInterval
    private var gaze = CGPoint.zero
    private var gazeTarget = CGPoint.zero
    private var nextGazeAt: CFTimeInterval = 0
    private var blinkStart: CFTimeInterval = -10
    private var nextBlinkAt: CFTimeInterval
    private var doubleBlink = false

    init(mood: Mood, now: CFTimeInterval = CACurrentMediaTime()) {
        self.mood = mood
        params = mood.params
        moodSince = now
        lastTime = now
        nextBlinkAt = now + Double.random(in: 1...4)
    }

    /// color: the session's /color. Calm moods take it, alerts keep their color and pulse
    /// so they stay recognizable even when the session color matches the alert color
    func frame(for target: Mood, color: SessionColor? = nil, at now: CFTimeInterval) -> FaceFrame {
        let dt = CGFloat(min(0.1, max(0, now - lastTime)))
        lastTime = now

        if target != mood {
            mood = target
            moodSince = now
            nextGazeAt = now
            // Robots blink when they change their mind
            if target.blinks { blinkStart = now }
        }

        var goal = mood.params
        if let color, !mood.isAlert {
            let c = color.eyeComponents
            let brightness: CGFloat = mood == .sleepy ? 0.6 : 1
            goal.r = c.r * brightness
            goal.g = c.g * brightness
            goal.b = c.b * brightness
        }
        params = params.mixed(goal, 1 - exp(-dt * 10))

        if now >= nextGazeAt { pickGaze(now) }
        let gazeEase = 1 - exp(-dt * 16)
        gaze.x = lerp(gaze.x, gazeTarget.x, gazeEase)
        gaze.y = lerp(gaze.y, gazeTarget.y, gazeEase)

        var shown = params
        if color != nil, mood.isAlert, mood != .happy {
            // Breathes towards white
            let pulse = CGFloat(sin(now * 2 * .pi / 1.4) + 1) / 2 * 0.45
            shown.r = lerp(shown.r, 1, pulse)
            shown.g = lerp(shown.g, 1, pulse)
            shown.b = lerp(shown.b, 1, pulse)
        }
        return FaceFrame(params: shown, gaze: gaze, blink: blink(at: now), lift: lift(at: now))
    }

    private func blink(at now: CFTimeInterval) -> CGFloat {
        guard mood.blinks else { return 0 }
        if now >= nextBlinkAt {
            blinkStart = now
            nextBlinkAt = now + Double.random(in: 2.4...6)
            doubleBlink = Double.random(in: 0...1) < 0.18
        }
        let duration = 0.16
        let t = now - blinkStart
        if t < duration { return CGFloat(sin(.pi * t / duration)) }
        if doubleBlink, t > 0.24, t < 0.24 + duration { return CGFloat(sin(.pi * (t - 0.24) / duration)) }
        return 0
    }

    private func lift(at now: CFTimeInterval) -> CGFloat {
        let since = now - moodSince
        switch mood {
        case .waiting:
            let phase = since.truncatingRemainder(dividingBy: 1.8)
            return phase < 0.45 ? CGFloat(sin(.pi * phase / 0.45)) * 0.09 : 0
        case .happy:
            if since < 0.5 { return CGFloat(sin(.pi * since / 0.5)) * 0.12 }
            if since < 0.85 { return CGFloat(sin(.pi * (since - 0.5) / 0.35)) * 0.05 }
            return 0
        case .surprised:
            return since < 0.3 ? CGFloat(sin(.pi * since / 0.3)) * 0.08 : 0
        case .sleepy:
            return CGFloat(sin(now * 2 * .pi / 4.5)) * 0.025
        default:
            return 0
        }
    }

    private func pickGaze(_ now: CFTimeInterval) {
        func r(_ range: ClosedRange<CGFloat>) -> CGFloat { CGFloat.random(in: range) }
        switch mood.gaze {
        case .center:
            gazeTarget = CGPoint(x: r(-0.08...0.08), y: r(-0.05...0.05))
            nextGazeAt = now + Double.random(in: 1.5...3)
        case .wander:
            gazeTarget = Double.random(in: 0...1) < 0.6 ? CGPoint(x: r(-0.7...0.7), y: r(-0.4...0.4)) : .zero
            nextGazeAt = now + Double.random(in: 1.8...4.5)
        case .upward:
            gazeTarget = CGPoint(x: (Bool.random() ? -0.55 : 0.55) + r(-0.1...0.1), y: r(0.45...0.7))
            nextGazeAt = now + Double.random(in: 1.2...2.8)
        case .dart:
            gazeTarget = CGPoint(x: r(-0.85...0.85), y: r(-0.5...0.5))
            nextGazeAt = now + Double.random(in: 0.45...1.2)
        case .scan:
            // Reads line by line, then goes back to the start of the next line
            let x = gazeTarget.x + 0.25
            gazeTarget = CGPoint(x: x > 0.55 ? -0.5 : x, y: -0.25 + r(-0.04...0.04))
            nextGazeAt = now + Double.random(in: 0.25...0.45)
        case .down:
            gazeTarget = CGPoint(x: r(-0.2...0.2), y: -0.55)
            nextGazeAt = now + Double.random(in: 2...4)
        case .jitter:
            gazeTarget = CGPoint(x: r(-0.35...0.35), y: r(-0.2...0.2))
            nextGazeAt = now + Double.random(in: 0.18...0.45)
        }
    }
}

// MARK: - Rendering

enum FaceRenderer {
    /// Base size of the face in rect, every measure derives from it
    static func unit(in rect: CGRect) -> CGFloat { min(rect.height, rect.width / 2) }

    static func color(_ p: FaceParams, alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: p.r, green: p.g, blue: p.b, alpha: p.alpha * alpha)
    }

    /// Outline of both eyes with the lids carved out
    static func eyesPath(_ f: FaceFrame, in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let u = unit(in: rect)
        guard u > 1 else { return path }

        let p = f.params
        let baseW = u * 0.5
        let baseH = u * 0.56
        let gap = u * 0.28
        let cx = rect.midX + f.gaze.x * u * 0.2
        let cy = rect.midY + f.gaze.y * u * 0.12 + f.lift * u

        for side: CGFloat in [-1, 1] {
            let e = side < 0 ? p.left : p.right
            // The eye on the gaze side looks slightly bigger
            let perspective = 1 + 0.09 * f.gaze.x * side
            let ew = baseW * e.w * perspective
            let eh = max(u * 0.05, baseH * e.h * perspective * (1 - 0.92 * f.blink))
            let ex = cx + side * (gap / 2 + baseW / 2)
            let ey = cy + e.dy * u
            let rect = CGRect(x: ex - ew / 2, y: ey - eh / 2, width: ew, height: eh)
            let radius = min(ew, eh) * 0.3
            var eye: CGPath = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            for lid in lidPaths(e, eye: rect, outerIsLeft: side < 0) {
                eye = eye.subtracting(lid)
            }
            path.addPath(eye)
        }
        return path
    }

    /// Draws two glowing eyes centered in rect (CPU rendering: Dock icon, snapshots)
    static func draw(_ f: FaceFrame, in rect: CGRect, ctx: CGContext, glow: Bool = true) {
        let u = unit(in: rect)
        guard u > 1 else { return }
        ctx.saveGState()
        if glow {
            ctx.setShadow(offset: .zero, blur: u * 0.16, color: color(f.params, alpha: 0.75))
        }
        ctx.addPath(eyesPath(f, in: rect))
        ctx.setFillColor(color(f.params))
        ctx.fillPath()
        ctx.restoreGState()
    }

    private static func lidPaths(_ e: EyeParams, eye r: CGRect, outerIsLeft: Bool) -> [CGPath] {
        var paths: [CGPath] = []

        if e.lidTop > 0.01 {
            let yCenter = r.maxY - e.lidTop * r.height
            let tilt = e.lidTilt * r.height * 0.35
            let yLeft = outerIsLeft ? yCenter - tilt : yCenter + tilt
            let yRight = outerIsLeft ? yCenter + tilt : yCenter - tilt
            let slope = (yRight - yLeft) / r.width
            let ext = r.width * 0.1
            let path = CGMutablePath()
            path.move(to: CGPoint(x: r.minX - ext, y: r.maxY + r.height))
            path.addLine(to: CGPoint(x: r.maxX + ext, y: r.maxY + r.height))
            path.addLine(to: CGPoint(x: r.maxX + ext, y: yRight + slope * ext))
            path.addLine(to: CGPoint(x: r.minX - ext, y: yLeft - slope * ext))
            path.closeSubpath()
            paths.append(path)
        }

        if e.lidBottom > 0.01 {
            let height = r.height * 1.3
            let top = r.minY + e.lidBottom * r.height * 1.25
            let ellipse = CGRect(x: r.midX - r.width * 0.75, y: top - height, width: r.width * 1.5, height: height)
            paths.append(CGPath(ellipseIn: ellipse, transform: nil))
        }

        return paths
    }
}

/// GPU-rendered face: the glow is a Core Animation shadow instead of a CPU blur
final class FaceLayer: CAShapeLayer {
    override init() {
        super.init()
        shadowOffset = .zero
        shadowOpacity = 0.75
        actions = ["path": NSNull(), "shadowPath": NSNull(), "fillColor": NSNull(), "shadowColor": NSNull(),
                   "shadowRadius": NSNull(), "position": NSNull(), "bounds": NSNull(), "frame": NSNull()]
    }

    override init(layer: Any) { super.init(layer: layer) }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func apply(_ f: FaceFrame, in rect: CGRect) {
        let path = FaceRenderer.eyesPath(f, in: rect)
        self.path = path
        shadowPath = path
        fillColor = FaceRenderer.color(f.params)
        shadowColor = FaceRenderer.color(f.params)
        shadowRadius = FaceRenderer.unit(in: rect) * 0.08
    }
}

extension FaceFrame {
    /// True when redrawing would not change anything visible
    func isClose(to o: FaceFrame) -> Bool {
        let values: [(CGFloat, CGFloat)] = [
            (gaze.x, o.gaze.x), (gaze.y, o.gaze.y), (blink, o.blink), (lift, o.lift),
            (params.left.w, o.params.left.w), (params.left.h, o.params.left.h), (params.left.lidTop, o.params.left.lidTop),
            (params.left.lidBottom, o.params.left.lidBottom), (params.right.h, o.params.right.h),
            (params.right.lidTop, o.params.right.lidTop), (params.r, o.params.r), (params.g, o.params.g),
            (params.b, o.params.b), (params.alpha, o.params.alpha),
        ]
        return values.allSatisfy { abs($0.0 - $0.1) < 0.003 }
    }
}

// MARK: - App icon

enum IconRenderer {
    /// Draws the rounded dark tile used by the Dock icon, returns its body rect
    @discardableResult
    static func drawTile(in rect: CGRect, ctx: CGContext) -> CGRect {
        let body = rect.insetBy(dx: rect.width * 0.098, dy: rect.height * 0.098)
        let radius = body.width * 0.225
        let path = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -rect.height * 0.012), blur: rect.height * 0.03,
                      color: CGColor(gray: 0, alpha: 0.35))
        ctx.addPath(path)
        ctx.setFillColor(CGColor(srgbRed: 0.09, green: 0.1, blue: 0.14, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        let colors = [CGColor(srgbRed: 0.17, green: 0.2, blue: 0.27, alpha: 1),
                      CGColor(srgbRed: 0.06, green: 0.07, blue: 0.1, alpha: 1)] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: body.midX, y: body.maxY),
                                   end: CGPoint(x: body.midX, y: body.minY), options: [])
        }
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(path)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.08))
        ctx.setLineWidth(max(1, rect.width * 0.006))
        ctx.strokePath()
        ctx.restoreGState()

        return body
    }

    static func draw(_ f: FaceFrame, in rect: CGRect, ctx: CGContext) {
        let body = drawTile(in: rect, ctx: ctx)
        FaceRenderer.draw(f, in: body.insetBy(dx: body.width * 0.06, dy: body.height * 0.26), ctx: ctx)
    }
}

enum Icons {
    /// Static template image for the menu bar
    static func menuBar() -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 16), flipped: false) { _ in
            NSColor.black.setFill()
            for x in [4.75, 10.75] {
                NSBezierPath(roundedRect: NSRect(x: x, y: 3.5, width: 4.5, height: 8.5), xRadius: 1.8, yRadius: 1.8).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    static func dot(_ tint: Tint) -> NSImage {
        NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            tint.color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }
}

// MARK: - Offscreen rendering (build-time icon, debug gallery)

enum Snapshot {
    static func png(size: NSSize, draw: (CGContext, CGRect) -> Void) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let gc = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        draw(gc.cgContext, CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    static func writeIconset(to dir: String) {
        var frame = FaceFrame.still(.neutral)
        frame.params = FaceParams(tint: .working)
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let px = base * scale
                let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
                let data = png(size: NSSize(width: px, height: px)) { ctx, rect in
                    IconRenderer.draw(frame, in: rect, ctx: ctx)
                }
                try? data?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
            }
        }
    }

    static func writeColorTiles(to path: String) {
        let moods: [Mood] = [.neutral, .focused, .sleepy, .waiting]
        let tile: CGFloat = 160
        let colors: [SessionColor?] = [nil] + SessionColor.allCases
        let size = NSSize(width: tile * CGFloat(colors.count), height: tile * CGFloat(moods.count))
        let data = png(size: size) { ctx, rect in
            ctx.setFillColor(CGColor(srgbRed: 0.85, green: 0.87, blue: 0.9, alpha: 1))
            ctx.fill(rect)
            for (row, mood) in moods.enumerated() {
                for (column, color) in colors.enumerated() {
                    // Settle the animator on the mood, as seen after a few seconds
                    let animator = FaceAnimator(mood: mood, now: 0)
                    var frame = animator.frame(for: mood, color: color, at: 0)
                    for step in 1...60 { frame = animator.frame(for: mood, color: color, at: Double(step) * 0.05) }
                    frame.gaze = .zero
                    frame.blink = 0
                    frame.lift = 0
                    let cell = CGRect(x: CGFloat(column) * tile, y: size.height - CGFloat(row + 1) * tile, width: tile, height: tile)
                    IconRenderer.draw(frame, in: cell, ctx: ctx)
                }
            }
        }
        try? data?.write(to: URL(fileURLWithPath: path))
    }

    static func writeGallery(to path: String) {
        let columns = 4
        let cell = NSSize(width: 260, height: 170)
        let rows = (Mood.allCases.count + columns - 1) / columns
        let size = NSSize(width: cell.width * CGFloat(columns), height: cell.height * CGFloat(rows))
        let data = png(size: size) { ctx, rect in
            ctx.setFillColor(CGColor(srgbRed: 0.07, green: 0.08, blue: 0.1, alpha: 1))
            ctx.fill(rect)
            for (i, mood) in Mood.allCases.enumerated() {
                let col = i % columns
                let row = i / columns
                let origin = CGPoint(x: CGFloat(col) * cell.width, y: size.height - CGFloat(row + 1) * cell.height)
                let face = CGRect(x: origin.x + 20, y: origin.y + 40, width: cell.width - 40, height: cell.height - 60)
                FaceRenderer.draw(.still(mood), in: face, ctx: ctx)
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .semibold),
                                                            .foregroundColor: NSColor.white]
                (mood.label as NSString).draw(at: CGPoint(x: origin.x + 20, y: origin.y + 12), withAttributes: attrs)
            }
        }
        try? data?.write(to: URL(fileURLWithPath: path))
    }
}
