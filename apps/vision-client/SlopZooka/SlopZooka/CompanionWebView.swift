import SwiftUI
import WebKit

#if canImport(UIKit)
import UIKit

struct CompanionWebView: UIViewRepresentable {
    let url: URL
    let hostID: String?
    let reloadToken: Int
    @Binding var loadState: TerminalLoadState
    let isActive: Bool
    let focusRequestToken: Int
    let interruptRequestToken: Int
    let zoom: Double
    let showsScrollback: Bool
    let dragScrollback: Bool
    @AppStorage(TerminalKeyboard.optionAsMetaKey) private var optionAsMeta = false
    var onNotification: (Int, String) -> Bool = { _, _ in false }
    var onSelect: () -> Void = {}

    func makeCoordinator() -> TerminalSessionController { TerminalSessionController(loadState: $loadState) }
    func makeUIView(context: Context) -> TerminalSurface {
        context.coordinator.reloadToken = reloadToken
        context.coordinator.hostID = hostID
        context.coordinator.focusToken = focusRequestToken
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(WKUserScript(
            source: TerminalKeyboard.script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        configuration.userContentController.add(context.coordinator, name: "terminalState")
        configuration.userContentController.add(context.coordinator, name: "terminalScrollback")
        configuration.userContentController.add(context.coordinator, name: "terminalNotification")
        configuration.userContentController.add(context.coordinator, name: "diagnostics")
        context.coordinator.onNotification = onNotification
        context.coordinator.onSelect = onSelect
        let webView = TerminalWebView(frame: .zero, configuration: configuration)
        context.coordinator.requestZoom(zoom, in: webView)
        context.coordinator.requestOptionAsMeta(optionAsMeta, in: webView)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = UIColor(red: 0.02, green: 0.03, blue: 0.04, alpha: 1)
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        let surface = TerminalSurface(webView: webView)
        context.coordinator.scrollStrip = surface.scrollStrip
        context.coordinator.bodyPan = surface.bodyPan
        surface.scrollStrip.onScroll = { [weak coordinator = context.coordinator] pages in
            coordinator?.scrollHistory(pages, from: .strip)
        }
        surface.bodyPan.onScroll = { [weak coordinator = context.coordinator] pages in
            coordinator?.scrollHistory(pages, from: .body)
        }
        context.coordinator.configureScrollback(strip: showsScrollback, drag: dragScrollback)
        context.coordinator.updateActivity(isActive, in: webView)
        context.coordinator.load(url, in: webView)
        return surface
    }
    func updateUIView(_ surface: TerminalSurface, context: Context) {
        let webView = surface.webView
        context.coordinator.loadState = $loadState
        context.coordinator.hostID = hostID
        context.coordinator.onNotification = onNotification
        context.coordinator.onSelect = onSelect
        context.coordinator.updateActivity(isActive, in: webView)
        context.coordinator.configureScrollback(strip: showsScrollback, drag: dragScrollback)
        let reload = context.coordinator.reloadToken != reloadToken
        context.coordinator.reloadToken = reloadToken
        context.coordinator.load(url, in: webView, force: reload)
        context.coordinator.requestZoom(zoom, in: webView)
        context.coordinator.requestOptionAsMeta(optionAsMeta, in: webView)
        if context.coordinator.interruptToken != interruptRequestToken {
            context.coordinator.interruptToken = interruptRequestToken
            webView.evaluateJavaScript("window.slzInterruptTerminal?.()")
        }
        if context.coordinator.focusToken != focusRequestToken {
            context.coordinator.focusToken = focusRequestToken
            context.coordinator.requestFocus(in: webView, showKeyboard: true)
        }
    }
    static func dismantleUIView(_ surface: TerminalSurface, coordinator: TerminalSessionController) {
        let webView = surface.webView
        coordinator.configureScrollback(strip: false, drag: false)
        surface.scrollStrip.onScroll = nil
        surface.bodyPan.onScroll = nil
        coordinator.onNotification = { _, _ in false }
        coordinator.onSelect = {}
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "terminalState")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "terminalScrollback")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "terminalNotification")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "diagnostics")
        webView.evaluateJavaScript("window.slzDetachTerminal?.()")
        webView.navigationDelegate = nil
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
    }
}

private final class TerminalWebView: WKWebView {
    private lazy var terminalKeyCommands: [UIKeyCommand] = [
        keyCommand("a", title: "Select All Terminal Text", action: #selector(selectTerminalText(_:))),
        keyCommand("c", title: "Copy Terminal Text", action: #selector(copyTerminalText(_:))),
        // Keep paste in WebKit's edit pipeline so xterm receives the paste event.
        keyCommand("v", title: "Paste", action: #selector(UIResponderStandardEditActions.paste(_:)))
    ]

    private static let navigationKeys = [
        UIKeyCommand.inputUpArrow: "ArrowUp", UIKeyCommand.inputDownArrow: "ArrowDown",
        UIKeyCommand.inputLeftArrow: "ArrowLeft", UIKeyCommand.inputRightArrow: "ArrowRight",
        UIKeyCommand.inputHome: "Home", UIKeyCommand.inputEnd: "End"
    ]
    private static let editingKeys = ["\t": "Tab", "\r": "Enter", UIKeyCommand.inputEscape: "Escape"]

    private lazy var navigationCommands: [UIKeyCommand] = {
        let modifiers: [UIKeyModifierFlags] = [
            .shift, .alternate, .control, [.shift, .alternate], [.shift, .control],
            [.alternate, .control], [.shift, .alternate, .control]
        ]
        let chords = Self.navigationKeys.keys.sorted().flatMap { input in modifiers.map { (input, $0) } }
            + [("\t", .shift), ("\r", .alternate), (UIKeyCommand.inputEscape, .alternate)]
        return chords.map { input, flags in
            let command = UIKeyCommand(input: input, modifierFlags: flags, action: #selector(sendModifiedKey(_:)))
            command.wantsPriorityOverSystemBehavior = true
            command.allowsAutomaticMirroring = false
            command.allowsAutomaticLocalization = false
            return command
        }
    }()

    override var keyCommands: [UIKeyCommand]? {
        terminalKeyCommands + navigationCommands + (super.keyCommands ?? [])
    }

    @objc private func sendModifiedKey(_ sender: UIKeyCommand) {
        guard window?.isKeyWindow == true, let input = sender.input,
            let key = Self.navigationKeys[input] ?? Self.editingKeys[input] else { return }
        let flags = sender.modifierFlags
        evaluateJavaScript("""
            window.slzTerminalModifiedKey?.('\(key)', {
                shiftKey: \(flags.contains(.shift)), altKey: \(flags.contains(.alternate)),
                ctrlKey: \(flags.contains(.control))
            })
            """)
    }

    private func keyCommand(_ input: String, title: String, action: Selector) -> UIKeyCommand {
        let command = UIKeyCommand(title: title, action: action, input: input, modifierFlags: .command)
        // The focused WebKit textarea has no native selection for xterm output.
        command.wantsPriorityOverSystemBehavior = true
        return command
    }

    @objc private func selectTerminalText(_ sender: UIKeyCommand) {
        evaluateJavaScript("window.slzSelectAllTerminalText?.()")
    }

    @objc private func copyTerminalText(_ sender: UIKeyCommand) {
        guard window?.isKeyWindow == true, let url else { return }
        evaluateJavaScript("window.slzSelectedTerminalText?.()") { [weak self] result, _ in
            guard let self, self.window?.isKeyWindow == true, self.url == url,
                let text = result as? String, !text.isEmpty else { return }
            UIPasteboard.general.string = text
        }
    }
}
#endif

/// Owns the terminal document bridge. A loaded page is not a connected session.
@MainActor
final class TerminalSessionController: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    var hostID: String?
    private var log: AppLog { AppLog("terminal-webview", fields: ["hostId": hostID ?? ""]) }
    var loadState: Binding<TerminalLoadState>
    var focusToken = 0
    var interruptToken = 0
    var reloadToken = 0
    var onNotification: (Int, String) -> Bool = { _, _ in false }
    var onSelect: () -> Void = {}
    #if os(visionOS)
    private let notificationSound = TerminalNotificationSound()
    #endif
    private var requestedURL: URL?
    private weak var webView: WKWebView?
    private var terminalReady = false
    private var documentReady = false
    private var isActive = false
    private var focusGeneration = 0
    // nil means no pending focus; false keeps physical typing ready without software UI.
    private var pendingFocus: Bool?
    private var zoom = 1.0
    private var optionAsMeta = false
    #if canImport(UIKit)
    enum ScrollSource { case strip, body }

    weak var scrollStrip: TerminalScrollStrip?
    weak var bodyPan: TerminalScrollPan?
    private var hasScrollbackBridge = false
    private var bodyScrollAvailable = false
    private var wantsScrollStrip = false
    private var wantsBodyScroll = true
    private var pendingScroll: (source: ScrollSource, pages: Double)?
    private var scrollInFlight = false

    func configureScrollback(strip: Bool, drag: Bool) {
        wantsScrollStrip = strip
        wantsBodyScroll = drag
        updateScrollback()
    }

    private var canScrollHistory: Bool {
        hasScrollbackBridge && terminalReady && isActive
    }

    private func updateScrollback() {
        scrollStrip?.isHidden = !(wantsScrollStrip && hasScrollbackBridge)
        let stripEnabled = canScrollHistory && wantsScrollStrip
        let bodyEnabled = canScrollHistory && wantsBodyScroll && bodyScrollAvailable
        scrollStrip?.setEnabled(stripEnabled)
        if let bodyPan, bodyPan.isEnabled != bodyEnabled { bodyPan.isEnabled = bodyEnabled }
        if let pendingScroll, !scrollEnabled(for: pendingScroll.source) { self.pendingScroll = nil }
    }

    private func scrollEnabled(for source: ScrollSource) -> Bool {
        switch source {
        case .strip: return scrollStrip?.isUserInteractionEnabled == true
        case .body: return bodyPan?.isEnabled == true
        }
    }

    func scrollHistory(_ pages: Double, from source: ScrollSource) {
        guard scrollEnabled(for: source), pages.isFinite, pages != 0 else { return }
        // Motion from a new control replaces any unsent motion from the previous one.
        let queuedPages = pendingScroll?.source == source ? pendingScroll?.pages ?? 0 : 0
        // Bound the catch-up distance when WebKit is busy with output.
        pendingScroll = (source, min(4, max(-4, queuedPages + pages)))
        flushScrollHistory()
    }

    private func flushScrollHistory() {
        guard canScrollHistory, !scrollInFlight, let pendingScroll, pendingScroll.pages != 0,
            let webView, let url = webView.url, let requestedURL,
            !webView.isLoading, TerminalNavigation.allows(url, document: requestedURL)
        else { return }
        self.pendingScroll = nil
        scrollInFlight = true
        webView.callAsyncJavaScript(
            "window.slzScrollback?.(pages, fromBody)",
            arguments: ["pages": pendingScroll.pages, "fromBody": pendingScroll.source == .body],
            in: nil, in: .page
        ) { [weak self] _ in
            self?.scrollInFlight = false
            self?.flushScrollHistory()
        }
    }
    #endif

    func requestOptionAsMeta(_ enabled: Bool, in webView: WKWebView) {
        guard optionAsMeta != enabled else { return }
        optionAsMeta = enabled
        if documentReady || terminalReady { applyOptionAsMeta(in: webView) }
    }

    private func applyOptionAsMeta(in webView: WKWebView) {
        webView.evaluateJavaScript("window.slzSetTerminalOptionAsMeta?.(\(optionAsMeta))")
    }

    func requestZoom(_ zoom: Double, in webView: WKWebView) {
        guard self.zoom != zoom else { return }
        self.zoom = zoom
        if documentReady || terminalReady { applyZoom(in: webView) }
    }

    private func applyZoom(in webView: WKWebView) {
        // Scale the terminal font, not the web view's drawing surface. The web
        // bridge explicitly refits the emulator and sends its new grid to the PTY.
        webView.evaluateJavaScript(TerminalZoom.script(scale: zoom))
    }
    func updateActivity(_ active: Bool, in webView: WKWebView) {
        guard isActive != active else { return }
        isActive = active
        #if canImport(UIKit)
        updateScrollback()
        #endif
        focusGeneration += 1
        if active { requestFocus(in: webView) }
        else {
            pendingFocus = nil
            webView.evaluateJavaScript("window.slzBlurTerminal?.()")
        }
    }
    func requestFocus(in webView: WKWebView, showKeyboard: Bool = false) {
        guard isActive else { return }
        pendingFocus = showKeyboard
        guard terminalReady else { return }
        pendingFocus = nil
        focusGeneration += 1
        let generation = focusGeneration
        // Set the keyboard mode before requesting native focus, otherwise a
        // previously requested software keyboard can briefly reopen on activation.
        webView.evaluateJavaScript("window.slzFocusTerminal?.(\(showKeyboard))") { [weak self, weak webView] _, _ in
            guard let self, self.isActive, self.terminalReady, self.focusGeneration == generation else { return }
            webView?.becomeFirstResponder()
        }
    }
    init(loadState: Binding<TerminalLoadState>) { self.loadState = loadState }
    func load(_ url: URL, in webView: WKWebView, force: Bool = false) {
        guard force || requestedURL != url else { return }
        requestedURL = url
        self.webView = webView
        terminalReady = false
        documentReady = false
        #if canImport(UIKit)
        hasScrollbackBridge = false
        bodyScrollAvailable = false
        updateScrollback()
        #endif
        focusGeneration += 1
        pendingFocus = isActive ? false : nil
        DispatchQueue.main.async { self.loadState.wrappedValue = .loading("Connecting") }
        webView.load(CompanionClient.authorized(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)))
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.webView === webView else { return }
        if message.name == "diagnostics" {
            guard let requestedURL, let frameURL = message.frameInfo.request.url,
                frameURL.scheme == requestedURL.scheme, frameURL.host == requestedURL.host,
                frameURL.port == requestedURL.port, frameURL.path == requestedURL.path else { return }
            NativeDiagnostics.shared.receiveBrowserEvent(message.body, hostID: hostID)
            return
        }
        if message.name == "terminalNotification" {
            guard let body = message.body as? [String: Any] else { return }
            if body["kind"] as? String == "selected" {
                onSelect()
            } else if body["kind"] as? String == "alert",
                let value = body["sequence"] as? NSNumber,
                CFGetTypeID(value) != CFBooleanGetTypeID(),
                value.doubleValue.isFinite, value.doubleValue >= 0,
                value.doubleValue <= 9_007_199_254_740_991,
                value.doubleValue.rounded() == value.doubleValue,
                let instance = body["serviceInstanceId"] as? String {
                let isNew = onNotification(value.intValue, instance)
                #if os(visionOS)
                if isNew, body["audible"] as? Bool == true,
                    let sceneID = webView?.window?.windowScene?.session.persistentIdentifier {
                    notificationSound.play(sceneID: sceneID)
                }
                #endif
            }
            return
        }
        #if canImport(UIKit)
        if message.name == "terminalScrollback" {
            guard let requestedURL, let frameURL = message.frameInfo.request.url,
                TerminalNavigation.allows(frameURL, document: requestedURL),
                let available = message.body as? String else { return }
            bodyScrollAvailable = available == "1"
            updateScrollback()
            return
        }
        #endif
        guard message.name == "terminalState", let body = message.body as? [String: String] else { return }
        #if canImport(UIKit)
        if let requestedURL, let frameURL = message.frameInfo.request.url,
            TerminalNavigation.allows(frameURL, document: requestedURL) {
            hasScrollbackBridge = body["scrollback"] == "1"
        }
        #endif
        terminalReady = body["state"] == "running"
        #if canImport(UIKit)
        updateScrollback()
        #endif
        switch body["state"] {
        case "running":
            terminalReady = true
            loadState.wrappedValue = .loaded
            if let webView {
                applyZoom(in: webView)
                applyOptionAsMeta(in: webView)
            }
            if let showKeyboard = pendingFocus, let webView { requestFocus(in: webView, showKeyboard: showKeyboard) }
        case "disconnected": loadState.wrappedValue = .disconnected
        case "failed": loadState.wrappedValue = .failed(body["message"] ?? "Session unavailable")
        case "exited": loadState.wrappedValue = .ended(body["message"] ?? "Session ended")
        default: loadState.wrappedValue = .loading(body["message"] ?? "Connecting")
        }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        log.error("navigation.failed", error: error)
        loadState.wrappedValue = .failed(error.localizedDescription)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        documentReady = true
        #if canImport(UIKit)
        flushScrollHistory()
        #endif
        applyZoom(in: webView)
        applyOptionAsMeta(in: webView)
        // Older companion pages focus their textarea on load. Keep inactive
        // scenes unfocused when recovering those document revisions too.
        if !isActive { webView.evaluateJavaScript("window.slzBlurTerminal?.()") }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        log.error("navigation.failed", error: error)
        loadState.wrappedValue = .failed(error.localizedDescription)
    }
    func webView(
        _ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
        if navigationResponse.isForMainFrame,
            let response = navigationResponse.response as? HTTPURLResponse, response.statusCode >= 400 {
            loadState.wrappedValue = .failed(response.statusCode == 401
                ? "Pair with your Mac from the launcher, then reopen this terminal"
                : "Terminal page returned HTTP \(response.statusCode). Reopen the terminal or check the Mac logs.")
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        log.warn("process.terminated")
        guard let requestedURL else { return }
        terminalReady = false
        documentReady = false
        #if canImport(UIKit)
        hasScrollbackBridge = false
        bodyScrollAvailable = false
        updateScrollback()
        #endif
        focusGeneration += 1
        // Restore physical typing without replaying an old software-keyboard request.
        pendingFocus = isActive ? false : nil
        loadState.wrappedValue = .loading("Reconnecting")
        webView.load(CompanionClient.authorized(URLRequest(url: requestedURL)))
    }
    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard let target = navigationAction.request.url, let requestedURL else {
            decisionHandler(.cancel)
            return
        }
        let allowed = TerminalNavigation.allows(target, document: requestedURL)
        if !allowed && navigationAction.targetFrame?.isMainFrame != false {
            loadState.wrappedValue = .failed("Terminal navigation was blocked: \(target.scheme ?? "unknown")://\(target.host ?? "unknown")\(target.path)")
        }
        decisionHandler(allowed ? .allow : .cancel)
    }
}
