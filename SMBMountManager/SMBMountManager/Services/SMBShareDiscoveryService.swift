import Foundation

enum SMBShareOutputParser {
    static func parseShares(from output: String, serverAddress: String) -> [DiscoveredSMBShare] {
        let ignoredPrefixes = ["Share", "-", "Server", "Comment"]
        let separatorPattern = try? NSRegularExpression(pattern: "\\s{2,}")

        let shares = output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                !line.isEmpty && !ignoredPrefixes.contains { line.hasPrefix($0) }
            }
            .compactMap { line -> DiscoveredSMBShare? in
                let parts = splitColumns(in: line, using: separatorPattern)
                guard let name = parts.first, name.isEmpty == false else {
                    return nil
                }

                let type = parts.count > 1 ? parts[1] : "Unknown"
                let comment = parts.count > 2 ? parts[2] : ""

                return DiscoveredSMBShare(
                    name: name,
                    type: type,
                    comment: comment,
                    serverAddress: serverAddress
                )
            }

        return Array(Dictionary(uniqueKeysWithValues: shares.map { ($0.id, $0) }).values).sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private static func splitColumns(in line: String, using regex: NSRegularExpression?) -> [String] {
        guard let regex else {
            return [line]
        }

        let nsRange = NSRange(line.startIndex..<line.endIndex, in: line)
        let matches = regex.matches(in: line, range: nsRange)
        guard matches.isEmpty == false else {
            return [line]
        }

        var parts: [String] = []
        var currentIndex = line.startIndex

        for match in matches {
            guard let range = Range(match.range, in: line) else {
                continue
            }

            let column = line[currentIndex..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            if column.isEmpty == false {
                parts.append(column)
            }
            currentIndex = range.upperBound
        }

        let trailing = line[currentIndex...].trimmingCharacters(in: .whitespacesAndNewlines)
        if trailing.isEmpty == false {
            parts.append(trailing)
        }

        if parts.count > 3 {
            return [parts[0], parts[1], parts.dropFirst(2).joined(separator: " ")]
        }

        return parts
    }
}

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
    ) async throws -> [DiscoveredSMBShare] {
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
                    let shares = SMBShareOutputParser.parseShares(from: output, serverAddress: trimmedServer)
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
}
