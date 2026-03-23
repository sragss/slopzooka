import SwiftUI
import RealityKit
import UIKit

struct HandLauncherSpikeView: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            RealityView { content in
                let leftPalmAnchor = AnchorEntity(.hand(.left, location: .palm), trackingMode: .continuous)
                leftPalmAnchor.addChild(makeLauncherPanel())
                content.add(leftPalmAnchor)

                let leftWristAnchor = AnchorEntity(.hand(.left, location: .wrist), trackingMode: .continuous)
                leftWristAnchor.addChild(makeWristMarker())
                content.add(leftWristAnchor)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Palm Launcher Spike")
                    .font(.headline)

                Text("Real-device test only. Hold your left hand naturally and check whether the attached launcher feels stable, legible, and easy to target.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 340, alignment: .leading)
            }
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(16)
        }
    }

    private func makeLauncherPanel() -> Entity {
        let panel = Entity()
        panel.position = [0, 0.035, -0.03]

        let base = ModelEntity(
            mesh: .generateBox(size: [0.12, 0.07, 0.004]),
            materials: [SimpleMaterial(color: .init(white: 0.08, alpha: 0.92), isMetallic: false)]
        )
        panel.addChild(base)

        let colors: [UIColor] = [.systemBlue, .systemGreen, .systemOrange]
        let xOffsets: [Float] = [-0.035, 0, 0.035]

        for (index, color) in colors.enumerated() {
            let button = ModelEntity(
                mesh: .generateBox(size: [0.024, 0.024, 0.008]),
                materials: [SimpleMaterial(color: color, isMetallic: false)]
            )
            button.position = [xOffsets[index], 0, 0.008]
            panel.addChild(button)
        }

        return panel
    }

    private func makeWristMarker() -> Entity {
        let marker = ModelEntity(
            mesh: .generateSphere(radius: 0.012),
            materials: [SimpleMaterial(color: .systemPink, isMetallic: false)]
        )
        marker.position = [0, 0, 0]
        return marker
    }
}

#Preview(windowStyle: .automatic) {
    HandLauncherSpikeView()
}
