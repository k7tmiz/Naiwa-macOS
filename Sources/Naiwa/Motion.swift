import Foundation

/// 全部动作/物理状态机：逐行对应 C# 版 Motion 类。
final class Motion {
    static let pokeDuration = 0.95

    var look = 0.0
    var start = -1.0
    var elapsed = 0.0
    var clock = 0.0
    var blinkStart = -1.0
    var nextBlink = 4.0
    var wakeStart = -1.0
    var pokeStart = -1.0
    var pokeX = 144.0
    var pokeY = 205.0
    var landingStart = -1.0
    var dragAngle = 0.0

    var resting = false
    var holding = false
    var playCount = 0

    private var previous = -1.0
    private var dragTarget = 0.0
    private var dragVelocity = 0.0
    private var lastDragTime = 0.0

    var playing: Bool { start >= 0 }
    var blinking: Bool { blinkStart >= 0 }
    var poking: Bool { pokeStart >= 0 }
    var landing: Bool { landingStart >= 0 }
    var waking: Bool { wakeStart >= 0 }
    var moving: Bool { holding || landing || abs(dragAngle) > 0.02 }

    var pokeAmount: Double {
        let t = clock - pokeStart
        if !poking || t < 0 || t >= Motion.pokeDuration { return 0 }
        if t < 0.12 { return 0.60 * sin(t / 0.12 * Double.pi / 2) }
        return 0.60 * exp(-4.8 * (t - 0.12)) * cos(18 * (t - 0.12))
    }

    var squash: Double {
        let t = clock - landingStart
        guard landing && t >= 0 else { return 0 }
        return 0.055 * exp(-6 * t) * sin(19 * t)
    }

    func update(now: Double, over: Bool, duration: Double, blinkDuration: Double) {
        clock = now
        let dt = previous < 0 ? 0 : min(0.05, max(0, now - previous))
        previous = now
        let goal = over ? 1.0 : 0.0
        let step = dt / 0.18
        look += max(-step, min(step, goal - look))

        if playing {
            elapsed = max(0, now - start)
            if elapsed >= duration {
                start = -1
                elapsed = duration
                resting = true
            }
        }
        if waking && now - wakeStart >= 0.24 { wakeStart = -1 }
        if poking && now - pokeStart >= Motion.pokeDuration { pokeStart = -1 }
        if landing && now - landingStart >= 0.9 { landingStart = -1 }
        if blinking && now - blinkStart >= blinkDuration {
            blinkStart = -1
            scheduleBlink(now)
        }
        if !playing && !resting && !holding && !landing && !poking && !waking && !blinking && now >= nextBlink {
            blinkStart = now
        }
        if !holding || now - lastDragTime > 0.10 { dragTarget = 0 }

        // 临界阻尼倾斜：限制单步时长，避免长时间未刷新时数值发散。
        let steps = max(1, Int(ceil(dt / 0.008)))
        let stepTime = dt / Double(steps)
        for _ in 0 ..< steps {
            dragVelocity += (160 * (dragTarget - dragAngle) - 25 * dragVelocity) * stepTime
            dragAngle += dragVelocity * stepTime
        }
        dragAngle = max(-7, min(7, dragAngle))
        if !holding && abs(dragAngle) < 0.02 && abs(dragVelocity) < 0.05 {
            dragAngle = 0
            dragVelocity = 0
        }
    }

    private func scheduleBlink(_ now: Double) {
        nextBlink = now + 4 + Double.random(in: 0 ..< 1) * 4
    }

    private func clearEffects(_ now: Double) {
        clock = now
        blinkStart = -1
        pokeStart = -1
        wakeStart = -1
        landingStart = -1
        holding = false
        dragAngle = 0
        dragTarget = 0
        dragVelocity = 0
        scheduleBlink(now)
    }

    @discardableResult
    func laugh(_ now: Double) -> Bool {
        if playing { return false }
        clearEffects(now)
        resting = false
        start = now
        elapsed = 0
        playCount += 1
        return true
    }

    func stop() {
        start = -1
        elapsed = 0
        resting = false
        clearEffects(clock)
    }

    func stand(_ now: Double) {
        guard resting else { return }
        resting = false
        clearEffects(now)
        wakeStart = now
    }

    static func inBelly(_ x: Double, _ y: Double) -> Bool {
        let dx = (x - 144) / 69
        let dy = (y - 211) / 68
        return dx * dx + dy * dy <= 1
    }

    @discardableResult
    func poke(now: Double, x: Double, y: Double) -> Bool {
        if playing || resting || holding || !Motion.inBelly(x, y) { return false }
        clearEffects(now)
        pokeStart = now
        pokeX = x
        pokeY = y
        return true
    }

    func beginDrag(_ now: Double) {
        start = -1
        elapsed = 0
        clearEffects(now)
        holding = true
        lastDragTime = now
    }

    func drag(now: Double, dx: Double) {
        if !holding { beginDrag(now) }
        let dt = max(1.0 / 120, now - lastDragTime)
        lastDragTime = now
        dragTarget = max(-7, min(7, dx / dt * 0.013))
        clock = now
    }

    func endDrag(_ now: Double) {
        guard holding else { return }
        holding = false
        dragTarget = 0
        clock = now
        landingStart = now
        scheduleBlink(now)
    }

    func suspend(_ now: Double) {
        start = -1
        elapsed = 0
        look = 0
        clearEffects(now)
    }
}
