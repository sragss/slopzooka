import SwiftUI

struct WorkspaceFrontendButton: View {
    let baseURL: URL?
    let workspaceId: String
    @State private var expanded = false
    @State private var frontends: [FrontendSummary] = []
    @State private var warning: String?
    var body: some View {
        HStack(spacing: 0) {
            if !frontends.isEmpty || warning != nil {
                Button { expanded.toggle() } label: {
                    Image(systemName: "globe").font(.title3)
                }
                .buttonStyle(.plain)
                .padding(10)
                .background(.regularMaterial, in: Circle())
                .help("Workspace frontends").accessibilityLabel("Show workspace frontends")
                .popover(isPresented: $expanded) {
                    ScrollView {
                        FrontendListView(frontends: frontends, warning: warning, baseURL: baseURL, workspaceId: workspaceId)
                    }.frame(width: 420).frame(maxHeight: 420)
                }
            }
        }
        .task(id: baseURL) {
            frontends = []
            warning = nil
            guard let baseURL else { return }
            while !Task.isCancelled {
                do {
                    let catalog = try await CompanionAPI.request(
                        FrontendCatalog.self, base: baseURL, path: "/api/frontends")
                    guard !Task.isCancelled else { return }
                    frontends = catalog.frontends.filter { $0.workspaceId == workspaceId && $0.workspaceVisible != false && !$0.isService }
                    warning = catalog.warning
                } catch {
                    guard !Task.isCancelled else { return }
                    warning = error.localizedDescription
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}

struct FrontendListView: View {
    let frontends: [FrontendSummary]
    let warning: String?
    let baseURL: URL?
    var workspaceId: String? = nil
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var error: String?
    @State private var failureAction = "complete this action"
    @State private var opening: String?
    @State private var urlInput = ""
    @State private var saving = false
    @State private var showAddURL = false
    @State private var updatedFrontends: [FrontendSummary]?
    private var visibleFrontends: [FrontendSummary] {
        (updatedFrontends ?? frontends).filter { frontend in
            workspaceId == nil || (frontend.workspaceId == workspaceId && frontend.workspaceVisible != false && !frontend.isService)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Frontends", systemImage: "globe").font(.headline)
                Spacer()
                if workspaceId == nil {
                    Button {
                        showAddURL.toggle()
                    } label: {
                        Label(showAddURL ? "Cancel" : "Add URL", systemImage: showAddURL ? "xmark" : "plus")
                    }
                    .disabled(saving || baseURL == nil)
                }
            }
            if let warning {
                DisclosureGroup("Discovery notice") { Text(warning).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                    .font(.caption).foregroundStyle(.orange)
            }
            if let error {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Couldn’t \(failureAction). Try again, or check Details.").foregroundStyle(.red)
                    DisclosureGroup("Details") { Text(error).textSelection(.enabled) }
                }.font(.caption)
            }
            if visibleFrontends.allSatisfy({ $0.isService }) && warning == nil {
                Text("Ask your agent to start a web app on your Mac, or add a URL.").font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(visibleFrontends.filter { !$0.isService }) { frontend in
                frontendRow(frontend)
            }
            let services = visibleFrontends.filter { $0.isService }
            if !services.isEmpty {
                DisclosureGroup("Other services (\(services.count))") {
                    ForEach(services) { frontend in frontendRow(frontend) }
                }.font(.subheadline)
            }
            if showAddURL {
                HStack {
                    TextField("http://localhost:3000 or https://…", text: $urlInput)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onSubmit { Task { await addURL() } }
                    Button("Add URL") { Task { await addURL() } }
                        .disabled(
                            saving || urlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || baseURL == nil
                        )
                }
            }
        }
        .onChange(of: frontends) { _, _ in updatedFrontends = nil }
        .onChange(of: baseURL) { _, _ in updatedFrontends = nil; error = nil }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 24))
    }

    @ViewBuilder
    private func frontendRow(_ frontend: FrontendSummary) -> some View {
        Button {
            Task { await open(frontend) }
        } label: {
            HStack {
                VStack(alignment: .leading) {
                    Text(frontend.displayTitle).lineLimit(1)
                    if frontend.status == "starting" || frontend.status == "stopped" {
                        Text(frontend.status == "stopped" ? "Stopped" : "Waiting for response")
                            .font(.caption).foregroundStyle(.orange)
                    } else {
                        Text(frontend.source == "local" ? frontend.hostname : (frontend.project ?? (frontend.transport == "direct" ? "Web" : "On your Mac")))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if opening == frontend.id { ProgressView() } else { Image(systemName: "arrow.up.right.square") }
            }.padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
        }
        .disabled(opening != nil || frontend.status == "stopped")
        .contextMenu {
            if frontend.source == "manual" {
                Button("Remove URL", role: .destructive) { Task { await remove(frontend) } }
            }
        }
    }

    private func addURL() async {
        guard !saving, let baseURL else { return }
        saving = true
        error = nil
        failureAction = "save this URL"
        defer { saving = false }
        do {
            _ = try await CompanionAPI.request(
                OpenFrontendResponse.self, base: baseURL, path: "/api/frontends",
                method: "POST",
                body: JSONSerialization.data(withJSONObject: [
                    "url": urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
                ]))
            urlInput = ""
            showAddURL = false
            updatedFrontends = try await CompanionAPI.request(
                FrontendCatalog.self, base: baseURL, path: "/api/frontends"
            ).frontends
        } catch { self.error = error.localizedDescription }
    }

    private func remove(_ frontend: FrontendSummary) async {
        guard let baseURL else { return }
        error = nil
        failureAction = "remove this URL"
        do {
            _ = try await CompanionAPI.request(
                APIAcknowledgement.self, base: baseURL,
                path: "/api/frontends/\(frontend.id)", method: "DELETE")
            updatedFrontends = try await CompanionAPI.request(
                FrontendCatalog.self, base: baseURL, path: "/api/frontends"
            ).frontends
        } catch { self.error = error.localizedDescription }
    }

    private func open(_ frontend: FrontendSummary) async {
        guard let baseURL else { return }
        opening = frontend.id
        error = nil
        failureAction = "open this frontend"
        defer { opening = nil }
        do {
            let result = try await CompanionAPI.request(
                OpenFrontendResponse.self, base: baseURL, path: "/api/frontends/open", method: "POST",
                body: JSONSerialization.data(withJSONObject: ["id": frontend.id]))
            guard var url = URLComponents(string: result.frontend.url) else { throw URLError(.badURL) }
            if let port = result.exposedPort, let token = result.accessToken {
                url.scheme = "http"
                url.host = baseURL.host
                url.port = port
                url.path = "/__slz_access"
                url.fragment = nil
                url.queryItems = [URLQueryItem(name: "token", value: token)]
            }
            guard let resolvedURL = url.url else { throw URLError(.badURL) }
            let id = "\(baseURL.host ?? "host"):\(baseURL.port ?? 80):\(frontend.id)"
            appModel.registerPreview(
                PreviewWindowPayload(id: id, title: frontend.displayTitle, urlString: resolvedURL.absoluteString))
            openWindow(id: "preview", value: id)
        } catch { self.error = error.localizedDescription }
    }
}
