import SwiftUI

@main struct ProbeFixtureApp: App {
    var body: some Scene { WindowGroup { FixtureView() } }
}
struct FixtureView: View {
    @State private var nonce = "initial"
    @State private var draft = "Unfinished draft"
    @State private var setting = false
    @State private var counter = 0
    @State private var showDialog = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Identity and freshness") {
                    Text("Nonce: \(nonce)").accessibilityIdentifier("nonce")
                    Text("Count: \(counter)").accessibilityIdentifier("counter")
                    Button("Increment") { counter += 1 }.accessibilityIdentifier("increment")
                }
                Section("Settings") {
                    Toggle("Dark appearance", isOn: $setting).accessibilityIdentifier("setting")
                    TextField("Draft", text: $draft).accessibilityIdentifier("draft")
                    Button("Show dialog") { showDialog = true }.accessibilityIdentifier("show-dialog")
                }
                Section("Scrolling") { ForEach(0..<50) { i in Text("Row \(i) • Small text ABCDEFG 0123456789").accessibilityIdentifier("row-\(i)") } }
            }
            .navigationTitle("Probe Settings")
            .preferredColorScheme(setting ? .dark : .light)
            .alert("Fixture dialog", isPresented: $showDialog) { Button("Done", role: .cancel) {} }
            .onOpenURL { url in
                guard url.scheme == "slz-probe", url.host == "nonce",
                      let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "value" })?.value else { return }
                nonce = String(value.prefix(80))
            }
        }
    }
}
