import Foundation

enum SMBShareDiscoveryError: LocalizedError {
    case invalidInput
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .invalidInput:
            return "Server, username and password are required to discover shares."
        case .failed(let message):
            return message
        }
    }
}

struct SMBShareDiscoveryService {
    static func discoverShares(
        serverAddress: String,
        username: String,
        password: String
    ) async throws -> [String] {
        let trimmedServer = serverAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedServer.isEmpty, !trimmedUsername.isEmpty, !trimmedPassword.isEmpty else {
            throw SMBShareDiscoveryError.invalidInput
        }

        LoggingService.shared.record(.info, category: .discovery, message: "Starting share discovery for SMB host \(trimmedServer)")

        let encodedUsername = trimmedUsername.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? trimmedUsername
        let encodedPassword = trimmedPassword.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? trimmedPassword
        let target = "//\(encodedUsername):\(encodedPassword)@\(trimmedServer)"

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let standardOutput = Pipe()
            let standardError = Pipe()

            process.executableURL = URL(fileURLWithPath: "/usr/bin/smbutil")
            process.arguments = ["view", target]
            process.standardOutput = standardOutput
            process.standardError = standardError

            process.terminationHandler = { process in
                let outputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
                let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: outputData, encoding: .utf8) ?? ""
                let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

                if process.terminationStatus == 0 {
                    let shares = parseShares(from: output)
                    LoggingService.shared.record(.info, category: .discovery, message: "Share discovery for \(trimmedServer) returned \(shares.count) entries")
                    continuation.resume(returning: shares)
                } else {
                    let failureReason = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                    LoggingService.shared.record(.error, category: .discovery, message: "Share discovery failed for \(trimmedServer): \(failureReason)")
                    continuation.resume(throwing: SMBShareDiscoveryError.failed(
                        failureReason.isEmpty ? "Share discovery failed with exit code \(process.terminationStatus)." : failureReason
                    ))
                }
            }

            do {
                try process.run()
            } catch {
                LoggingService.shared.record(.error, category: .discovery, message: "Unable to launch smbutil for \(trimmedServer): \(error.localizedDescription)")
                continuation.resume(throwing: error)
            }
        }
    }

    private static func parseShares(from output: String) -> [String] {
        let ignoredPrefixes = ["Share", "-", "Server", "Comment"]

        let shares = output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                !line.isEmpty && !ignoredPrefixes.contains { line.hasPrefix($0) }
            }
            .compactMap { line in
                line.split(whereSeparator: \.isWhitespace).first.map(String.init)
            }

        return Array(Set(shares)).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }
}
