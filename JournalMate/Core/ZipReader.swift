import Compression
import Foundation

/// 最小限の zip 読み取り。書き出した Vault から復元用のスナップショットを取り出すためだけにある。
///
/// iOS には zip を展開する公開 API が無い。圧縮は `NSFileCoordinator` の `.forUploading` に
/// 任せているので、読む側も依存を増やさず、中央ディレクトリを辿って
/// 無圧縮（stored）と deflate だけを扱う。ZIP64 と暗号化は扱わない。
struct ZipReader {

    enum Error: Swift.Error, LocalizedError {
        case notAZip
        case unsupported
        case corrupted

        var errorDescription: String? {
            switch self {
            case .notAZip: return String(localized: "This file is not a zip archive.")
            case .unsupported: return String(localized: "This zip archive uses a format that can't be read.")
            case .corrupted: return String(localized: "The zip archive is damaged.")
            }
        }
    }

    struct Entry {
        let name: String
        let method: UInt16
        let flags: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    private let data: Data
    let entries: [Entry]

    init(url: URL) throws {
        data = try Data(contentsOf: url, options: .mappedIfSafe)
        entries = try Self.readCentralDirectory(data)
    }

    /// 名前の末尾が一致する最初の項目。zip の先頭フォルダ名に頼らずに探すため。
    func entry(named filename: String) -> Entry? {
        entries.first { $0.name == filename || $0.name.hasSuffix("/" + filename) }
    }

    func extract(_ entry: Entry) throws -> Data {
        guard entry.flags & 0x1 == 0 else { throw Error.unsupported }   // 暗号化
        let header = entry.localHeaderOffset
        guard header + 30 <= data.count, u32(data, header) == 0x0403_4b50 else { throw Error.corrupted }
        let start = header + 30 + Int(u16(data, header + 26)) + Int(u16(data, header + 28))
        let end = start + entry.compressedSize
        guard end <= data.count else { throw Error.corrupted }
        let compressed = data.subdata(in: data.startIndex + start ..< data.startIndex + end)

        switch entry.method {
        case 0:
            return compressed
        case 8:
            // COMPRESSION_ZLIB は zlib ヘッダの無い素の deflate（zip の中身そのもの）を読む。
            guard entry.uncompressedSize > 0 else { return Data() }
            var output = Data(count: entry.uncompressedSize)
            let written = output.withUnsafeMutableBytes { destination in
                compressed.withUnsafeBytes { source in
                    compression_decode_buffer(
                        destination.bindMemory(to: UInt8.self).baseAddress!, entry.uncompressedSize,
                        source.bindMemory(to: UInt8.self).baseAddress!, compressed.count,
                        nil, COMPRESSION_ZLIB)
                }
            }
            guard written == entry.uncompressedSize else { throw Error.corrupted }
            return output
        default:
            throw Error.unsupported
        }
    }

    // MARK: - 中央ディレクトリ

    private static func readCentralDirectory(_ data: Data) throws -> [Entry] {
        // 終端レコード（22 バイト + コメント最大 64KB）を後ろから探す。
        guard data.count >= 22 else { throw Error.notAZip }
        let lowest = max(0, data.count - 22 - 0xFFFF)
        var eocd: Int?
        var offset = data.count - 22
        while offset >= lowest {
            if u32(data, offset) == 0x0605_4b50 { eocd = offset; break }
            offset -= 1
        }
        guard let eocd else { throw Error.notAZip }

        let count = Int(u16(data, eocd + 10))
        let directoryOffset = u32(data, eocd + 16)
        guard directoryOffset != 0xFFFF_FFFF, count != 0xFFFF else { throw Error.unsupported }

        var entries: [Entry] = []
        var cursor = Int(directoryOffset)
        for _ in 0..<count {
            guard cursor + 46 <= data.count, u32(data, cursor) == 0x0201_4b50 else { throw Error.corrupted }
            let nameLength = Int(u16(data, cursor + 28))
            let extraLength = Int(u16(data, cursor + 30))
            let commentLength = Int(u16(data, cursor + 32))
            let compressedSize = u32(data, cursor + 20)
            let uncompressedSize = u32(data, cursor + 24)
            let localOffset = u32(data, cursor + 42)
            guard compressedSize != 0xFFFF_FFFF, uncompressedSize != 0xFFFF_FFFF,
                  localOffset != 0xFFFF_FFFF else { throw Error.unsupported }
            guard cursor + 46 + nameLength <= data.count else { throw Error.corrupted }

            let nameStart = data.startIndex + cursor + 46
            let name = String(decoding: data[nameStart ..< nameStart + nameLength], as: UTF8.self)
            entries.append(Entry(name: name,
                                 method: u16(data, cursor + 10),
                                 flags: u16(data, cursor + 8),
                                 compressedSize: Int(compressedSize),
                                 uncompressedSize: Int(uncompressedSize),
                                 localHeaderOffset: Int(localOffset)))
            cursor += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }
}

// zip の数値はすべてリトルエンディアン。
private func u16(_ data: Data, _ offset: Int) -> UInt16 {
    data.withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self)) }
}

private func u32(_ data: Data, _ offset: Int) -> UInt32 {
    data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
}
