import AVFAudio
import Combine
import Speech
import SwiftUI

@MainActor
final class PlaygroundInbox: ObservableObject {
    @Published private(set) var messages: [TerminalVoiceCommand] = []

    func receive(_ command: TerminalVoiceCommand) {
        guard !messages.contains(where: { $0.commandID == command.commandID }) else { return }
        messages.append(command)
    }
}

@main
struct VoicePlaygroundApp: App {
    @StateObject private var inbox: PlaygroundInbox
    @StateObject private var voice: TerminalVoiceController

    init() {
        let inbox = PlaygroundInbox()
        _inbox = StateObject(wrappedValue: inbox)
        _voice = StateObject(wrappedValue: TerminalVoiceController(capture: SpeechCaptureController(),
            isAvailable: { _, _ in true }, rename: { _, _, _ in },
            deliver: { [weak inbox] command in inbox?.receive(command) }))
    }

    var body: some Scene {
        WindowGroup("Voice Playground") {
            VoicePlaygroundView()
                .environmentObject(inbox)
                .environmentObject(voice)
        }
        .defaultSize(width: 1000, height: 680)
        .windowStyle(.plain)
        .windowResizability(.contentSize)
    }
}

private struct VoicePlaygroundView: View {
    @EnvironmentObject private var inbox: PlaygroundInbox
    @EnvironmentObject private var voice: TerminalVoiceController
    @State private var microphoneReady = SFSpeechRecognizer.authorizationStatus() == .authorized
        && AVAudioApplication.shared.recordPermission == .granted
    @State private var isPreparing = false
    @State private var permissionError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Voice Playground").font(.largeTitle.weight(.semibold))
                    Text("Hold. Speak. Release.").font(.title3).foregroundStyle(.secondary)
                }
                Spacer()
                Text("Local demo").font(.caption.weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.thinMaterial, in: Capsule())
            }
            Divider()
            if inbox.messages.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Your messages land here.").font(.title2.weight(.medium))
                    Text("A chunky click and a quick flash mean it sent.").foregroundStyle(.secondary)
                }
                .padding(.top, 14)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            ForEach(Array(inbox.messages.enumerated()), id: \.element.commandID) { index, message in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Sent \(index + 1)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    Text(message.text).font(.title3).textSelection(.enabled)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(message.commandID)
                            }
                        }
                        .padding(.vertical, 12)
                        .padding(.trailing, 150)
                    }
                    .onChange(of: inbox.messages.count) { _, _ in
                        if let id = inbox.messages.last?.commandID { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }
            }
            Text("Nothing here goes to a terminal. No pairing needed.")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.bottom, 8)
        }
        .padding(32)
        .frame(width: 1000, height: 680)
        .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 18))
        .modifier(TerminalVoiceOverlay(id: "playground", isAvailable: microphoneReady, canRename: false))
        .overlay {
            if !microphoneReady {
                VStack(spacing: 18) {
                    Text("Let's hear it.").font(.title.weight(.semibold))
                    Text("Enable the microphone and speech recognition, then try a hold.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Button(isPreparing ? "Getting ready…" : "Enable Microphone") {
                        Task { await prepareMicrophone() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isPreparing)
                    if let permissionError {
                        Text(permissionError).font(.caption).foregroundStyle(.orange)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(28)
                .frame(width: 480)
                .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 24))
            }
        }
    }

    private func prepareMicrophone() async {
        isPreparing = true
        defer { isPreparing = false }
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speech == .authorized else {
            permissionError = "Allow Speech Recognition for Voice Playground in Settings, then try again."
            return
        }
        let granted = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
        microphoneReady = granted
        permissionError = granted ? nil : "Allow Microphone for Voice Playground in Settings, then try again."
    }
}
