import Foundation
import Observation

enum ConnectionMethod: String, CaseIterable, Identifiable {
    case localNetwork = "Local Network"
    case direct = "Direct to Mac"

    var id: Self { self }
    var other: Self { self == .direct ? .localNetwork : .direct }
}

enum LabMac: String, CaseIterable, Identifiable {
    case studio = "Studio Mac"
    case laptop = "MacBook Pro"

    var id: Self { self }
    var hostname: String { self == .studio ? "Studio-Mac.local" : "MacBook-Pro.local" }
    var address: String { "\(hostname):7777" }
    var origin: String { "http://\(address)" }
    var manualIP: String { self == .studio ? "192.0.2.10:7777" : "192.0.2.11:7777" }

    static func matching(_ url: URL) -> Self? {
        guard url.port == 7777, let host = url.host()?.lowercased() else { return nil }
        return allCases.first { host == $0.hostname.lowercased() || "\(host):7777" == $0.manualIP }
    }
}

enum LabScenario: String, CaseIterable, Identifiable {
    case discovering = "First-run discovery"
    case noMacs = "No Macs discovered"
    case discoveryDenied = "Local Network permission denied"
    case discoveryFailed = "Bonjour discovery failed"
    case checking = "Checking Mac address"
    case multipleMacs = "Multiple Macs"
    case manual = "Manual address"
    case invalidAddress = "Invalid address"
    case unreachable = "Mac unreachable"
    case incompatible = "Protocol version mismatch"
    case wrongMac = "Saved Mac identity mismatch"
    case pairing = "Enter pairing code"
    case pairingSubmitting = "Pairing in progress"
    case pairingRejected = "Wrong pairing code"
    case pairingLimited = "Pairing rate limited"
    case pairingNetworkError = "Pairing request interrupted"
    case codeHidden = "Mac code window dismissed"
    case connected = "Connected on Local Network"
    case localReconnecting = "Local Network reconnecting"
    case localRetrying = "Local Network retry in progress"
    case pairingRevoked = "Pairing revoked"
    case workspaceBusy = "Workspace action in progress"
    case directUnpaired = "Direct requires initial LAN pairing"
    case directUnprepared = "Direct trust missing after LAN pairing"
    case directChecking = "Looking for a nearby Mac"
    case directOffline = "Direct Mac out of range"
    case directUnsupported = "Direct version mismatch"
    case directWrongMac = "Direct identity mismatch"
    case directRevoked = "Direct credential rejected"
    case directConnected = "Connected on Direct"
    case directReconnecting = "Direct reconnecting"
    case settings = "Settings"
    case layoutError = "Settings with layout error"
    case voiceActive = "Settings with active voice input"
    case immersiveOn = "Immersive on"
    case immersiveUpdating = "Immersive transition"
    case immersiveFailed = "Immersive failed"
    case micNotAsked = "Voice permission required"
    case micPreparing = "Voice permission in progress"
    case micDenied = "Microphone denied"
    case speechDenied = "Speech recognition denied"
    case micAllowed = "Voice permissions granted"
    case capturePermission = "Screen Recording required"
    case captureLocked = "Mac screen locked"
    case captureUnavailable = "Mac window sharing unavailable"
    case captureReady = "Direct with Mac window sharing"

    var id: Self { self }

    enum Group: String, CaseIterable {
        case local = "Local Network", pairing = "Pairing", direct = "Direct", settings = "Settings", permissions = "Permissions & previews"
    }

    var group: Group {
        switch self {
        case .pairing, .pairingSubmitting, .pairingRejected, .pairingLimited, .pairingNetworkError, .codeHidden, .pairingRevoked: .pairing
        case .directUnpaired, .directUnprepared, .directChecking, .directOffline, .directUnsupported, .directWrongMac,
                .directRevoked, .directConnected, .directReconnecting: .direct
        case .settings, .layoutError, .voiceActive, .immersiveOn, .immersiveUpdating, .immersiveFailed: .settings
        case .micNotAsked, .micPreparing, .micDenied, .speechDenied, .micAllowed,
                .capturePermission, .captureLocked, .captureUnavailable, .captureReady: .permissions
        default: .local
        }
    }
}

enum LabSurface: String {
    case launcher, settings, yourMac = "your-mac", frontends, ask
}

enum ConnectionPhase: Equatable {
    case idle, checking, codeEntry, submitting, connected
    case failed(String), reconnecting(String)

    var error: String? {
        switch self {
        case .failed(let message), .reconnecting(let message): message
        default: nil
        }
    }

    var isReconnecting: Bool {
        if case .reconnecting = self { return true }
        return false
    }
}

enum ConnectionFault: String, CaseIterable, Identifiable {
    case healthy = "Reachable"
    case offline = "Unreachable"
    case incompatible = "Incompatible version"
    case wrongIdentity = "Wrong Mac identity"
    case revoked = "Credential rejected"

    var id: Self { self }
}

enum DiscoveryOutcome: String, CaseIterable, Identifiable {
    case oneMac = "One Mac found"
    case twoMacs = "Two Macs found"
    case noMacs = "No Macs found"
    case permissionDenied = "Local Network denied"
    case bonjourError = "Bonjour error"

    var id: Self { self }
}

enum PairingOutcome: String, CaseIterable, Identifiable {
    case checkCode = "Check code"
    case rateLimited = "Rate limited"
    case networkError = "Connection interrupted"

    var id: Self { self }
}

enum VoicePermission: String, CaseIterable, Identifiable {
    case undetermined = "Undetermined"
    case granted = "Granted"
    case microphoneDenied = "Microphone denied"
    case speechDenied = "Speech recognition denied"

    var id: Self { self }

}

enum ImmersiveOutcome: String, CaseIterable, Identifiable {
    case opened = "Complete"
    case cancelled = "User cancelled"
    case failed = "Failed"

    var id: Self { self }
}

enum CaptureState: String, CaseIterable, Identifiable {
    case hidden = "Catalog absent"
    case permission = "Permission required"
    case locked = "Mac locked"
    case failed = "Provider unavailable"
    case ready = "Ready"

    var id: Self { self }

    var message: String? {
        switch self {
        case .permission: "Allow Screen Recording on your Mac to share windows."
        case .locked: "Unlock your Mac to share windows."
        case .failed: "Mac window sharing is unavailable."
        default: nil
        }
    }
}

@MainActor
@Observable
final class LabModel {
    static let validCode = "123456"
    static let discoveryDenied = "Bonjour search failed: [\"NSNetServicesErrorCode\": -65570, \"NSNetServicesErrorDomain\": 10]"
    static let discoveryFailed = "Bonjour search failed: [\"NSNetServicesErrorCode\": -72000, \"NSNetServicesErrorDomain\": 10]"
    static let immersiveFailure = "Couldn’t open the immersive mode. Try again."

    private(set) var scenario: LabScenario = .discovering
    private(set) var surface: LabSurface = .launcher
    private(set) var surfaceRequest = 0
    private(set) var startsWithManualAddress = false
    private(set) var method: ConnectionMethod = .localNetwork
    private(set) var phase: ConnectionPhase = .idle
    private(set) var discovered: [LabMac] = []
    private(set) var discoveryError: String?
    private(set) var host = ""
    private(set) var pairingCode = ""
    private(set) var pairingError: String?
    private(set) var isCodeDisplayed = false
    private var codeDisplaySuppressed = false
    private(set) var mac: LabMac?
    private var acceptedOrigin: URL?
    var workspaceBusy = false
    var autoConnectFixture = false
    var layoutError: String?
    private(set) var reloadCount = 0

    // Fixtures describe what an attempt will observe when its pending operation completes.
    var discoveryOutcome: DiscoveryOutcome = .oneMac
    var faults: [ConnectionMethod: ConnectionFault] = [:]
    var pairingOutcome: PairingOutcome = .checkCode
    private(set) var voicePermission: VoicePermission = .undetermined
    var nextVoicePermission: VoicePermission = .granted
    private(set) var isRequestingVoice = false
    var voiceActive = false
    var capture: CaptureState = .hidden
    private(set) var captureAction: String?
    private(set) var immersive = false
    private(set) var immersiveTarget: Bool?
    private(set) var immersiveError: String?
    var immersiveOutcome: ImmersiveOutcome = .opened

    private var credentials: Set<LabMac> = []
    private var authorizedAddresses: [String: LabMac] = [:]
    private var directTrust: Set<LabMac> = []
    private var methodsByMac: [LabMac: ConnectionMethod] = [:]
    private var rememberedMac: LabMac?
    private var rememberedHost = ""
    private var pending: Pending?
    private enum Pending {
        case discovery
        case connect(UUID, expected: LabMac?, reconnect: Bool, previous: ConnectionSnapshot)
        case pair(mac: LabMac, code: String)
    }

    private struct ConnectionSnapshot {
        let phase: ConnectionPhase
        let method: ConnectionMethod
        let host: String
        let mac: LabMac?
        let origin: URL?
        let discovered: [LabMac]
        let discoveryError: String?
        let wasDiscovering: Bool
        let savedMethods: [LabMac: ConnectionMethod]
    }

    var isReady: Bool { phase == .connected }
    var isReconnectAttempt: Bool {
        if case .connect(_, _, let reconnect, _) = pending { return reconnect }
        return false
    }
    var automaticConnectionID: UUID? {
        guard autoConnectFixture, case .connect(let id, _, _, _) = pending else { return nil }
        return id
    }
    var workspaceMacName: String? { rememberedMac?.rawValue }
    var isDiscovering: Bool {
        if case .discovery = pending { return true }
        return false
    }
    var needsPairing: Bool { phase == .codeEntry || phase == .submitting }
    var isPairing: Bool { phase == .submitting }
    var canChangeConnection: Bool { !isPairing && !workspaceBusy }
    var normalizedHost: String { host.trimmingCharacters(in: .whitespacesAndNewlines) }
    var selectedMacName: String {
        if let mac, discovered.contains(mac) { return mac.rawValue }
        return acceptedOrigin?.host() ?? "your Mac"
    }
    var healthOrigin: String? { acceptedOrigin?.absoluteString }
    var pendingLabel: String? {
        switch pending {
        case .discovery: "Complete discovery"
        case .connect: "Complete connection check"
        case .pair: "Complete pairing request"
        case nil: nil
        }
    }

    init(scenario: LabScenario = .discovering) { load(scenario) }

    func navigate(_ surface: LabSurface) {
        self.surface = surface
        surfaceRequest += 1
    }

    func load(_ scenario: LabScenario) {
        self.scenario = scenario
        method = .localNetwork
        pending = nil
        phase = .idle
        discovered = []
        discoveryError = nil
        host = ""
        mac = nil
        acceptedOrigin = nil
        pairingCode = ""
        pairingError = nil
        isCodeDisplayed = false
        codeDisplaySuppressed = false
        credentials = []
        authorizedAddresses = [:]
        directTrust = []
        methodsByMac = [:]
        rememberedMac = nil
        rememberedHost = ""
        faults = [:]
        discoveryOutcome = .oneMac
        pairingOutcome = .checkCode
        workspaceBusy = false
        autoConnectFixture = scenario == .discovering || scenario == .multipleMacs || scenario == .connected
        layoutError = nil
        reloadCount = 0
        voicePermission = .undetermined
        nextVoicePermission = .granted
        isRequestingVoice = false
        voiceActive = false
        capture = .hidden
        captureAction = nil
        immersive = false
        immersiveTarget = nil
        immersiveError = nil
        immersiveOutcome = .opened
        startsWithManualAddress = scenario == .manual || scenario == .invalidAddress

        var destination: LabSurface = .launcher
        switch scenario {
        case .discovering, .manual:
            pending = .discovery
        case .noMacs:
            discoveryOutcome = .noMacs
        case .discoveryDenied, .discoveryFailed:
            discoveryOutcome = scenario == .discoveryDenied ? .permissionDenied : .bonjourError
            finishDiscovery()
        case .checking:
            host = LabMac.studio.address
            connect()
        case .multipleMacs:
            discoveryOutcome = .twoMacs
            finishDiscovery()
        case .invalidAddress:
            select("https://")
        case .unreachable, .incompatible, .wrongMac:
            host = LabMac.studio.address
            faults[.localNetwork] = switch scenario {
            case .unreachable: .offline
            case .incompatible: .incompatible
            default: .wrongIdentity
            }
            connect()
            advanceConnection()
        case .pairing, .pairingSubmitting, .pairingRejected, .pairingLimited, .pairingNetworkError, .codeHidden:
            preparePairing()
            switch scenario {
            case .pairingSubmitting: enterCode(Self.validCode)
            case .pairingRejected: enterCode("000000"); advanceConnection()
            case .pairingLimited: pairingOutcome = .rateLimited; enterCode(Self.validCode); advanceConnection()
            case .pairingNetworkError: pairingOutcome = .networkError; enterCode(Self.validCode); advanceConnection()
            case .codeHidden: dismissCode(); codeDisplaySuppressed = true
            default: break
            }
        case .connected, .workspaceBusy, .localReconnecting, .localRetrying, .pairingRevoked:
            prepareConnected()
            if scenario == .connected {
                discoveryOutcome = .twoMacs
                finishDiscovery()
            }
            if scenario == .workspaceBusy { workspaceBusy = true; destination = .yourMac }
            if scenario == .localReconnecting { loseConnection() }
            if scenario == .localRetrying {
                loseConnection()
                connect()
            }
            if scenario == .pairingRevoked { revokePairing(); destination = .yourMac }
        case .directUnpaired, .directUnprepared, .directChecking, .directOffline, .directUnsupported,
                .directWrongMac, .directRevoked, .directConnected, .directReconnecting:
            if scenario == .directUnpaired { preparePairing() } else { prepareConnected() }
            if scenario == .directUnprepared { directTrust = [] }
            faults[.direct] = switch scenario {
            case .directOffline: .offline
            case .directUnsupported: .incompatible
            case .directWrongMac: .wrongIdentity
            case .directRevoked: .revoked
            default: .healthy
            }
            if scenario == .directRevoked { faults[.localNetwork] = .revoked }
            changeMethod(.direct)
            if scenario != .directChecking { advanceConnection() }
            if scenario == .directReconnecting { loseConnection() }
            if scenario != .directReconnecting { destination = .yourMac }
        case .settings, .layoutError, .voiceActive, .immersiveOn, .immersiveUpdating, .immersiveFailed:
            prepareConnected()
            destination = .settings
            if scenario == .layoutError {
                layoutError = "Could not save the window layout: The network connection was lost."
                destination = .yourMac
            }
            if scenario == .voiceActive { voiceActive = true; voicePermission = .granted }
            if scenario == .immersiveOn { immersive = true }
            if scenario == .immersiveUpdating { setImmersive(true) }
            if scenario == .immersiveFailed { immersiveError = Self.immersiveFailure }
        case .micNotAsked, .micPreparing, .micDenied, .speechDenied, .micAllowed:
            prepareConnected()
            destination = .ask
            if scenario == .micPreparing { requestVoice() }
            if scenario == .micDenied { voicePermission = .microphoneDenied }
            if scenario == .speechDenied { voicePermission = .speechDenied }
            if scenario == .micAllowed { voicePermission = .granted }
        case .capturePermission, .captureLocked, .captureUnavailable, .captureReady:
            prepareConnected()
            destination = .frontends
            capture = switch scenario {
            case .capturePermission: .permission
            case .captureLocked: .locked
            case .captureUnavailable: .failed
            default: .ready
            }
            if scenario == .captureReady { changeMethod(.direct); advanceConnection() }
        }
        navigate(destination)
    }

    private func preparePairing() {
        host = LabMac.studio.address
        mac = .studio
        acceptedOrigin = Self.baseURL(host)
        rememberedHost = host
        if discovered.isEmpty { discovered = [.studio] }
        phase = .codeEntry
        isCodeDisplayed = true
    }

    private func prepareConnected() {
        preparePairing()
        credentials.insert(.studio)
        if let acceptedOrigin { authorizedAddresses[Self.originKey(acceptedOrigin)] = .studio }
        directTrust.insert(.studio)
        rememberedMac = .studio
        phase = .connected
        isCodeDisplayed = false
    }

    func restartDiscovery() {
        guard method == .localNetwork, !isReady, !needsPairing else { return }
        phase = .idle
        findMacs()
    }

    func findMacs() {
        guard method == .localNetwork, canChangeConnection, phase != .checking else { return }
        discoveryError = nil
        pending = .discovery
    }

    func select(_ address: String) {
        guard method == .localNetwork, canChangeConnection else { return }
        let previous = connectionSnapshot()
        let sameOrigin = Self.baseURL(address).map(Self.originKey) == Self.baseURL(host).map(Self.originKey)
        let reconnect = sameOrigin && (phase.isReconnecting || isReady)
        host = address
        if let url = Self.baseURL(address), let selected = authorizedAddresses[Self.originKey(url)],
           credentials.contains(selected), selected != mac {
            mac = selected
            method = methodsByMac[selected] ?? .localNetwork
            if method == .direct { discovered = [] }
        }
        startConnection(expected: nil, reconnect: reconnect, previous: previous)
    }

    func changeMethod(_ next: ConnectionMethod) {
        guard method != next, canChangeConnection else { return }
        let previous = connectionSnapshot()
        method = next
        if let mac, credentials.contains(mac) { methodsByMac[mac] = next }
        discovered = []
        discoveryError = nil
        acceptedOrigin = nil
        if next == .localNetwork, normalizedHost.isEmpty {
            restartDiscovery()
            return
        }
        startConnection(expected: nil, reconnect: false, previous: previous)
    }

    func connect() { startConnection(expected: nil, reconnect: phase.isReconnecting || isReady) }

    private func startConnection(expected: LabMac?, reconnect: Bool, previous: ConnectionSnapshot? = nil) {
        let previous = previous ?? connectionSnapshot()
        pending = nil
        pairingCode = ""
        pairingError = nil
        isCodeDisplayed = false
        codeDisplaySuppressed = false
        if method == .direct, normalizedHost.isEmpty {
            phase = .failed("Pair with your Mac over Local Network before using Direct.")
            return
        }
        guard Self.baseURL(normalizedHost) != nil else {
            phase = .failed("Enter a valid companion host")
            return
        }
        phase = .checking
        pending = .connect(UUID(), expected: expected, reconnect: reconnect, previous: previous)
    }

    private func connectionSnapshot() -> ConnectionSnapshot {
        if case .connect(_, _, _, let previous) = pending { return previous }
        return ConnectionSnapshot(phase: phase, method: method, host: host, mac: mac, origin: acceptedOrigin,
                                  discovered: discovered, discoveryError: discoveryError, wasDiscovering: isDiscovering,
                                  savedMethods: methodsByMac)
    }

    func cancelConnection() {
        switch pending {
        case .connect(_, _, _, let previous):
            pending = previous.wasDiscovering ? .discovery : nil
            phase = previous.phase
            method = previous.method
            host = previous.host
            mac = previous.mac
            acceptedOrigin = previous.origin
            discovered = previous.discovered
            discoveryError = previous.discoveryError
            methodsByMac = previous.savedMethods
            if needsPairing { showCode() }
        case .pair:
            pending = nil
            pairingCode = ""
            phase = .codeEntry
        default:
            break
        }
    }

    func enterCode(_ input: String) {
        guard phase == .codeEntry, let mac else { return }
        pairingCode = String(input.filter { $0 >= "0" && $0 <= "9" }.prefix(6))
        guard pairingCode.count == 6 else { return }
        pairingError = nil
        phase = .submitting
        pending = .pair(mac: mac, code: pairingCode)
    }

    func showCode() {
        if needsPairing { isCodeDisplayed = true }
    }

    func requestCodeDisplay() {
        if !codeDisplaySuppressed { showCode() }
    }

    func dismissCode() { isCodeDisplayed = false }

    func advanceConnection() {
        guard let operation = pending else { return }
        pending = nil
        switch operation {
        case .discovery:
            finishDiscovery()
        case .connect(_, let expected, let reconnect, _):
            finishConnection(expected: expected, reconnect: reconnect)
        case .pair(let mac, let code):
            finishPairing(mac: mac, code: code)
        }
    }

    func completeAutomaticConnection(_ id: UUID) {
        guard automaticConnectionID == id else { return }
        advanceConnection()
    }

    private func finishDiscovery() {
        switch discoveryOutcome {
        case .permissionDenied: discoveryError = Self.discoveryDenied
        case .bonjourError: discoveryError = Self.discoveryFailed
        case .noMacs: discovered = []
        case .oneMac, .twoMacs:
            discovered = discoveryOutcome == .twoMacs ? [.laptop, .studio] : [.studio]
        }
    }

    private func finishConnection(expected: LabMac?, reconnect: Bool) {
        guard let url = Self.baseURL(normalizedHost) else { return }
        let destination = method == .direct ? mac : LabMac.matching(url)
        let fault = faults[method] ?? .healthy
        if let message = connectionFailure(destination: destination, expected: expected, fault: fault) {
            let details = "\(method.rawValue): \(message)"
            phase = reconnect ? .reconnecting(details) : .failed(details)
            return
        }
        guard let destination else { return }
        mac = destination
        acceptedOrigin = method == .direct ? URL(string: destination.origin) : url
        rememberedHost = normalizedHost
        if autoConnectFixture && method == .localNetwork && fault == .healthy {
            credentials.insert(destination)
            authorizedAddresses[Self.originKey(url)] = destination
        }
        if fault == .revoked {
            forgetCredential(for: destination)
            faults[.localNetwork] = .healthy
        }
        if credentials.contains(destination), method == .direct || authorizedAddresses[Self.originKey(url)] == destination {
            if method == .localNetwork { directTrust.insert(destination) }
            rememberedMac = destination
            methodsByMac[destination] = method
            phase = .connected
        } else {
            phase = .codeEntry
            showCode()
        }
    }

    private func connectionFailure(destination: LabMac?, expected: LabMac?, fault: ConnectionFault) -> String? {
        if method == .direct {
            guard let mac, directTrust.contains(mac), credentials.contains(mac) else {
                return "Reconnect using Local Network with an updated Mac companion first to prepare Direct to Mac."
            }
        }
        if destination == nil || fault == .offline { return "A server with the specified hostname could not be found." }
        if fault == .wrongIdentity || (expected != nil && expected != destination) {
            return "The connection did not authenticate the selected Mac."
        }
        if fault == .incompatible {
            return method == .direct ? "Update the Mac companion and headset app together to use Direct to Mac." : "Update the companion and headset app together"
        }
        if fault == .revoked && method == .direct { return "Pair again using Local Network before using Direct to Mac." }
        return nil
    }

    private func finishPairing(mac: LabMac, code: String) {
        let error: String?
        switch pairingOutcome {
        case .checkCode: error = code == Self.validCode ? nil : "Enter the pairing code shown on your Mac"
        case .rateLimited: error = "Wait a minute before pairing again"
        case .networkError: error = "The network connection was lost."
        }
        if let error {
            phase = .codeEntry
            pairingCode = ""
            pairingError = "\(healthOrigin ?? mac.origin)\n\(error)"
        } else {
            credentials.insert(mac)
            if let acceptedOrigin { authorizedAddresses[Self.originKey(acceptedOrigin)] = mac }
            phase = .codeEntry
            connect()
        }
    }

    func loseConnection() {
        guard isReady else { return }
        phase = .reconnecting("The network connection was lost.")
    }

    func revokePairing() {
        guard isReady, let mac else { return }
        forgetCredential(for: mac)
        phase = .codeEntry
        showCode()
    }

    func relaunch() {
        discovered = []
        discoveryError = nil
        voiceActive = false
        isRequestingVoice = false
        immersive = false
        immersiveTarget = nil
        immersiveError = nil
        acceptedOrigin = nil
        mac = rememberedMac
        host = rememberedHost
        method = mac.flatMap { methodsByMac[$0] } ?? .localNetwork
        if method == .localNetwork, normalizedHost.isEmpty {
            restartDiscovery()
        } else {
            phase = rememberedMac == nil ? .idle : .reconnecting("Connection interrupted.")
            startConnection(expected: mac, reconnect: rememberedMac != nil)
        }
        navigate(.launcher)
    }

    private func forgetCredential(for mac: LabMac) {
        credentials.remove(mac)
        directTrust.remove(mac)
        authorizedAddresses = authorizedAddresses.filter { $0.value != mac }
    }

    func reload() {
        if isReady { reloadCount += 1 }
    }

    func setImmersive(_ enabled: Bool) {
        guard immersiveTarget == nil, immersive != enabled else { return }
        immersiveError = nil
        immersiveTarget = enabled
    }

    func advanceImmersive() {
        guard let target = immersiveTarget else { return }
        immersiveTarget = nil
        if !target || immersiveOutcome == .opened { immersive = target }
        else if immersiveOutcome == .failed { immersiveError = Self.immersiveFailure }
    }

    func requestVoice() {
        if voicePermission != .granted { isRequestingVoice = true }
    }

    func cancelVoiceRequest() {
        isRequestingVoice = false
    }

    func advanceVoice() {
        guard isRequestingVoice else { return }
        isRequestingVoice = false
        voicePermission = nextVoicePermission
    }

    func requestCapture(settings: Bool) {
        guard capture == .permission && isReady else { return }
        captureAction = settings ? "Open Mac Privacy Settings" : "Allow Screen Recording on Mac"
    }

    private static func baseURL(_ address: String) -> URL? {
        let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, let url = URL(string: value.contains("://") ? value : "http://\(value)"),
              let host = url.host(), !host.isEmpty, url.scheme == "http" || url.scheme == "https" else { return nil }
        return url
    }

    private static func originKey(_ url: URL) -> String {
        let scheme = url.scheme?.lowercased() ?? "http"
        let host = url.host()?.lowercased() ?? ""
        return "\(scheme)://\(host):\(url.port ?? (scheme == "https" ? 443 : 80))"
    }
}
