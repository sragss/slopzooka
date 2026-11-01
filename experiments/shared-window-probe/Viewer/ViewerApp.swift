import SwiftUI
import AVFoundation
import UIKit

@MainActor final class ViewerModel: ObservableObject {
    @Published var configurationText = ""
    @Published var message = "Paste the connection from the Mac host."
    @Published var targets: [[String: Any]] = []
    @Published var generation = 0
    @Published var hasLoaded = false
    @Published var config: ConnectionConfig?
    private var session: URLSession?
    private var polling: Task<Void, Never>?
    func connect() {
        polling?.cancel(); session?.invalidateAndCancel()
        do {
            let config = try JSONDecoder().decode(ConnectionConfig.self, from: Data(configurationText.utf8))
            _ = try config.request("/status")
            self.config = config
            session = pinnedSession(PinnedDelegate(config.fingerprint))
            polling = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    await self?.refresh()
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        } catch { message = error.localizedDescription; self.config = nil }
    }
    func refresh() async {
        guard let session, let config else { return }
        do {
            let (data, response) = try await session.data(for: config.request("/status"))
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let status = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ProbeFailure("status_failed", "Host rejected status") }
            targets = status["targets"] as? [[String: Any]] ?? []
            hasLoaded = true
            generation = status["generation"] as? Int ?? 0
            let desktop = status["desktop"] as? [String: Any] ?? [:]
            let duration = status["untilStopped"] as? Bool == true ? "manual stop" : "\(status["remainingSeconds"] ?? 0) seconds left"
            message = "Desktop: \(desktop["state"] ?? "unknown") • \(duration)"
        } catch { message = "Disconnected: \(error.localizedDescription)" }
    }
    func command(_ values: [String: Any]) async -> String {
        guard let session, let config else { return "Not connected" }
        do {
            var values = values; values["generation"] = generation
            let (data, _) = try await session.data(for: config.request("/command", method: "POST", body: jsonData(values)))
            await refresh(); return String(decoding: data, as: UTF8.self)
        } catch { return error.localizedDescription }
    }
}

@MainActor final class StreamModel: ObservableObject {
    let layer = AVSampleBufferDisplayLayer()
    @Published var message = "Connecting"
    @Published var png: UIImage?
    @Published var hasImage = false
    private var parser = PacketParser()
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private var retries: Task<Void, Never>?
    private var reading: Task<Void, Never>?
    private var alive = false
    private var waitingKey = true
    private var generation = -1
    private var frames = 0
    private var config: ConnectionConfig?
    private var target = ""
    func start(config: ConnectionConfig, target: String) {
        stop(); alive = true; self.config = config; self.target = target; connect()
    }
    private func connect() {
        guard alive, let config else { return }
        reading?.cancel(); task?.cancel(); session?.invalidateAndCancel()
        parser.reset(); waitingKey = true; clearImage()
        let inbox = StreamInbox()
        let delegate = PinnedDelegate(config.fingerprint)
        delegate.data = { inbox.append($0) }
        delegate.finished = { inbox.finish($0) }
        session = pinnedSession(delegate)
        do { task = session?.dataTask(with: try config.request("/stream/\(target)")); task?.resume() }
        catch { message = error.localizedDescription; return }
        reading = Task { @MainActor [weak self] in
            var lastBytes = uptime()
            while !Task.isCancelled {
                let (data, error) = inbox.drain()
                if let error { self?.disconnected(error); return }
                if !data.isEmpty { lastBytes = uptime(); self?.receive(data) }
                if uptime() - lastBytes > 3 { self?.disconnected("No stream heartbeat for three seconds"); return }
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
        }
    }
    private func clearImage() {
        hasImage = false; png = nil
        layer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
    }
    private func disconnected(_ error: String?) {
        reading?.cancel(); task?.cancel(); session?.invalidateAndCancel()
        clearImage(); parser.reset(); waitingKey = true
        guard alive else { return }
        message = "Stream unavailable. Reconnecting… \(error ?? "")"
        retries?.cancel()
        retries = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.session?.invalidateAndCancel(); self?.session = nil; self?.connect()
        }
    }
    private func receive(_ data: Data) {
        guard alive else { return }
        do {
            for packet in try parser.append(data) {
                if generation != packet.header.generation {
                    generation = packet.header.generation; clearImage(); waitingKey = true
                }
                switch packet.header.kind {
                case "h264":
                    if waitingKey && !packet.header.keyframe { continue }
                    if !layer.sampleBufferRenderer.isReadyForMoreMediaData || layer.sampleBufferRenderer.status == .failed {
                        clearImage(); waitingKey = true
                        if !packet.header.keyframe { continue }
                    }
                    waitingKey = false; layer.sampleBufferRenderer.enqueue(try videoSample(packet)); frames += 1; hasImage = true
                case "png", "jpeg": png = UIImage(data: packet.payload); frames += 1
                case "paused": clearImage(); waitingKey = true; message = packet.header.reason ?? "Paused"
                case "status":
                    let state = packet.header.reason ?? "unknown"
                    if !["complete", "idle", "diagnostic_png_1fps", "snapshot_ready", "device_mjpeg"].contains(state) {
                        clearImage(); waitingKey = true
                    }
                    message = "\(state) • \(frames) received frames"
                default: throw ProbeFailure("packet_kind", "Unknown stream packet")
                }
            }
        } catch { disconnected(error.localizedDescription) }
    }
    func stop() {
        alive = false; reading?.cancel(); retries?.cancel(); task?.cancel(); session?.invalidateAndCancel()
        task = nil; session = nil; parser.reset(); clearImage()
    }
}
struct VideoSurface: UIViewRepresentable {
    let layer: AVSampleBufferDisplayLayer
    class Container: UIView {
        let video: AVSampleBufferDisplayLayer
        init(_ video: AVSampleBufferDisplayLayer) { self.video = video; super.init(frame: .zero); layer.addSublayer(video); video.videoGravity = .resizeAspect }
        required init?(coder: NSCoder) { fatalError("not used") }
        override func layoutSubviews() { super.layoutSubviews(); video.frame = bounds }
    }
    func makeUIView(context: Context) -> Container { Container(layer) }
    func updateUIView(_ uiView: Container, context: Context) {}
}
struct StreamPanel: View {
    @EnvironmentObject var model: ViewerModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var stream = StreamModel()
    let id: String
    @State private var result = ""
    var body: some View {
        VStack {
            Text(model.targets.first(where: { $0["id"] as? String == id })?["label"] as? String ?? id).font(.headline)
            ZStack {
                VideoSurface(layer: stream.layer).opacity(stream.hasImage ? 1 : 0)
                if let image = stream.png { Image(uiImage: image).resizable().scaledToFit() }
            }.frame(minWidth: 400, minHeight: 300).background(.black)
            Text(stream.message).font(.caption)
            HStack {
                Button("Resume native") { act("resume") }
                Button("Start device snapshots") { act("deviceStream") }
                Button("Inspect AX") { act("observe") }
                Button("Resize Mac window to 1000×700") {
                    Task { result = await model.command(["action": "resize", "target": id, "width": 1000, "height": 700]) }
                }
            }
            if !result.isEmpty { ScrollView { Text(result).font(.caption.monospaced()).textSelection(.enabled) }.frame(maxHeight: 100) }
        }.padding().onAppear { if let config = model.config { stream.start(config: config, target: id) } }
            .onChange(of: model.config) { _, config in
                if let config { stream.start(config: config, target: id) } else { stream.stop() }
            }.onChange(of: model.targets.compactMap { $0["id"] as? String }) { _, ids in
                if model.hasLoaded && !ids.contains(id) { stream.stop(); dismiss() }
            }.onDisappear { stream.stop() }
    }
    private func act(_ action: String) { Task { result = await model.command(["action": action, "target": id]) } }
}
@main struct ProbeViewerApp: App {
    @StateObject private var model = ViewerModel()
    var body: some Scene {
        WindowGroup { ConnectionPanel().environmentObject(model) }
        WindowGroup("Shared target", for: String.self) { $id in
            if let id { StreamPanel(id: id).environmentObject(model) }
        }.defaultSize(width: 1000, height: 750)
    }
}
struct ConnectionPanel: View {
    @EnvironmentObject var model: ViewerModel
    @Environment(\.openWindow) private var openWindow
    @State private var autoOpened = false
    var body: some View {
        VStack(alignment: .leading) {
            Text("Shared Window Probe").font(.largeTitle)
            TextEditor(text: $model.configurationText).font(.caption.monospaced()).frame(height: 130)
            Button("Connect with pinned certificate") { model.connect() }
            Text(model.message)
            List(Array(model.targets.enumerated()), id: \.offset) { _, target in
                HStack {
                    VStack(alignment: .leading) { Text(target["label"] as? String ?? "Target"); Text(target["state"] as? String ?? "unknown").font(.caption) }
                    Spacer()
                    if let id = target["id"] as? String { Button("Open stream") { openWindow(value: id) } }
                }
            }
        }.padding(24).onAppear {
            if model.config == nil, let connection = ProcessInfo.processInfo.environment["SLZ_PROBE_CONNECTION"] {
                model.configurationText = connection; model.connect()
            }
        }.onChange(of: model.targets.count) { _, _ in
            if !autoOpened, let mode = ProcessInfo.processInfo.environment["SLZ_PROBE_AUTO_OPEN"], !model.targets.isEmpty {
                autoOpened = true
                for target in mode == "all" ? model.targets : Array(model.targets.prefix(1)) {
                    if let id = target["id"] as? String { openWindow(value: id) }
                }
            }
        }
    }
}
