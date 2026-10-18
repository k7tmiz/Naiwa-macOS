import AppKit
import CoreGraphics

/// 全屏检测：macOS 上通过 CGWindowList 查询“前台应用是否有覆盖奶蛙所在屏幕的窗口”。
/// 与 Windows 版语义一致：只有铺满整块屏幕（含菜单栏区域）的窗口才视为全屏；
/// 普通“最大化”（菜单栏仍可见）不触发隐藏。
///
/// 注意：Mission Control 等系统状态下，窗口服务器会把所有应用窗口整体缩放，
/// CGWindowList 返回的窗口坐标与 NSScreen 坐标不再 1:1。这里用奶蛙自身窗口的
/// NS 尺寸与 CG 尺寸做一次自校准，把屏幕矩形换算到同一坐标空间。
enum Fullscreen {
    static let tolerance: CGFloat = 2

    struct ScreenSpace {
        let rect: CGRect
        let tolerance: CGFloat
    }

    /// 纯几何判定：window 是否完全覆盖 screen（对应 C# Fullscreen.Covers）。
    static func covers(_ window: CGRect, _ screen: CGRect, tolerance: CGFloat = Fullscreen.tolerance) -> Bool {
        window.minX <= screen.minX + tolerance
            && window.minY <= screen.minY + tolerance
            && window.maxX >= screen.maxX - tolerance
            && window.maxY >= screen.maxY - tolerance
    }

    /// 前台应用 appPID 是否拥有覆盖 screenFrameCG 的窗口。CG 窗口坐标（左上原点）。
    static func covers(screenFrameCG: CGRect, appPID: pid_t, excluding windowNumbers: Set<Int>,
                       tolerance: CGFloat = Fullscreen.tolerance) -> Bool {
        guard appPID > 0 else { return false }
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        for info in list {
            guard let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid == appPID else { continue }
            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            guard layer == 0 else { continue }
            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            guard alpha > 0.001 else { continue }
            if let number = (info[kCGWindowNumber as String] as? NSNumber)?.intValue, windowNumbers.contains(number) {
                continue
            }
            guard let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { continue }
            if covers(bounds, screenFrameCG, tolerance: tolerance) { return true }
        }
        return false
    }

    /// 把 NSScreen 坐标（左下原点）转成 CGWindowList 坐标（主屏左上原点）。
    static func cgFrame(of screen: NSScreen) -> CGRect {
        let primaryHeight = primaryScreenHeight()
        let frame = screen.frame
        return CGRect(x: frame.minX,
                      y: primaryHeight - frame.maxY,
                      width: frame.width,
                      height: frame.height)
    }

    static func primaryScreenHeight() -> CGFloat {
        // 主屏（带菜单栏）在 NSScreen.screens 中排第一，其 frame 原点为 (0,0)。
        let screens = NSScreen.screens
        let primary = screens.first { $0.frame.origin == .zero } ?? screens.first
        return primary?.frame.height ?? 0
    }

    /// 计算“屏幕在窗口服务器坐标空间中的矩形”，用奶蛙窗口做缩放/位移校准。
    /// 若无法校准（窗口不在列表、缩放异常），退回 1:1 坐标。
    static func screenSpace(for screen: NSScreen,
                            petWindowNumber: Int,
                            petFrame: NSRect,
                            primaryHeight: CGFloat) -> ScreenSpace {
        let plain = cgFrame(of: screen)
        let fallback = ScreenSpace(rect: plain, tolerance: tolerance)
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return fallback
        }
        var petRect: CGRect?
        for info in list {
            guard (info[kCGWindowNumber as String] as? NSNumber)?.intValue == petWindowNumber,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: boundsDict) else { continue }
            petRect = rect
            break
        }
        guard let petRect, petFrame.width > 1, petFrame.height > 1 else { return fallback }
        let sx = petRect.width / petFrame.width
        let sy = petRect.height / petFrame.height
        // 只接受等比例缩放（窗口服务器做的是整体仿射变换）；误差明显时放弃校准。
        guard sx > 0.2, sx < 5, sy > 0.2, sy < 5, abs(sx - sy) < 0.03 else { return fallback }
        let scale = (sx + sy) / 2
        let tx = petRect.minX - petFrame.minX * scale
        let ty = petRect.minY - (primaryHeight - petFrame.maxY) * scale
        let rect = CGRect(x: plain.minX * scale + tx,
                          y: plain.minY * scale + ty,
                          width: plain.width * scale,
                          height: plain.height * scale)
        // 缩放状态下窗口坐标存在 ±几像素的取整误差；按比例放宽容差。
        let adjustedTolerance: CGFloat = abs(scale - 1) < 0.01
            ? tolerance
            : max(4, plain.width * 0.01)
        return ScreenSpace(rect: rect, tolerance: adjustedTolerance)
    }
}

/// 全屏状态防抖门限（对应 C# 的 FullscreenGate）。
final class FullscreenGate {
    private(set) var hidden = false
    private var candidate = false
    private var since = 0.0

    /// 返回 true 表示状态发生变化（需要隐藏/显示奶蛙）。
    func update(_ detected: Bool, _ now: Double) -> Bool {
        if candidate != detected {
            candidate = detected
            since = now
        }
        if candidate != hidden && now - since >= (candidate ? 0.15 : 0.25) {
            hidden = candidate
            return true
        }
        return false
    }

    func reset() {
        hidden = false
        candidate = false
        since = 0
    }

    func set(_ value: Bool, _ now: Double) {
        hidden = value
        candidate = value
        since = now
    }
}
