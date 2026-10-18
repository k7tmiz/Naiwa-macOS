import Foundation
import Compression

/// 读取 素材.nwp（ZIP 容器）所需的最小实现。
/// 支持 store（0）与 deflate（8）两种压缩方式；尺寸取自中央目录，可兼容带数据描述符的归档。
struct ZipEntry {
    let name: String
    let method: Int
    let compressedSize: Int
    let uncompressedSize: Int
    let localHeaderOffset: Int
}

final class ZipArchive {
    private let bytes: [UInt8]
    private var entries: [String: ZipEntry] = [:]

    init(url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        bytes = [UInt8](data)
        try parse()
    }

    var count: Int { entries.count }

    func contains(_ name: String) -> Bool { entries[name] != nil }

    func data(for name: String) throws -> Data {
        guard let entry = entries[name] else {
            throw NaiwaError.assets("缺少素材条目：\(name)")
        }
        let lh = entry.localHeaderOffset
        guard lh + 30 <= bytes.count,
              bytes[lh] == 0x50, bytes[lh + 1] == 0x4b, bytes[lh + 2] == 0x03, bytes[lh + 3] == 0x04 else {
            throw NaiwaError.assets("归档条目损坏：\(name)")
        }
        let nameLen = u16(lh + 26)
        let extraLen = u16(lh + 28)
        let start = lh + 30 + nameLen + extraLen
        guard start + entry.compressedSize <= bytes.count, entry.uncompressedSize >= 0, entry.uncompressedSize <= 1 << 30 else {
            throw NaiwaError.assets("归档条目越界：\(name)")
        }
        let compressed = bytes[start ..< start + entry.compressedSize]
        switch entry.method {
        case 0:
            return Data(compressed)
        case 8:
            var output = [UInt8](repeating: 0, count: max(entry.uncompressedSize, 1))
            let written = output.withUnsafeMutableBufferPointer { dst -> Int in
                compressed.withUnsafeBufferPointer { src -> Int in
                    guard let d = dst.baseAddress, let s = src.baseAddress else { return 0 }
                    return compression_decode_buffer(d, dst.count, s, src.count, nil, COMPRESSION_ZLIB)
                }
            }
            guard written == entry.uncompressedSize else {
                throw NaiwaError.assets("解压失败：\(name)")
            }
            return Data(output)
        default:
            throw NaiwaError.assets("不支持的压缩方式（\(entry.method)）：\(name)")
        }
    }

    // MARK: - ZIP 结构解析

    private func u16(_ offset: Int) -> Int {
        Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
    }

    private func u32(_ offset: Int) -> Int {
        Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
    }

    private func parse() throws {
        guard bytes.count >= 22 else { throw NaiwaError.assets("素材文件不完整") }
        // 从文件尾部向前搜索 EOCD（PK\05\06）。
        var eocd = -1
        let lowerBound = max(0, bytes.count - 65557)
        var i = bytes.count - 22
        while i >= lowerBound {
            if bytes[i] == 0x50, bytes[i + 1] == 0x4b, bytes[i + 2] == 0x05, bytes[i + 3] == 0x06 {
                eocd = i
                break
            }
            i -= 1
        }
        guard eocd >= 0 else { throw NaiwaError.assets("不是有效的 素材.nwp") }
        let total = u16(eocd + 10)
        var offset = u32(eocd + 16)
        for _ in 0 ..< total {
            guard offset + 46 <= bytes.count,
                  bytes[offset] == 0x50, bytes[offset + 1] == 0x4b,
                  bytes[offset + 2] == 0x01, bytes[offset + 3] == 0x02 else {
                throw NaiwaError.assets("素材目录损坏")
            }
            let method = u16(offset + 10)
            let compressed = u32(offset + 20)
            let uncompressed = u32(offset + 24)
            let nameLen = u16(offset + 28)
            let extraLen = u16(offset + 30)
            let commentLen = u16(offset + 32)
            let localOffset = u32(offset + 42)
            let nameStart = offset + 46
            guard nameStart + nameLen <= bytes.count else { throw NaiwaError.assets("素材目录越界") }
            let name = String(decoding: bytes[nameStart ..< nameStart + nameLen], as: UTF8.self)
            entries[name] = ZipEntry(name: name, method: method,
                                     compressedSize: compressed, uncompressedSize: uncompressed,
                                     localHeaderOffset: localOffset)
            offset = nameStart + nameLen + extraLen + commentLen
        }
        guard !entries.isEmpty else { throw NaiwaError.assets("素材.nwp 是空的") }
    }
}
