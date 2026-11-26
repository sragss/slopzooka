import UIKit
import WebKit

final class TerminalSurface: UIStackView {
    let webView: WKWebView
    let scrollStrip = TerminalScrollStrip()
    let bodyPan = TerminalScrollPan()

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        axis = .horizontal
        addArrangedSubview(webView)
        addArrangedSubview(scrollStrip)
        let width = scrollStrip.widthAnchor.constraint(equalToConstant: 56)
        // A hidden arranged view gets a required zero-width constraint.
        width.priority = .defaultHigh
        width.isActive = true
        bodyPan.allowedTouchTypes = [UITouch.TouchType.direct, .indirect].map { NSNumber(value: $0.rawValue) }
        // Give the pan a chance to win before WebKit treats the pinch as a tap.
        bodyPan.delaysTouchesBegan = true
        webView.addGestureRecognizer(bodyPan)
        webView.scrollView.panGestureRecognizer.require(toFail: bodyPan)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

final class TerminalScrollPan: UIPanGestureRecognizer, UIGestureRecognizerDelegate {
    var onScroll: ((Double) -> Void)?

    init() {
        super.init(target: nil, action: nil)
        addTarget(self, action: #selector(handlePan))
        delegate = self
        maximumNumberOfTouches = 1
        isEnabled = false
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        let movement = translation(in: view)
        return abs(movement.y) >= abs(movement.x)
    }

    @objc private func handlePan() {
        guard [.began, .changed, .ended].contains(state), let view, view.bounds.height > 0 else { return }
        let distance = translation(in: view).y
        setTranslation(.zero, in: view)
        onScroll?(-Double(distance / view.bounds.height))
    }
}

final class TerminalScrollStrip: UIView {
    private let pan = TerminalScrollPan()
    var onScroll: ((Double) -> Void)? {
        get { pan.onScroll }
        set { pan.onScroll = newValue }
    }

    init() {
        super.init(frame: .zero)
        backgroundColor = UIColor(white: 0.15, alpha: 1)
        let icon = UIImageView(image: UIImage(systemName: "arrow.up.and.down"))
        icon.tintColor = .white
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        accessibilityLabel = "Terminal scrollback"
        accessibilityHint = "Adjust to move one page through terminal history"
        accessibilityTraits = .adjustable
        pan.allowedScrollTypesMask = .all
        addGestureRecognizer(pan)
        isHidden = true
        setEnabled(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setEnabled(_ enabled: Bool) {
        guard isUserInteractionEnabled != enabled else { return }
        isUserInteractionEnabled = enabled
        isAccessibilityElement = enabled
        pan.isEnabled = enabled
    }

    override func accessibilityIncrement() { onScroll?(1) }
    override func accessibilityDecrement() { onScroll?(-1) }
}
