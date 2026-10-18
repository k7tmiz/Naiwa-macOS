import AppKit
import Darwin

/// 单实例锁：第二个实例通过分布式通知让已有奶蛙回到右下角。
enum InstanceLock {
    private static var heldDescriptor: Int32 = -1

    static func acquire() -> Bool {
        let folder = Settings.folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent(".lock").path
        let fd = open(path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return true }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            heldDescriptor = fd
            return true
        }
        close(fd)
        return false
    }
}

extension Notification.Name {
    static let naiwaWake = Notification.Name("com.naiwa.mac.wake")
    static let naiwaQuit = Notification.Name("com.naiwa.mac.quit")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let assetsFolder: URL?
    private var controller: PetController?
    private var statusItem: NSStatusItem?
    private var pendingStatusWork: DispatchWorkItem?
    private var statusMenuObserver: MenuStateObserver?
    private var activityToken: NSObjectProtocol?
    private var observers: [NSObjectProtocol] = []

    init(assetsFolder: URL?) {
        self.assetsFolder = assetsFolder
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        activityToken = ProcessInfo.processInfo.beginActivity(options: [.userInitiated],
                                                              reason: "奶蛙桌宠运行中")
        guard let folder = assetsFolder else {
            reportFailure(NaiwaError.assets("找不到 素材.nwp。请把 奶蛙桌宠.app、素材.nwp 和 原版笑声.wav 放在同一个文件夹。"))
            return
        }
        do {
            let assets = try Assets(folder: folder)
            let controller = PetController(assets: assets, settings: Settings.load(), testing: false)
            self.controller = controller
            if let eye = Optional(assets.eye(0)) {
                NSApp.applicationIconImage = Icon.image(from: eye, size: 256)
            }
            controller.show()
            setupStatusItem(controller: controller)
            observers.append(DistributedNotificationCenter.default().addObserver(forName: .naiwaWake, object: nil, queue: .main) { [weak self] _ in
                self?.controller?.returnHome()
            })
            observers.append(DistributedNotificationCenter.default().addObserver(forName: .naiwaQuit, object: nil, queue: .main) { _ in
                NSApp.terminate(nil)
            })
            observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                self?.controller?.displayChanged()
            })
        } catch {
            reportFailure(error)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.shutdown()
        if let activityToken {
            ProcessInfo.processInfo.endActivity(activityToken)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// 对已运行的 App 再次执行 open 时（LaunchServices 复用实例），同样回右下角。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller?.returnHome()
        return true
    }

    private func reportFailure(_ error: Error) {
        let folder = Settings.folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp) \(error)\n"
        if let handle = try? FileHandle(forWritingTo: folder.appendingPathComponent("error.log")) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: folder.appendingPathComponent("error.log"), atomically: true, encoding: .utf8)
        }
        let alert = NSAlert()
        alert.messageText = "奶蛙桌宠"
        alert.informativeText = "奶蛙暂时没能启动。请将程序、素材.nwp 和原版笑声.wav 放在同一个文件夹。\n\n\(error.localizedDescription)"
        alert.alertStyle = .informational
        alert.runModal()
        NSApp.terminate(nil)
    }

    // MARK: - 菜单栏图标

    private func setupStatusItem(controller: PetController) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            if let image = Icon.statusBarImage(from: controller.assets.eye(0), height: 18) {
                button.image = image
            } else {
                button.title = "蛙"
            }
            button.toolTip = "奶蛙 · 戳肚子 / 双击笑 / 拖动"
            button.target = self
            button.action = #selector(statusButtonClicked(_:))
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }
        statusItem = item
    }

    @objc private func statusButtonClicked(_ sender: Any?) {
        guard let controller else { return }
        let event = NSApp.currentEvent
        let isRight = event?.type == .rightMouseDown || (event?.modifierFlags.contains(.control) ?? false)
        if isRight {
            pendingStatusWork?.cancel()
            pendingStatusWork = nil
            showStatusMenu(controller: controller)
            return
        }
        if (event?.clickCount ?? 1) >= 2 {
            pendingStatusWork?.cancel()
            pendingStatusWork = nil
            controller.returnHome()
            return
        }
        // 单击：等待双击间隔后弹出菜单；期间若发生第二次点击则视为双击回到右下角。
        let work = DispatchWorkItem { [weak self] in
            self?.pendingStatusWork = nil
            guard let controller = self?.controller else { return }
            self?.showStatusMenu(controller: controller)
        }
        pendingStatusWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + min(NSEvent.doubleClickInterval, 0.4), execute: work)
    }

    private func showStatusMenu(controller: PetController) {
        guard let item = statusItem else { return }
        let observer = MenuStateObserver()
        observer.onWillOpen = { [weak controller] in controller?.menuWillOpen() }
        observer.onDidClose = { [weak self, weak controller] in
            controller?.menuDidClose()
            self?.statusItem?.menu = nil
            self?.statusMenuObserver = nil
        }
        statusMenuObserver = observer
        let menu = controller.buildMenu(delegate: observer)
        item.menu = menu
        item.button?.performClick(nil)
    }
}
