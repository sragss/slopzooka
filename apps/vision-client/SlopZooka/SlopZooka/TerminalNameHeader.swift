import SwiftUI

struct TerminalNameHeader: View {
    let payload: TerminalWindowPayload
    let isAvailable: Bool
    @EnvironmentObject private var voice: TerminalVoiceController
    private let outline = RoundedRectangle(cornerRadius: 24, style: .continuous)

    var body: some View {
        HStack(spacing: 0) {
            if let project = payload.projectName {
                Text(project).padding(.horizontal, 28).padding(.vertical, 14)
            }
            if let workspace = payload.workspaceName {
                name(workspace, target: .workspace, leadingDivider: payload.projectName != nil, trailingDivider: true)
            }
            name(payload.title, target: .window,
                leadingDivider: payload.projectName != nil || payload.workspaceName != nil, trailingDivider: false)
        }
        .font(.system(size: 48, weight: .bold, design: .rounded))
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .fixedSize(horizontal: false, vertical: true)
        .clipShape(outline)
        .contentShape(outline)
        .glassBackgroundEffect(in: outline)
        .accessibilityAddTraits(.isHeader)
    }

    private func name(_ text: String, target: TerminalVoiceController.NameTarget,
        leadingDivider: Bool, trailingDivider: Bool) -> some View {
        Button { voice.activateRename(payload.id, target: target) } label: {
            Text(text)
                .padding(.horizontal, 28).padding(.vertical, 14)
                .frame(maxHeight: .infinity)
        }
        .buttonStyle(HeaderNameStyle(shape: HeaderSegment(leadingDivider: leadingDivider, trailingDivider: trailingDivider)))
        .overlay(alignment: .leading) {
            if leadingDivider {
                HeaderSlash().stroke(.secondary, lineWidth: 2)
                    .frame(width: HeaderSegment.dividerWidth)
                    .offset(x: -HeaderSegment.dividerWidth / 2)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .disabled(!isAvailable || voice.isSubmitting)
        .accessibilityLabel("Rename \(target.rawValue), \(text)")
        .accessibilityHint("Start voice naming for this \(target.rawValue)")
    }
}

// Adjacent segments share the same diagonal, including the half outside each
// layout cell. The outer header clips their highlights to its rounded corners.
private struct HeaderSegment: Shape {
    let leadingDivider: Bool
    let trailingDivider: Bool
    static let dividerWidth: CGFloat = 20
    static func halfSlant(height: CGFloat) -> CGFloat { min(dividerWidth / 2, height / 8) }

    func path(in rect: CGRect) -> Path {
        let slant = Self.halfSlant(height: rect.height)
        let left = leadingDivider ? slant : 0
        let right = trailingDivider ? slant : 0
        return Path { path in
            path.move(to: CGPoint(x: rect.minX + left, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX + right, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - right, y: rect.maxY))
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
