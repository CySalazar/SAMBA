import Foundation

enum ConnectionStatus: Equatable {
    case disconnected
    case connecting
    case connected
    case error(String)

    var label: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .error(let msg): return "Error: \(msg)"
        }
    }
}

struct SMBConnection: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var serverAddress: String
    var shareName: String
    var username: String
    var autoConnect: Bool

    var mountPoint: String {
        let sanitizedServer = serverAddress
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let sanitizedShareName = shareName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let folderName = [sanitizedServer, sanitizedShareName]
            .filter { $0.isEmpty == false }
            .joined(separator: "-")

        return "\(NSHomeDirectory())/Volumes/\(folderName.isEmpty ? id.uuidString : folderName)"
    }

    var smbURL: String {
        "smb://\(serverAddress)/\(shareName)"
    }

    init(
        id: UUID = UUID(),
        name: String = "",
        serverAddress: String = "",
        shareName: String = "",
        username: String = "",
        autoConnect: Bool = false
    ) {
        self.id = id
        self.name = name
        self.serverAddress = serverAddress
        self.shareName = shareName
        self.username = username
        self.autoConnect = autoConnect
    }
}
