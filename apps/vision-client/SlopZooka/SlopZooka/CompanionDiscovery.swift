import Foundation
import Combine

@MainActor
final class CompanionDiscovery: NSObject, ObservableObject {
    @Published private(set) var companions: [DiscoveredCompanion] = []
    @Published private(set) var state: CompanionDiscoveryState = .idle

    var onCompanionResolved: ((DiscoveredCompanion) -> Void)?

    private let browser = NetServiceBrowser()
    private var resolvedServices: [String: NetService] = [:]
    private let serviceType = "_slopzooka._tcp."
    private let serviceDomain = "local."

    override init() {
        super.init()
        browser.delegate = self
    }

    var preferredHost: String? {
        companions.first?.host
    }

    func start() {
        slzLog("bonjour browse start type=\(serviceType)")
        state = .searching
        browser.searchForServices(ofType: serviceType, inDomain: serviceDomain)
    }

    func stop() {
        browser.stop()
        for service in resolvedServices.values {
            service.stop()
        }
        resolvedServices.removeAll()
        state = .idle
        slzLog("bonjour browse stop")
    }

    private func serviceKey(_ service: NetService) -> String {
        "\(service.name)|\(service.type)|\(service.domain)"
    }

    private func upsertResolvedService(_ service: NetService) {
        guard service.port > 0 else {
            return
        }

        guard let hostName = normalizedHostName(service.hostName) else {
            slzLog("bonjour resolved service missing hostname name=\(service.name)")
            return
        }

        let candidateHosts = orderedUniqueHosts([
            "\(hostName):\(service.port)"
        ])
        let host = candidateHosts.first ?? "\(hostName):\(service.port)"
        let item = DiscoveredCompanion(
            id: serviceKey(service),
            name: service.name,
            host: host,
            hostname: hostName,
            port: service.port,
            candidateHosts: candidateHosts
        )

        if let index = companions.firstIndex(where: { $0.id == item.id }) {
            companions[index] = item
        } else {
            companions.append(item)
            companions.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }

        state = .found(count: companions.count)
        slzLog("bonjour resolved service name=\(service.name) host=\(host)")
        onCompanionResolved?(item)
    }

    private func removeService(_ service: NetService) {
        let key = serviceKey(service)
        resolvedServices[key]?.stop()
        resolvedServices.removeValue(forKey: key)
        companions.removeAll { $0.id == key }
        state = companions.isEmpty ? .searching : .found(count: companions.count)
        slzLog("bonjour removed service name=\(service.name)")
    }

    private func normalizedHostName(_ value: String?) -> String? {
        guard let value else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if trimmed.hasSuffix(".") {
            return String(trimmed.dropLast())
        }

        return trimmed
    }

    private func orderedUniqueHosts(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                continue
            }

            guard !seen.contains(trimmed) else {
                continue
            }

            seen.insert(trimmed)
            result.append(trimmed)
        }

        return result
    }
}

extension CompanionDiscovery: NetServiceBrowserDelegate {
    func netServiceBrowserWillSearch(_ browser: NetServiceBrowser) {
        slzLog("bonjour search active")
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String : NSNumber]) {
        let message = "Bonjour search failed: \(errorDict)"
        state = .failed(message)
        slzLog(message)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        resolvedServices[serviceKey(service)] = service
        service.resolve(withTimeout: 5)
        slzLog("bonjour found service name=\(service.name)")
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        removeService(service)
    }
}

extension CompanionDiscovery: NetServiceDelegate {
    func netServiceDidResolveAddress(_ sender: NetService) {
        upsertResolvedService(sender)
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
        resolvedServices.removeValue(forKey: serviceKey(sender))
        let message = "Bonjour resolve failed for \(sender.name): \(errorDict)"
        slzLog(message)
        if companions.isEmpty {
            state = .searching
        }
    }
}
