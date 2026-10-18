import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// 图标渲染：与 Windows 版一致，取待机素材剪裁区域 (60,40)-(235,265)，
/// 按原比例目标框（等价于 64×64 时的 6,0,52,64）绘制。
enum Icon {
    static func renderIcon(from eye: RasterImage, size: CGFloat) -> CGImage? {
        let pixelSize = Int(size.rounded())
        guard pixelSize > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pixelSize, height: pixelSize,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.clear(CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
        let scale = size / 64
        let dest = CGRect(x: 6 * scale, y: 0, width: 52 * scale, height: 64 * scale)
        let sourceRegion = CGRect(x: 60, y: 40, width: 175, height: 225)
        if let cropped = eye.cgImage.cropping(to: sourceRegion) {
            ctx.draw(cropped, in: dest)
        }
        return ctx.makeImage()
    }

    static func image(from eye: RasterImage, size: CGFloat) -> NSImage? {
        guard let cg = renderIcon(from: eye, size: size) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: size, height: size))
    }

    static func statusBarImage(from eye: RasterImage, height: CGFloat = 18) -> NSImage? {
        guard let cg = renderIcon(from: eye, size: height * 2) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: height, height: height))
        image.isTemplate = false
        return image
    }

    // MARK: - icns 打包

    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// 生成 .icns（含 32/64/128/256/512/1024 的 PNG 块）。
    @discardableResult
    static func writeICNS(from eye: RasterImage, to url: URL) -> Bool {
        let entries: [(String, CGFloat)] = [
            ("ic11", 32), ("ic12", 64), ("ic07", 128),
            ("ic13", 256), ("ic14", 512), ("ic10", 1024),
        ]
        var chunks = Data()
        for (type, size) in entries {
            guard let image = renderIcon(from: eye, size: size), let png = pngData(image) else { continue }
            var length = UInt32(png.count + 8).bigEndian
            withUnsafeBytes(of: &length) { chunks.append(contentsOf: $0) }
            chunks.append(Data(type.utf8))
            chunks.append(png)
        }
        guard !chunks.isEmpty else { return false }
        var file = Data("icns".utf8)
        var total = UInt32(chunks.count + 8).bigEndian
        withUnsafeBytes(of: &total) { file.append(contentsOf: $0) }
        file.append(chunks)
        return (try? file.write(to: url)) != nil
    }
}
