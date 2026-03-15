import AppKit
import SwiftUI

struct DiagnosticsConsoleView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var loggingService: LoggingService
    @ObservedObject var mountService: MountService
    @AppStorage("connectSharesOnLaunch") private var connectSharesOnLaunch = false
    @AppStorage("disconnectSharesOnQuit") private var disconnectSharesOnQuit = false

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Diagnostics Console")
                    .font(.title3.weight(.semibold))

                Spacer()

                Picker("Visibility", selection: $loggingService.visibilityMode) {
                    ForEach(LogVisibilityMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 320)
                .help("Choose which diagnostic messages are visible")
            }

            HStack {
                Text("Automatic Retry Limit")
                    .font(.headline)

                Spacer()

                Stepper(value: $mountService.maximumAutomaticRetryCount, in: 1...20) {
                    Text("\(mountService.maximumAutomaticRetryCount) attempts")
                        .monospacedDigit()
                }
                .frame(width: 220)
                .help("Maximum number of automatic reconnect attempts before the app stops retrying")
            }

            VStack(alignment: .leading, spacing: 10) {
                Toggle("Connect auto-connect shares when the app launches", isOn: $connectSharesOnLaunch)
                    .help("If enabled, the app connects shares marked Auto-connect as soon as the app opens")

                Toggle("Disconnect connected shares when the app quits", isOn: $disconnectSharesOnQuit)
                    .help("If enabled, the app disconnects all currently mounted shares during app termination")
            }

            if loggingService.visibleEntries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "text.alignleft")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text(emptyStateTitle)
                        .font(.headline)
                    Text(emptyStateMessage)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(loggingService.visibleEntries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(entry.severity.rawValue.uppercased())
                                .font(.caption.weight(.bold))
                                .foregroundStyle(color(for: entry.severity))
                            Text(entry.category.rawValue.capitalized)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(entry.timestamp, style: .time)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Text(entry.message)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.plain)
            }

            HStack {
                Button("Copy Logs") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(loggingService.exportText(), forType: .string)
                }
                .help("Copy the current diagnostic log to the clipboard")

                Button("Clear") {
                    loggingService.clear()
                }
                .help("Clear all collected diagnostic messages")

                Spacer()

                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .help("Close the diagnostics console")
            }
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 420)
    }

    private var emptyStateTitle: String {
        loggingService.visibilityMode == .hidden ? "Logs Hidden" : "No Logs Available"
    }

    private var emptyStateMessage: String {
        switch loggingService.visibilityMode {
        case .hidden:
            return "Set visibility to Errors Only, Standard or All to inspect diagnostic activity."
        case .errorsOnly:
            return "No errors have been recorded in this session."
        case .standard, .all:
            return "Run a discovery or a mount operation to populate the diagnostic console."
        }
    }

    private func color(for severity: LogSeverity) -> Color {
        switch severity {
        case .error:
            return .red
        case .warning:
            return .orange
        case .info:
            return .blue
        case .debug:
            return .secondary
        }
    }
}
