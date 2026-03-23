import Foundation
import Combine
import os

@MainActor
final class AppDebugLog: ObservableObject {
    static let shared = AppDebugLog()

    @Published private(set) var entries: [String] = []

    private let logger = Logger(subsystem: "com.samragsdale.SlopZooka", category: "vision-client")
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private init() {}

    func record(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)"
        entries.append(line)
        if entries.count > 120 {
            entries.removeFirst(entries.count - 120)
        }
        logger.log("\(line, privacy: .public)")
    }
}

@MainActor
func slzLog(_ message: String) {
    AppDebugLog.shared.record(message)
}
