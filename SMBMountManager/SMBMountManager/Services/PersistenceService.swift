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
            return []
        }
        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode([SMBConnection].self, from: data)
        } catch {
            print("Failed to load connections: \(error)")
            return []
        }
    }

    static func save(_ connections: [SMBConnection]) {
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(connections)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("Failed to save connections: \(error)")
        }
    }
}
