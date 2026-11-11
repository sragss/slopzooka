import SwiftUI
@main struct IOSFixture: App {
    var body: some Scene { WindowGroup { FixtureView() } }
}
struct FixtureView: View {
    @State private var nonce = "ready"
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Slz iPhone Preview").font(.largeTitle.bold())
            Text("Nonce: \(nonce)").font(.title2.monospaced())
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                let time = context.date.timeIntervalSince1970
                Text(String(format: "Clock: %.1f", time)).monospaced()
                GeometryReader { geometry in
                    RoundedRectangle(cornerRadius: 6).fill(.orange).frame(width: 38, height: 18)
                        .offset(x: (geometry.size.width - 38) * (time.truncatingRemainder(dividingBy: 4) / 4))
                }.frame(height: 24)
            }
            Text("Small text: ABCDEFG abcdefg 0123456789").font(.footnote.monospaced())
            Text("Native iOS Simulator window").foregroundStyle(.secondary)
            Spacer()
        }.padding(28).preferredColorScheme(.dark)
        .task {
            let file = URL.documentsDirectory.appendingPathComponent("preview-state.json")
            while !Task.isCancelled {
                if let data = try? Data(contentsOf: file),
                   let state = try? JSONDecoder().decode([String: String].self, from: data),
                   let value = state["nonce"] { nonce = String(value.prefix(40)) }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }
}
