import CoreGraphics
import Foundation

/// 渲染画布：一块复用的 RGBA 位图上下文 + 快照 CGImage。
final class Canvas {
    let pointWidth: Int
    let pointHeight: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let backingScale: CGFloat
    let context: CGContext
    private var snapshot: CGImage?

    init?(pointWidth: Int, pointHeight: Int, backingScale: CGFloat) {
        self.pointWidth = pointWidth
        self.pointHeight = pointHeight
        self.backingScale = backingScale
        pixelWidth = max(1, Int((CGFloat(pointWidth) * backingScale).rounded()))
        pixelHeight = max(1, Int((CGFloat(pointHeight) * backingScale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pixelWidth, height: pixelHeight,
                                  bitsPerComponent: 8, bytesPerRow: pixelWidth * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.setShouldAntialias(true)
        context = ctx
    }

    /// 当前帧的快照（每次渲染后调用；makeImage 会生成独立副本）。
    var cgImage: CGImage? {
        if let snapshot { return snapshot }
        snapshot = context.makeImage()
        return snapshot
    }

    func invalidateSnapshot() { snapshot = nil }

    /// 逐像素命中测试：point 为画布坐标（左上原点，单位 point）。
    func alpha(at point: CGPoint) -> UInt8 {
        let x = Int(floor(point.x * backingScale))
        let y = Int(floor(point.y * backingScale))
        guard x >= 0, y >= 0, x < pixelWidth, y < pixelHeight, let data = context.data else { return 0 }
        return data.assumingMemoryBound(to: UInt8.self)[(y * pixelWidth + x) * 4 + 3]
    }
}

/// 软件渲染器：逐行对应 C# 的 Renderer（含肚子变形、交叉渐隐与拖动/落地变换）。
enum Renderer {
    /// 复用同一块画布（尺寸或缩放变化时重建），避免每帧分配。
    static var lastCanvas: Canvas?

    static func render(assets: Assets, motion: Motion, scale: Int, backingScale: CGFloat) -> Canvas? {
        // C# 为整数除法：288*85/100 = 244。
        let w = max(1, assets.width * scale / 100)
        let h = max(1, assets.height * scale / 100)
        guard let canvas = canvas(pointWidth: w, pointHeight: h, backingScale: backingScale) else { return nil }
        let ctx = canvas.context
        canvas.invalidateSnapshot()
        ctx.saveGState()
        ctx.clear(CGRect(x: 0, y: 0, width: canvas.pixelWidth, height: canvas.pixelHeight))
        ctx.scaleBy(x: backingScale, y: backingScale)
        // 翻成 y 向下坐标系，便于逐行沿用 GDI+ 的变换与坐标。
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)

        // 变换只移动原始素材，不绘制任何替换身体或表情。
        if motion.moving {
            let s = CGFloat(motion.squash)
            let px = CGFloat(w) * 0.5
            let py = CGFloat(h) * (motion.holding ? 0.56 : 0.9565)
            ctx.translateBy(x: px, y: py - (motion.holding ? 2 * CGFloat(scale) / 100 : 0))
            ctx.rotate(by: CGFloat(motion.dragAngle) * .pi / 180)
            ctx.scaleBy(x: motion.holding ? 1.008 : 1 + s, y: motion.holding ? 1.018 : 1 - s)
            ctx.translateBy(x: -px, y: -py)
        }

        let rect = CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h))
        if motion.resting {
            draw(ctx, assets.frame(assets.count - 1), in: rect, alpha: 1)
        } else if motion.waking {
            let t = min(1, (motion.clock - motion.wakeStart) / 0.24)
            draw(ctx, assets.frame(assets.count - 1), in: rect, alpha: CGFloat(1 - t))
            draw(ctx, assets.eye(motion.look), in: rect, alpha: CGFloat(t))
        } else if !motion.playing {
            let idle = motion.blinking
                ? assets.blink(motion.look, frame: Int((motion.clock - motion.blinkStart) * assets.blinkFps))
                : assets.eye(motion.look)
            if motion.poking {
                let warped = warpBelly(idle, cx: motion.pokeX, cy: motion.pokeY, amount: motion.pokeAmount)
                draw(ctx, warped, in: rect, alpha: 1)
            } else {
                draw(ctx, idle, in: rect, alpha: 1)
            }
        } else if motion.elapsed < 0.10 {
            draw(ctx, assets.eye(motion.look), in: rect, alpha: 1)
            draw(ctx, assets.frame(Int(motion.elapsed * assets.fps)), in: rect, alpha: CGFloat(motion.elapsed / 0.10))
        } else {
            draw(ctx, assets.frame(Int(motion.elapsed * assets.fps)), in: rect, alpha: 1)
        }
        ctx.restoreGState()
        return canvas
    }

    private static func canvas(pointWidth: Int, pointHeight: Int, backingScale: CGFloat) -> Canvas? {
        if let existing = lastCanvas,
           existing.pointWidth == pointWidth,
           existing.pointHeight == pointHeight,
           existing.backingScale == backingScale {
            return existing
        }
        guard let fresh = Canvas(pointWidth: pointWidth, pointHeight: pointHeight, backingScale: backingScale) else {
            return nil
        }
        lastCanvas = fresh
        return fresh
    }

    /// 在 y 向下坐标系中正确朝上地绘制图像（内部再做一次翻转）。
    static func draw(_ ctx: CGContext, _ image: RasterImage, in rect: CGRect, alpha: CGFloat) {
        if alpha <= 0 { return }
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image.cgImage, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        ctx.restoreGState()
    }

    /// 戳肚子的局部变形（逐行对应 C# Renderer.WarpBelly）。
    static func warpBelly(_ original: RasterImage, cx: Double, cy: Double, amount: Double) -> RasterImage {
        let w = original.width
        let h = original.height
        var result = original.pixels
        let radiusX = 96.0
        let radiusY = 72.0
        let left = max(0, Int(cx - radiusX))
        let right = min(w - 2, Int(cx + radiusX))
        let top = max(105, Int(cy - radiusY))
        let bottom = min(min(300, h - 2), Int(cy + radiusY))
        if left <= right && top <= bottom && w >= 2 && h >= 2 {
            let src = original.pixels
            result.withUnsafeMutableBufferPointer { dst in
                src.withUnsafeBufferPointer { source in
                    func sample(_ index: Int) -> Double { Double(source[index]) }
                    for y in top ... bottom {
                        for x in left ... right {
                            let dx = Double(x) - cx
                            let dy = Double(y) - cy
                            let r = dx * dx / (radiusX * radiusX) + dy * dy / (radiusY * radiusY)
                            if r >= 1 { continue }
                            // 含肚子轮廓，在脸部与脚部之前淡出。
                            let neck = min(1, (Double(y) - 105) / 30.0)
                            let legs = min(1, (300.0 - Double(y)) / 20.0)
                            let fadeN = neck * neck * (3 - 2 * neck)
                            let fadeL = legs * legs * (3 - 2 * legs)
                            let fade = fadeN * fadeL
                            let fall = (1 - r) * (1 - r) * amount * fade
                            let sx = max(0, min(Double(w) - 1.001, Double(x) + dx * fall))
                            let sy = max(0, min(Double(h) - 1.001, Double(y) + dy * fall * 0.6))
                            let ix = max(0, min(w - 2, Int(sx)))
                            let iy = max(0, min(h - 2, Int(sy)))
                            let fx = sx - Double(ix)
                            let fy = sy - Double(iy)
                            let dest = (y * w + x) * 4
                            let a = (iy * w + ix) * 4
                            let b = a + 4
                            let c = a + w * 4
                            let d = c + 4
                            for channel in 0 ..< 4 {
                                let topMix = sample(a + channel) * (1 - fx) + sample(b + channel) * fx
                                let bottomMix = sample(c + channel) * (1 - fx) + sample(d + channel) * fx
                                let value = topMix * (1 - fy) + bottomMix * fy
                                dst[dest + channel] = UInt8(max(0, min(255, value.rounded(.toNearestOrEven))))
                            }
                        }
                    }
                }
            }
        }
        return RasterImage(width: w, height: h, pixels: result)
    }
}
