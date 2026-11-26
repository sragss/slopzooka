import SwiftUI

struct NameEditorButton: View {
    let title: String
    let isAvailable: Bool
    var subject = "window"
    var isPending = false
    var onEditingChanged: (Bool) -> Void = { _ in }
    let save: (String) async throws -> Void

    @State private var isPresented = false
    @State private var isSaving = false
    @State private var draft = ""
    @State private var error: String?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            if isPending {
                Image(systemName: "clock")
                    .font(.caption)
                    .accessibilityLabel("Name waiting to sync")
            }
            Button {
                draft = title
                error = nil
                isPresented = true
            } label: {
                Image(systemName: "pencil")
                    .font(.body.weight(.semibold))
                    .frame(width: 48, height: 48)
            }
            .buttonStyle(.borderless)
            .disabled(!isAvailable || isSaving)
            .accessibilityLabel("Edit \(subject) name")
            .accessibilityValue(title)
            .help("Edit \(subject) name")
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                editor
            }
            .onChange(of: isPresented) { _, presented in onEditingChanged(presented) }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename \(subject)").font(.headline)
            TextField("\(subject.capitalized) name", text: $draft)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($fieldFocused)
                .disabled(isSaving)
                .onSubmit(commit)
                .onChange(of: draft) { _, _ in error = nil }

            if let error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .accessibilityAddTraits(.updatesFrequently)
            }

            HStack {
                if isSaving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                Button("Save", action: commit)
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .defaultFocus($fieldFocused, true)
        .interactiveDismissDisabled(isSaving)
    }

    private func commit() {
        guard !isSaving, isPresented else { return }
        isSaving = true
        fieldFocused = false
        error = nil
        let name = draft
        Task {
            defer { isSaving = false }
            do {
                if name != title { try await save(name) }
                isPresented = false
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
