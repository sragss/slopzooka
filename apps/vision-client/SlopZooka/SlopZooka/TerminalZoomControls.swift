import SwiftUI

/// Separate native buttons leave room for gaze feedback; the percentage is a readout.
struct TerminalZoomControls: View {
    @Binding var steps: Int
    let defaultSteps: Int

    var body: some View {
        HStack(spacing: 8) {
            Button { steps -= 1 } label: {
                Image(systemName: "minus.magnifyingglass").frame(minWidth: 60, minHeight: 60)
            }
            .accessibilityLabel("Zoom Out")
            .disabled(steps <= TerminalZoom.stepRange.lowerBound)
            Button { steps += 1 } label: {
                Image(systemName: "plus.magnifyingglass").frame(minWidth: 60, minHeight: 60)
            }
            .accessibilityLabel("Zoom In")
            .disabled(steps >= TerminalZoom.stepRange.upperBound)
            Button { steps = defaultSteps } label: {
                Image(systemName: "magnifyingglass").frame(minWidth: 60, minHeight: 60)
            }
            .accessibilityLabel("Reset Zoom (\(TerminalZoom.percent(steps: defaultSteps))%)")
            .disabled(steps == defaultSteps)
            Text("\(100 + steps * 10)%")
                .monospacedDigit()
                .font(.body.weight(.medium))
                .frame(width: 60, alignment: .trailing)
                .accessibilityLabel("Zoom \(100 + steps * 10) percent")
                .allowsHitTesting(false)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
    }
}
