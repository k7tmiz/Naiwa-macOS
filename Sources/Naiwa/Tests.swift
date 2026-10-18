import AppKit
import CoreGraphics
import Darwin
import Foundation
import QuartzCore

/// 自检与演示：对应 C# 版 Tests 类（--self-test / --demo）。
final class CheckLog {
    var lines: [String] = []
    var failed = false

    func check(_ value: Bool, _ name: String) {
        if value {
            lines.append("PASS: \(name)")
        } else {
            failed = true
            lines.append("FAIL: \(name)")
        }
    }

    func note(_ text: String) {
        lines.append(text)
    }

    /// 允许像函数一样调用：check(value, name)。
    func callAsFunction(_ value: Bool, _ name: String) {
        check(value, name)
    }

    func finish(to folder: URL) -> Never {
        lines.append(failed ? "RESULT: FAIL" : "RESULT: PASS")
        try? (lines.joined(separator: "\n") + "\n").write(to: folder.appendingPathComponent("self-test.txt"),
                                                         atomically: true, encoding: .utf8)
        exit(failed ? 1 : 0)
    }
}

enum Tests {
    // MARK: - 自检

    static func runSelfTest(outputFolder: URL, assetsFolder: URL?) {
        try? FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        let log = CheckLog()

        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)

        guard let assetsFolder else {
            log.check(false, "找不到 素材.nwp（可用 --assets 指定素材目录）")
            log.finish(to: outputFolder)
        }

        do {
            let assets = try Assets(folder: assetsFolder)
            runAssetChecks(assets, log)
            runMotionChecks(assets, log)
            runGestureChecks(log)
            runSettingsChecks(outputFolder, log)
            runClampAndFullscreenChecks(log)
            runWindowChecks(assets, outputFolder, log, log.note)
            runRenderSamples(assets, outputFolder, log)
            runIconCheck(assets, outputFolder, log)
        } catch {
            log.lines.append("FAIL: 素材加载 — \(error.localizedDescription)")
        }
        log.finish(to: outputFolder)
    }

    // MARK: - 素材校验

    private static func runAssetChecks(_ assets: Assets, _ check: CheckLog) {
        check(assets.count == 422 && abs(assets.fps - 30) < 0.01, "original 422-frame clip at 30 fps")
        check(assets.eye(0).alpha(x: 0, y: 0) == 0 && assets.eye(1).alpha(x: 0, y: 0) == 0,
              "transparent idle and hover backgrounds")

        var differences = 0
        var outsideEyes = 0
        for y in 0 ..< assets.height {
            for x in 0 ..< assets.width where !pixelEqual(assets.eye(0), assets.eye(1), x, y) {
                differences += 1
                if y > 92 { outsideEyes += 1 }
            }
        }
        check(differences > 10 && outsideEyes == 0, "hover changes only eye area, body is identical")

        if let audioURL = assets.audioURL, let wav = try? Data(contentsOf: audioURL), wav.count > 1000 {
            check(String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF", "original soundtrack decodes as WAV")
        } else {
            check(false, "original soundtrack decodes as WAV")
        }

        check(assets.blinkCount == 7 && abs(assets.blinkFps - 30) < 0.01, "blink uses seven original video frames")
        for bank in 0 ..< 2 {
            for frame in 0 ..< assets.blinkCount {
                check(equal(assets.eye(Double(bank)), assets.blink(Double(bank), frame: frame), fromY: 92),
                      "blink body preserved, bank \(bank) frame \(frame)")
            }
        }
        check(!equal(assets.eye(0), assets.blink(0, frame: 3), fromY: 0, toY: 92),
              "closed eye differs from open eye")
        check.note("METRIC: assets \(assets.width)x\(assets.height), \(assets.count) frames, \(assets.eyeCount) look frames")
    }

    // MARK: - 动作逻辑校验

    private static func runMotionChecks(_ assets: Assets, _ check: CheckLog) {
        let duration = assets.duration
        let blinkDuration = assets.blinkDuration

        func advance(_ m: Motion, _ begin: Double, _ end: Double, _ over: Bool) {
            var t = begin
            while t <= end + 0.00001 {
                m.update(now: t, over: over, duration: duration, blinkDuration: blinkDuration)
                t += 1.0 / 60
            }
        }

        let look = Motion()
        advance(look, 0, 0.3, true)
        check(look.look > 0.999, "hover turns eyes toward pointer")
        advance(look, 0.32, 0.62, false)
        check(look.look < 0.001, "mouse leave restores original eyes")

        let laugh = Motion()
        check(laugh.laugh(1) && !laugh.laugh(1.01) && laugh.playCount == 1,
              "double-click playback does not overlap or restart")
        laugh.update(now: 1 + duration - 0.05, over: false, duration: duration, blinkDuration: blinkDuration)
        check(laugh.playing, "complete source clip plays through ending")
        laugh.update(now: 1 + duration + 0.01, over: false, duration: duration, blinkDuration: blinkDuration)
        check(!laugh.playing && laugh.resting, "laugh ends in resting pose")
        laugh.update(now: 100, over: true, duration: duration, blinkDuration: blinkDuration)
        check(laugh.resting && !laugh.blinking, "resting pose stays until clicked")
        laugh.stand(100)
        check(!laugh.resting && laugh.waking, "single click starts standing up")
        advance(laugh, 100, 100.3, false)
        check(!laugh.waking && !laugh.playing, "standing settles to original idle")
        _ = laugh.laugh(101)
        laugh.update(now: 101 + duration + 0.001, over: false, duration: duration, blinkDuration: blinkDuration)
        check(laugh.laugh(120) && !laugh.resting, "can laugh again from resting pose")
        laugh.stop()
        check(!laugh.playing && !laugh.resting, "stop action cancels playback")

        let blink = Motion()
        blink.update(now: 4, over: false, duration: duration, blinkDuration: blinkDuration)
        check(blink.blinking, "idle schedules a blink")
        blink.update(now: 4 + blinkDuration + 0.01, over: false, duration: duration, blinkDuration: blinkDuration)
        check(!blink.blinking && blink.nextBlink >= blink.clock + 4 && blink.nextBlink <= blink.clock + 8,
              "blink ends and schedules random 4-8 second interval")

        blink.poke(now: 5, x: 143, y: 211)
        check(blink.poking && !blink.blinking, "poke interrupts blink")
        blink.update(now: 5.1, over: false, duration: duration, blinkDuration: blinkDuration)
        let warped = Renderer.warpBelly(assets.eye(0), cx: blink.pokeX, cy: blink.pokeY, amount: blink.pokeAmount)
        check(equal(warped, assets.eye(0), fromY: 0, toY: 105), "belly feedback preserves face")
        check(!equal(warped, assets.eye(0), fromY: 160, toY: 260),
              "belly feedback visibly deforms source pixels")
        advance(blink, 5.11, 6, false)
        check(!blink.poking && abs(blink.pokeAmount) < 0.0001, "belly rebound settles")
        check(!blink.poke(now: 6, x: 125, y: 67), "clicking face does not poke belly")
        blink.poke(now: 6, x: 144, y: 210)
        blink.laugh(6.1)
        check(!blink.poking && blink.playing, "double click cancels poke before original laugh")

        let drag = Motion()
        drag.beginDrag(7)
        check(drag.holding && !drag.playing, "drag interrupts playback")
        for i in 1 ... 30 {
            let t = 7 + Double(i) / 60
            drag.drag(now: t, dx: 12)
            drag.update(now: t, over: true, duration: duration, blinkDuration: blinkDuration)
        }
        check(drag.dragAngle > 2 && drag.dragAngle <= 7, "drag tilts toward movement and stays bounded")
        drag.endDrag(7.5)
        drag.update(now: 7.57, over: true, duration: duration, blinkDuration: blinkDuration)
        check(!drag.holding && drag.landing && drag.squash > 0.01, "release starts landing bounce")
        advance(drag, 7.58, 9, false)
        check(!drag.landing && abs(drag.dragAngle) < 0.05, "drag and landing settle cleanly")
    }

    private static func runGestureChecks(_ check: CheckLog) {
        let gesture = Gesture(doubleClickTime: 0.5)
        let p = CGPoint(x: 100, y: 100)
        gesture.down(p)
        check(!gesture.up(p, now: 1), "single click does not laugh")
        gesture.down(p)
        check(gesture.up(p, now: 1.12), "double click triggers laugh")
        gesture.down(p)
        gesture.move(CGPoint(x: 140, y: 160))
        check(!gesture.up(CGPoint(x: 140, y: 160), now: 2), "drag does not trigger laugh")
        gesture.down(p)
        check(!gesture.up(p, now: 2.1), "drag resets double-click sequence")
        gesture.cancel()
        check(!gesture.pressed, "cancelled pointer capture releases drag")
    }

    private static func runSettingsChecks(_ folder: URL, _ check: CheckLog) {
        let temp = folder.appendingPathComponent("settings-test", isDirectory: true)
        let settings = Settings()
        settings.scale = 110
        settings.x = 123
        settings.y = -45
        settings.position = true
        settings.sound = true
        settings.onTop = false
        settings.autoHide = false
        settings.save(to: temp)
        let loaded = Settings.load(from: temp)
        check(loaded.scale == 110 && loaded.x == 123 && loaded.y == -45 && loaded.position
              && loaded.sound && !loaded.onTop && !loaded.autoHide, "settings round-trip")
    }

    private static func runClampAndFullscreenChecks(_ check: CheckLog) {
        let clamped = PetController.clamp(origin: CGPoint(x: -3000, y: -50),
                                          size: CGSize(width: 245, height: 312),
                                          area: CGRect(x: -1920, y: 0, width: 1920, height: 1040),
                                          allowance: 10)
        check(clamped.x == -1920 && clamped.y == -10, "negative-coordinate monitor bounds")

        let monitor = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        check(Fullscreen.covers(monitor, monitor), "borderless fullscreen is detected")
        check(!Fullscreen.covers(CGRect(x: 0, y: 25, width: 1920, height: 1055), monitor),
              "window that leaves menu bar visible is not fullscreen")
        check(!Fullscreen.covers(CGRect(x: -1920, y: 0, width: 1920, height: 1080), monitor),
              "fullscreen on another monitor is ignored")
        check(Fullscreen.covers(CGRect(x: -1920, y: 0, width: 1920, height: 1080),
                                CGRect(x: -1920, y: 0, width: 1920, height: 1080)),
              "fullscreen works on negative-coordinate monitor")

        let gate = FullscreenGate()
        check(!gate.update(true, 0) && !gate.update(false, 0.08) && !gate.hidden,
              "brief fullscreen switch does not flash pet")
        _ = gate.update(true, 1)
        check(gate.update(true, 1.2) && gate.hidden, "stable fullscreen hides pet")
        _ = gate.update(false, 2)
        check(gate.update(false, 2.3) && !gate.hidden, "leaving fullscreen restores pet")
    }

    // MARK: - 窗口检查

    private static func runWindowChecks(_ assets: Assets, _ outputFolder: URL,
                                        _ check: CheckLog, _ note: (String) -> Void) {
        guard NSScreen.main != nil else {
            check(false, "native pet window is visible（无可用显示器）")
            return
        }
        let settingsFolder = outputFolder.appendingPathComponent("settings-app", isDirectory: true)
        let controller = PetController(assets: assets, settings: Settings(), testing: true,
                                       settingsFolder: settingsFolder)
        controller.show()

        check(controller.window.isVisible, "native pet window is visible")
        check(controller.window.level == .floating, "pet window floats above normal windows")
        check(!controller.window.canBecomeKey && !controller.window.isOpaque,
              "transparent window does not steal focus")
        check(controller.window.collectionBehavior.contains(.canJoinAllSpaces),
              "pet window joins all spaces")
        check(controller.scalePercent == 85, "default scale is 85 percent")

        controller.setSize(65)
        check(controller.window.frame.width == CGFloat(assets.width * 65 / 100), "small size renders")
        controller.setSize(110)
        check(controller.window.frame.width == CGFloat(assets.width * 110 / 100), "large size renders")
        controller.setSize(85)

        controller.window.setFrameOrigin(NSPoint(x: -50000, y: -50000))
        controller.keepVisible()
        check(NSScreen.screens.contains { $0.visibleFrame.intersects(controller.window.frame) },
              "lost window position recovers")

        controller.setSound(true)
        check(controller.soundEnabled, "original audio switch can be enabled")
        controller.setSound(false)
        check(!controller.soundEnabled, "sound switch can be muted")

        // 逐像素命中测试
        let frame = controller.window.frame
        let corner = CGPoint(x: frame.minX + 2, y: frame.maxY - 2)
        let belly = CGPoint(x: frame.minX + frame.width * 0.5, y: frame.minY + frame.height * 0.42)
        check(!controller.hitTest(point: corner), "transparent corner is click-through")
        check(controller.hitTest(point: belly), "belly is clickable")

        // 原生鼠标交互（合成事件）
        let windowNumber = controller.window.windowNumber
        let h = controller.window.frame.height
        if let downBelly = mouseEvent(windowNumber, .leftMouseDown, NSPoint(x: 120, y: h - 160)),
           let upBelly = mouseEvent(windowNumber, .leftMouseUp, NSPoint(x: 120, y: h - 160)),
           let dragTo = mouseEvent(windowNumber, .leftMouseDragged, NSPoint(x: 140, y: h - 180)),
           let downFoot = mouseEvent(windowNumber, .leftMouseDown, NSPoint(x: 170, y: h - 240)),
           let upFoot = mouseEvent(windowNumber, .leftMouseUp, NSPoint(x: 170, y: h - 240)) {
            controller.leftMouseDown(downBelly)
            controller.leftMouseUp(upBelly)
            check(!controller.motion.playing && controller.motion.poking,
                  "native single belly click triggers poke")

            controller.leftMouseDown(downBelly)
            controller.leftMouseUp(upBelly)
            check(controller.motion.playing && !controller.motion.poking,
                  "native double-click events replace poke with playback")
            controller.stopLaugh()

            _ = controller.motion.laugh(0)
            controller.motion.update(now: assets.duration, over: false,
                                     duration: assets.duration, blinkDuration: assets.blinkDuration)
            check(controller.motion.resting, "native window reaches resting state")

            controller.leftMouseDown(downFoot)
            controller.leftMouseUp(upFoot)
            check(!controller.motion.resting && controller.motion.waking,
                  "native click wakes resting pet")
            controller.stopLaugh()

            controller.leftMouseDown(downBelly)
            controller.leftMouseDragged(dragTo)
            check(controller.motion.holding, "native drag starts feedback")
            controller.leftMouseUp(upBelly)
            check(!controller.motion.holding && controller.motion.landing && !controller.motion.playing,
                  "native drag release bounces without laughing")
            controller.stopLaugh()
        } else {
            check(false, "synthetic mouse events available")
        }

        // 全屏检测与自动隐藏（真实窗口）
        if let petScreen = controller.window.screen ?? NSScreen.main {
            let testWindow = NSWindow(contentRect: petScreen.frame, styleMask: .borderless,
                                      backing: .buffered, defer: false)
            testWindow.isOpaque = false
            testWindow.alphaValue = 0.01
            testWindow.level = .normal
            testWindow.ignoresMouseEvents = true
            testWindow.orderFrontRegardless()
            // 让窗口服务器完成登记（对应 C# 自检里的 Application.DoEvents）。
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
            let space2 = Fullscreen.screenSpace(for: petScreen,
                                                petWindowNumber: controller.window.windowNumber,
                                                petFrame: controller.window.frame,
                                                primaryHeight: Fullscreen.primaryScreenHeight())
            check(Fullscreen.covers(screenFrameCG: space2.rect, appPID: getpid(),
                                    excluding: [controller.window.windowNumber],
                                    tolerance: space2.tolerance),
                  "native borderless fullscreen detection")
            check(!Fullscreen.covers(screenFrameCG: space2.rect, appPID: getpid(),
                                     excluding: [controller.window.windowNumber, testWindow.windowNumber],
                                     tolerance: space2.tolerance),
                  "pet window is excluded from fullscreen detection")

            let savedLocation = controller.window.frame.origin
            controller.laugh()
            controller.applyFullscreen(true)
            check(controller.hiddenForFullscreen && !controller.window.isVisible && !controller.motion.playing,
                  "fullscreen hides native pet and interrupts playback")
            check(!controller.laugh(), "hidden pet cannot play audio or laugh")
            controller.applyFullscreen(false)
            check(!controller.hiddenForFullscreen && controller.window.isVisible
                  && controller.window.frame.origin == savedLocation,
                  "fullscreen exit restores same position")

            _ = controller.motion.laugh(0)
            controller.motion.update(now: assets.duration, over: false,
                                     duration: assets.duration, blinkDuration: assets.blinkDuration)
            controller.applyFullscreen(true)
            controller.applyFullscreen(false)
            check(controller.motion.resting, "resting pose survives fullscreen hide and restore")

            controller.applyFullscreen(true)
            controller.setAutoHide(false)
            check(controller.window.isVisible && !controller.hiddenForFullscreen,
                  "disabling automatic hide reveals pet")
            controller.setAutoHide(true)
            controller.stopLaugh()
            testWindow.orderOut(nil)
            testWindow.close()
        } else {
            check(false, "pet screen available")
        }

        // 渲染性能与缓存
        for i in 0 ..< 12 { _ = assets.frame(i) }
        let before = footprintBytes()
        let start = CACurrentMediaTime()
        _ = controller.motion.laugh(0)
        for i in 0 ..< assets.count {
            controller.motion.elapsed = Double(i) / assets.fps
            controller.renderNow(force: true)
        }
        let average = (CACurrentMediaTime() - start) / Double(assets.count) * 1000
        let after = footprintBytes()
        note("METRIC: all-frame decode/render average \(String(format: "%.2f", average)) ms; footprint delta \(after > before ? after - before : 0) bytes")
        for i in 0 ..< assets.count {
            controller.motion.elapsed = Double(i) / assets.fps
            controller.renderNow(force: true)
        }
        let stable = footprintBytes()
        note("METRIC: repeat-playback footprint delta \(stable > after ? stable - after : 0) bytes")
        check(assets.cacheCount <= 12, "decoded frame cache stays bounded")
        controller.motion.stop()
        controller.renderNow(force: true)
        controller.window.orderOut(nil)
        controller.shutdown()
        check(!controller.window.isVisible, "window closes cleanly")
    }

    // MARK: - 渲染样张

    private static func runRenderSamples(_ assets: Assets, _ outputFolder: URL, _ check: CheckLog) {
        let blinkDuration = assets.blinkDuration
        func save(_ name: String) {
            guard let canvas = Renderer.lastCanvas, let image = canvas.cgImage,
                  let png = Icon.pngData(image) else {
                check(false, "render sample \(name)")
                return
            }
            try? png.write(to: outputFolder.appendingPathComponent(name))
        }
        func render(_ motion: Motion) {
            _ = Renderer.render(assets: assets, motion: motion, scale: 100, backingScale: 1)
        }

        let idle = Motion()
        render(idle)
        save("native-idle.png")

        let hover = Motion()
        hover.look = 1
        render(hover)
        save("native-hover.png")

        let laugh = Motion()
        _ = laugh.laugh(0)
        laugh.elapsed = 1
        render(laugh)
        save("native-laugh.png")

        let poke = Motion()
        poke.poke(now: 0, x: 144, y: 211)
        poke.update(now: 0.10, over: false, duration: assets.duration, blinkDuration: blinkDuration)
        render(poke)
        save("native-poke.png")

        let drag = Motion()
        drag.beginDrag(1)
        drag.dragAngle = 6
        render(drag)
        save("native-drag.png")

        let blink = Motion()
        blink.blinkStart = 0
        blink.clock = 0.1
        render(blink)
        save("native-blink.png")

        let rest = Motion()
        rest.resting = true
        render(rest)
        save("native-rest.png")

        check(FileManager.default.fileExists(atPath: outputFolder.appendingPathComponent("native-idle.png").path),
              "render samples written")
    }

    private static func runIconCheck(_ assets: Assets, _ outputFolder: URL, _ check: CheckLog) {
        let icns = outputFolder.appendingPathComponent("naiwa.icns")
        check(Icon.writeICNS(from: assets.eye(0), to: icns), "icon icns generated")
        if let image = Icon.renderIcon(from: assets.eye(0), size: 64), let png = Icon.pngData(image) {
            try? png.write(to: outputFolder.appendingPathComponent("naiwa-icon64.png"))
        }
        if let image = Icon.statusBarImage(from: assets.eye(0), height: 36), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil), let png = Icon.pngData(cg) {
            try? png.write(to: outputFolder.appendingPathComponent("naiwa-status.png"))
        }
    }

    // MARK: - 演示序列

    static func runDemo(outputFolder: URL, assetsFolder: URL?) {
        try? FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        guard let assetsFolder else {
            FileHandle.standardError.write(Data("错误：找不到 素材.nwp（可用 --assets 指定素材目录）\n".utf8))
            exit(1)
        }
        do {
            let assets = try Assets(folder: assetsFolder)
            let motion = Motion()
            motion.nextBlink = 0.6
            for i in 0 ..< 720 {
                let t = Double(i) / 30.0
                if i == 60 { motion.poke(now: t, x: 143, y: 205) }
                if i == 90 { motion.beginDrag(t) }
                if i >= 90 && i < 126 { motion.drag(now: t, dx: i < 108 ? 5 : -5) }
                if i == 126 { motion.endDrag(t) }
                if i == 174 { motion.laugh(t) }
                if i == 666 { motion.stand(t) }
                motion.update(now: t, over: t >= 1.1 && t < 5.8,
                              duration: assets.duration, blinkDuration: assets.blinkDuration)
                guard let canvas = Renderer.render(assets: assets, motion: motion, scale: 100, backingScale: 1),
                      let image = canvas.cgImage,
                      let png = Icon.pngData(image) else {
                    FileHandle.standardError.write(Data("错误：第 \(i) 帧渲染失败\n".utf8))
                    exit(1)
                }
                do {
                    try png.write(to: outputFolder.appendingPathComponent(String(format: "%04d.png", i)))
                } catch {
                    FileHandle.standardError.write(Data("错误：第 \(i) 帧写入失败 \(error)\n".utf8))
                    exit(1)
                }
            }
            print("演示序列已输出到 \(outputFolder.path)")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("错误：\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    // MARK: - 辅助

    private static func pixelEqual(_ a: RasterImage, _ b: RasterImage, _ x: Int, _ y: Int) -> Bool {
        let pa = a.pixel(x: x, y: y)
        let pb = b.pixel(x: x, y: y)
        return pa == pb
    }

    private static func equal(_ a: RasterImage, _ b: RasterImage, fromY: Int, toY: Int? = nil) -> Bool {
        let end = min(toY ?? a.height, min(a.height, b.height))
        guard a.width == b.width else { return false }
        for y in fromY ..< end {
            for x in 0 ..< a.width where !pixelEqual(a, b, x, y) {
                return false
            }
        }
        return true
    }

    private static func mouseEvent(_ windowNumber: Int, _ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: windowNumber, context: nil, eventNumber: 0,
                           clickCount: 1, pressure: 1)
    }

    private static func footprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
