import SwiftUI

struct TerminalNameHeader: View {
    let payload: TerminalWindowPayload
    let isAvailable: Bool
    @Binding var editingName: TerminalVoiceController.NameTarget?
    @EnvironmentObject private var windows: WindowGateway
    @EnvironmentObject private var voice: TerminalVoiceController
    private let outline = RoundedRectangle(cornerRadius: 24, style: .continuous)

    var body: some View {
        HStack(spacing: 0) {
            if let project = payload.projectName {
                Text(project).frame(maxWidth: 180)
                    .fixedSize(horizontal: true, vertical: false).padding(.horizontal, 18)
            }
            if let workspace = payload.workspaceName {
                name(workspace, target: .workspace, leadingDivider: payload.projectName != nil)
            }
            name(payload.headerTitle, target: .window,
                leadingDivider: payload.projectName != nil || payload.workspaceName != nil)
        }
        .font(.system(size: 28, weight: .bold, design: .rounded))
        .lineLimit(1)
        .frame(minHeight: 54)
        .fixedSize(horizontal: false, vertical: true)
        .clipShape(outline)
        .contentShape(outline)
        .glassBackgroundEffect(in: outline)
        .accessibilityAddTraits(.isHeader)
    }

    private func name(_ text: String, target: TerminalVoiceController.NameTarget, leadingDivider: Bool) -> some View {
        HStack(spacing: 0) {
            Button { voice.activateRename(payload.id, target: target) } label: {
                Text(text)
                    .frame(maxWidth: 190)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.leading, 18)
                    .padding(.trailing, 4)
                    .frame(maxHeight: .infinity)
            }
            .buttonStyle(HeaderNameStyle(shape: HeaderSegment(leadingDivider: leadingDivider)))
            .disabled(!isAvailable || voice.isSubmitting || editingName != nil)
            .accessibilityLabel("Rename \(target.rawValue), \(text)")
            .accessibilityHint("Start voice naming for this \(target.rawValue)")

            NameEditorButton(title: text,
                isAvailable: isAvailable && !voice.isSubmitting && !(voice.mode == .rename && voice.targetID == payload.id)
                    && (editingName == nil || editingName == target),
                subject: target.rawValue,
                onEditingChanged: { presented in
                    if presented { editingName = target }
                    else if editingName == target { editingName = nil }
                },
                save: { try await windows.rename(id: payload.id, name: $0, target: target) })
                .padding(.trailing, 10)
        }
        .overlay(alignment: .leading) {
            if leadingDivider {
                HeaderSlash().stroke(.secondary, lineWidth: 2)
                    .frame(width: HeaderSegment.dividerWidth)
                    .offset(x: -HeaderSegment.dividerWidth / 2)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

// Follow the leading separator when highlighting the voice rename button.
private struct HeaderSegment: Shape {
    let leadingDivider: Bool
    static let dividerWidth: CGFloat = 20
    static func halfSlant(height: CGFloat) -> CGFloat { min(dividerWidth / 2, height / 8) }

    func path(in rect: CGRect) -> Path {
        let slant = Self.halfSlant(height: rect.height)
        let left = leadingDivider ? slant : 0
        return Path { path in
            path.move(to: CGPoint(x: rect.minX + left, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX - left, y: rect.maxY))
            path.closeSubpath()
        }
    }
}

private struct HeaderSlash: Shape {
    func path(in rect: CGRect) -> Path {
        let slant = HeaderSegment.halfSlant(height: rect.height)
        return Path { path in
            path.move(to: CGPoint(x: rect.midX + slant, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX - slant, y: rect.maxY))
        }
    }
}

private struct HeaderNameStyle: ButtonStyle {
    let shape: HeaderSegment
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .overlay {
                shape.fill(.white.opacity(configuration.isPressed ? 0.12 : 0))
                    .allowsHitTesting(false)
            }
            .contentShape([.interaction, .hoverEffect], shape)
            .overlay {
                shape.fill(.white.opacity(0.08))
                    .hoverEffect { effect, isActive, _ in effect.opacity(isActive ? 1 : 0) }
                    .allowsHitTesting(false)
            }
            .opacity(isEnabled ? 1 : 0.4)
            .hoverEffectGroup()
    }
}
