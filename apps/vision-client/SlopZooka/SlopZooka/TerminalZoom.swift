import Foundation

enum TerminalZoom {
    static let defaultStepsKey = "defaultTerminalZoomSteps"
    static let initialDefaultSteps = -2
    static let stepRange = -9...10

    static func resolvedSteps(scene: Int?, defaultSteps: Int) -> Int {
        min(stepRange.upperBound, max(stepRange.lowerBound, scene ?? defaultSteps))
    }

    static func scale(steps: Int) -> Double { Double(10 + steps) / 10 }
    static func percent(steps: Int) -> Int { 100 + steps * 10 }

    static func script(scale: Double) -> String {
        """
        (() => {
            const zoom = \(scale);
            if (!Number.isFinite(zoom) || zoom < 0.1 || zoom > 2) return;
            if (typeof window.slzSetTerminalZoom === 'function') {
                window.slzSetTerminalZoom(zoom);
                return;
            }
            // Older companions have no font-zoom bridge. Give their ResizeObserver
            // a new logical viewport, then scale it to fill the native surface.
            // pageZoom alone does not refit xterm in visionOS WebKit.
            const mount = document.getElementById('terminal');
            if (!mount) return;
            mount.style.transformOrigin = 'top left';
            mount.style.width = (100 / zoom) + '%';
            mount.style.height = (100 / zoom) + '%';
            mount.style.transform = 'scale(' + zoom + ')';
        })()
        """
    }
}
