import SwiftUI

@MainActor final class ProbeModel: ObservableObject {
    @Published var status = "Ready"
    @Published var running = false
    @Published var condition = "same-ap"
    @Published var rows: [String] = []
    private var client: LinkClient?
    private var file: FileHandle?
    func start(peer: Bool) {
        guard !running else { return }
        do {
            guard let configURL = Bundle.main.url(forResource: "connection", withExtension: "json") else { throw LinkError.invalidConfig }
            let config = try LinkConfig.load(configURL)
            let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let url = folder.appendingPathComponent("link-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).jsonl")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let file = try FileHandle(forWritingTo: url); self.file = file
            let client = LinkClient(config: config, peer: peer, condition: condition)
            self.client = client; running = true; rows = []; status = "Discovering Mac…"
            client.event = { [weak self] entry in
                try? file.write(contentsOf: json(entry) + Data([10]))
                Task { @MainActor in
                    guard let self else { return }
                    let kind = entry["event"] as? String ?? "event"
                    self.status = kind
                    if kind == "phase_result", let row = entry["result"] as? [String: Any] {
                        self.rows.append(String(format: "%@ Mbps: %.2f received, RTT p95 %.1f ms",
                            String(describing: row["targetMbps"] ?? "?"), row["receivedPayloadMbps"] as? Double ?? 0,
                            row["rttP95Ms"] as? Double ?? 0))
                    }
                    if kind == "failed" { self.rows.append(entry["reason"] as? String ?? "Unknown failure") }
                }
            }
            client.complete = { [weak self] success in
                try? file.close()
                Task { @MainActor in
                    self?.running = false
                    self?.status = success ? "Complete — results saved on Mac and headset" : "Failed — local log retained"
                }
            }
            linkQueue.async { client.start() }
        } catch { status = "Setup failed: \(error)" }
    }
    func stop() { if let client { linkQueue.async { client.cancel() } } }
}
@main struct PeerLinkViewer: App {
    @StateObject private var model = ProbeModel()
    var body: some Scene {
        WindowGroup {
            VStack(alignment: .leading, spacing: 16) {
                Text("SlopZooka Link Probe").font(.title)
                Text("Synthetic traffic only • about 20 seconds per run")
                TextField("Condition (same-ap / no-shared-ap)", text: $model.condition).disabled(model.running)
                HStack {
                    Button("Run LAN") { model.start(peer: false) }.disabled(model.running)
                    Button("Run peer eligible") { model.start(peer: true) }.disabled(model.running)
                    Button("Stop") { model.stop() }.disabled(!model.running)
                }
                Text(model.status)
                ForEach(Array(model.rows.enumerated()), id: \.offset) { _, row in Text(row).monospaced() }
                Text("Peer eligible does not prove a direct radio path. The operator checks endpoint/interface evidence.").font(.caption)
            }.padding(28).task {
                let args = ProcessInfo.processInfo.arguments
                if let i = args.firstIndex(of: "--condition"), i + 1 < args.count { model.condition = args[i + 1] }
                if args.contains("--autorun") { model.start(peer: args.contains("--peer")) }
            }
        }.defaultSize(width: 660, height: 440)
    }
}
