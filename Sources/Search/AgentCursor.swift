import AppKit
import Combine
import SwiftUI

enum AgentEdge: String, CaseIterable, Identifiable {
    case aura, comet, frame, off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .aura: return "Aura"
        case .comet: return "Comet"
        case .frame: return "Frame"
        case .off: return "Off"
        }
    }
}

struct AgentGlide {
    let points: [CGPoint]
    let marks: [CGFloat]
    let start: TimeInterval
    let duration: TimeInterval
    let linear: Bool

    init(points: [CGPoint], start: TimeInterval, duration: TimeInterval, linear: Bool) {
        var marks: [CGFloat] = [0]
        for index in points.indices.dropFirst() {
            let a = points[index - 1], b = points[index]
            marks.append(marks[index - 1] + hypot(b.x - a.x, b.y - a.y))
        }
        self.points = points
        self.marks = marks
        self.start = start
        self.duration = duration
        self.linear = linear
    }

    var end: CGPoint { points[points.count - 1] }
    var finish: TimeInterval { start + duration }

    func at(_ now: TimeInterval) -> CGPoint {
        guard duration > 0, points.count > 1, let total = marks.last, total > 0 else { return end }
        let t = min(max((now - start) / duration, 0), 1)
        let want = CGFloat(linear ? t : AgentGlide.ease(t)) * total
        var index = 1
        while index < marks.count - 1 && marks[index] < want { index += 1 }
        let span = marks[index] - marks[index - 1]
        let f = span > 0 ? (want - marks[index - 1]) / span : 1
        let a = points[index - 1], b = points[index]
        return CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
    }

    static func ease(_ x: Double) -> Double {
        let (x1, y1, x2, y2) = (0.34, 0.0, 0.12, 1.0)
        func curve(_ t: Double, _ a: Double, _ b: Double) -> Double {
            let u = 1 - t
            return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t
        }
        func slope(_ t: Double, _ a: Double, _ b: Double) -> Double {
            let u = 1 - t
            return 3 * u * u * a + 6 * u * t * (b - a) + 3 * t * t * (1 - b)
        }
        var t = x
        for _ in 0..<8 {
            let d = slope(t, x1, x2)
            if abs(d) < 1e-6 { break }
            t = min(max(t - (curve(t, x1, x2) - x) / d, 0), 1)
        }
        return curve(t, y1, y2)
    }

    static func arc(from a: CGPoint, to b: CGPoint) -> [CGPoint] {
        let dx = b.x - a.x, dy = b.y - a.y
        let distance = hypot(dx, dy)
        guard distance > 0 else { return [b] }
        let bend = min(distance * 0.16, 56) * (dx >= 0 ? -1 : 1)
        let control = CGPoint(x: (a.x + b.x) / 2 - dy / distance * bend,
                              y: (a.y + b.y) / 2 + dx / distance * bend)
        return (0...20).map { (step: Int) -> CGPoint in
            let t = CGFloat(step) / 20
            let u: CGFloat = 1 - t
            let wa: CGFloat = u * u
            let wc: CGFloat = 2 * u * t
            let wb: CGFloat = t * t
            let x: CGFloat = wa * a.x + wc * control.x + wb * b.x
            let y: CGFloat = wa * a.y + wc * control.y + wb * b.y
            return CGPoint(x: x, y: y)
        }
    }
}

@MainActor
final class AgentPresence: ObservableObject {
    struct Tap {
        let at: CGPoint
        let time: TimeInterval
    }

    @Published fileprivate(set) var awake = false
    fileprivate(set) var live = false
    fileprivate(set) var changed: TimeInterval = 0
    fileprivate(set) var glide: AgentGlide?
    fileprivate(set) var pressed = false
    fileprivate(set) var taps: [Tap] = []
    fileprivate(set) var word: String?
    fileprivate(set) var wordTime: TimeInterval = 0
    fileprivate(set) var keyTime: TimeInterval = -1000
    fileprivate var origin: DriveOrigin?
    fileprivate var quiet: DispatchWorkItem?
    fileprivate var nap: DispatchWorkItem?
    fileprivate var arrival: DispatchWorkItem?

    static var now: TimeInterval { Date.timeIntervalSinceReferenceDate }

    var still: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    fileprivate func wake() {
        nap?.cancel()
        nap = nil
        if !live {
            live = true
            changed = Self.now
        }
        if !awake { awake = true }
    }

    fileprivate func sleep() {
        quiet?.cancel()
        quiet = nil
        guard live else { return }
        live = false
        pressed = false
        changed = Self.now
        let nap = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.live else { return }
                self.awake = false
                self.word = nil
            }
        }
        self.nap = nap
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: nap)
    }

    @discardableResult
    fileprivate func move(to point: CGPoint, word: String?) -> TimeInterval {
        let now = Self.now
        arrival?.cancel()
        arrival = nil
        let from = glide?.at(now) ?? CGPoint(x: point.x + 64, y: point.y + 84)
        let distance = hypot(point.x - from.x, point.y - from.y)
        let duration = still || distance < 2 ? 0 : min(0.46, 0.18 + distance.squareRoot() / 110)
        glide = AgentGlide(points: duration == 0 ? [point] : AgentGlide.arc(from: from, to: point),
                           start: now, duration: duration, linear: false)
        if let word { say(word) }
        return duration
    }

    fileprivate func trace(_ points: [CGPoint], over duration: TimeInterval) {
        let now = Self.now
        arrival?.cancel()
        arrival = nil
        let from = glide?.at(now) ?? points.first ?? .zero
        glide = AgentGlide(points: [from] + points, start: now, duration: still ? 0 : duration, linear: true)
    }

    fileprivate func tap(at point: CGPoint? = nil) {
        let now = Self.now
        guard let spot = point ?? glide?.at(now) else { return }
        taps.removeAll { now - $0.time > 1 }
        taps.append(Tap(at: spot, time: now))
    }

    fileprivate func tapOnArrival(after delay: TimeInterval) {
        guard delay > 0 else { tap(); return }
        let arrival = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.tap() }
        }
        self.arrival = arrival
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: arrival)
    }

    fileprivate func hold(_ down: Bool) {
        pressed = down
        if down { tap() }
    }

    fileprivate func say(_ word: String) {
        self.word = word
        wordTime = Self.now
    }

    fileprivate func key() {
        if word != "Typing" { say("Typing") }
        keyTime = Self.now
    }
}

@MainActor
final class AgentCursor: ObservableObject {
    static let shared = AgentCursor()

    @Published var showsCursor: Bool
    @Published var edge: AgentEdge

    private var presences: [UUID: AgentPresence] = [:]
    private var turnWatch: AnyCancellable?

    private init() {
        showsCursor = Store.settings.object(forKey: "ask.agentCursor") as? Bool ?? true
        edge = AgentEdge(rawValue: Store.settings.string(forKey: "ask.agentEdge") ?? "") ?? .aura
    }

    private var enabled: Bool { showsCursor || edge != .off }

    func presence(for id: UUID) -> AgentPresence {
        if let presence = presences[id] { return presence }
        let presence = AgentPresence()
        presences[id] = presence
        return presence
    }

    func wake(_ id: UUID, from origin: DriveOrigin) {
        guard enabled else { return }
        if origin == .app { watchTurns() }
        let presence = presence(for: id)
        presence.origin = origin
        presence.quiet?.cancel()
        presence.quiet = nil
        presence.wake()
        for (other, sibling) in presences where other != id && sibling.live && sibling.origin == origin {
            quiet(sibling, after: 1.5, force: true)
        }
    }

    func rest(_ id: UUID) {
        guard let presence = presences[id], presence.live else { return }
        quiet(presence, after: 4, force: false)
    }

    func sleep(_ origin: DriveOrigin) {
        for presence in presences.values where presence.origin == origin { presence.sleep() }
    }

    func sleep(tab id: UUID) {
        presences[id]?.sleep()
    }

    func forget(_ id: UUID) {
        presences.removeValue(forKey: id)?.sleep()
    }

    func glide(_ id: UUID, to point: [Double]?, word: String?, tap: Bool = false) {
        guard showsCursor, let presence = presences[id], presence.live else { return }
        guard let point = Self.point(point) else {
            if let word { presence.say(word) }
            return
        }
        let travel = presence.move(to: point, word: word)
        if tap { presence.tapOnArrival(after: travel) }
    }

    func approach(_ id: UUID, in view: NSView, to point: [Double], word: String, then go: @escaping () -> Void) {
        guard showsCursor, let presence = presences[id], presence.live, let spot = Self.point(point) else { go(); return }
        let travel = presence.move(to: spot, word: word)
        guard travel > 0, Self.onScreen(view) else { go(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + travel) { go() }
    }

    func tap(_ id: UUID, at point: [Double]) {
        guard showsCursor, let presence = presences[id], presence.live else { return }
        presence.tap(at: Self.point(point))
    }

    func hold(_ id: UUID, _ down: Bool) {
        guard let presence = presences[id] else { return }
        if down && !(showsCursor && presence.live) { return }
        presence.hold(down)
    }

    func trace(_ id: UUID, through points: [[Double]], over duration: TimeInterval) {
        guard showsCursor, let presence = presences[id], presence.live else { return }
        presence.trace(points.compactMap(Self.point), over: duration)
    }

    func key(_ id: UUID) {
        guard showsCursor, let presence = presences[id], presence.live else { return }
        presence.key()
    }

    func dragPace(_ id: UUID, in view: NSView, steps: Int) -> TimeInterval {
        guard showsCursor, presences[id]?.live == true, Self.onScreen(view), steps > 0,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return 0.008 }
        return min(max(0.42 / Double(steps), 0.008), 0.05)
    }

    private func quiet(_ presence: AgentPresence, after delay: TimeInterval, force: Bool) {
        presence.quiet?.cancel()
        let work = DispatchWorkItem { [weak presence] in
            MainActor.assumeIsolated {
                guard let presence, presence.live else { return }
                if !force, presence.origin == .app, Mind.shared.runningChatID != nil { return }
                presence.sleep()
            }
        }
        presence.quiet = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func watchTurns() {
        guard turnWatch == nil else { return }
        turnWatch = Mind.shared.$runningChatID
            .removeDuplicates()
            .sink { [weak self] running in
                guard running == nil else { return }
                MainActor.assumeIsolated {
                    guard let self else { return }
                    for presence in self.presences.values where presence.live && presence.origin == .app {
                        self.quiet(presence, after: 1, force: true)
                    }
                }
            }
    }

    private static func point(_ raw: [Double]?) -> CGPoint? {
        guard let raw, raw.count == 2, raw.allSatisfy(\.isFinite) else { return nil }
        return CGPoint(x: raw[0], y: raw[1])
    }

    static func onScreen(_ view: NSView) -> Bool {
        guard let window = view.window, !Bench.shared.isRoom(window), window.isVisible,
              window.occlusionState.contains(.visible), view.superview is StageView else { return false }
        return true
    }
}

struct AgentVeil: View {
    @ObservedObject private var presence: AgentPresence
    @ObservedObject private var look = AgentCursor.shared
    @State private var ink = AgentInk()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let radius: CGFloat

    init(tab: UUID, radius: CGFloat) {
        _presence = ObservedObject(wrappedValue: AgentCursor.shared.presence(for: tab))
        self.radius = radius
    }

    fileprivate init(presence: AgentPresence, radius: CGFloat) {
        _presence = ObservedObject(wrappedValue: presence)
        self.radius = radius
    }

    var body: some View {
        if presence.awake && (look.showsCursor || look.edge != .off) {
            TimelineView(.animation) { timeline in
                let scene = ink.frame(presence, at: timeline.date.timeIntervalSinceReferenceDate,
                                      edge: look.edge, cursor: look.showsCursor, radius: radius, still: reduceMotion)
                Canvas { context, size in scene.draw(in: &context, size: size) }
            }
            .allowsHitTesting(false)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
    }
}

@MainActor
final class AgentInk {
    private var last: TimeInterval = 0
    private var spot: CGPoint?
    private var velocity = CGVector.zero
    private var lean: Double = 0
    private var leanSpeed: Double = 0
    private var squash: Double = 1
    private var squashSpeed: Double = 0
    private var label = CGPoint.zero
    private var labelSpeed = CGVector.zero
    private var trail: [(CGPoint, TimeInterval)] = []
    private var lastTap: TimeInterval = 0

    func frame(_ presence: AgentPresence, at now: TimeInterval, edge: AgentEdge, cursor: Bool,
               radius: CGFloat, still: Bool) -> AgentScene {
        let dt = min(max(now - last, 1.0 / 240), 1.0 / 30)
        last = now
        let alpha = presence.live
            ? min(1, (now - presence.changed) / 0.35)
            : max(0, 1 - (now - presence.changed) / 0.6)
        let newest = presence.taps.last?.time ?? 0
        if newest > lastTap {
            lastTap = newest
            if !still { squashSpeed -= 7 }
        }
        let beat = newest > 0 ? exp(-(now - newest) * 4) : 0
        var scene = AgentScene(now: now, alpha: alpha, edge: edge, radius: radius, still: still, beat: beat)
        guard cursor, let glide = presence.glide else { return scene }

        let target = glide.at(now)
        if let previous = spot, !still {
            let raw = CGVector(dx: (target.x - previous.x) / dt, dy: (target.y - previous.y) / dt)
            let blend = min(1, dt * 18)
            velocity = CGVector(dx: velocity.dx + (raw.dx - velocity.dx) * blend,
                                dy: velocity.dy + (raw.dy - velocity.dy) * blend)
        } else {
            velocity = .zero
            label = CGPoint(x: target.x + 18, y: target.y + 25)
        }
        spot = target

        if still {
            lean = 0
            leanSpeed = 0
            squash = presence.pressed ? 0.88 : 1
            squashSpeed = 0
            trail.removeAll()
            label = CGPoint(x: target.x + 18, y: target.y + 25)
        } else {
            let wantLean = max(-1, min(1, velocity.dx / 1900)) * 0.32
            leanSpeed += ((wantLean - lean) * 300 - leanSpeed * 15) * dt
            lean += leanSpeed * dt
            let wantSquash = presence.pressed ? 0.86 : 1
            squashSpeed += ((wantSquash - squash) * 480 - squashSpeed * 20) * dt
            squash += squashSpeed * dt
            let anchor = CGPoint(x: target.x + 18, y: target.y + 25)
            labelSpeed.dx += ((anchor.x - label.x) * 170 - labelSpeed.dx * 21) * dt
            labelSpeed.dy += ((anchor.y - label.y) * 170 - labelSpeed.dy * 21) * dt
            label.x += labelSpeed.dx * dt
            label.y += labelSpeed.dy * dt
            trail.append((target, now))
            trail.removeAll { now - $0.1 > 0.16 }
        }

        let speed = hypot(velocity.dx, velocity.dy)
        let typing = now - presence.keyTime < 0.5
        var wordAlpha = 0.0
        if presence.word != nil {
            let age = now - presence.wordTime
            wordAlpha = typing ? 1 : min(1, age / 0.12) * max(0, min(1, (2.4 - age) / 0.3))
        }
        scene.cursor = AgentScene.Pose(
            tip: target,
            lean: lean,
            stretch: still ? 0 : min(speed / 2600, 0.28),
            heading: atan2(velocity.dy, velocity.dx),
            squash: squash,
            pressed: presence.pressed,
            idle: presence.pressed ? 0 : max(0, now - glide.finish),
            trail: trail.map { ($0.0, now - $0.1) },
            taps: presence.taps.map { ($0.at, now - $0.time) }.filter { $0.1 < 0.7 },
            word: presence.word,
            wordAlpha: wordAlpha * alpha,
            typing: typing,
            label: label
        )
        return scene
    }
}

struct AgentScene {
    struct Pose {
        var tip: CGPoint
        var lean: Double
        var stretch: Double
        var heading: Double
        var squash: Double
        var pressed: Bool
        var idle: Double
        var trail: [(CGPoint, Double)]
        var taps: [(CGPoint, Double)]
        var word: String?
        var wordAlpha: Double
        var typing: Bool
        var label: CGPoint
    }

    static let blue = Color(red: 0x6B / 255, green: 0x97 / 255, blue: 1)
    static let deep = Color(red: 0x3E / 255, green: 0x6F / 255, blue: 0xF5 / 255)
    static let violet = Color(red: 0.66, green: 0.54, blue: 1)
    static let cyan = Color(red: 0.40, green: 0.82, blue: 1)

    static let arrow: Path = {
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 6.7, y: 22), CGPoint(x: 10, y: 12.7), CGPoint(x: 20, y: 10.8)]
        let radii: [CGFloat] = [1.6, 2.8, 1.4, 2.8]
        var path = Path()
        let first = corners[0], lastCorner = corners[corners.count - 1]
        path.move(to: CGPoint(x: (first.x + lastCorner.x) / 2, y: (first.y + lastCorner.y) / 2))
        for index in corners.indices {
            path.addArc(tangent1End: corners[index], tangent2End: corners[(index + 1) % corners.count], radius: radii[index])
        }
        path.closeSubpath()
        return path
    }()

    var now: TimeInterval
    var alpha: Double
    var edge: AgentEdge
    var radius: CGFloat
    var still: Bool
    var beat: Double
    var cursor: Pose?

    func draw(in context: inout GraphicsContext, size: CGSize) {
        guard alpha > 0.001 else { return }
        switch edge {
        case .aura: aura(&context, size)
        case .comet: comet(&context, size)
        case .frame: frame(&context, size)
        case .off: break
        }
        if let cursor { pointer(cursor, &context, size) }
    }

    private func wave(_ period: Double) -> Double {
        still ? 0.5 : 0.5 + 0.5 * sin(now * 2 * .pi / period)
    }

    private func aura(_ context: inout GraphicsContext, _ size: CGSize) {
        let shape = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: radius, style: .continuous)
        let strength = alpha * (0.40 + 0.18 * wave(3.4) + 0.35 * beat)
        let shading = GraphicsContext.Shading.conicGradient(
            Gradient(colors: [Self.blue, Self.violet, Self.cyan, Self.blue, Self.violet, Self.blue]),
            center: CGPoint(x: size.width / 2, y: size.height / 2),
            angle: .radians(still ? 0 : now * 0.42))
        context.drawLayer { layer in
            layer.opacity = strength
            layer.addFilter(.blur(radius: 20))
            layer.stroke(shape, with: shading, lineWidth: 30)
        }
        context.drawLayer { layer in
            layer.opacity = strength * 0.85
            layer.addFilter(.blur(radius: 3))
            layer.stroke(shape, with: shading, lineWidth: 4)
        }
    }

    private func comet(_ context: inout GraphicsContext, _ size: CGSize) {
        let inset = max(radius - 1.25, 0)
        let ring = Path(roundedRect: CGRect(origin: .zero, size: size).insetBy(dx: 1.25, dy: 1.25),
                        cornerRadius: inset, style: .continuous)
        context.stroke(ring, with: .color(Self.blue.opacity(0.14 * alpha)), lineWidth: 1)
        let head = still ? 0.1 : (now / 4.6).truncatingRemainder(dividingBy: 1)
        let length = 0.14 + 0.08 * beat
        for (offset, weight) in [(0.0, 1.0), (0.5, 0.55)] {
            let lead = head + offset
            let slices = 16
            for index in 0..<slices {
                let from = lead - length * Double(index + 1) / Double(slices)
                let to = lead - length * Double(index) / Double(slices)
                let fade = pow(1 - Double(index) / Double(slices), 1.8)
                context.stroke(Self.segment(ring, from, to),
                               with: .color(Self.blue.opacity(fade * weight * alpha)),
                               style: StrokeStyle(lineWidth: 2.5, lineCap: .butt))
            }
            context.drawLayer { layer in
                layer.opacity = weight * alpha * (0.85 + 0.15 * beat)
                layer.addFilter(.blur(radius: 9))
                layer.stroke(Self.segment(ring, lead - length * 0.45, lead),
                             with: .color(Self.cyan), style: StrokeStyle(lineWidth: 10, lineCap: .round))
            }
            context.fill(Path(ellipseIn: CGRect(origin: Self.spot(on: ring, at: lead), size: .zero).insetBy(dx: -2, dy: -2)),
                         with: .color(Color.white.opacity(weight * alpha * 0.9)))
        }
    }

    private func frame(_ context: inout GraphicsContext, _ size: CGSize) {
        let breathe = wave(2.6)
        let inset = 10 + 3 * breathe - 5 * beat
        let arm = 18 + 7 * breathe
        let bend: CGFloat = 7
        let w = size.width, h = size.height
        var brackets = Path()
        let corners: [(CGPoint, CGFloat, CGFloat)] = [
            (CGPoint(x: inset, y: inset), 1, 1),
            (CGPoint(x: w - inset, y: inset), -1, 1),
            (CGPoint(x: inset, y: h - inset), 1, -1),
            (CGPoint(x: w - inset, y: h - inset), -1, -1),
        ]
        for (corner, sx, sy) in corners {
            brackets.move(to: CGPoint(x: corner.x, y: corner.y + sy * arm))
            brackets.addLine(to: CGPoint(x: corner.x, y: corner.y + sy * bend))
            brackets.addQuadCurve(to: CGPoint(x: corner.x + sx * bend, y: corner.y), control: corner)
            brackets.addLine(to: CGPoint(x: corner.x + sx * arm, y: corner.y))
        }
        let edge = Path(roundedRect: CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5),
                        cornerRadius: max(radius - 0.5, 0), style: .continuous)
        context.stroke(edge, with: .color(Self.blue.opacity(alpha * (0.10 + 0.08 * breathe))), lineWidth: 1)
        context.drawLayer { layer in
            layer.opacity = alpha * (0.45 + 0.4 * beat)
            layer.addFilter(.blur(radius: 6))
            layer.stroke(brackets, with: .color(Self.cyan), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
        }
        context.stroke(brackets, with: .color(Self.blue.opacity(alpha * (0.62 + 0.28 * breathe))),
                       style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
    }

    private func pointer(_ pose: Pose, _ context: inout GraphicsContext, _ size: CGSize) {
        var ink = context
        ink.opacity = alpha

        if pose.trail.count > 2 {
            for index in 1..<pose.trail.count {
                let f = 1 - pose.trail[index].1 / 0.16
                guard f > 0 else { continue }
                var line = Path()
                line.move(to: pose.trail[index - 1].0)
                line.addLine(to: pose.trail[index].0)
                ink.stroke(line, with: .color(Self.blue.opacity(0.26 * f)),
                           style: StrokeStyle(lineWidth: 1 + 5 * f, lineCap: .round))
            }
        }

        for (spot, age) in pose.taps {
            let p = min(age / 0.6, 1)
            let grow = 1 - pow(1 - p, 3)
            let r = 5 + 24 * grow
            let ring = Path(ellipseIn: CGRect(x: spot.x - r, y: spot.y - r, width: r * 2, height: r * 2))
            ink.stroke(ring, with: .color(Self.blue.opacity((1 - p) * 0.65)), lineWidth: 1.6)
            let core = r * 0.55
            ink.fill(Path(ellipseIn: CGRect(x: spot.x - core, y: spot.y - core, width: core * 2, height: core * 2)),
                     with: .color(Self.blue.opacity((1 - p) * 0.16)))
        }

        if pose.pressed {
            let r: CGFloat = 11
            ink.fill(Path(ellipseIn: CGRect(x: pose.tip.x - r, y: pose.tip.y - r, width: r * 2, height: r * 2)),
                     with: .color(Self.blue.opacity(0.18)))
        } else if pose.idle > 0.9 {
            let settle = min((pose.idle - 0.9) / 0.5, 1)
            let r = 12 + 3 * wave(2.2)
            ink.stroke(Path(ellipseIn: CGRect(x: pose.tip.x - r, y: pose.tip.y - r, width: r * 2, height: r * 2)),
                       with: .color(Self.blue.opacity(0.16 * settle * (0.5 + 0.5 * wave(2.2)))), lineWidth: 1.2)
        }

        var hand = ink
        hand.translateBy(x: pose.tip.x, y: pose.tip.y)
        hand.rotate(by: .radians(pose.lean))
        if pose.stretch > 0.001 {
            hand.rotate(by: .radians(pose.heading - pose.lean))
            hand.scaleBy(x: 1 + pose.stretch, y: 1 - pose.stretch * 0.45)
            hand.rotate(by: .radians(pose.lean - pose.heading))
        }
        hand.scaleBy(x: pose.squash, y: pose.squash)
        hand.drawLayer { layer in
            layer.addFilter(.shadow(color: .black.opacity(0.30), radius: 3.5, x: 0, y: 1.5))
            layer.fill(Self.arrow, with: .linearGradient(Gradient(colors: [Self.blue, Self.deep]),
                                                         startPoint: .zero, endPoint: CGPoint(x: 12, y: 18)))
        }
        hand.stroke(Self.arrow, with: .color(.white), style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))

        guard let word = pose.word, pose.wordAlpha > 0.01 else { return }
        var tag = context
        tag.opacity = pose.wordAlpha * pose.wordAlpha
        let text = tag.resolve(Text(word).font(.system(size: 11, weight: .semibold)).foregroundColor(.white))
        let measured = text.measure(in: CGSize(width: 240, height: 40))
        let dots: CGFloat = pose.typing ? 16 : 0
        let pill = CGSize(width: measured.width + 16 + dots, height: measured.height + 8)
        let origin = CGPoint(x: min(max(pose.label.x, 4), size.width - pill.width - 4),
                             y: min(max(pose.label.y, 4), size.height - pill.height - 4))
        let settle = 0.86 + 0.14 * pose.wordAlpha
        tag.translateBy(x: origin.x, y: origin.y - 4 * (1 - pose.wordAlpha))
        tag.scaleBy(x: settle, y: settle)
        tag.translateBy(x: -origin.x, y: -origin.y)
        let body = Path(roundedRect: CGRect(origin: origin, size: pill), cornerRadius: pill.height / 2, style: .continuous)
        tag.drawLayer { layer in
            layer.addFilter(.shadow(color: .black.opacity(0.22), radius: 4, x: 0, y: 1.5))
            layer.fill(body, with: .linearGradient(Gradient(colors: [Self.blue, Self.deep]),
                                                   startPoint: origin, endPoint: CGPoint(x: origin.x, y: origin.y + pill.height)))
        }
        tag.draw(text, at: CGPoint(x: origin.x + 8, y: origin.y + pill.height / 2), anchor: .leading)
        guard pose.typing else { return }
        for index in 0..<3 {
            let phase = still ? 1 : 0.35 + 0.65 * (0.5 + 0.5 * sin(now * 9 - Double(index) * 0.9))
            let x = origin.x + 8 + measured.width + 4 + CGFloat(index) * 4.5
            let dot = CGRect(x: x, y: origin.y + pill.height / 2 - 1.5, width: 3, height: 3)
            tag.fill(Path(ellipseIn: dot), with: .color(.white.opacity(phase)))
        }
    }

    private static func segment(_ path: Path, _ from: Double, _ to: Double) -> Path {
        let a = from - floor(from), span = min(max(to - from, 0), 1)
        let b = a + span
        if b <= 1 { return path.trimmedPath(from: a, to: b) }
        var joined = path.trimmedPath(from: a, to: 1)
        joined.addPath(path.trimmedPath(from: 0, to: b - 1))
        return joined
    }

    private static func spot(on path: Path, at fraction: Double) -> CGPoint {
        let f = fraction - floor(fraction)
        return path.trimmedPath(from: f, to: min(f + 0.0005, 1)).currentPoint
            ?? path.trimmedPath(from: max(f - 0.0005, 0), to: f).currentPoint
            ?? .zero
    }
}

struct AgentVeilPreview: View {
    @StateObject private var presence = AgentPresence()
    @State private var size = CGSize(width: 480, height: 170)

    var body: some View {
        ZStack(alignment: .topLeading) {
            sketch
            AgentVeil(presence: presence, radius: 10)
        }
        .frame(height: 170)
        .background(Palette.ground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { size = proxy.size }
                .onChange(of: proxy.size) { _, new in size = new }
        })
        .task { await rehearse() }
        .onDisappear { presence.sleep() }
    }

    private var sketch: some View {
        VStack(alignment: .leading, spacing: 10) {
            RoundedRectangle(cornerRadius: 4).fill(Palette.hairline).frame(width: 140, height: 12)
            RoundedRectangle(cornerRadius: 3).fill(Palette.hairline.opacity(0.7)).frame(height: 8)
            RoundedRectangle(cornerRadius: 3).fill(Palette.hairline.opacity(0.7)).frame(width: 220, height: 8)
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.hairline, lineWidth: 1).frame(width: 170, height: 26)
                RoundedRectangle(cornerRadius: 6).fill(Palette.hairline).frame(width: 64, height: 26)
            }
            .padding(.top, 6)
        }
        .padding(22)
    }

    private func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: size.width * x, y: size.height * y)
    }

    private func pause(_ seconds: Double) async -> Bool {
        try? await Task.sleep(for: .seconds(seconds))
        return !Task.isCancelled
    }

    private func rehearse() async {
        presence.wake()
        while !Task.isCancelled {
            presence.wake()
            let field = presence.move(to: CGPoint(x: 64, y: 99), word: "Click")
            guard await pause(field) else { return }
            presence.tap()
            guard await pause(0.5) else { return }
            for _ in 0..<9 {
                presence.key()
                guard await pause(0.09) else { return }
            }
            guard await pause(0.6) else { return }
            let button = presence.move(to: CGPoint(x: 234, y: 99), word: "Click")
            guard await pause(button) else { return }
            presence.tap()
            guard await pause(1.1) else { return }
            let grip = presence.move(to: at(0.72, 0.3), word: "Drag")
            guard await pause(grip) else { return }
            presence.hold(true)
            presence.trace([at(0.78, 0.45), at(0.86, 0.62)], over: 0.5)
            guard await pause(0.55) else { return }
            presence.hold(false)
            guard await pause(0.9) else { return }
            _ = presence.move(to: at(0.36, 0.2), word: "Hover")
            guard await pause(2.4) else { return }
        }
    }
}
