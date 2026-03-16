import Foundation

enum PersistenceCodec {
    static func decodeConnections(from data: Data) throws -> [SMBConnection] {
        try JSONDecoder().decode([SMBConnection].self, from: data)
    }

    static func encodeConnections(_ connections: [SMBConnection]) throws -> Data {
        try JSONEncoder().encode(connections)
    }

    static func decodeRuntimeDetails(from data: Data) throws -> [UUID: SMBConnectionRuntimeDetails] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([UUID: SMBConnectionRuntimeDetails].self, from: data)
    }

    static func encodeRuntimeDetails(_ runtimeDetails: [UUID: SMBConnectionRuntimeDetails]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(runtimeDetails)
    }
}

struct PersistenceService {
    struct PersistedConnectionState: Codable {
        var connections: [SMBConnection]
        var runtimeDetails: [UUID: SMBConnectionRuntimeDetails]
    }

    private static var directoryURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("SMBMountManager", isDirectory: true)
    }

    private static var fileURL: URL {
        directoryURL.appendingPathComponent("connections.json")
    }

    private static var runtimeDetailsURL: URL {
        directoryURL.appendingPathComponent("runtime-details.json")
    }

    static func load() -> [SMBConnection] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            LoggingService.shared.record(.debug, category: .persistence, message: "No persisted connections found at \(fileURL.path)")
            return []
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let connections = try PersistenceCodec.decodeConnections(from: data)
            LoggingService.shared.record(.info, category: .persistence, message: "Loaded \(connections.count) persisted connections")
            return connections
        } catch {
            LoggingService.shared.record(.error, category: .persistence, message: "Failed to load connections: \(error.localizedDescription)")
            return []
        }
    }

    static func save(_ connections: [SMBConnection]) {
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let data = try PersistenceCodec.encodeConnections(connections)
            try data.write(to: fileURL, options: .atomic)
            LoggingService.shared.record(.info, category: .persistence, message: "Saved \(connections.count) connections")
        } catch {
            LoggingService.shared.record(.error, category: .persistence, message: "Failed to save connections: \(error.localizedDescription)")
        }
    }

    static func loadRuntimeDetails() -> [UUID: SMBConnectionRuntimeDetails] {
        guard FileManager.default.fileExists(atPath: runtimeDetailsURL.path) else {
            return [:]
        }

        do {
            let data = try Data(contentsOf: runtimeDetailsURL)
            let details = try PersistenceCodec.decodeRuntimeDetails(from: data)
            LoggingService.shared.record(.info, category: .persistence, message: "Loaded runtime details for \(details.count) connections")
            return details
        } catch {
            LoggingService.shared.record(.warning, category: .persistence, message: "Failed to load runtime details: \(error.localizedDescription)")
            return [:]
        }
    }

    static func saveRuntimeDetails(_ runtimeDetails: [UUID: SMBConnectionRuntimeDetails]) {
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let data = try PersistenceCodec.encodeRuntimeDetails(runtimeDetails)
            try data.write(to: runtimeDetailsURL, options: .atomic)
        } catch {
            LoggingService.shared.record(.warning, category: .persistence, message: "Failed to save runtime details: \(error.localizedDescription)")
        }
    }
}
