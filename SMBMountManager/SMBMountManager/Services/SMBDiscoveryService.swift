import Foundation

struct DiscoveredSMBHost: Identifiable, Hashable {
    let serviceName: String
    let hostName: String
    let port: Int

    var id: String {
        "\(serviceName)|\(hostName)|\(port)"
    }

    var displayName: String {
        serviceName.isEmpty ? hostName : serviceName
    }

    var normalizedHostName: String {
        hostName.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }
}

@MainActor
final class SMBDiscoveryService: NSObject, ObservableObject {
    @Published private(set) var hosts: [DiscoveredSMBHost] = []
    @Published private(set) var isBrowsing = false
    @Published var errorMessage: String?

    private let browser = NetServiceBrowser()
    private var resolvingServices: [String: NetService] = [:]

    override init() {
        super.init()
        browser.delegate = self
    }

    func startBrowsing() {
        stopBrowsing()
        hosts = []
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
            port: service.port
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
            self.hosts.removeAll { $0.serviceName == service.name }
        }
    }
}

extension SMBDiscoveryService: NetServiceDelegate {
    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        Task { @MainActor in
            self.updateHost(from: sender)
            self.resolvingServices.removeValue(forKey: sender.name)
        }
    }

    nonisolated func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        Task { @MainActor in
            self.resolvingServices.removeValue(forKey: sender.name)
            LoggingService.shared.record(.warning, category: .discovery, message: "Failed to resolve SMB service \(sender.name): \(errorDict)")
        }
    }
}
