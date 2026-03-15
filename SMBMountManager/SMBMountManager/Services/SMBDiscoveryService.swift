import Foundation

struct DiscoveredSMBHost: Identifiable, Hashable {
    let serviceName: String
    let hostName: String
    let port: Int
    let ipAddresses: [String]
    let lastResolvedAt: Date
    let resolveDuration: TimeInterval?

    var id: String {
        "\(serviceName)|\(hostName)|\(port)"
    }

    var displayName: String {
        serviceName.isEmpty ? hostName : serviceName
    }

    var normalizedHostName: String {
        hostName.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    var secondaryDetails: String {
        let addresses = ipAddresses.isEmpty ? "No IP yet" : ipAddresses.joined(separator: ", ")
        return "\(addresses) • Port \(port)"
    }
}

@MainActor
final class SMBDiscoveryService: NSObject, ObservableObject {
    @Published private(set) var hosts: [DiscoveredSMBHost] = []
    @Published private(set) var isBrowsing = false
    @Published var errorMessage: String?

    private let browser = NetServiceBrowser()
    private var resolvingServices: [String: NetService] = [:]
    private var resolveStartedAt: [String: Date] = [:]

    override init() {
        super.init()
        browser.delegate = self
    }

    func startBrowsing() {
        stopBrowsing()
        errorMessage = nil
        isBrowsing = true
        LoggingService.shared.record(.info, category: .discovery, message: "Starting Bonjour discovery for SMB services")
        browser.searchForServices(ofType: "_smb._tcp.", inDomain: "local.")
    }

    func stopBrowsing() {
        if isBrowsing {
            LoggingService.shared.record(.debug, category: .discovery, message: "Stopping Bonjour discovery")
        }
        browser.stop()
        resolvingServices.values.forEach { $0.stop() }
        resolvingServices.removeAll()
        resolveStartedAt.removeAll()
        isBrowsing = false
    }

    private func updateHost(from service: NetService) {
        guard let hostName = service.hostName?.trimmingCharacters(in: CharacterSet(charactersIn: ".")),
              !hostName.isEmpty else {
            return
        }

        let discoveredHost = DiscoveredSMBHost(
            serviceName: service.name,
            hostName: hostName,
            port: service.port,
            ipAddresses: resolvedIPAddresses(for: service),
            lastResolvedAt: Date(),
            resolveDuration: resolveDuration(for: service.name)
        )

        if let existingIndex = hosts.firstIndex(where: { $0.id == discoveredHost.id }) {
            hosts[existingIndex] = discoveredHost
        } else {
            hosts.append(discoveredHost)
            hosts.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        }

        LoggingService.shared.record(.info, category: .discovery, message: "Discovered SMB host \(discoveredHost.displayName) at \(discoveredHost.normalizedHostName):\(discoveredHost.port)")
    }
}

extension SMBDiscoveryService: NetServiceBrowserDelegate {
    nonisolated func netServiceBrowserWillSearch(_ browser: NetServiceBrowser) {
        Task { @MainActor in
            self.errorMessage = nil
        }
    }

    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        Task { @MainActor in
            self.resolvingServices[service.name] = service
            self.resolveStartedAt[service.name] = Date()
            service.delegate = self
            service.resolve(withTimeout: 5)
        }
    }

    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        Task { @MainActor in
            self.isBrowsing = false
            self.errorMessage = "Unable to browse SMB services on the local network."
            LoggingService.shared.record(.error, category: .discovery, message: "Bonjour browser failed with \(errorDict)")
        }
    }

    nonisolated func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        Task { @MainActor in
            self.isBrowsing = false
        }
    }

    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        Task { @MainActor in
            self.resolvingServices.removeValue(forKey: service.name)
            self.resolveStartedAt.removeValue(forKey: service.name)
        }
    }
}

extension SMBDiscoveryService: NetServiceDelegate {
    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        Task { @MainActor in
            self.updateHost(from: sender)
            self.resolvingServices.removeValue(forKey: sender.name)
            self.resolveStartedAt.removeValue(forKey: sender.name)
        }
    }

    nonisolated func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        Task { @MainActor in
            self.resolvingServices.removeValue(forKey: sender.name)
            self.resolveStartedAt.removeValue(forKey: sender.name)
            LoggingService.shared.record(.warning, category: .discovery, message: "Failed to resolve SMB service \(sender.name): \(errorDict)")
        }
    }
}

private extension SMBDiscoveryService {
    func resolveDuration(for serviceName: String) -> TimeInterval? {
        guard let startedAt = resolveStartedAt[serviceName] else {
            return nil
        }

        return Date().timeIntervalSince(startedAt)
    }

    func resolvedIPAddresses(for service: NetService) -> [String] {
        guard let addresses = service.addresses else {
            return []
        }

        let hostAddresses = addresses.compactMap { data -> String? in
            data.withUnsafeBytes { rawBufferPointer in
                guard let baseAddress = rawBufferPointer.baseAddress else {
                    return nil
                }

                let sockaddrPointer = baseAddress.assumingMemoryBound(to: sockaddr.self)
                var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))

                let result = getnameinfo(
                    sockaddrPointer,
                    socklen_t(data.count),
                    &hostBuffer,
                    socklen_t(hostBuffer.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )

                guard result == 0 else {
                    return nil
                }

                return String(cString: hostBuffer)
            }
        }

        return Array(Set(hostAddresses)).sorted()
    }
}
