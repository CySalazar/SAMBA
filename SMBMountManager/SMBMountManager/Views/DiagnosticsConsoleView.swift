import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum DiagnosticsTab: String, CaseIterable, Identifiable {
    case logs
    case health

    var id: String { rawValue }
}

struct DiagnosticsConsoleView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var loggingService: LoggingService
    @ObservedObject var mountService: MountService
    let connections: [SMBConnection]
    @AppStorage("connectSharesOnLaunch") private var connectSharesOnLaunch = false
    @AppStorage("disconnectSharesOnQuit") private var disconnectSharesOnQuit = false
    @State private var selectedTab: DiagnosticsTab = .logs
    @State private var exportMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Diagnostics Console")
                    .font(.title3.weight(.semibold))

                Spacer()

                Picker("View", selection: $selectedTab) {
                    ForEach(DiagnosticsTab.allCases) { tab in
                        Text(tab.rawValue.capitalized).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
            }

            settingsPanel

            if selectedTab == .logs {
                logsView
            } else {
                healthView
            }

            HStack {
                if selectedTab == .logs {
                    Button("Copy Logs") {
                        copy(loggingService.exportText())
                    }

                    Menu {
                        ForEach(LogExportFormat.allCases) { format in
                            Button("Export \(format.title)") {
                                exportLogs(as: format)
                            }
                        }
                    } label: {
                        Text("Export Logs")
                    }
                } else {
                    Button("Copy Health JSON") {
                        copy(mountService.exportHealthJSON(for: connections))
                    }
                }

                Button("Clear") {
                    loggingService.clear()
                }
                .disabled(selectedTab != .logs)

                Spacer()

                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 900, minHeight: 560)
        .alert("Export Logbook", isPresented: Binding(
            get: { exportMessage != nil },
            set: { if $0 == false { exportMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportMessage ?? "")
        }
    }

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Automatic Retry Limit")
                    .font(.headline)

                Spacer()

                Stepper(value: $mountService.maximumAutomaticRetryCount, in: 1...20) {
                    Text("\(mountService.maximumAutomaticRetryCount) attempts")
                        .monospacedDigit()
                }
                .frame(width: 220)
            }

            HStack {
                Text("Probe Interval")
                Slider(value: $mountService.probeIntervalSeconds, in: 10...120, step: 5)
                Text("\(Int(mountService.probeIntervalSeconds))s")
                    .monospacedDigit()
                    .frame(width: 48)

                Text("Session Refresh")
                Slider(value: $mountService.sessionRefreshIntervalSeconds, in: 30...300, step: 10)
                Text("\(Int(mountService.sessionRefreshIntervalSeconds))s")
                    .monospacedDigit()
                    .frame(width: 48)

                Picker("Window", selection: $mountService.stabilityObservationWindow) {
                    ForEach(StabilityObservationWindow.allCases) { window in
                        Text(window.title).tag(window)
                    }
                }
                .frame(width: 140)

                Stepper(value: $mountService.benchmarkPayloadSizeMB, in: 1...64) {
                    Text("Benchmark \(mountService.benchmarkPayloadSizeMB)MB")
                        .monospacedDigit()
                }
                .frame(width: 220)
            }
            .font(.caption)

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Connect auto-connect shares when the app launches", isOn: $connectSharesOnLaunch)
                Toggle("Disconnect connected shares when the app quits", isOn: $disconnectSharesOnQuit)
                Toggle("Run background diagnostics on mounted shares", isOn: $mountService.backgroundDiagnosticsEnabled)
                Text("When disabled, the app stops scanning mounted network volumes in the background and only refreshes share details on manual request.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var logsView: some View {
        VStack(spacing: 12) {
            Picker("Visibility", selection: $loggingService.visibilityMode) {
                ForEach(LogVisibilityMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

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
        }
    }

    private var healthView: some View {
        let snapshots = mountService.healthSnapshots(for: connections)

        return HSplitView {
            List(snapshots) { snapshot in
                VStack(alignment: .leading, spacing: 4) {
                    Text(snapshot.displayName)
                        .font(.headline)
                    Text("\(snapshot.serverAddress)/\(snapshot.shareName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Text(snapshot.statusLabel)
                        Text(snapshot.stabilityLabel)
                        Text(snapshot.confidenceLabel)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(connections) { connection in
                        let details = mountService.runtimeDetails[connection.id] ?? SMBConnectionRuntimeDetails()
                        GroupBox(connection.name.isEmpty ? connection.shareName : connection.name) {
                            VStack(alignment: .leading, spacing: 8) {
                                detailLine("Status", mountService.statuses[connection.id]?.label ?? ConnectionStatus.disconnected.label)
                                detailLine("Success Rate", String(format: "%.0f%%", details.successRate * 100))
                                detailLine("Probe History", details.recentProbeLatencies.map(formatDuration).joined(separator: ", ").ifEmpty("No samples"))
                                detailLine("Error Breakdown", formattedErrors(details.errorCounts))
                                detailLine("Latest Error", details.lastErrorCategory?.title ?? "None")

                                if details.timeline.isEmpty == false {
                                    Divider()
                                    ForEach(details.timeline.sorted(by: { $0.timestamp > $1.timestamp }).prefix(5), id: \.id) { event in
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(event.title)
                                                .font(.caption.weight(.semibold))
                                            Text(event.details)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private func detailLine(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.caption)
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

    private func formattedErrors(_ errors: [String: Int]) -> String {
        guard errors.isEmpty == false else {
            return "None"
        }

        return errors
            .sorted { $0.key < $1.key }
            .map { "\(ConnectionErrorCategory(rawValue: $0.key)?.title ?? $0.key): \($0.value)" }
            .joined(separator: " • ")
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        if duration < 1 {
            return "\(Int((duration * 1000).rounded()))ms"
        }
        return String(format: "%.2fs", duration)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func exportLogs(as format: LogExportFormat) {
        let panel = NSSavePanel()
        panel.title = "Export Logbook"
        panel.nameFieldStringValue = "SMBMountManager-logbook.\(format.fileExtension)"
        panel.allowedContentTypes = contentTypes(for: format)

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        let payload = LogExportFormatter.export(loggingService.entries, format: format)

        do {
            try payload.write(to: url, atomically: true, encoding: .utf8)
            exportMessage = "Logbook exported as \(format.title)."
        } catch {
            exportMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    private func contentTypes(for format: LogExportFormat) -> [UTType] {
        switch format {
        case .plainText:
            return [.plainText]
        case .json:
            return [.json]
        case .csv:
            return [.commaSeparatedText]
        case .markdown:
            return [.plainText]
        }
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}
