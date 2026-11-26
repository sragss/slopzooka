@main
@MainActor
struct LabModelChecks {
    static func main() {
        presets()
        pairingAndRecovery()
        directAndMacSelection()
        cancelConnectionAttempts()
        automaticFixtureConnection()
        permissionsAndSettings()
        print("PASS: \(LabScenario.allCases.count) presets, pairing, recovery, Direct, settings, and permissions")
    }

    private static func automaticFixtureConnection() {
        let lab = LabModel(scenario: .multipleMacs)
        lab.select(LabMac.studio.address)
        guard let cancelled = lab.automaticConnectionID else { preconditionFailure("Expected a timed check") }
        lab.cancelConnection()
        lab.select(LabMac.laptop.address)
        guard let current = lab.automaticConnectionID else { preconditionFailure("Expected a new timed check") }
        lab.completeAutomaticConnection(cancelled)
        precondition(lab.phase == .checking && !lab.isReady)
        lab.completeAutomaticConnection(current)
        precondition(lab.isReady && lab.workspaceMacName == LabMac.laptop.rawValue)
        lab.changeMethod(.direct)
        guard let direct = lab.automaticConnectionID else { preconditionFailure("Expected a timed Direct check") }
        lab.completeAutomaticConnection(direct)
        precondition(lab.isReady && lab.method == .direct)

        lab.load(.multipleMacs)
        lab.faults[.localNetwork] = .offline
        lab.select(LabMac.studio.address)
        guard let offline = lab.automaticConnectionID else { preconditionFailure("Expected a timed failure") }
        lab.completeAutomaticConnection(offline)
        precondition(lab.phase.error != nil && lab.workspaceMacName == nil)
    }

    private static func cancelConnectionAttempts() {
        let lab = LabModel(scenario: .multipleMacs)
        lab.select(LabMac.laptop.address)
        precondition(lab.phase == .checking)
        lab.cancelConnection()
        lab.advanceConnection()
        precondition(lab.phase == .idle && lab.mac == nil && lab.discovered.count == 2 && lab.pendingLabel == nil)

        lab.load(.pairingSubmitting)
        lab.cancelConnection()
        lab.advanceConnection()
        precondition(lab.phase == .codeEntry && lab.pairingCode.isEmpty && lab.pendingLabel == nil)
        lab.enterCode(LabModel.validCode)
        lab.advanceConnection()
        lab.cancelConnection()
        precondition(lab.phase == .codeEntry && lab.isCodeDisplayed)

        lab.load(.connected)
        lab.changeMethod(.direct)
        precondition(lab.phase == .checking)
        lab.cancelConnection()
        lab.advanceConnection()
        precondition(lab.isReady && lab.method == .localNetwork && lab.workspaceMacName == LabMac.studio.rawValue)
        lab.relaunch()
        lab.advanceConnection()
        precondition(lab.isReady && lab.method == .localNetwork)

        lab.loseConnection()
        precondition(!lab.isReconnectAttempt)
        lab.connect()
        precondition(lab.isReconnectAttempt)
        lab.cancelConnection()
        precondition(lab.phase.isReconnecting && lab.pendingLabel == nil && !lab.isReconnectAttempt)
    }

    private static func presets() {
        let lab = LabModel()
        for scenario in LabScenario.allCases {
            lab.load(scenario)
            switch scenario {
            case .discovering, .manual:
                precondition(lab.phase == .idle && lab.pendingLabel == "Complete discovery")
            case .noMacs:
                precondition(lab.phase == .idle && lab.pendingLabel == nil && lab.discovered.isEmpty)
            case .checking, .directChecking:
                precondition(lab.phase == .checking && lab.pendingLabel == "Complete connection check")
            case .discoveryDenied, .discoveryFailed:
                precondition(lab.phase == .idle && lab.discoveryError != nil)
            case .invalidAddress, .unreachable, .incompatible, .wrongMac, .directUnpaired, .directUnprepared,
                 .directOffline, .directUnsupported, .directWrongMac, .directRevoked:
                precondition(lab.phase.error != nil && !lab.phase.isReconnecting)
            case .localReconnecting, .directReconnecting:
                precondition(lab.phase.isReconnecting)
            case .localRetrying:
                precondition(lab.phase == .checking && lab.isReconnectAttempt)
            case .multipleMacs:
                precondition(lab.phase == .idle && lab.discovered.count == 2 && lab.workspaceMacName == nil)
            case .pairing, .pairingRevoked:
                precondition(lab.needsPairing && lab.isCodeDisplayed)
            case .codeHidden:
                lab.requestCodeDisplay()
                precondition(lab.needsPairing && !lab.isCodeDisplayed)
            case .pairingSubmitting:
                precondition(lab.isPairing && !lab.canChangeConnection)
            case .pairingRejected, .pairingLimited, .pairingNetworkError:
                precondition(lab.phase == .codeEntry && lab.pairingCode.isEmpty && lab.pairingError != nil)
            default:
                precondition(lab.isReady)
            }
        }
    }

    private static func pairingAndRecovery() {
        let lab = LabModel(scenario: .discoveryDenied)
        lab.discoveryOutcome = .twoMacs
        lab.restartDiscovery()
        lab.advanceConnection()
        precondition(lab.discoveryError == nil && lab.discovered.count == 2 && lab.phase == .idle && lab.mac == nil)
        lab.select(LabMac.studio.address)
        lab.advanceConnection()
        precondition(lab.phase == .codeEntry && lab.isCodeDisplayed)

        lab.enterCode("a12９3")
        precondition(lab.pairingCode == "123" && !lab.isPairing)
        lab.enterCode("000-0009")
        precondition(lab.pairingCode == "000000" && lab.isPairing)
        lab.advanceConnection()
        precondition(lab.pairingError?.contains("Enter the pairing code shown on your Mac") == true)
        lab.enterCode(LabModel.validCode)
        lab.advanceConnection()
        precondition(lab.phase == .checking && lab.pairingError == nil)
        lab.advanceConnection()
        precondition(lab.isReady && !lab.isCodeDisplayed && lab.workspaceMacName == LabMac.studio.rawValue)

        lab.findMacs()
        precondition(lab.isReady && lab.isDiscovering)
        lab.advanceConnection()
        precondition(lab.isReady && lab.discovered.count == 2)

        lab.select("http://studio-mac.local:7777/")
        lab.advanceConnection()
        precondition(lab.isReady, "Equivalent origins reuse the fixture pairing")

        lab.loseConnection()
        precondition(lab.workspaceMacName == LabMac.studio.rawValue && !lab.isReady)
        lab.faults[.localNetwork] = .offline
        lab.connect()
        lab.advanceConnection()
        precondition(lab.phase.isReconnecting && lab.workspaceMacName == LabMac.studio.rawValue)
        lab.faults[.localNetwork] = .healthy
        lab.connect()
        lab.advanceConnection()
        precondition(lab.isReady)

        lab.select(LabMac.studio.manualIP)
        lab.advanceConnection()
        precondition(lab.needsPairing, "A new LAN address needs its own first pairing")
        lab.enterCode(LabModel.validCode)
        lab.load(.directOffline)
        lab.advanceConnection()
        precondition(lab.method == .direct && lab.phase.error != nil, "Reset discards a staged pairing response")
    }

    private static func directAndMacSelection() {
        let lab = LabModel(scenario: .directUnprepared)
        precondition(lab.phase.error?.contains("prepare Direct to Mac") == true)
        lab.changeMethod(.localNetwork)
        lab.advanceConnection()
        precondition(lab.isReady)
        lab.changeMethod(.direct)
        lab.advanceConnection()
        precondition(lab.isReady && lab.method == .direct && lab.discovered.isEmpty)
        lab.relaunch()
        lab.advanceConnection()
        precondition(lab.isReady && lab.method == .direct)

        lab.load(.directOffline)
        lab.connect()
        lab.advanceConnection()
        precondition(lab.method == .direct && !lab.isReady)
        lab.changeMethod(.localNetwork)
        lab.advanceConnection()
        precondition(lab.isReady && lab.method == .localNetwork)
        lab.load(.directRevoked)
        lab.changeMethod(.localNetwork)
        lab.advanceConnection()
        precondition(lab.needsPairing)

        lab.load(.multipleMacs)
        lab.autoConnectFixture = false
        lab.select(LabMac.laptop.address)
        lab.advanceConnection()
        precondition(lab.needsPairing && lab.selectedMacName == LabMac.laptop.rawValue)
        lab.enterCode(LabModel.validCode)
        lab.advanceConnection()
        lab.advanceConnection()
        precondition(lab.mac == .laptop && lab.isReady)
        lab.select(LabMac.studio.address)
        lab.advanceConnection()
        precondition(lab.needsPairing && lab.mac == .studio && lab.workspaceMacName == LabMac.laptop.rawValue)
        lab.relaunch()
        lab.advanceConnection()
        precondition(lab.phase.error?.contains("did not authenticate the selected Mac") == true)
    }

    private static func permissionsAndSettings() {
        let lab = LabModel(scenario: .voiceActive)
        precondition(lab.surface == .settings && lab.voiceActive)
        lab.reload()
        lab.loseConnection()
        lab.reload()
        precondition(lab.reloadCount == 1)

        lab.load(.micNotAsked)
        lab.requestVoice()
        lab.cancelVoiceRequest()
        lab.advanceVoice()
        precondition(lab.voicePermission == .undetermined && !lab.isRequestingVoice)
        lab.requestVoice()
        lab.nextVoicePermission = .speechDenied
        lab.advanceVoice()
        precondition(lab.voicePermission == .speechDenied && !lab.isRequestingVoice)
        lab.requestVoice()
        lab.nextVoicePermission = .granted
        lab.advanceVoice()
        precondition(lab.voicePermission == .granted)

        lab.load(.immersiveUpdating)
        lab.immersiveOutcome = .cancelled
        lab.advanceImmersive()
        precondition(!lab.immersive && lab.immersiveError == nil)
        lab.setImmersive(true)
        lab.immersiveOutcome = .failed
        lab.advanceImmersive()
        precondition(!lab.immersive && lab.immersiveError == LabModel.immersiveFailure)
        lab.setImmersive(true)
        lab.immersiveOutcome = .opened
        lab.advanceImmersive()
        precondition(lab.immersive && lab.immersiveError == nil)
        lab.setImmersive(false)
        lab.advanceImmersive()
        precondition(!lab.immersive)

        lab.load(.capturePermission)
        lab.requestCapture(settings: true)
        precondition(lab.surface == .frontends && lab.captureAction == "Open Mac Privacy Settings")
        lab.requestCapture(settings: false)
        precondition(lab.captureAction == "Allow Screen Recording on Mac")
        lab.capture = .ready
        precondition(lab.capture.message == nil)
    }
}
