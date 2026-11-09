import AppKit

/// Where robots can stand: the bottom of every screen and the top of windows with room above them.
/// Window frames come from CGWindowList (bounds need no permission) and are only read when a robot needs them.
/// Coordinates are AppKit's: origin at the bottom-left of the main screen, y up.
final class RobotWorld {
    struct Screen {
        let id: CGDirectDisplayID
        let frame: CGRect
        let visible: CGRect
    }

    struct Window {
        let id: CGWindowID
        let frame: CGRect
        /// 0 is the frontmost
        let order: Int
    }

    enum Support: Equatable {
        case ground(CGDirectDisplayID)
        case window(CGWindowID)
    }

    /// A horizontal stretch a robot can walk on
    struct Surface {
        let support: Support
        let y: CGFloat
        let minX: CGFloat
        let maxX: CGFloat
    }

    /// A window side a robot can climb. side is +1 when the wall is on the robot's right (the window's left edge),
    /// 0 for the window's face, climbed straight up at offset from its left edge.
    struct Wall {
        let window: CGWindowID
        let side: CGFloat
        var offset: CGFloat = 0

        /// Where the robot goes up, for the window's current frame
        func x(in frame: CGRect) -> CGFloat {
            side > 0 ? frame.minX : side < 0 ? frame.maxX : frame.minX + offset
        }
    }

    /// A window top a robot can reach by climbing straight up the window's face.
    /// touches: the window comes down to the robot's surface, so it can climb it by hand too.
    struct Face {
        let window: Window
        let x: CGFloat
        let touches: Bool
    }

    private(set) var screens: [Screen] = []
    private(set) var windows: [Window] = []
    private var windowsReadAt: CFTimeInterval = -100
    private let ownPid = getpid()

    init() {
        refreshScreens()
    }

    func refreshScreens() {
        screens = NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
            return Screen(id: id, frame: screen.frame, visible: screen.visibleFrame)
        }
    }

    /// Reads the window list, at most once every maxAge seconds
    func refreshWindows(maxAge: CFTimeInterval) {
        let now = CACurrentMediaTime()
        guard now - windowsReadAt >= maxAge else { return }
        windowsReadAt = now
        guard let primaryHeight = NSScreen.screens.first?.frame.height,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            windows = []
            return
        }
        var result: [Window] = []
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? pid_t) != ownPid,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.2,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
                  bounds.width >= 120, bounds.height >= 60 else { continue }
            // CoreGraphics counts y downwards from the top of the main screen
            let frame = CGRect(x: bounds.minX, y: primaryHeight - bounds.maxY, width: bounds.width, height: bounds.height)
            result.append(Window(id: id, frame: frame, order: result.count))
        }
        windows = result
    }

    func window(_ id: CGWindowID) -> Window? {
        windows.first { $0.id == id }
    }

    func screen(containing point: CGPoint) -> Screen? {
        screens.first { $0.frame.contains(point) }
    }

    func screen(_ id: CGDirectDisplayID) -> Screen? {
        screens.first { $0.id == id }
    }

    func nearestScreen(to point: CGPoint) -> Screen? {
        screen(containing: point) ?? screens.min { distance(point, $0.frame) < distance(point, $1.frame) }
    }

    private func distance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        hypot(max(r.minX - p.x, 0, p.x - r.maxX), max(r.minY - p.y, 0, p.y - r.maxY))
    }

    func ground(_ screen: Screen) -> Surface {
        Surface(support: .ground(screen.id), y: screen.visible.minY, minX: screen.visible.minX, maxX: screen.visible.maxX)
    }

    /// Parts of a window's top edge with room above them: below the menu bar, not covered by a window in front
    func tops(of window: Window, clearance: CGFloat, minWidth: CGFloat) -> [Surface] {
        let f = window.frame
        guard let screen = screen(containing: CGPoint(x: f.midX, y: f.maxY - 1)),
              f.maxY + clearance <= screen.visible.maxY, f.maxY > screen.visible.minY + 30 else { return [] }
        var segments = [(max(f.minX, screen.visible.minX), min(f.maxX, screen.visible.maxX))]
        let band = CGRect(x: f.minX, y: f.maxY - 2, width: f.width, height: clearance + 2)
        for other in windows where other.order < window.order && other.frame.intersects(band) {
            segments = segments.flatMap { segment -> [(CGFloat, CGFloat)] in
                let lo = other.frame.minX, hi = other.frame.maxX
                if hi <= segment.0 || lo >= segment.1 { return [segment] }
                var parts: [(CGFloat, CGFloat)] = []
                if lo > segment.0 { parts.append((segment.0, lo)) }
                if hi < segment.1 { parts.append((hi, segment.1)) }
                return parts
            }
        }
        return segments.filter { $0.1 - $0.0 >= minWidth }
            .map { Surface(support: .window(window.id), y: f.maxY, minX: $0.0, maxX: $0.1) }
    }

    /// Where a robot standing on support at x can walk, or nil when that place is gone
    func surface(_ support: Support, at x: CGFloat, clearance: CGFloat, halfWidth: CGFloat) -> Surface? {
        switch support {
        case .ground(let id):
            return screen(id).map(ground)
        case .window(let id):
            guard let window = window(id) else { return nil }
            return tops(of: window, clearance: clearance, minWidth: halfWidth * 2)
                .first { $0.minX - halfWidth * 0.5 <= x && x <= $0.maxX + halfWidth * 0.5 }
        }
    }

    /// The highest place to stand at x, not above y
    func landing(at x: CGFloat, below y: CGFloat, clearance: CGFloat, halfWidth: CGFloat) -> Surface? {
        var best: Surface?
        for window in windows where window.frame.maxY <= y + 0.5 && window.frame.minX < x && window.frame.maxX > x {
            for top in tops(of: window, clearance: clearance, minWidth: halfWidth * 2)
            where top.minX <= x && x <= top.maxX && top.y > (best?.y ?? -.infinity) {
                best = top
            }
        }
        let below = screens.filter { $0.frame.minX <= x && x < $0.frame.maxX && $0.visible.minY <= y + 0.5 }
        if let screen = below.max(by: { $0.visible.minY < $1.visible.minY }), screen.visible.minY > (best?.y ?? -.infinity) {
            best = ground(screen)
        }
        return best
    }

    /// Window sides a robot on surface can reach and climb, with room to stand on top
    func walls(from surface: Surface, halfWidth hw: CGFloat, height: CGFloat) -> [Wall] {
        guard surface.maxX - surface.minX > hw * 2 else { return [] }
        var result: [Wall] = []
        for window in windows {
            if surface.support == .window(window.id) { continue }
            let f = window.frame
            // The side must reach down to the surface (a robot can jump a little) and be worth the climb
            guard f.minY <= surface.y + height * 0.4, f.maxY >= surface.y + height else { continue }
            let tops = tops(of: window, clearance: height + 8, minWidth: hw * 2 + 10)
            let reachable = surface.minX + hw...surface.maxX - hw
            if reachable.contains(f.minX - hw), tops.contains(where: { $0.minX <= f.minX + 1 && $0.maxX >= f.minX + hw * 2 + 10 }) {
                result.append(Wall(window: window.id, side: 1))
            }
            if reachable.contains(f.maxX + hw), tops.contains(where: { $0.maxX >= f.maxX - 1 && $0.minX <= f.maxX - hw * 2 - 10 }) {
                result.append(Wall(window: window.id, side: -1))
            }
        }
        return result
    }

    /// Window faces a robot on surface can climb straight up to a top with room, right above the surface.
    /// A window floating higher is only for robots that fly or throw a hook.
    func faces(from surface: Surface, halfWidth hw: CGFloat, height: CGFloat) -> [Face] {
        var result: [Face] = []
        for window in windows {
            if surface.support == .window(window.id) { continue }
            let f = window.frame
            guard f.maxY >= surface.y + height else { continue }
            for top in tops(of: window, clearance: height + 8, minWidth: hw * 2 + 10) {
                let lo = max(top.minX, surface.minX) + hw, hi = min(top.maxX, surface.maxX) - hw
                guard hi - lo > 10 else { continue }
                result.append(Face(window: window, x: CGFloat.random(in: lo...hi), touches: f.minY <= surface.y + height * 0.4))
            }
        }
        return result
    }

    /// The screen right next to this one (side +1: on its right), when their grounds join
    func neighbor(of screen: Screen, side: CGFloat) -> Screen? {
        // A Dock on that side cuts the ground off
        guard side > 0 ? screen.visible.maxX >= screen.frame.maxX - 1 : screen.visible.minX <= screen.frame.minX + 1 else { return nil }
        return screens.first { other in
            other.id != screen.id
                && abs(side > 0 ? other.frame.minX - screen.frame.maxX : screen.frame.minX - other.frame.maxX) < 2
                && other.frame.minY < screen.frame.maxY && other.frame.maxY > screen.frame.minY
                && (side > 0 ? other.visible.minX <= other.frame.minX + 1 : other.visible.maxX >= other.frame.maxX - 1)
        }
    }
}
