import Compression
import Foundation

/// 极简 ZIP 读取器（只做解压，不写压缩包）。
///
/// xlsx 本质是 ZIP + XML，而 Foundation 没有公开的 ZIP 接口，
/// 这里直接解析中央目录，并用系统 Compression 框架解 Deflate。
struct ZIPArchive {
    struct Entry {
        let name: String
        let compressionMethod: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    enum ArchiveError: LocalizedError {
        case notAnArchive
        case unsupportedZip64
        case unsupportedCompression(UInt16)
        case damagedEntry(String)

        var errorDescription: String? {
            switch self {
            case .notAnArchive: "文件不是有效的 xlsx（ZIP）结构。"
            case .unsupportedZip64: "暂不支持 ZIP64 格式的超大文件。"
            case .unsupportedCompression(let method): "压缩方式 \(method) 暂不支持。"
            case .damagedEntry(let name): "压缩包内「\(name)」的数据已损坏。"
            }
        }
    }

    private static let centralDirectorySignature: UInt32 = 0x0201_4B50
    private static let endOfCentralDirectorySignature: UInt32 = 0x0605_4B50
    private static let localHeaderSignature: UInt32 = 0x0403_4B50
    private static let zip64Marker: UInt32 = 0xFFFF_FFFF

    private let bytes: [UInt8]
    let entries: [Entry]

    init(data: Data) throws {
        bytes = [UInt8](data)
        entries = try ZIPArchive.readCentralDirectory(bytes)
    }

    var entryNames: [String] { entries.map(\.name) }

    func data(for name: String) throws -> Data? {
        guard let entry = entries.first(where: { $0.name == name }) else { return nil }
        return try read(entry)
    }

    // MARK: - 中央目录

    private static func readCentralDirectory(_ bytes: [UInt8]) throws -> [Entry] {
        guard let eocd = findEndOfCentralDirectory(bytes) else { throw ArchiveError.notAnArchive }

        let entryCount = readUInt16(bytes, eocd + 10)
        let directoryOffset = readUInt32(bytes, eocd + 16)
        guard directoryOffset != zip64Marker else { throw ArchiveError.unsupportedZip64 }

        var entries: [Entry] = []
        var cursor = Int(directoryOffset)

        for _ in 0..<entryCount {
            guard readUInt32(bytes, cursor) == centralDirectorySignature else { break }

            let method = readUInt16(bytes, cursor + 10)
            let compressedSize = readUInt32(bytes, cursor + 20)
            let uncompressedSize = readUInt32(bytes, cursor + 24)
            let nameLength = Int(readUInt16(bytes, cursor + 28))
            let extraLength = Int(readUInt16(bytes, cursor + 30))
            let commentLength = Int(readUInt16(bytes, cursor + 32))
            let localOffset = readUInt32(bytes, cursor + 42)

            guard compressedSize != zip64Marker, uncompressedSize != zip64Marker, localOffset != zip64Marker else {
                throw ArchiveError.unsupportedZip64
            }

            let nameStart = cursor + 46
            let nameEnd = nameStart + nameLength
            guard nameEnd <= bytes.count else { break }
            let name = String(decoding: bytes[nameStart..<nameEnd], as: UTF8.self)

            entries.append(
                Entry(
                    name: name,
                    compressionMethod: method,
                    compressedSize: Int(compressedSize),
                    uncompressedSize: Int(uncompressedSize),
                    localHeaderOffset: Int(localOffset)
                )
            )

            cursor = nameEnd + extraLength + commentLength
        }

        guard !entries.isEmpty else { throw ArchiveError.notAnArchive }
        return entries
    }

    private static func findEndOfCentralDirectory(_ bytes: [UInt8]) -> Int? {
        let minimumSize = 22
        guard bytes.count >= minimumSize else { return nil }

        // 注释最长 65535 字节，从尾部向前找签名。
        let searchLimit = max(0, bytes.count - minimumSize - 65_535)
        var index = bytes.count - minimumSize
        while index >= searchLimit {
            if readUInt32(bytes, index) == endOfCentralDirectorySignature { return index }
            index -= 1
        }
        return nil
    }

    // MARK: - 解压

    private func read(_ entry: Entry) throws -> Data {
        let local = entry.localHeaderOffset
        guard readUInt32(bytes, local) == ZIPArchive.localHeaderSignature else {
            throw ArchiveError.damagedEntry(entry.name)
        }

        let nameLength = Int(readUInt16(bytes, local + 26))
        let extraLength = Int(readUInt16(bytes, local + 28))
        let start = local + 30 + nameLength + extraLength
        let end = start + entry.compressedSize
        guard start >= 0, end <= bytes.count else { throw ArchiveError.damagedEntry(entry.name) }

        let payload = Array(bytes[start..<end])

        switch entry.compressionMethod {
        case 0:
            return Data(payload)
        case 8:
            return try inflate(payload, expectedSize: entry.uncompressedSize, name: entry.name)
        default:
            throw ArchiveError.unsupportedCompression(entry.compressionMethod)
        }
    }

    private func inflate(_ payload: [UInt8], expectedSize: Int, name: String) throws -> Data {
        guard expectedSize > 0 else { return Data() }

        var output = [UInt8](repeating: 0, count: expectedSize)
        let written = output.withUnsafeMutableBufferPointer { destination -> Int in
            payload.withUnsafeBufferPointer { source -> Int in
                guard let destinationBase = destination.baseAddress,
                      let sourceBase = source.baseAddress else { return 0 }
                return compression_decode_buffer(
                    destinationBase,
                    expectedSize,
                    sourceBase,
                    payload.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }

        guard written == expectedSize else { throw ArchiveError.damagedEntry(name) }
        return Data(output)
    }

    // MARK: - 字节读取

}

private func readUInt16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
    guard offset >= 0, offset + 2 <= bytes.count else { return 0 }
    return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
}

private func readUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
    guard offset >= 0, offset + 4 <= bytes.count else { return 0 }
    return UInt32(bytes[offset])
        | (UInt32(bytes[offset + 1]) << 8)
        | (UInt32(bytes[offset + 2]) << 16)
        | (UInt32(bytes[offset + 3]) << 24)
}
