import SwiftUI
import Combine
import AVFoundation

struct NativePreviewView: View {
    let id: String
    let payload: NativeWindowPayload
    let revision: Int
    @EnvironmentObject private var windows: WindowGateway
    @Environment(\.scenePhase) private var phase
    @StateObject private var model = NativePreviewModel()

    var body: some View {
        ZStack {
            NativeVideoSurface(layer: model.layer)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let message = model.message {
                ContentUnavailableView("Mac Window", systemImage: "macwindow", description: Text(message))
            }
        }
        .background(.black)
        .background(PreviewGeometry(size: model.contentSize ?? CGSize(width: payload.source.contentWidth, height: payload.source.contentHeight)))
        .ornament(attachmentAnchor: .scene(.top), contentAlignment: .bottom) {
            HStack {
                Text("\(payload.source.application) · \(payload.source.title)").lineLimit(1).frame(maxWidth: 350)
                Button("Reload", systemImage: "arrow.clockwise") { windows.reload(id: id) }.labelStyle(.iconOnly)
                Menu("Preview actions", systemImage: "ellipsis") {
                    Button("Close Preview", systemImage: "xmark") { windows.close(id: id) }
                }.labelStyle(.iconOnly)
            }.padding(12).glassBackgroundEffect()
        }
        .task(id: revision) { if phase != .background { model.start(payload) } }
        .onChange(of: phase) { previous, next in if next == .background { model.stop() } else if previous == .background { model.start(payload) } }
        .onDisappear { model.stop() }
    }
}

@MainActor
private final class NativePreviewModel: ObservableObject {
    let layer = AVSampleBufferDisplayLayer()
    @Published var message: String? = "Connecting to Mac window…"
    @Published var contentSize: CGSize?
    private var socket: VideoSocket?
    private var source: NativeWindowPayload?
    private var channelID: UUID?
    private var receiveWindow: VideoReceiveWindow?
    private var samples = WindowVideoSamples()
    private var formatID: UInt64 = 0
    private var terminalState = false
    private var retry: Task<Void, Never>?
    private var attempts = 0
    private let log = AppLog("window-preview")

    func start(_ source: NativeWindowPayload, retrying: Bool = false) {
        stop()
        if !retrying { attempts = 0 }
        self.source = source
        terminalState = false
        let id = UUID(); channelID = id
        message = "Connecting to Mac window…"
        do {
            let (connection, request) = try source.route.windowChannel(id: id, sourceID: source.source.id)
            let socket = VideoSocket(connection: connection, request: request, consume: { [weak self] packets, deadline, complete in
                Task { @MainActor in
                    guard let self, self.channelID == id, ProcessInfo.processInfo.systemUptime < deadline else { complete(false); return }
                    complete(self.consume(packets))
                }
            }, ended: { [weak self] reason in
                Task { @MainActor in
                    guard let self, self.channelID == id else { return }
                    self.disconnected(reason, id: id)
                }
            })
            self.socket = socket
            socket.start()
            log.info("stream.connecting")
        } catch { message = "Reconnect to your Mac to share this window." }
    }
    private func disconnected(_ reason: VideoDisconnect, id: UUID) {
        clearImage()
        source?.route.releaseWindowChannel(id: id)
        log.info("stream.ended", ["reason": reason.rawValue])
        guard !terminalState else { return }
        message = reason.message
        guard reason.retryable, attempts < 3, let source else { return }
        attempts += 1
        let delay = Double(1 << (attempts - 1))
        message = "\(reason.message) Reconnecting…"
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.channelID == id else { return }
            self.start(source, retrying: true)
        }
    }
    private func clearImage() { layer.sampleBufferRenderer.flush(removingDisplayedImage: true) }
    func stop() {
        retry?.cancel(); retry = nil
        socket?.stop(); socket = nil
        if let channelID { source?.route.releaseWindowChannel(id: channelID) }
        channelID = nil; source = nil
        receiveWindow = nil; samples.reset(); formatID = 0
        layer.sampleBufferRenderer.flush(removingDisplayedImage: true)
    }
    private func consume(_ packets: [VideoPacket]) -> Bool {
        do {
            for packet in packets {
                let now = ProcessInfo.processInfo.systemUptime
                if receiveWindow == nil { receiveWindow = VideoReceiveWindow(streamID: packet.header.streamID, now: now) }
                let accepted = try receiveWindow!.receive(packet, now: now)
                if packet.header.kind == .state {
                    if let state = packet.header.state, state != .idle {
                        samples.reset(); formatID = 0
                        layer.sampleBufferRenderer.flush(removingDisplayedImage: true)
                        terminalState = state != .waiting
                        switch state {
                        case .waiting: message = "Waiting for a fresh frame…"
                        case .locked: message = "Unlock your Mac to share this window. Then reload."
                        case .permissionRequired: message = "Allow Screen Recording on your Mac. Then reload."
                        case .sourceGone: message = "This window is no longer available. Select a window from the launcher."
                        case .failed: message = "Mac capture stopped. Reload to try again."
                        case .idle: break
                        }
                    }
                    continue
                }
                guard accepted else { continue }
                if formatID != packet.header.formatID {
                    layer.sampleBufferRenderer.flush(removingDisplayedImage: true)
                    formatID = packet.header.formatID
                }
                guard layer.sampleBufferRenderer.isReadyForMoreMediaData else { return false }
                layer.sampleBufferRenderer.enqueue(try samples.sample(packet))
                guard layer.sampleBufferRenderer.status != .failed else { return false }
                let size = CGSize(width: packet.header.contentWidth, height: packet.header.contentHeight)
                if contentSize != size { contentSize = size }
                if message != nil { message = nil }
                attempts = 0
            }
            return true
        } catch { return false }
    }
}

private struct NativeVideoSurface: UIViewRepresentable {
    let layer: AVSampleBufferDisplayLayer
    func makeUIView(context: Context) -> Surface {
        let view = Surface(); view.video = layer; view.layer.addSublayer(layer); layer.videoGravity = .resizeAspect
        return view
    }
    func updateUIView(_ view: Surface, context: Context) {}
    final class Surface: UIView {
        var video: AVSampleBufferDisplayLayer?
        override func layoutSubviews() { super.layoutSubviews(); video?.frame = bounds }
    }
}
