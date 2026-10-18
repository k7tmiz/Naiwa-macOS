import AppKit
import Foundation

/// 单击 / 双击 / 拖动判定（对应 C# 的 Gesture 类）。
/// 双击间隔取系统设置（NSEvent.doubleClickInterval），位置容差与原点距离判定与 Windows 版一致。
final class Gesture {
    var pressed = false
    var dragged = false
    var origin = CGPoint.zero

    private var lastClickPoint = CGPoint.zero
    private var lastClick = -100.0

    private let fixedDoubleClickTime: Double?

    init(doubleClickTime: Double? = nil) {
        fixedDoubleClickTime = doubleClickTime
    }

    private var doubleClickTime: Double {
        if let fixedDoubleClickTime { return fixedDoubleClickTime }
        let t = NSEvent.doubleClickInterval
        return t > 0.05 ? t : 0.5
    }

    private let doubleClickSize: CGFloat = 8

    func down(_ p: CGPoint) {
        pressed = true
        dragged = false
        origin = p
    }

    func move(_ p: CGPoint) {
        if pressed && (abs(p.x - origin.x) > 5 || abs(p.y - origin.y) > 5) {
            dragged = true
        }
    }

    /// 返回 true 表示这是一次双击（对应 C# Gesture.Up）。
    func up(_ p: CGPoint, now: Double) -> Bool {
        if !pressed { return false }
        pressed = false
        if dragged {
            lastClick = -100
            return false
        }
        let twice = now - lastClick <= doubleClickTime
            && abs(p.x - lastClickPoint.x) <= doubleClickSize
            && abs(p.y - lastClickPoint.y) <= doubleClickSize
        lastClick = twice ? -100 : now
        lastClickPoint = p
        return twice
    }

    func cancel() {
        pressed = false
        dragged = false
        lastClick = -100
    }
}
