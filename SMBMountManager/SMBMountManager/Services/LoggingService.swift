import Foundation
import OSLog

enum LogSeverity: String, CaseIterable, Identifiable {
    case error
    case warning
    case info
    case debug

    var id: String { rawValue }
}

enum LogCategory: String {
    case app
    case mount
    case discovery
    case keychain
    case persistence
    case ui
}

enum LogVisibilityMode: String, CaseIterable, Identifiable {
    case hidden
    case errorsOnly
    case standard
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hidden: return "Hidden"
        case .errorsOnly: return "Errors Only"
        case .standard: return "Standard"
        case .all: return "All"
        }
    }
}

struct LogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let severity: LogSeverity
    let category: LogCategory
    let message: String
}

enum LogExportFormat: String, CaseIterable, Identifiable {
    case plainText
    case json
    case csv
    case markdown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .plainText:
            return "Plain Text"
        case .json:
            return "JSON"
        case .csv:
            return "CSV"
        case .markdown:
            return "Markdown"
        }
    }

    var fileExtension: String {
        switch self {
        case .plainText:
            return "txt"
        case .json:
            return "json"
        case .csv:
            return "csv"
        case .markdown:
            return "md"
        }
    }
}

enum LogExportFormatter {
    static func export(_ entries: [LogEntry], format: LogExportFormat) -> String {
        switch format {
        case .plainText:
            return exportPlainText(entries)
        case .json:
            return exportJSON(entries)
        case .csv:
            return exportCSV(entries)
        case .markdown:
            return exportMarkdown(entries)
        }
    }

    private static func exportPlainText(_ entries: [LogEntry]) -> String {
        let formatter = ISO8601DateFormatter()
        return entries.map { entry in
            "[\(formatter.string(from: entry.timestamp))] [\(entry.severity.rawValue.uppercased())] [\(entry.category.rawValue)] \(entry.message)"
        }
        .joined(separator: "\n")
    }

    private static func exportJSON(_ entries: [LogEntry]) -> String {
        let formatter = ISO8601DateFormatter()
        let payload = entries.map { entry in
            [
                "timestamp": formatter.string(from: entry.timestamp),
                "severity": entry.severity.rawValue,
                "category": entry.category.rawValue,
                "message": entry.message
            ]
        }

        guard
            let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        else {
            return "[]"
        }

        return text
    }

    private static func exportCSV(_ entries: [LogEntry]) -> String {
        let formatter = ISO8601DateFormatter()
        let rows = entries.map { entry in
            [
                formatter.string(from: entry.timestamp),
                entry.severity.rawValue,
                entry.category.rawValue,
                entry.message
            ]
            .map(csvEscape)
            .joined(separator: ",")
        }

        return ([ "timestamp,severity,category,message" ] + rows).joined(separator: "\n")
    }

    private static func exportMarkdown(_ entries: [LogEntry]) -> String {
        let formatter = ISO8601DateFormatter()
        let rows = entries.map { entry in
            "| \(formatter.string(from: entry.timestamp)) | \(entry.severity.rawValue) | \(entry.category.rawValue) | \(markdownEscape(entry.message)) |"
        }

        return ([
            "| Timestamp | Severity | Category | Message |",
            "| --- | --- | --- | --- |"
        ] + rows).joined(separator: "\n")
    }

    private static func csvEscape(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        if escaped.contains(",") || escaped.contains("\"") || escaped.contains("\n") {
            return "\"\(escaped)\""
        }
        return escaped
    }

    private static func markdownEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: "<br>")
    }
}

final class LoggingService: ObservableObject {
    static let shared = LoggingService()

    @Published private(set) var entries: [LogEntry] = []
    @Published var visibilityMode: LogVisibilityMode {
        didSet {
            UserDefaults.standard.set(visibilityMode.rawValue, forKey: Self.visibilityModeDefaultsKey)
        }
    }

    private static let subsystem = "com.matteo.SMBMountManager"
    private static let visibilityModeDefaultsKey = "logVisibilityMode"
    private let logger = Logger(subsystem: subsystem, category: "diagnostics")
    private let maximumEntries = 500

    private init() {
        let storedMode = UserDefaults.standard.string(forKey: Self.visibilityModeDefaultsKey)
        visibilityMode = LogVisibilityMode(rawValue: storedMode ?? "") ?? .standard
    }

    var visibleEntries: [LogEntry] {
        let filtered: [LogEntry]

        switch visibilityMode {
        case .hidden:
            filtered = []
        case .errorsOnly:
            filtered = entries.filter { $0.severity == .error }
        case .standard:
            filtered = entries.filter { $0.severity != .debug }
        case .all:
            filtered = entries
        }

        return filtered.sorted { $0.timestamp > $1.timestamp }
    }

    func record(_ severity: LogSeverity, category: LogCategory, message: String) {
        let entry = LogEntry(timestamp: Date(), severity: severity, category: category, message: message)

        switch severity {
        case .error:
            logger.error("[\(category.rawValue)] \(message, privacy: .private(mask: .hash))")
        case .warning:
            logger.warning("[\(category.rawValue)] \(message, privacy: .private(mask: .hash))")
        case .info:
            logger.info("[\(category.rawValue)] \(message, privacy: .private(mask: .hash))")
        case .debug:
            logger.debug("[\(category.rawValue)] \(message, privacy: .private(mask: .hash))")
        }

        DispatchQueue.main.async {
            self.entries.insert(entry, at: 0)
            if self.entries.count > self.maximumEntries {
                self.entries.removeLast(self.entries.count - self.maximumEntries)
            }
        }
    }

    func clear() {
        entries.removeAll()
    }

    func exportText() -> String {
        LogExportFormatter.export(entries, format: .plainText)
    }
}
