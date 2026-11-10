import Foundation
import Network
import Security

/// Native byte transport shared by the Mac ingress and the headset's loopback
/// adapter. HTTP, WebSocket framing, terminal replay, and media stay above it.
nonisolated enum NativeStream {
    static let queue = DispatchQueue(label: "com.slopzooka.transport")
    static let serviceType = "_slz-direct._tcp"
    static let admission = Data("SLZ-DIRECT-1\n".utf8)

    #if os(macOS)
    static func serverParameters(identity: URL) throws -> NWParameters {
        guard #available(macOS 15.0, *) else { throw URLError(.unsupportedURL) }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        var items: CFArray?
        let options = [kSecImportExportPassphrase as String: "slopzooka-local",
                       kSecImportToMemoryOnly as String: true] as CFDictionary
        let status = SecPKCS12Import(try Data(contentsOf: identity) as CFData, options, &items)
        guard status == errSecSuccess,
              let item = (items as? [[String: Any]])?.first,
              let raw = item[kSecImportItemIdentity as String], CFGetTypeID(raw as CFTypeRef) == SecIdentityGetTypeID(),
              let identity = sec_identity_create(unsafeBitCast(raw as CFTypeRef, to: SecIdentity.self)) else { throw URLError(.clientCertificateRejected) }
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, identity)

        return NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    }
    #endif

    static func clientParameters(authority: Data) throws -> NWParameters {
        guard let anchor = SecCertificateCreateWithData(nil, authority as CFData) else {
            throw URLError(.serverCertificateUntrusted)
        }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            let value = sec_trust_copy_ref(trust).takeRetainedValue()
            SecTrustSetPolicies(value, SecPolicyCreateSSL(true, "slopzooka.local" as CFString))
            SecTrustSetAnchorCertificates(value, [anchor] as CFArray)
            SecTrustSetAnchorCertificatesOnly(value, true)
            complete(SecTrustEvaluateWithError(value, nil))
        }, queue)
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.includePeerToPeer = true
        return parameters
    }
}

/// Transport reports metadata to its owner; it never owns a logger or log store.
/// Successful byte channels are counted, not logged (including log-upload traffic).
nonisolated struct StreamObservation: Sendable {
    typealias Sink = @Sendable (StreamObservation) -> Void
    let event: String
    let fields: [String: String]
}

/// One read/send in flight in each direction, at most 64 KiB per direction.
/// All state is confined to NativeStream.queue. Cancellation never replays bytes.
/// A waiting byte channel fails promptly; retry belongs to the API/WebSocket owner,
/// which knows whether its operation can be retried safely.
nonisolated final class StreamPipe: @unchecked Sendable {
    private let incoming: NWConnection
    private let outgoing: NWConnection
    private let admit: @Sendable (NWConnection) -> Bool
    private let readAdmission: Bool
    private let writeAdmission: Bool
    private let onClose: @Sendable ([String: String]?) -> Void
    private let started = ProcessInfo.processInfo.systemUptime
    private var stopped = false
    private var incomingReady = false
    private var outgoingReady = false
    private var pumping = false
    private var admitted = false
    private var endedDirections = 0

    init(incoming: NWConnection, outgoing: NWConnection,
         readAdmission: Bool = false, writeAdmission: Bool = false,
         admit: @escaping @Sendable (NWConnection) -> Bool = { _ in true },
         onClose: @escaping @Sendable ([String: String]?) -> Void) {
        self.incoming = incoming
        self.outgoing = outgoing
        self.readAdmission = readAdmission
        self.writeAdmission = writeAdmission
        self.admit = admit
        self.onClose = onClose
    }

    func start() {
        incoming.stateUpdateHandler = { [weak self] state in
            guard let self, !self.stopped else { return }
            switch state {
            case .ready:
                guard self.admit(self.incoming) else { self.stop(stage: "admission"); return }
                self.incomingReady = true
                self.outgoing.start(queue: NativeStream.queue)
                self.beginIfReady()
            case .failed(let error): self.stop(stage: "incoming", error: error)
            case .cancelled: self.stop()
            case .waiting(let error): self.stop(stage: "incoming", error: error)
            default: break
            }
        }
        outgoing.stateUpdateHandler = { [weak self] state in
            guard let self, !self.stopped else { return }
            switch state {
            case .ready: self.outgoingReady = true; self.beginIfReady()
            case .failed(let error): self.stop(stage: "outgoing", error: error)
            case .cancelled: self.stop()
            case .waiting(let error): self.stop(stage: "outgoing", error: error)
            default: break
            }
        }
        incoming.pathUpdateHandler = { [weak self] _ in
            guard let self, self.incomingReady, !self.stopped else { return }
            if !self.admit(self.incoming) { self.stop(stage: "path") }
        }
        incoming.start(queue: NativeStream.queue)
        NativeStream.queue.asyncAfter(deadline: .now() + 12) { [weak self] in
            if let self, !self.admitted { self.stop(stage: "deadline") }
        }
    }

    func stop(stage: String? = nil, error: NWError? = nil) {
        guard !stopped else { return }
        stopped = true
        incoming.pathUpdateHandler = nil
        incoming.stateUpdateHandler = nil
        outgoing.stateUpdateHandler = nil
        incoming.cancel()
        outgoing.cancel()
        var failure: [String: String]?
        if let stage {
            failure = ["stage": stage, "durationMs": String(Int((ProcessInfo.processInfo.systemUptime - started) * 1000))]
            if let error {
                failure?["errorDomain"] = (error as NSError).domain
                failure?["errorCode"] = String((error as NSError).code)
            }
        }
        onClose(failure)
    }

    private func beginIfReady() {
        guard incomingReady, outgoingReady, !pumping, !stopped else { return }
        pumping = true
        if readAdmission {
            outgoing.receive(minimumIncompleteLength: NativeStream.admission.count,
                             maximumLength: NativeStream.admission.count) { [weak self] data, _, end, error in
                guard let self else { return }
                guard error == nil, !end, data == NativeStream.admission else { self.stop(stage: "admission", error: error); return }
                self.pump()
            }
        } else if writeAdmission {
            incoming.send(content: NativeStream.admission, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if let error { self.stop(stage: "admission", error: error) } else { self.pump() }
            })
        } else { pump() }
    }

    private func pump() {
        guard !stopped else { return }
        admitted = true
        copy(from: incoming, to: outgoing)
        copy(from: outgoing, to: incoming)
    }

    private func copy(from: NWConnection, to: NWConnection) {
        guard !stopped else { return }
        from.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, end, error in
            guard let self, !self.stopped else { return }
            guard error == nil else { self.stop(stage: "read", error: error); return }
            to.send(content: data, isComplete: end, completion: .contentProcessed { [weak self] error in
                guard let self, !self.stopped else { return }
                if let error { self.stop(stage: "write", error: error) }
                else if end {
                    self.endedDirections += 1
                    if self.endedDirections == 2 { self.stop() }
                } else { self.copy(from: from, to: to) }
            })
        }
    }
}

/// Fixed destination, loopback-only listener. It is not an arbitrary-port proxy.
/// Keeping HTTP/WebSocket unchanged preserves one xterm reconnect state machine.
nonisolated final class StreamListener: @unchecked Sendable {
    private let listener: NWListener
    private let destination: @Sendable () throws -> NWConnection
    private let readAdmission: Bool
    private let writeAdmission: Bool
    private let admit: @Sendable (NWConnection) -> Bool
    private var pipes: [UUID: StreamPipe] = [:]
    private var stopped = false
    private var answered = false
    private let observe: StreamObservation.Sink
    private var reportedFailures: Set<String> = []
    private var opened = 0
    private var failures = 0

    init(parameters: NWParameters, serviceName: String? = nil,
         observe: @escaping StreamObservation.Sink = { _ in },
         readAdmission: Bool = false, writeAdmission: Bool = false,
         admit: @escaping @Sendable (NWConnection) -> Bool = { _ in true },
         destination: @escaping @Sendable () throws -> NWConnection) throws {
        self.listener = try NWListener(using: parameters)
        self.observe = observe
        self.destination = destination
        self.readAdmission = readAdmission
        self.writeAdmission = writeAdmission
        self.admit = admit
        if let serviceName { listener.service = NWListener.Service(name: serviceName, type: NativeStream.serviceType) }
    }

    func start(completion: @escaping @Sendable (Result<UInt16, Error>) -> Void) {
        NativeStream.queue.async { [self] in
            guard !stopped else { completion(.failure(URLError(.cancelled))); return }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    if !self.answered, let port = self.listener.port {
                        self.answered = true
                        self.observe(StreamObservation(event: "listener.ready", fields: [:]))
                        completion(.success(port.rawValue))
                    }
                case .failed(let error):
                    self.observe(StreamObservation(event: "listener.failed", fields: ["errorDomain": (error as NSError).domain, "errorCode": String((error as NSError).code)]))
                    if !self.answered { self.answered = true; completion(.failure(error)) }
                    self.stopOnQueue()
                case .cancelled:
                    if !self.answered { self.answered = true; completion(.failure(URLError(.cancelled))) }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] incoming in
                guard let self, !self.stopped else { incoming.cancel(); return }
                guard self.pipes.count < 64 else {
                    self.failed(["stage": "capacity"])
                    incoming.cancel(); return
                }
                do {
                    let id = UUID()
                    let pipe = StreamPipe(incoming: incoming, outgoing: try self.destination(),
                        readAdmission: self.readAdmission, writeAdmission: self.writeAdmission, admit: self.admit,
                        onClose: { [weak self] failure in
                            self?.pipes.removeValue(forKey: id)
                            if var failure {
                                failure["connectionId"] = id.uuidString
                                self?.failed(failure)
                            }
                        })
                    self.opened += 1
                    self.pipes[id] = pipe
                    pipe.start()
                } catch {
                    self.failed(["stage": "destination", "errorDomain": (error as NSError).domain, "errorCode": String((error as NSError).code)])
                    incoming.cancel()
                }
            }
            listener.start(queue: NativeStream.queue)
            NativeStream.queue.asyncAfter(deadline: .now() + 10) { [weak self] in
                guard let self, !self.answered else { return }
                self.answered = true
                completion(.failure(URLError(.timedOut)))
                self.stopOnQueue()
            }
        }
    }

    // One sample per finite failure stage for this route. In particular, repeated
    // failed diagnostics uploads cannot recursively refill their own log outbox.
    private func failed(_ fields: [String: String]) {
        failures += 1
        guard reportedFailures.insert(fields["stage"] ?? "unknown").inserted else { return }
        observe(StreamObservation(event: "stream.failed", fields: fields))
    }

    func stop() { NativeStream.queue.async { [self] in stopOnQueue() } }
    private func stopOnQueue() {
        guard !stopped else { return }
        stopped = true
        observe(StreamObservation(event: "listener.stopped", fields: ["opened": String(opened), "failed": String(failures), "active": String(pipes.count)]))
        listener.cancel()
        for pipe in Array(pipes.values) { pipe.stop() }
        pipes.removeAll()
    }
}
