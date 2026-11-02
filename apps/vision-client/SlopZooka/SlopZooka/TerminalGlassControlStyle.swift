import SwiftUI

/// Keep native glass, interaction, and gaze feedback on the same label bounds.
struct TerminalGlassControlStyle<S: InsettableShape>: ButtonStyle {
    let shape: S
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.role == .destructive ? Color.red : .primary)
            .glassBackgroundEffect(in: shape)
            .overlay {
                shape.fill(.white.opacity(configuration.isPressed ? 0.12 : 0))
                    .allowsHitTesting(false)
            }
            .contentShape([.interaction, .hoverEffect], shape)
            .overlay {
                shape.fill(.white.opacity(0.08))
                    .overlay { shape.strokeBorder(.white.opacity(0.22), lineWidth: 1) }
                    .hoverEffect { effect, isActive, _ in
                        effect.opacity(isActive ? 1 : 0)
                    }
                    .allowsHitTesting(false)
            }
            .opacity(isEnabled ? 1 : 0.4)
            .hoverEffectGroup()
    }
}
