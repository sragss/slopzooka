import SwiftUI

struct WorkspaceFrontendButton: View {
    let baseURL: URL?
    let workspaceId: String
    @State private var expanded = false
    @State private var frontends: [FrontendSummary] = []
    @State private var warning: String?
    @State private var isLoading = true

    var body: some View {
        Button { expanded.toggle() } label: {
            Image(systemName: "globe")
                .font(.system(size: 26, weight: .medium))
                .frame(width: 72, height: 72)
                .overlay(alignment: .topTrailing) {
                    ZStack {
                        if isLoading {
                            ProgressView().controlSize(.mini).tint(.black)
                                .frame(width: 12, height: 12)
                        } else if warning != nil {
                            Image(systemName: "exclamationmark")
                                .font(.caption2.weight(.bold))
                        } else {
                            Text(frontends.count > 99 ? "99+" : "\(frontends.count)")
                                .font(.caption2.weight(.semibold).monospacedDigit())
                        }
                    }
                    .foregroundStyle(.black)
                    .padding(.horizontal, 6)
                    .frame(minWidth: 24, minHeight: 24)
                    .background(warning == nil ? Color("AccentHighlight") : .orange, in: Capsule())
                    .offset(x: -2, y: 2)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
        }
        .buttonStyle(TerminalGlassControlStyle(shape: Circle()))
        .disabled(baseURL == nil)
        .accessibilityLabel("Show workspace frontends")
        .accessibilityValue(accessibilityStatus)
        .popover(isPresented: $expanded, arrowEdge: .top) {
            ScrollView {
                FrontendListView(frontends: frontends, warning: warning, baseURL: baseURL, workspaceId: workspaceId)
            }
            .frame(width: 420).frame(maxHeight: 420)
        }
        .task(id: baseURL) {
            frontends = []
            warning = nil
            isLoading = baseURL != nil
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
                isLoading = false
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private var accessibilityStatus: String {
        guard baseURL != nil else { return "Unavailable" }
        if isLoading { return "Searching" }
        if warning != nil { return "\(frontends.count) frontends, discovery notice" }
        return "\(frontends.count) frontends"
    }
}

struct FrontendListView: View {
    let frontends: [FrontendSummary]
    let warning: String?
    let baseURL: URL?
    var workspaceId: String? = nil
    @EnvironmentObject private var windows: WindowGateway
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
                Text(workspaceId == nil
                    ? "Ask your agent to start a web app on your Mac, or add a URL."
                    : "No frontends for this workspace yet. Ask your agent to start a web app on your Mac.")
                    .font(.caption)
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
        .padding(workspaceId == nil ? 0 : 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func frontendRow(_ frontend: FrontendSummary) -> some View {
        HStack(spacing: 0) {
            Button {
                Task { await open(frontend) }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "globe")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 40, height: 40)
                        .background(.quaternary, in: Circle())
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 5) {
                        Text(frontend.displayTitle)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        if frontend.status == "starting" || frontend.status == "stopped" {
                            Text(frontend.status == "stopped" ? "Stopped" : "Waiting for response")
                                .font(.caption).foregroundStyle(.orange)
                        } else {
                            Text(frontend.source == "local" ? frontend.hostname : (frontend.project ?? (frontend.transport == "direct" ? "Web" : "On your Mac")))
                                .font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    if opening == frontend.id {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.up.forward")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverEffectDisabled()
        }
        .modifier(LauncherRowSurface())
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
            try windows.openPreview(frontend, base: baseURL)
        } catch { self.error = error.localizedDescription }
    }
}
