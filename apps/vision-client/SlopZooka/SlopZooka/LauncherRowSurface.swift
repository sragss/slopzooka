import SwiftUI

/// Shared surface for repository and workspace rows; actions remain inside the outline.
struct LauncherRowSurface: ViewModifier {
    private let shape = RoundedRectangle(cornerRadius: 18)

    func body(content: Content) -> some View {
        content
            .background(.white.opacity(0.05), in: shape)
            .overlay {
                shape.strokeBorder(.white.opacity(0.12), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .contentShape(.hoverEffect, shape)
            .hoverEffect(.highlight)
    }
}
