import CoreGraphics
import Foundation
import ImageIO

enum NaiwaError: LocalizedError {
    case assets(String)

    var errorDescription: String? {
        switch self {
        case .assets(let message): return message
        }
    }
}

/// 32 位 RGBA（预乘）位图：同时保留像素缓冲区（用于命中测试 / 测试比较 / 肚子变形）
/// 与可直接交给 Core Graphics 绘制的 CGImage。
final class RasterImage {
    let width: Int
    let height: Int
    let pixels: [UInt8]
    let cgImage: CGImage

    /// 从 PNG 数据解码（对应 C# 的 Assets.Decode）。
    static func decode(_ data: Data) -> RasterImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return RasterImage(cgImage: image)
    }

    init?(cgImage: CGImage) {
        let w = cgImage.width
        let h = cgImage.height
        guard w > 0, h > 0, w <= 4096, h <= 4096 else { return nil }
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        self.width = w
        self.height = h
        self.pixels = buffer
        self.cgImage = cgImage
    }

    /// 从像素缓冲区构造（肚子变形结果）。
    init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
        self.cgImage = RasterImage.makeCGImage(width: width, height: height, pixels: pixels) ?? {
            // 兜底：理论上不会发生；返回 1x1 透明图像避免崩溃。
            fatalError("无法构造图像")
        }()
    }

    static func makeCGImage(width: Int, height: Int, pixels: [UInt8]) -> CGImage? {
        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true,
                       intent: .defaultIntent)
    }

    func pixel(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let i = (y * width + x) * 4
        return (pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3])
    }

    func alpha(x: Int, y: Int) -> UInt8 {
        guard x >= 0, y >= 0, x < width, y < height else { return 0 }
        return pixels[(y * width + x) * 4 + 3]
    }
}
