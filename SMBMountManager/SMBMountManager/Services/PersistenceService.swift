import Foundation

struct PersistenceService {
    private static var directoryURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("SMBMountManager", isDirectory: true)
    }

    private static var fileURL: URL {
        directoryURL.appendingPathComponent("connections.json")
    }

    static func load() -> [SMBConnection] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            LoggingService.shared.record(.debug, category: .persistence, message: "No persisted connections found at \(fileURL.path)")
            return []
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let connections = try JSONDecoder().decode([SMBConnection].self, from: data)
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
            let data = try JSONEncoder().encode(connections)
            try data.write(to: fileURL, options: .atomic)
            LoggingService.shared.record(.info, category: .persistence, message: "Saved \(connections.count) connections")
        } catch {
            LoggingService.shared.record(.error, category: .persistence, message: "Failed to save connections: \(error.localizedDescription)")
        }
    }
}
