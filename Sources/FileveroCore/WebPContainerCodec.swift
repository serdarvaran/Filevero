import Foundation

/// Low-level RIFF/WebP container parser and metadata payload injector.
/// Modifies EXIF and XMP chunks while byte-accurately preserving existing intra/inter frame payload streams.
enum WebPContainerCodec {
    struct Chunk {
        var name: String
        var payload: Data
    }

    static func chunks(_ data: Data) throws -> [Chunk] {
        let bytes = [UInt8](data)
        guard bytes.count >= 12,
              String(bytes: bytes[0..<4], encoding: .ascii) == "RIFF",
              String(bytes: bytes[8..<12], encoding: .ascii) == "WEBP"
        else {
            throw FileveroError.invalidInput("This is not a WebP container.")
        }
        
        let containerEnd = Int(read32(bytes, 4)) + 8
        guard containerEnd <= bytes.count, containerEnd >= 12 else {
            throw FileveroError.invalidInput("The WebP container is truncated.")
        }
        
        var chunkList: [Chunk] = []
        var offset = 12
        while offset < containerEnd {
            guard offset + 8 <= containerEnd else {
                throw FileveroError.invalidInput("The WebP chunk header is incomplete.")
            }
            let length = Int(read32(bytes, offset + 4))
            let chunkDataStart = offset + 8
            guard length <= containerEnd - chunkDataStart,
                  chunkDataStart + length + (length % 2) <= containerEnd,
                  let chunkName = String(bytes: bytes[offset..<offset + 4], encoding: .ascii)
            else {
                throw FileveroError.invalidInput("The WebP chunk is invalid.")
            }
            
            chunkList.append(Chunk(name: chunkName, payload: Data(bytes[chunkDataStart..<chunkDataStart + length])))
            offset = chunkDataStart + length + (length % 2)
        }
        return chunkList
    }

    static func replaceEXIF(_ data: Data, exif: Data?, removeXMP: Bool, width: Int, height: Int) throws -> Data {
        guard width > 0, height > 0, width <= 0x1000000, height <= 0x1000000 else {
            throw FileveroError.invalidInput("Invalid WebP canvas dimensions.")
        }
        
        var filteredChunks = try chunks(data).filter { $0.name != "EXIF" && !(removeXMP && $0.name == "XMP ") }
        if let newExif = exif, !newExif.isEmpty {
            filteredChunks.append(Chunk(name: "EXIF", payload: newExif))
        }
        
        let vp8xIndex = filteredChunks.firstIndex { $0.name == "VP8X" }
        let requiresExtendedHeader = vp8xIndex != nil || exif != nil
        
        if requiresExtendedHeader {
            var flags: UInt8 = 0
            if filteredChunks.contains(where: { $0.name == "ICCP" }) { flags |= 0x20 }
            if filteredChunks.contains(where: {
                $0.name == "ALPH" || ($0.name == "VP8L" && $0.payload.count >= 5 && ($0.payload[$0.payload.startIndex + 4] & 0x10) != 0)
            }) {
                flags |= 0x10
            }
            if let existingIndex = vp8xIndex, filteredChunks[existingIndex].payload.count == 10 {
                flags |= filteredChunks[existingIndex].payload[filteredChunks[existingIndex].payload.startIndex] & 0x10
            }
            if filteredChunks.contains(where: { $0.name == "EXIF" }) { flags |= 0x08 }
            if filteredChunks.contains(where: { $0.name == "XMP " }) { flags |= 0x04 }
            if filteredChunks.contains(where: { $0.name == "ANIM" || $0.name == "ANMF" }) { flags |= 0x02 }
            
            var extendedPayload = Data([flags, 0, 0, 0])
            append24(width - 1, to: &extendedPayload)
            append24(height - 1, to: &extendedPayload)
            
            if let existingIndex = vp8xIndex {
                filteredChunks[existingIndex].payload = extendedPayload
            } else {
                filteredChunks.insert(Chunk(name: "VP8X", payload: extendedPayload), at: 0)
            }
        }
        
        var bodyData = Data("WEBP".utf8)
        for chunk in filteredChunks {
            guard chunk.payload.count <= Int(UInt32.max) else {
                throw FileveroError.invalidInput("WebP metadata is too large.")
            }
            bodyData.append(Data(chunk.name.utf8))
            append32(UInt32(chunk.payload.count), to: &bodyData)
            bodyData.append(chunk.payload)
            if chunk.payload.count % 2 != 0 {
                bodyData.append(0)
            }
        }
        
        guard bodyData.count <= Int(UInt32.max) - 9 else {
            throw FileveroError.invalidInput("The WebP file is too large.")
        }
        
        var riffOutput = Data("RIFF".utf8)
        append32(UInt32(bodyData.count), to: &riffOutput)
        riffOutput.append(bodyData)
        return riffOutput
    }

    static func exifPayload(fromJPEG data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else {
            throw FileveroError.failed("Could not encode Exif metadata.")
        }
        var offset = 2
        while offset + 4 <= bytes.count {
            guard bytes[offset] == 0xFF else { break }
            let marker = bytes[offset + 1]
            if marker == 0xDA || marker == 0xD9 { break }
            let length = Int(bytes[offset + 2]) * 256 + Int(bytes[offset + 3])
            let markerStart = offset + 4
            let markerEnd = offset + 2 + length
            guard length >= 2, markerEnd <= bytes.count else { break }
            if marker == 0xE1, markerEnd - markerStart >= 6, Array(bytes[markerStart..<markerStart + 6]) == [69, 120, 105, 102, 0, 0] {
                return Data(bytes[markerStart..<markerEnd])
            }
            offset = markerEnd
        }
        throw FileveroError.failed("The local encoder could not serialize these Exif tags.")
    }

    static func tiffTextFields(_ exifData: Data) -> [String: String] {
        var rawBytes = [UInt8](exifData)
        if rawBytes.starts(with: [69, 120, 105, 102, 0, 0]) {
            rawBytes = Array(rawBytes.dropFirst(6))
        }
        guard rawBytes.count >= 8 else { return [:] }
        let isLittleEndian = rawBytes[0] == 73 && rawBytes[1] == 73
        guard isLittleEndian || (rawBytes[0] == 77 && rawBytes[1] == 77) else { return [:] }
        
        func parseNumber(_ offset: Int, _ byteCount: Int) -> Int? {
            guard offset >= 0, byteCount > 0, offset <= rawBytes.count - byteCount else { return nil }
            var acc = 0
            for idx in 0..<byteCount {
                acc |= Int(rawBytes[offset + idx]) << ((isLittleEndian ? idx : byteCount - 1 - idx) * 8)
            }
            return acc
        }
        
        guard parseNumber(2, 2) == 42,
              let directoryOffset = parseNumber(4, 4),
              let entryCount = parseNumber(directoryOffset, 2),
              directoryOffset + 2 <= rawBytes.count,
              entryCount <= (rawBytes.count - directoryOffset - 2) / 12
        else { return [:] }
        
        let recognizedTags: [Int: String] = [
            269: "DocumentName", 270: "ImageDescription", 271: "Make", 272: "Model", 305: "Software", 306: "DateTime",
            315: "Artist", 316: "HostComputer", 33432: "Copyright",
        ]
        var tagResults: [String: String] = [:]
        
        for idx in 0..<entryCount {
            let entryOffset = directoryOffset + 2 + idx * 12
            guard let tagId = parseNumber(entryOffset, 2),
                  let tagName = recognizedTags[tagId],
                  parseNumber(entryOffset + 2, 2) == 2,
                  let stringLength = parseNumber(entryOffset + 4, 4),
                  stringLength > 0,
                  let dataOffset = stringLength <= 4 ? entryOffset + 8 : parseNumber(entryOffset + 8, 4),
                  dataOffset <= rawBytes.count - stringLength
            else { continue }
            
            let valueData = Data(rawBytes[dataOffset..<dataOffset + stringLength].prefix(while: { $0 != 0 }))
            tagResults[tagName] = String(data: valueData, encoding: .utf8) ?? String(data: valueData, encoding: .isoLatin1)
        }
        return tagResults
    }

    private static func read32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }

    private static func append32(_ value: UInt32, to data: inout Data) {
        data.append(contentsOf: [
            UInt8(value & 255), UInt8((value >> 8) & 255), UInt8((value >> 16) & 255), UInt8((value >> 24) & 255),
        ])
    }

    private static func append24(_ value: Int, to data: inout Data) {
        data.append(contentsOf: [UInt8(value & 255), UInt8((value >> 8) & 255), UInt8((value >> 16) & 255)])
    }
}

typealias WebPMetadataContainer = WebPContainerCodec

