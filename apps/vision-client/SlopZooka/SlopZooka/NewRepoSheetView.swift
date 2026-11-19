import SwiftUI

struct NewRepoSheetView: View {
    let owners: [RepoOwnerSummary]
    let suggestedOwnerLogin: String?
    let selectedTool: LaunchTarget
    let isSubmitting: Bool
    let error: String?
    let onSubmit: (String?, String, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedOwnerLogin = ""
    @State private var rawRepoName = ""
    @State private var createOnGitHub = false
    @State private var isPrivate = true

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("New repo")
                        .font(.title2.weight(.semibold))

                    Text(createOnGitHub ? "Create on GitHub and open \(selectedTool.title)." : "Create on this Mac and open \(selectedTool.title).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Toggle("Create on GitHub", isOn: $createOnGitHub)
                    .disabled(owners.isEmpty || isSubmitting)
                if createOnGitHub {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Owner")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        Picker("Owner", selection: $selectedOwnerLogin) {
                            ForEach(owners) { owner in
                                Text(owner.login).tag(owner.login)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Repo Name")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    TextField("Type or dictate a repo name", text: $rawRepoName)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Repo")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)

                        Text(
                            "\(createOnGitHub ? selectedOwnerLogin : "On this Mac")/\(normalizedRepoName.isEmpty ? "repo-name" : normalizedRepoName)"
                        )
                        .font(.footnote.monospaced())
                        .foregroundStyle(normalizedRepoName.isEmpty ? .tertiary : .primary)
                    }
                    .padding(12)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                if createOnGitHub { Toggle("Private Repo", isOn: $isPrivate) }

                if let error {
                    Text("Couldn’t create the repo.").foregroundStyle(.orange)
                    DisclosureGroup("Details") { Text(error).font(.caption).textSelection(.enabled) }
                }
                if isSubmitting {
                    ProgressView("Creating repo on your Mac…")
                    Text("Closing this window stops waiting; a repo already created is kept.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()

                HStack(spacing: 10) {
                    Button(isSubmitting ? "Stop Waiting" : "Cancel") {
                        dismiss()
                    }
                    .buttonStyle(.bordered)

                    Button(isSubmitting ? "Creating..." : "Create & Launch") {
                        onSubmit(createOnGitHub ? selectedOwnerLogin : nil, normalizedRepoName, isPrivate)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSubmit)
                }
            }
            .padding(24)
            .navigationBarHidden(true)
        }
        .frame(minWidth: 520, minHeight: 420)
        .onAppear {
            if selectedOwnerLogin.isEmpty {
                selectedOwnerLogin = suggestedOwnerLogin ?? owners.first?.login ?? ""
            }
        }
    }

    private var normalizedRepoName: String {
        normalizeRepoSlug(rawRepoName)
    }

    private var canSubmit: Bool {
        (!createOnGitHub || !selectedOwnerLogin.isEmpty) && !normalizedRepoName.isEmpty && !isSubmitting
    }
}

private func normalizeRepoSlug(_ value: String) -> String {
    value
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
        .replacingOccurrences(of: "[\\s_]+", with: "-", options: .regularExpression)
        .replacingOccurrences(of: "[^a-z0-9-]+", with: "", options: .regularExpression)
        .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
        .replacingOccurrences(of: "^-|-$", with: "", options: .regularExpression)
}
