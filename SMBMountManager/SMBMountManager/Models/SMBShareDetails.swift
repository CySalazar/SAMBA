import Foundation

struct DiscoveredSMBShare: Identifiable, Hashable {
    let name: String
    let type: String
    let comment: String
    let serverAddress: String

    var id: String {
        "\(serverAddress.lowercased())/\(name.lowercased())"
    }

    var isHidden: Bool {
        name.hasSuffix("$")
    }

    var smbURL: String {
        "smb://\(serverAddress)/\(name)"
    }
}

enum ConnectionStabilityGrade: String {
    case insufficientHistory
    case low
    case medium
    case high

    var title: String {
        switch self {
        case .insufficientHistory:
            return "Insufficient History"
        case .low:
            return "Low"
        case .medium:
            return "Medium"
        case .high:
            return "High"
        }
    }
}

enum ConnectionConfidenceLevel: String {
    case low
    case medium
    case high

    var title: String {
        rawValue.capitalized
    }
}

struct SMBBenchmarkResult {
    let timestamp: Date
    let payloadSizeBytes: Int
    let writeDuration: TimeInterval
    let readDuration: TimeInterval

    var writeThroughputMBps: Double {
        throughput(for: writeDuration)
    }

    var readThroughputMBps: Double {
        throughput(for: readDuration)
    }

    private func throughput(for duration: TimeInterval) -> Double {
        guard duration > 0 else {
            return 0
        }

        let megabytes = Double(payloadSizeBytes) / 1_048_576
        return megabytes / duration
    }
}

struct SMBConnectionRuntimeDetails {
    var lastMountDuration: TimeInterval?
    var lastProbeLatency: TimeInterval?
    var averageProbeLatency: TimeInterval?
    var probeLatencyJitter: TimeInterval?
    var successfulMounts: Int = 0
    var failedMounts: Int = 0
    var disconnectCount: Int = 0
    var automaticRetryCount: Int = 0
    var totalConnectedDuration: TimeInterval = 0
    var totalDisconnectedDuration: TimeInterval = 0
    var protocolVersion: String?
    var signingState: String?
    var encryptionState: String?
    var multichannelState: String?
    var sessionAttributes: [String: String] = [:]
    var benchmarkResult: SMBBenchmarkResult?
    var benchmarkStatusMessage: String?
    var isBenchmarkRunning = false
    var stabilityGrade: ConnectionStabilityGrade = .insufficientHistory
    var confidenceLevel: ConnectionConfidenceLevel = .low
}
