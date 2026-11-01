import SwiftUI

/// The percentage is a readout, not a fourth button. Each icon gets a full cell;
/// the same shape defines the tap target and the system-rendered gaze highlight.
struct TerminalZoomControls: View {
    @Binding var steps: Int
    let defaultSteps: Int

    var body: some View {
        HStack(spacing: 0) {
            Button("Zoom Out", systemImage: "minus.magnifyingglass") { steps -= 1 }
                .disabled(steps <= TerminalZoom.stepRange.lowerBound)
            Button("Zoom In", systemImage: "plus.magnifyingglass") { steps += 1 }
                .disabled(steps >= TerminalZoom.stepRange.upperBound)
            Button("Reset Zoom (\(TerminalZoom.percent(steps: defaultSteps))%)", systemImage: "magnifyingglass") {
                steps = defaultSteps
            }
                .disabled(steps == defaultSteps)
            Text("\(100 + steps * 10)%")
                .monospacedDigit()
                .font(.body.weight(.medium))
                .frame(width: 64, alignment: .trailing)
                .padding(.trailing, 20)
                .accessibilityLabel("Zoom \(100 + steps * 10) percent")
                .allowsHitTesting(false)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(TerminalMenuButtonStyle(alignment: .center))
    }
}

/// Put padding inside the hit region. Plain buttons avoid a second, inset native
/// capsule; the popover clips only its outside corners, not each menu row.
struct TerminalMenuButtonStyle: ButtonStyle {
    var alignment: Alignment = .leading
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body)
            .foregroundStyle(configuration.role == .destructive ? Color.red : .primary)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: alignment)
            .background(.white.opacity(configuration.isPressed ? 0.16 : 0.025))
            .contentShape(.interaction, Rectangle())
            .contentShape(.hoverEffect, Rectangle())
            .hoverEffect(.highlight)
            .opacity(isEnabled ? 1 : 0.3)
    }
}
