import Foundation

struct MultipartJPEGParser {
    private var buffer = Data()
    mutating func append(_ bytes: Data) throws -> [Data] {
        guard buffer.count + bytes.count <= 10 * 1024 * 1024 else { throw ProbeFailure("mjpeg_limit", "MJPEG buffer limit") }
        buffer.append(bytes)
        var images: [Data] = []
        while true {
            while buffer.starts(with: [13, 10]) { buffer = Data(buffer.dropFirst(2)) }
            guard let boundary = buffer.range(of: Data("\r\n\r\n".utf8)) else { break }
            guard boundary.lowerBound < 4096,
                  let headers = String(data: buffer.prefix(upTo: boundary.lowerBound), encoding: .utf8),
                  let line = headers.components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("content-length:") }),
                  let size = Int(line.dropFirst(15).trimmingCharacters(in: .whitespaces)), (1...8*1024*1024).contains(size) else {
                throw ProbeFailure("mjpeg_header", "Invalid MJPEG part headers")
            }
            let end = boundary.upperBound + size
            guard buffer.count >= end else { break }
            let image = buffer.subdata(in: boundary.upperBound..<end)
            guard image.starts(with: [0xff, 0xd8]), image.suffix(2) == Data([0xff, 0xd9]) else { throw ProbeFailure("mjpeg_image", "Invalid JPEG markers") }
            images.append(image); buffer = Data(buffer.dropFirst(end))
        }
        return images
    }
}
