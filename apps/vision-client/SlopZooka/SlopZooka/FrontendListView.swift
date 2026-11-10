import SwiftUI

struct WorkspaceFrontendButton: View {
    @EnvironmentObject private var client: CompanionClient
    let hostID: String?
    let workspaceId: String
    @State private var expanded = false
    private var catalog: FrontendCatalog { client.frontends(for: hostID) }
    private var frontends: [FrontendSummary] { catalog.visibleFrontends(workspaceID: workspaceId) }

    var body: some View {
        Button { expanded.toggle() } label: {
            Image(systemName: "globe")
                .font(.system(size: 26, weight: .medium))
                .frame(width: 72, height: 72)
        }
        .buttonStyle(TerminalGlassControlStyle(shape: Circle()))
        // The badge has its own foreground plane, outside the globe's glass.
        .overlay(alignment: .topTrailing) {
            if !frontends.isEmpty {
                Text(frontends.count > 99 ? "99+" : "\(frontends.count)")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.black)
                    .padding(.horizontal, 6)
                    .frame(minWidth: 24, minHeight: 24)
                    .background(Color("AccentHighlight"), in: Capsule())
                    .compositingGroup()
                    .clipShape(Capsule())
                    .offset(x: -2, y: 2)
                    .offset(z: 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .disabled(hostID == nil)
        .accessibilityLabel("Show workspace frontends")
        .accessibilityValue(accessibilityStatus)
        .popover(isPresented: $expanded, arrowEdge: .top) {
            ScrollView {
                FrontendListView(hostID: hostID, workspaceId: workspaceId).id(hostID)
            }
            .frame(width: 420).frame(maxHeight: 420)
        }
    }

    private var accessibilityStatus: String {
        guard hostID != nil else { return "Unavailable" }
        if catalog.warning != nil { return "\(frontends.count) frontends, discovery notice" }
        return "\(frontends.count) frontends"
    }
}

struct FrontendListView: View {
    let hostID: String?
    var workspaceId: String? = nil
    @EnvironmentObject private var windows: WindowGateway
    @EnvironmentObject private var client: CompanionClient
    @State private var error: String?
    @State private var failureAction = "complete this action"
    @State private var showAddURL = false
    private var catalog: FrontendCatalog { client.frontends(for: hostID) }
    private var visibleFrontends: [FrontendSummary] {
        catalog.visibleFrontends(workspaceID: workspaceId)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Frontends", systemImage: "globe").font(.headline)
                Spacer()
                if workspaceId == nil {
                    Button("Add URL", systemImage: "plus") { showAddURL = true }
                        .disabled(hostID == nil)
                }
            }
            if let warning = catalog.warning {
                DisclosureGroup("Discovery notice") { Text(warning).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                    .font(.caption).foregroundStyle(.orange)
            }
            if let error {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Couldn’t \(failureAction). Try again, or check Details.").foregroundStyle(.red)
                    DisclosureGroup("Details") { Text(error).textSelection(.enabled) }
                }.font(.caption)
            }
            if visibleFrontends.allSatisfy({ $0.isService }) && catalog.warning == nil {
                Text(workspaceId == nil
                    ? "Ask your agent to start a web app on your Mac, or add a URL."
                    : "No frontends for this workspace yet. Ask your agent to start a web app on your Mac.").font(.caption)
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
        }
        .padding(workspaceId == nil ? 0 : 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $showAddURL) {
            if let hostID { AddFrontendSheet(hostID: hostID) }
        }
    }

    @ViewBuilder
    private func frontendRow(_ frontend: FrontendSummary) -> some View {
        HStack(spacing: 0) {
            Button {
                open(frontend)
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
                        if let availability = frontend.presentation, !availability.available {
                            Text(availability.message ?? "Unavailable on this connection")
                                .font(.caption).foregroundStyle(.orange)
                        } else if frontend.status == "starting" || frontend.status == "stopped" {
                            Text(frontend.status == "stopped" ? "Stopped" : "Waiting for response")
                                .font(.caption).foregroundStyle(.orange)
                        } else {
                            Text(frontend.source == "local" ? frontend.hostname : (frontend.project ?? (frontend.transport == "direct" ? "Web" : "On your Mac")))
                                .font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "arrow.up.forward")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(hostID.map { client.frontendOpenError(id: frontend.id, hostID: $0) != nil } != false)
            .hoverEffectDisabled()
        }
        .modifier(LauncherRowSurface())
        .contextMenu {
            if frontend.source == "manual" {
                Button("Remove URL", role: .destructive) { Task { await remove(frontend) } }
            }
        }
    }

    private func remove(_ frontend: FrontendSummary) async {
        guard let hostID else { return }
        error = nil
        failureAction = "remove this URL"
        do {
            try await client.removeFrontend(hostID: hostID, id: frontend.id)
        } catch { self.error = error.localizedDescription }
    }

    private func open(_ frontend: FrontendSummary) {
        guard let hostID else { return }
        error = nil
        failureAction = "open this frontend"
        do {
            try windows.openPreview(frontend, hostID: hostID)
        } catch { self.error = error.localizedDescription }
    }
}

private struct AddFrontendSheet: View {
    let hostID: String
    @EnvironmentObject private var client: CompanionClient
    @Environment(\.dismiss) private var dismiss
    @State private var urlInput = ""
    @State private var saving = false
    @State private var error: String?
    @FocusState private var urlFocused: Bool
    private var url: String { urlInput.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Add URL").font(.title2.weight(.semibold))
            TextField("http://localhost:3000 or https://…", text: $urlInput)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .focused($urlFocused)
                .onSubmit { Task { await save() } }
                .disabled(saving)
            if let error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button(saving ? "Adding…" : "Add URL") { Task { await save() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(saving || url.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
        .task {
            await Task.yield()
            urlFocused = true
        }
    }

    private func save() async {
        guard !saving, !url.isEmpty else { return }
        saving = true
        error = nil
        defer { saving = false }
        do {
            try await client.addFrontend(hostID: hostID, url: url)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
