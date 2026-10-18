import AppKit

// 奶蛙桌宠 · macOS 移植版入口。
// 用法：
//   Naiwa                 正常启动桌宠（也可直接双击 Naiwa.app）
//   Naiwa --self-test DIR 运行自检并输出报告与渲染样张到 DIR
//   Naiwa --demo DIR      渲染交互演示序列（720 帧 PNG）到 DIR
//   Naiwa --make-icon FILE 由素材生成 .icns 图标
//   Naiwa --probe FILE    查询正在运行的奶蛙窗口状态并写入 FILE
//   Naiwa --quit          让正在运行的奶蛙退出
//   Naiwa --assets DIR    指定素材目录（含 素材.nwp 与 原版笑声.wav）

let arguments = CommandLine.arguments

func argumentValue(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func resolveAssetsFolder(override: URL?) -> URL? {
    var candidates: [URL] = []
    if let override { candidates.append(override) }
    if let resource = Bundle.main.resourceURL { candidates.append(resource) }
    let bundleURL = Bundle.main.bundleURL
    if bundleURL.pathExtension == "app" {
        candidates.append(bundleURL.deletingLastPathComponent())
    } else {
        candidates.append(bundleURL)
    }
    candidates.append(Settings.folder)
    candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
    let manager = FileManager.default
    for candidate in candidates {
        if manager.fileExists(atPath: candidate.appendingPathComponent("素材.nwp").path) {
            return candidate
        }
    }
    return nil
}

let assetsOverride = argumentValue("--assets").map { URL(fileURLWithPath: $0, isDirectory: true) }

// --self-test：完整自检（素材校验、动作逻辑、渲染样张、窗口交互）。
if let folder = argumentValue("--self-test") {
    let assetsFolder = resolveAssetsFolder(override: assetsOverride)
    Tests.runSelfTest(outputFolder: URL(fileURLWithPath: folder, isDirectory: true), assetsFolder: assetsFolder)
}

// --demo：按脚本渲染 720 帧演示序列。
if let folder = argumentValue("--demo") {
    let assetsFolder = resolveAssetsFolder(override: assetsOverride)
    Tests.runDemo(outputFolder: URL(fileURLWithPath: folder, isDirectory: true), assetsFolder: assetsFolder)
}

// --make-icon：由素材生成 .icns。
if let output = argumentValue("--make-icon") {
    do {
        guard let folder = resolveAssetsFolder(override: assetsOverride) else {
            throw NaiwaError.assets("找不到 素材.nwp")
        }
        let assets = try Assets(folder: folder)
        let url = URL(fileURLWithPath: output)
        if Icon.writeICNS(from: assets.eye(0), to: url) {
            print("图标已写入 \(url.path)")
            exit(0)
        }
        throw NaiwaError.assets("图标生成失败")
    } catch {
        FileHandle.standardError.write(Data("错误：\(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

// --probe：查询正在运行的奶蛙窗口。
if let output = argumentValue("--probe") {
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: "local.naiwa.desktoppet")
    let targetPIDs = Set(running.map { $0.processIdentifier })
    let list = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
    var found = false
    var onscreen = false
    var bounds = CGRect.zero
    var bestArea: CGFloat = 0
    for info in list {
        let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? -1
        let owner = info[kCGWindowOwnerName as String] as? String ?? ""
        let isNaiwa = targetPIDs.contains(pid) || owner == "Naiwa" || owner == "奶蛙桌宠"
        guard isNaiwa else { continue }
        guard let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: boundsDict) else { continue }
        // 跳过菜单栏图标等小窗口，取奶蛙本体（面积最大）
        let area = rect.width * rect.height
        guard rect.width >= 50, rect.height >= 50, area >= bestArea else { continue }
        bestArea = area
        found = true
        bounds = rect
        onscreen = (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
    }
    let text = "Found=\(found)\r\nVisible=\(onscreen)\r\nBounds=\(Int(bounds.minX)),\(Int(bounds.minY)),\(Int(bounds.maxX)),\(Int(bounds.maxY))\r\nState=unknown"
    try? text.write(toFile: output, atomically: true, encoding: .utf8)
    exit(0)
}

// --quit：通知正在运行的奶蛙退出。
if arguments.contains("--quit") {
    DistributedNotificationCenter.default().post(name: .naiwaQuit, object: nil)
    exit(0)
}

// 正常启动：单实例 + 桌宠。
if !InstanceLock.acquire() {
    DistributedNotificationCenter.default().post(name: .naiwaWake, object: nil)
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate(assetsFolder: resolveAssetsFolder(override: assetsOverride))
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
