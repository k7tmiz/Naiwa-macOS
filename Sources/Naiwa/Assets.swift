import Foundation

/// 打开 素材.nwp 并载入全部动作素材（对应 C# 的 Assets 类）。
final class Assets {
    let width: Int
    let height: Int
    let count: Int
    let eyeCount: Int
    let blinkCount: Int
    let fps: Double
    let duration: Double
    let blinkFps: Double
    var blinkDuration: Double { Double(blinkCount) / blinkFps }

    let folder: URL
    let audioURL: URL?

    private let eyes: [RasterImage]
    private let blinks: [[RasterImage]] // [2][blinkCount]
    private let encoded: [Data]
    private var cache: [Int: RasterImage] = [:]
    private var order: [Int] = []

    var cacheCount: Int { cache.count }

    init(folder: URL) throws {
        self.folder = folder
        let zipURL = folder.appendingPathComponent("素材.nwp")
        let audio = folder.appendingPathComponent("原版笑声.wav")
        audioURL = FileManager.default.fileExists(atPath: audio.path) ? audio : nil

        guard FileManager.default.fileExists(atPath: zipURL.path) else {
            throw NaiwaError.assets("找不到 素材.nwp")
        }
        let zip = try ZipArchive(url: zipURL)

        let metaData = try zip.data(for: "metadata.json")
        guard let meta = try JSONSerialization.jsonObject(with: metaData) as? [String: Any] else {
            throw NaiwaError.assets("素材信息无效")
        }
        func int(_ key: String) -> Int? { (meta[key] as? NSNumber)?.intValue }
        func double(_ key: String) -> Double? { (meta[key] as? NSNumber)?.doubleValue }

        guard let width = int("width"), let height = int("height"),
              let count = int("frames"), let fps = double("fps"),
              let eyeCount = int("eyeFrames"),
              let blinkCount = int("blinkFrames"), let blinkFps = double("blinkFps") else {
            throw NaiwaError.assets("素材信息无效")
        }
        guard width >= 1, height >= 1, width <= 1024, height <= 1024,
              count >= 1, count <= 2000, fps >= 1, fps <= 120,
              eyeCount >= 2, eyeCount <= 60,
              blinkCount >= 2, blinkCount <= 60, blinkFps >= 1, blinkFps <= 120 else {
            throw NaiwaError.assets("素材信息无效")
        }
        self.width = width
        self.height = height
        self.count = count
        self.fps = fps
        self.eyeCount = eyeCount
        self.blinkCount = blinkCount
        self.blinkFps = blinkFps
        duration = Double(count) / fps

        var lookFrames: [RasterImage] = []
        for i in 0 ..< eyeCount {
            lookFrames.append(try Assets.decode(zip.data(for: String(format: "look/%02d.png", i)), width: width, height: height))
        }
        eyes = lookFrames

        var blinkBanks: [[RasterImage]] = []
        for bank in 0 ..< 2 {
            var frames: [RasterImage] = []
            for i in 0 ..< blinkCount {
                frames.append(try Assets.decode(zip.data(for: String(format: "blink/%d/%02d.png", bank, i)), width: width, height: height))
            }
            blinkBanks.append(frames)
        }
        blinks = blinkBanks

        var encodedFrames: [Data] = []
        encodedFrames.reserveCapacity(count)
        for i in 0 ..< count {
            encodedFrames.append(try zip.data(for: String(format: "laugh/%04d.png", i)))
        }
        encoded = encodedFrames

        // 预热前几帧，避免第一次双击时卡顿（与 Windows 版一致）。
        _ = frame(0)
        _ = frame(1)
        _ = frame(2)
    }

    private static func decode(_ data: Data, width: Int, height: Int) throws -> RasterImage {
        guard let image = RasterImage.decode(data) else {
            throw NaiwaError.assets("动作素材解码失败")
        }
        guard image.width == width, image.height == height else {
            throw NaiwaError.assets("动作尺寸不一致")
        }
        return image
    }

    func eye(_ value: Double) -> RasterImage {
        let index = max(0, min(eyeCount - 1, Int((value * Double(eyeCount - 1)).rounded())))
        return eyes[index]
    }

    func blink(_ look: Double, frame: Int) -> RasterImage {
        let bank = look > 0.5 ? 1 : 0
        let index = max(0, min(blinkCount - 1, frame))
        return blinks[bank][index]
    }

    /// 大笑帧（LRU 缓存，最多保留 12 帧，与 C# 版本一致）。
    func frame(_ index: Int) -> RasterImage {
        let i = max(0, min(count - 1, index))
        if let hit = cache[i] { return hit }
        guard let image = RasterImage.decode(encoded[i]) else {
            return eyes[0] // 不会发生；解码失败时保持不崩溃
        }
        cache[i] = image
        order.append(i)
        while order.count > 12 {
            let old = order.removeFirst()
            cache.removeValue(forKey: old)
        }
        return image
    }
}
