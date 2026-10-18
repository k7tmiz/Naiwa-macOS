import Foundation

/// 设置持久化：~/Library/Application Support/NaiwaDesktopPet/settings.ini
/// 键名与 Windows 版保持一致（scale / x / y / sound / top / fullscreen）。
final class Settings {
    var scale = 85
    var x = 0
    var y = 0
    var position = false
    // macOS 移植版默认开启原版笑声（Windows 原版默认关闭，可在右键菜单随时切换）。
    var sound = true
    var onTop = true
    var autoHide = true

    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("NaiwaDesktopPet", isDirectory: true)
    }

    static func load(from folder: URL = Settings.folder) -> Settings {
        let settings = Settings()
        let file = folder.appendingPathComponent("settings.ini")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return settings }
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            switch key {
            case "scale":
                if let n = Int(value) { settings.scale = max(50, min(150, n)) }
            case "x":
                if let n = Int(value) { settings.x = n; settings.position = true }
            case "y":
                if let n = Int(value) { settings.y = n }
            case "sound":
                settings.sound = (value == "True")
            case "top":
                settings.onTop = (value != "False")
            case "fullscreen":
                settings.autoHide = (value != "False")
            default:
                break
            }
        }
        return settings
    }

    func save(to folder: URL = Settings.folder) {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let lines = ["scale=\(scale)", "x=\(x)", "y=\(y)",
                         "sound=\(sound ? "True" : "False")",
                         "top=\(onTop ? "True" : "False")",
                         "fullscreen=\(autoHide ? "True" : "False")"]
            try (lines.joined(separator: "\n") + "\n").write(to: folder.appendingPathComponent("settings.ini"),
                                                            atomically: true, encoding: .utf8)
        } catch {
            // 与 Windows 版一致：保存失败不影响运行。
        }
    }
}
