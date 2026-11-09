import Foundation
import Darwin

let root = URL(fileURLWithPath: "/tmp/slz-codex-runtime-fixture")
let report: [String: Any] = [
    "pid": getpid(), "parentPid": getppid(),
    "bundleIdentifier": Bundle.main.bundleIdentifier ?? "missing",
    "inheritedCodexEnvironmentNames": ProcessInfo.processInfo.environment.keys.filter { $0.hasPrefix("CODEX_") || $0.hasPrefix("NODE_REPL_") || $0.hasPrefix("CUA_REPL_") }.sorted()
]
try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]).write(to: root.appendingPathComponent("launcher.json"), options: .atomic)
let process = Process()
process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/python3")
process.arguments = ["/tmp/slz-codex-runtime-probe.py", "--fixture"]
process.currentDirectoryURL = URL(fileURLWithPath: "/tmp")
process.standardInput = try FileHandle(forReadingFrom: root.appendingPathComponent("commands.jsonl"))
FileManager.default.createFile(atPath: root.appendingPathComponent("launchservices-results.jsonl").path, contents: nil)
let output = try FileHandle(forWritingTo: root.appendingPathComponent("launchservices-results.jsonl"))
process.standardOutput = output
process.standardError = output
try process.run()
process.waitUntilExit()
try output.close()
try Data(String(process.terminationStatus).utf8).write(to: root.appendingPathComponent("launcher-exit.txt"), options: .atomic)
