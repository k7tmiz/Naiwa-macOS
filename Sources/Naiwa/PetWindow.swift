import AppKit
import AVFoundation
import QuartzCore

/// 奶蛙窗口：无边框、不抢焦点、不进入 Dock 与窗口循环。
final class PetWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 事件转发视图：把鼠标事件交给 PetController 处理。
final class PetView: NSView {
    weak var controller: PetController?

    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override func mouseDown(with event: NSEvent) { controller?.leftMouseDown(event) }
    override func mouseDragged(with event: NSEvent) { controller?.leftMouseDragged(event) }
    override func mouseUp(with event: NSEvent) { controller?.leftMouseUp(event) }
    override func rightMouseDown(with event: NSEvent) { controller?.rightMouseDown(event) }
}

/// 菜单开合状态观察（用于抑制悬停 / 全屏检测）。
final class MenuStateObserver: NSObject, NSMenuDelegate {
    var onWillOpen: (() -> Void)?
    var onDidClose: (() -> Void)?

    func menuWillOpen(_ menu: NSMenu) { onWillOpen?() }
    func menuDidClose(_ menu: NSMenu) { onDidClose?() }
}

/// 核心控制器：PetWindow（C#）的行为移植。
final class PetController: NSObject {
    let assets: Assets
    let settings: Settings
    let settingsFolder: URL
    let testing: Bool

    let motion = Motion()
    let gesture = Gesture()

    private(set) var window: PetWindow!
    private let view = PetView()
    private let menuObserver = MenuStateObserver()

    private var sound: AVAudioPlayer?
    private var soundPreviewStop: DispatchWorkItem?
    private var tickTimer: Timer?
    private var globalMonitor: Any?
    private var localMonitor: Any?

    private var dragWindow = NSPoint.zero
    private var lastDragPointer = CGPoint.zero
    private let fullscreenGate = FullscreenGate()
    private var nextFullscreenCheck = 0.0
    private var lastVisual = ""
    private var canvas: Canvas?
    private var lastCursorOver = false

    private(set) var hiddenForFullscreen = false
    private(set) var menuOpen = false
    private(set) var ready = false
    private var shuttingDown = false
    private let baseTime = CACurrentMediaTime()

    // 鼠标位置缓存：由全局/本地鼠标事件更新，避免每帧向窗口服务器查询（单次约 0.4ms）。
    private var lastMouseLocation = CGPoint.zero
    private var hoverOver = false
    private var nextMouseSync = 0.0
    private var primaryScreenHeight: CGFloat = 0

    var now: Double { CACurrentMediaTime() - baseTime }
    var scalePercent: Int { settings.scale }
    var soundEnabled: Bool { settings.sound }

    private var backingScale: CGFloat {
        window?.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    init(assets: Assets, settings: Settings, testing: Bool, settingsFolder: URL? = nil) {
        self.assets = assets
        self.settings = settings
        self.testing = testing
        self.settingsFolder = settingsFolder ?? Settings.folder
        super.init()

        let size = sizeFor(settings.scale)
        window = PetWindow(contentRect: CGRect(origin: .zero, size: size),
                           styleMask: .borderless, backing: .buffered, defer: false)
        window.title = "NaiwaDesktop.macOS.v1"
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = settings.onTop ? .floating : .normal
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.animationBehavior = .none

        view.frame = CGRect(origin: .zero, size: size)
        view.controller = self
        view.wantsLayer = true
        if let layer = view.layer {
            layer.contentsScale = backingScale
            // 关闭隐式动画，避免 contents 切换时出现淡入淡出造成拖影。
            layer.actions = ["contents": NSNull(), "bounds": NSNull(),
                             "position": NSNull(), "contentsScale": NSNull()]
            layer.contentsGravity = .resize
        }
        window.contentView = view

        menuObserver.onWillOpen = { [weak self] in self?.menuOpen = true }
        menuObserver.onDidClose = { [weak self] in self?.menuOpen = false }

        if let audioURL = assets.audioURL {
            sound = try? AVAudioPlayer(contentsOf: audioURL)
            sound?.prepareToPlay()
        }

        if settings.position {
            window.setFrameOrigin(NSPoint(x: settings.x, y: settings.y))
        } else {
            home()
        }
        keepVisible()

        lastMouseLocation = NSEvent.mouseLocation
        primaryScreenHeight = Fullscreen.primaryScreenHeight()
        setupMouseMonitors()
        renderNow(force: true)
    }

    deinit {
        shutdown()
    }

    // MARK: - 生命周期

    func show() {
        window.orderFrontRegardless()
        ready = true
        renderNow(force: true)
        if !testing {
            checkFullscreen(immediate: true)
            startTimer()
        }
    }

    func shutdown() {
        guard !shuttingDown else { return }
        shuttingDown = true
        save()
        tickTimer?.invalidate()
        tickTimer = nil
        soundPreviewStop?.cancel()
        soundPreviewStop = nil
        sound?.stop()
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    private func startTimer() {
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    // MARK: - 帧循环

    func tick() {
        guard ready, !shuttingDown else { return }
        let t = now
        if t >= nextMouseSync {
            // 兜底同步：极端情况下（全局事件被系统拦截）仍能拿到真实鼠标位置。
            nextMouseSync = t + 1.0
            lastMouseLocation = NSEvent.mouseLocation
        }
        if t >= nextFullscreenCheck {
            nextFullscreenCheck = t + 0.12
            checkFullscreen(immediate: false)
        }
        updateMouseReception()
        if hiddenForFullscreen { return }
        let over = !menuOpen && hoverOver
        let wasPlaying = motion.playing
        motion.update(now: t, over: over, duration: assets.duration, blinkDuration: assets.blinkDuration)
        if wasPlaying && !motion.playing { sound?.stop() }
        renderNow(force: false)
    }

    func renderNow(force: Bool) {
        guard window != nil, !shuttingDown, !hiddenForFullscreen else { return }
        var key = motion.resting ? "R"
            : motion.playing ? "L\(Int(motion.elapsed * assets.fps))"
            : motion.blinking ? "B\(motion.look > 0.5 ? 1 : 0)/\(Int((motion.clock - motion.blinkStart) * assets.blinkFps))"
            : "E\(Int((motion.look * Double(assets.eyeCount - 1)).rounded(.toNearestOrEven)))"
        if motion.poking || motion.moving || motion.waking {
            key += "/M\(Int(motion.clock * 60))"
        }
        let scale = backingScale
        key += "/\(settings.scale)/\(Int(scale * 100))"
        if !force && key == lastVisual { return }
        guard let rendered = Renderer.render(assets: assets, motion: motion,
                                             scale: settings.scale, backingScale: scale) else { return }
        canvas = rendered
        view.layer?.contentsScale = scale
        view.layer?.contents = rendered.cgImage
        lastVisual = key
    }

    // MARK: - 命中测试 / 鼠标穿透

    /// screenPoint 为全局屏幕坐标；alpha 阈值 24 与 Windows 版一致。
    func hitTest(point: CGPoint) -> Bool {
        let frame = window.frame
        guard frame.contains(point), let canvas else { return false }
        let local = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY) // y 向上
        let yDown = frame.height - local.y
        return canvas.alpha(at: CGPoint(x: local.x, y: yDown)) > 24
    }

    func updateMouseReception() {
        guard !shuttingDown else { return }
        guard !hiddenForFullscreen, window.isVisible else {
            setIgnoringMouseEvents(true)
            hoverOver = false
            if lastCursorOver {
                lastCursorOver = false
                NSCursor.arrow.set()
            }
            return
        }
        if gesture.pressed || motion.holding {
            setIgnoringMouseEvents(false)
            return
        }
        // 复用本帧的命中结果，避免重复采样。
        let over = hitTest(point: lastMouseLocation)
        hoverOver = over
        setIgnoringMouseEvents(!over)
        if over != lastCursorOver {
            lastCursorOver = over
            if over { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
    }

    private func setIgnoringMouseEvents(_ ignoring: Bool) {
        if window.ignoresMouseEvents != ignoring {
            window.ignoresMouseEvents = ignoring
        }
    }

    /// 由鼠标事件更新缓存位置（CG 全局坐标 → AppKit 左下原点坐标），并即时刷新点击穿透状态。
    private func mouseEventObserved(_ event: NSEvent) {
        if let cg = event.cgEvent {
            lastMouseLocation = CGPoint(x: cg.location.x,
                                        y: primaryScreenHeight - cg.location.y)
        } else {
            lastMouseLocation = NSEvent.mouseLocation
        }
        updateMouseReception()
    }

    private func setupMouseMonitors() {
        let mask: NSEvent.EventTypeMask = [
            .mouseMoved,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .leftMouseUp, .rightMouseUp, .otherMouseUp,
        ]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.mouseEventObserved(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.mouseEventObserved(event)
            return event
        }
    }

    // MARK: - 鼠标事件

    private func globalPoint(_ event: NSEvent) -> CGPoint {
        let local = event.locationInWindow
        return CGPoint(x: window.frame.minX + local.x, y: window.frame.minY + local.y)
    }

    func leftMouseDown(_ event: NSEvent) {
        let p = globalPoint(event)
        gesture.down(p)
        lastDragPointer = p
        dragWindow = window.frame.origin
        window.ignoresMouseEvents = false
    }

    func leftMouseDragged(_ event: NSEvent) {
        guard gesture.pressed else { return }
        let p = globalPoint(event)
        gesture.move(p)
        if gesture.dragged {
            if !motion.holding {
                motion.beginDrag(now)
                sound?.stop()
            }
            motion.drag(now: now, dx: p.x - lastDragPointer.x)
            lastDragPointer = p
            window.setFrameOrigin(NSPoint(x: dragWindow.x + (p.x - gesture.origin.x),
                                          y: dragWindow.y + (p.y - gesture.origin.y)))
            renderNow(force: true)
        }
    }

    func leftMouseUp(_ event: NSEvent) {
        guard gesture.pressed else { return }
        let p = globalPoint(event)
        let moved = gesture.dragged
        let twice = gesture.up(p, now: now)
        if moved {
            motion.endDrag(now)
            keepVisible()
            renderNow(force: true)
            save()
        } else if twice {
            laugh()
        } else if motion.resting {
            motion.stand(now)
            renderNow(force: true)
        } else {
            let local = event.locationInWindow
            let yDown = window.frame.height - local.y
            if motion.poke(now: now,
                           x: local.x * 100.0 / Double(settings.scale),
                           y: yDown * 100.0 / Double(settings.scale)) {
                renderNow(force: true)
            }
        }
    }

    func rightMouseDown(_ event: NSEvent) {
        motion.endDrag(now)
        gesture.cancel()
        presentMenu(with: event)
    }

    func presentMenu(with event: NSEvent) {
        let menu = buildMenu()
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    // MARK: - 动作

    @discardableResult
    func laugh() -> Bool {
        if hiddenForFullscreen { return false }
        if !motion.laugh(now) { return false }
        soundPreviewStop?.cancel()
        soundPreviewStop = nil
        if let sound, settings.sound, !testing {
            sound.currentTime = 0
            sound.play()
        }
        renderNow(force: true)
        return true
    }

    func stopLaugh() {
        soundPreviewStop?.cancel()
        soundPreviewStop = nil
        motion.stop()
        sound?.stop()
        renderNow(force: true)
    }

    func setSound(_ enabled: Bool) {
        settings.sound = enabled && sound != nil
        soundPreviewStop?.cancel()
        soundPreviewStop = nil
        if !settings.sound {
            sound?.stop()
        } else if let sound, !testing, !motion.playing {
            // 开启时试听一小段，明确反馈“声音已就绪”；下一次大笑会完整播放原声。
            sound.currentTime = 0
            sound.play()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                if !self.motion.playing {
                    self.sound?.stop()
                }
                self.soundPreviewStop = nil
            }
            soundPreviewStop = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
        }
        save()
    }

    // MARK: - 尺寸 / 位置

    func sizeFor(_ scale: Int) -> CGSize {
        CGSize(width: assets.width * scale / 100, height: assets.height * scale / 100)
    }

    func setSize(_ scale: Int) {
        let center = window.frame.midX
        let bottom = window.frame.minY
        settings.scale = max(50, min(150, scale))
        let size = sizeFor(settings.scale)
        window.setFrame(CGRect(x: center - size.width / 2, y: bottom,
                               width: size.width, height: size.height), display: true)
        keepVisible()
        renderNow(force: true)
        save()
    }

    func home() {
        let screen = PetController.screen(containing: NSEvent.mouseLocation)
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let area = screen?.visibleFrame else { return }
        let size = window.frame.size
        let allowance = CGFloat(12 * settings.scale / 100)
        window.setFrameOrigin(NSPoint(x: area.maxX - size.width - 24,
                                      y: area.minY - allowance))
        keepVisible()
    }

    func returnHome() {
        home()
        if !testing { checkFullscreen(immediate: true) }
        if !hiddenForFullscreen {
            window.orderFrontRegardless()
            renderNow(force: true)
        }
        save()
    }

    func keepVisible() {
        let frame = window.frame
        guard let screen = PetController.screen(forRect: frame) ?? NSScreen.main else { return }
        let allowance = CGFloat(12 * settings.scale / 100)
        window.setFrameOrigin(PetController.clamp(origin: frame.origin, size: frame.size,
                                                  area: screen.visibleFrame, allowance: allowance))
    }

    /// 纯几何限制（对应 C# PetWindow.Clamp，注意 y 轴向上：
    /// 允许窗口底边越过屏幕底边最多 allowance，用于让脚部轻微悬出）。
    static func clamp(origin: CGPoint, size: CGSize, area: CGRect, allowance: CGFloat) -> CGPoint {
        let x = max(area.minX, min(origin.x, area.maxX - size.width))
        let y = max(area.minY - allowance, min(origin.y, area.maxY - size.height))
        return CGPoint(x: x, y: y)
    }

    func save() {
        guard !testing else { return }
        settings.x = Int(window.frame.origin.x.rounded())
        settings.y = Int(window.frame.origin.y.rounded())
        settings.save(to: settingsFolder)
    }

    func displayChanged() {
        primaryScreenHeight = Fullscreen.primaryScreenHeight()
        lastMouseLocation = NSEvent.mouseLocation
        keepVisible()
        renderNow(force: true)
        save()
    }

    static func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
    }

    static func screen(forRect rect: CGRect) -> NSScreen? {
        var best: NSScreen?
        var bestArea: CGFloat = 0
        for screen in NSScreen.screens {
            let intersection = screen.frame.intersection(rect)
            let area = intersection.isNull ? 0 : intersection.width * intersection.height
            if area > bestArea {
                bestArea = area
                best = screen
            }
        }
        return best ?? screen(containing: CGPoint(x: rect.midX, y: rect.midY)) ?? NSScreen.main
    }

    // MARK: - 全屏自动隐藏

    func checkFullscreen(immediate: Bool) {
        guard ready, !menuOpen, !gesture.pressed else { return }
        var detected = false
        if settings.autoHide {
            let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
            if frontPID > 0 && frontPID != getpid() {
                let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first
                if let screen {
                    let space = Fullscreen.screenSpace(for: screen,
                                                       petWindowNumber: window.windowNumber,
                                                       petFrame: window.frame,
                                                       primaryHeight: primaryScreenHeight)
                    detected = Fullscreen.covers(screenFrameCG: space.rect,
                                                 appPID: frontPID,
                                                 excluding: [window.windowNumber],
                                                 tolerance: space.tolerance)
                }
            }
        }
        if immediate {
            fullscreenGate.set(detected, now)
            applyFullscreen(fullscreenGate.hidden)
        } else if fullscreenGate.update(detected, now) {
            applyFullscreen(fullscreenGate.hidden)
        }
    }

    func applyFullscreen(_ hidden: Bool) {
        if hidden == hiddenForFullscreen { return }
        hiddenForFullscreen = hidden
        if hidden {
            gesture.cancel()
            motion.suspend(now)
            sound?.stop()
            window.orderOut(nil)
            window.ignoresMouseEvents = true
            if lastCursorOver {
                lastCursorOver = false
                NSCursor.arrow.set()
            }
        } else {
            motion.suspend(now)
            window.orderFrontRegardless()
            renderNow(force: true)
        }
        updateMouseReception()
    }

    func setAutoHide(_ value: Bool) {
        settings.autoHide = value
        fullscreenGate.reset()
        if !value {
            applyFullscreen(false)
        } else if !testing {
            checkFullscreen(immediate: true)
        }
        save()
    }

    // MARK: - 菜单

    func menuWillOpen() { menuOpen = true }
    func menuDidClose() { menuOpen = false }

    func buildMenu(delegate: NSMenuDelegate? = nil) -> NSMenu {
        let menu = NSMenu()
        let header = NSMenuItem(title: "奶蛙 · 原版陪伴", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        menu.addItem(item("捧腹大笑（双击）", #selector(menuLaugh)))
        let stopItem = item("停止大笑 / 站起来", #selector(menuStopOrStand))
        stopItem.isEnabled = motion.playing || motion.resting
        menu.addItem(stopItem)

        let soundItem = item("原版笑声", #selector(menuToggleSound))
        soundItem.state = settings.sound ? .on : .off
        soundItem.isEnabled = sound != nil
        menu.addItem(soundItem)

        menu.addItem(.separator())

        let sizes = NSMenuItem(title: "大小", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu()
        for (value, label) in [(65, "小号"), (85, "标准"), (110, "大号")] {
            let entry = NSMenuItem(title: label, action: #selector(menuSetSize(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = value
            entry.state = settings.scale == value ? .on : .off
            sizeMenu.addItem(entry)
        }
        sizes.submenu = sizeMenu
        menu.addItem(sizes)

        let topItem = item("总在最上面", #selector(menuToggleTop))
        topItem.state = settings.onTop ? .on : .off
        menu.addItem(topItem)

        let fullscreenItem = item("全屏时自动隐藏", #selector(menuToggleAutoHide))
        fullscreenItem.state = settings.autoHide ? .on : .off
        menu.addItem(fullscreenItem)

        menu.addItem(item("回到屏幕右下角", #selector(menuReturnHome)))
        menu.addItem(item("打开使用说明", #selector(menuOpenManual)))
        menu.addItem(.separator())
        menu.addItem(item("退出奶蛙", #selector(menuQuit)))

        menu.delegate = delegate ?? menuObserver
        return menu
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        return entry
    }

    @objc private func menuLaugh() { laugh() }

    @objc private func menuStopOrStand() {
        if motion.resting {
            motion.stand(now)
            renderNow(force: true)
        } else {
            stopLaugh()
        }
    }

    @objc private func menuToggleSound() { setSound(!settings.sound) }

    @objc private func menuSetSize(_ sender: NSMenuItem) { setSize(sender.tag) }

    @objc private func menuToggleTop() {
        settings.onTop.toggle()
        window.level = settings.onTop ? .floating : .normal
        save()
    }

    @objc private func menuToggleAutoHide() { setAutoHide(!settings.autoHide) }

    @objc private func menuReturnHome() { returnHome() }

    @objc private func menuOpenManual() { openManual() }

    @objc private func menuQuit() { NSApp.terminate(nil) }

    func openManual() {
        var candidates: [URL] = []
        if let resource = Bundle.main.resourceURL {
            candidates.append(resource.appendingPathComponent("使用说明-macOS.txt"))
            candidates.append(resource.appendingPathComponent("使用说明.txt"))
        }
        let bundleURL = Bundle.main.bundleURL
        let folder = bundleURL.pathExtension == "app" ? bundleURL.deletingLastPathComponent() : bundleURL
        candidates.append(folder.appendingPathComponent("使用说明-macOS.txt"))
        candidates.append(folder.appendingPathComponent("使用说明.txt"))
        candidates.append(assets.folder.appendingPathComponent("使用说明-macOS.txt"))
        candidates.append(assets.folder.appendingPathComponent("使用说明.txt"))
        if let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            NSWorkspace.shared.open(found)
        } else {
            NSSound.beep()
        }
    }
}
