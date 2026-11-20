import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum TranscriptImages {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic"]
    static let fullAttempts: [(pixels: Int, quality: Double)] = [(1600, 0.8), (1600, 0.6), (1200, 0.6), (800, 0.5)]

    static func refs(in block: [String: Any], entryID: String) -> [RemoteImageRef] {
        let images = (block["content"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "image" }
        return images.enumerated().compactMap { index, image in
            guard let length = ((image["source"] as? [String: Any])?["data"] as? String).flatMap({ Int($0) }) else { return nil }

            return RemoteImageRef(id: "\(entryID)-\(index)", bytes: length * 3 / 4)
        }
    }

    static func redactingImageData(_ line: Data) -> Data {
        let key = Data(#""data":""#.utf8)
        guard line.range(of: Data(#""tool_result""#.utf8)) != nil else { return line }

        var output = Data()
        var cursor = line.startIndex
        while let hit = line.range(of: key, in: cursor..<line.endIndex), let end = line[hit.upperBound...].firstIndex(of: UInt8(ascii: "\"")) {
            output.append(line[cursor..<hit.upperBound])
            output.append(contentsOf: String(line.distance(from: hit.upperBound, to: end)).utf8)
            cursor = end
        }
        output.append(line[cursor...])
        return output
    }

    static func isImagePath(_ path: String?) -> Bool {
        path.map { imageExtensions.contains(URL(filePath: $0).pathExtension.lowercased()) } ?? false
    }

    public static func image(id: String, variant: RemoteImageVariant, in transcript: URL, line knownLine: Range<Int>? = nil) -> Data? {
        let parts = id.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count >= 3, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
              let blockIndex = Int(parts[parts.count - 2]), let last = parts.last,
              let data = try? Data(contentsOf: transcript, options: .alwaysMapped),
              let uuid = Optional(parts.dropLast(2).joined(separator: "-")),
              let line = knownLine.flatMap({ object(in: data, range: $0) }).flatMap({ $0["uuid"] as? String == uuid ? $0 : nil }) ?? line(withKey: "uuid", value: uuid, in: data),
              let blocks = (line["message"] as? [String: Any])?["content"] as? [[String: Any]],
              blocks.indices.contains(blockIndex), blocks[blockIndex]["type"] as? String == "tool_result"
        else { return nil }

        let block = blocks[blockIndex]
        let source = last == "file" ? readFile(toolUseID: block["tool_use_id"] as? String, in: data) : embedded(Int(last), in: block)
        guard let source else { return nil }

        if variant == .thumbnail { return jpeg(source, maxPixel: TranscriptTail.thumbnailPixels, quality: 0.7) }

        return fullAttempts.lazy.compactMap { jpeg(source, maxPixel: $0.pixels, quality: $0.quality) }.first { $0.count <= RemoteImagesFeature.maxReplyBytes }
    }

    static func jpeg(_ data: Data, maxPixel: Int, quality: Double) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixel,
              ] as CFDictionary)
        else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }

        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    private static func embedded(_ index: Int?, in block: [String: Any]) -> Data? {
        let images = (block["content"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "image" }
        guard let index, images.indices.contains(index), let base64 = (images[index]["source"] as? [String: Any])?["data"] as? String else { return nil }

        return Data(base64Encoded: base64)
    }

    private static func readFile(toolUseID: String?, in data: Data) -> Data? {
        guard let toolUseID, toolUseID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }),
              let line = line(withKey: "id", value: toolUseID, in: data),
              let blocks = (line["message"] as? [String: Any])?["content"] as? [[String: Any]],
              let use = blocks.first(where: { $0["type"] as? String == "tool_use" && $0["id"] as? String == toolUseID }),
              use["name"] as? String == "Read",
              let path = (use["input"] as? [String: Any])?["file_path"] as? String, isImagePath(path),
              let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int, size <= RemoteImagesFeature.maxSourceBytes
        else { return nil }

        return try? Data(contentsOf: URL(filePath: path))
    }

    private static func object(in data: Data, range: Range<Int>) -> [String: Any]? {
        guard range.lowerBound >= 0, range.upperBound <= data.count else { return nil }

        return try? JSONSerialization.jsonObject(with: data[data.startIndex + range.lowerBound..<data.startIndex + range.upperBound]) as? [String: Any]
    }

    private static func line(withKey key: String, value: String, in data: Data) -> [String: Any]? {
        guard let hit = data.range(of: Data(#""\#(key)":"\#(value)""#.utf8), options: .backwards) else { return nil }

        let start = data[..<hit.lowerBound].lastIndex(of: UInt8(ascii: "\n")).map { $0 + 1 } ?? data.startIndex
        let end = data[hit.upperBound...].firstIndex(of: UInt8(ascii: "\n")) ?? data.endIndex
        return try? JSONSerialization.jsonObject(with: data[start..<end]) as? [String: Any]
    }
}
