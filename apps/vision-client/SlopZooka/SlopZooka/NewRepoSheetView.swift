import SwiftUI

struct NewRepoSheetView: View {
    let owners: [RepoOwnerSummary]
    let suggestedOwnerLogin: String?
    let selectedTool: LaunchTarget
    let isSubmitting: Bool
    let onSubmit: (String, String, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedOwnerLogin = ""
    @State private var rawRepoName = ""
    @State private var isPrivate = true

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("New repository")
                        .font(.title2.weight(.semibold))

                    Text("Create a GitHub repository and open \(selectedTool.title).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

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

                VStack(alignment: .leading, spacing: 8) {
                    Text("Repo Name")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    TextField("Type or dictate a repo name", text: $rawRepoName)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Repository")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)

                        Text(
                            "\(selectedOwnerLogin)/\(normalizedRepoName.isEmpty ? "repository-name" : normalizedRepoName)"
                        )
                        .font(.footnote.monospaced())
                        .foregroundStyle(normalizedRepoName.isEmpty ? .tertiary : .primary)
                    }
                    .padding(12)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                Toggle("Private Repository", isOn: $isPrivate)

                Spacer()

                HStack(spacing: 10) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .buttonStyle(.bordered)

                    Button(isSubmitting ? "Creating..." : "Create & Launch") {
                        onSubmit(selectedOwnerLogin, normalizedRepoName, isPrivate)
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
        !selectedOwnerLogin.isEmpty && !normalizedRepoName.isEmpty && !isSubmitting
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
