import Foundation

/// One serial writer with fresh segments; crash tails remain read-only evidence.
actor NativeLogFile {
    nonisolated let directory: URL
    private var file: URL?
    private var bytes = 0
    private var openedAt = Date.distantPast
    private let segmentBytes = 4 * 1024 * 1024

    init(directory: URL) { self.directory = directory }

    func append(_ data: Data) -> Bool {
        guard data.count <= segmentBytes else { return false }
        do {
            let fm = FileManager.default, now = Date()
            if file == nil || bytes + data.count > segmentBytes || now.timeIntervalSince(openedAt) >= 900 {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
                let files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))
                    .filter { $0.lastPathComponent.range(of: #"^(current|[0-9]+-[a-f0-9-]+)\.jsonl$"#, options: .regularExpression) != nil }
                    .map { ($0, try $0.resourceValues(forKeys: keys)) }
                    .sorted { ($0.1.contentModificationDate ?? .distantPast) < ($1.1.contentModificationDate ?? .distantPast) }
                // Reserve the whole incoming segment so appends need no rescans.
                var total = files.reduce(segmentBytes) { $0 + ($1.1.fileSize ?? 0) }, count = files.count + 1
                for (url, attributes) in files {
                    if total <= 16 * 1024 * 1024 && count <= 512
                        && now.timeIntervalSince(attributes.contentModificationDate ?? .distantPast) <= 86400 { continue }
                    try fm.removeItem(at: url)
                    total -= attributes.fileSize ?? 0
                    count -= 1
                }
                file = directory.appendingPathComponent("\(Int(now.timeIntervalSince1970 * 1000))-\(UUID().uuidString.lowercased()).jsonl")
                guard fm.createFile(atPath: file!.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    file = nil
                    return false
                }
                bytes = 0
                openedAt = now
            }
            let handle = try FileHandle(forWritingTo: file!)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            bytes += data.count
            return true
        } catch {
            file = nil // Never append after a potentially partial write.
            return false
        }
    }
}
