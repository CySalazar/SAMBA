# Architecture Overview

This document describes the technical architecture of SMB Mount Manager for developers who want to understand or contribute to the codebase.

## Design Pattern

The application follows **MVVM (Model-View-ViewModel)**:

- **Model** — `SMBConnection`, `ConnectionStatus`, and the `SMBShareDetails` types (stability grades, runtime details, health snapshots, benchmark results, timeline events, error categories)
- **ViewModel** — `AppState`, `MountService`, `SMBDiscoveryService`, `LoggingService` (shared `ObservableObject` instances managing state and business logic)
- **View** — SwiftUI views (`ContentView`, `ConnectionRow`, `ConnectionEditView`, `DiscoveryView`, `DiagnosticsConsoleView`, `SettingsView`)

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│  Views (SwiftUI)                                                                │
│  ContentView · ConnectionRow · ConnectionEditView · SettingsView                │
│  DiscoveryView · DiagnosticsConsoleView · ConnectionDetailsSheet                │
└──────────┬──────────────────┬──────────────────┬────────────────────────────────┘
           │ @StateObject     │ via AppState     │ @StateObject
┌──────────▼────────┐ ┌──────▼───────────┐ ┌────▼─────────────────────┐
│  AppState         │ │SMBDiscoveryServ. │ │ LoggingService (shared)  │
│  (connections)    │ │(Bonjour browser) │ │ (centralized logging)    │
│  (import/export)  │ │(IP resolution)   │ │ (multi-format export)    │
│  (launch login)   │ │                  │ │                          │
└────────┬──────────┘ └──────────────────┘ └──────────────────────────┘
         │ owns
┌────────▼──────────┐
│  MountService     │
│  (mount/unmount)  │
│  (telemetry)      │
│  (benchmarking)   │
│  (health monitor) │
└────┬────┬────┬────┘
     │    │    │
┌────▼──┐ ┌▼───────────┐ ┌▼────────────────┐
│Keychn.│ │Persistence │ │ System APIs     │
│Service│ │Service     │ │ /sbin/mount     │
│       │ │+ Codec     │ │ umount/diskutil │
│       │ │(JSON files)│ │ statfs/smbutil  │
│       │ │connections │ │                 │
│       │ │runtime-det.│ │                 │
└───────┘ └────────────┘ └─────────────────┘
```

## AppState

**File:** `SMBMountManager/SMBMountManagerApp.swift`

The central application state manager. An `@MainActor` `ObservableObject` that owns the connection lifecycle, service instances, and app-level behaviors.

**Published state:**

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| `connections` | `[SMBConnection]` | `[]` | All configured SMB connections |
| `showMenuBarExtra` | `Bool` | `false` | Controls menu bar extra visibility (persisted to UserDefaults) |
| `launchAtLoginEnabled` | `Bool` | `false` | Whether the app is registered to launch at login |
| `launchAtLoginRequiresApproval` | `Bool` | `false` | Whether the user needs to approve launch at login in System Settings |
| `launchAtLoginStatusMessage` | `String?` | `nil` | Status feedback for launch-at-login operations |

**Owned services:**

- `mountService: MountService` — mount/unmount, telemetry, benchmarking
- `loggingService: LoggingService` — shared logging singleton
- `discoveryService: SMBDiscoveryService` — Bonjour browser

**Key methods:**

| Method | Description |
|--------|-------------|
| `addConnection(_:password:)` | Saves a new connection to persistence and Keychain |
| `updateConnection(_:password:)` | Updates an existing connection |
| `deleteConnections(at:)` | Deletes connections with Keychain cleanup |
| `connectAll()` / `disconnectAll()` | Bulk mount/unmount operations |
| `exportConnections(to:)` | Exports connections as JSON via `PersistenceCodec` (passwords excluded) |
| `importConnections(from:)` | Imports connections from JSON with duplicate detection (same server+share+username) |
| `toggleLaunchAtLogin()` | Registers/unregisters via `SMAppService.mainApp` |
| `applyLaunchBehaviorIfNeeded(connectSharesOnLaunch:)` | Auto-connects shares on app launch if enabled |
| `handleApplicationWillTerminate(disconnectSharesOnQuit:)` | Auto-disconnects shares on app quit if enabled |

## Models

### SMBConnection

**File:** `SMBMountManager/Models/SMBConnection.swift`

A `Codable`, `Identifiable`, `Equatable` struct representing a saved SMB connection.

| Property | Type | Description |
|----------|------|-------------|
| `id` | `UUID` | Unique identifier (also used as Keychain account key) |
| `name` | `String` | User-friendly display name |
| `serverAddress` | `String` | IP address or hostname |
| `shareName` | `String` | Name of the SMB share |
| `username` | `String` | SMB authentication username |
| `autoConnect` | `Bool` | Whether to auto-reconnect when disconnected |

**Computed properties:**

- `mountPoint` → `~/Volumes/{sanitizedServer}-{sanitizedShare}` where `/` and `:` are replaced with `-`. Falls back to the connection's UUID string if both server and share are empty after sanitization.
- `smbURL` → `smb://{serverAddress}/{shareName}`

### ConnectionStatus

An enum representing the runtime state of a connection:

| Case | Indicator Color | Description |
|------|----------------|-------------|
| `.disconnected` | Red | Share is not mounted |
| `.connecting` | Yellow (animated) | Mount or unmount in progress |
| `.connected` | Green | Share is mounted and verified as `smbfs` |
| `.error(String)` | Orange | Operation failed with a message |

`ConnectionStatus` is `Equatable` but **not** `Codable` — it is runtime-only state, never persisted. The `label` property returns a human-readable description of the current state.

### SMBShareDetails Types

**File:** `SMBMountManager/Models/SMBShareDetails.swift`

This file defines all types used for share discovery, health monitoring, telemetry, and benchmarking.

#### DiscoveredSMBShare

An `Identifiable`, `Hashable`, `Codable` struct representing a share found during discovery.

| Property | Type | Description |
|----------|------|-------------|
| `name` | `String` | Share name on the server |
| `type` | `String` | Share type (e.g., disk, printer) |
| `comment` | `String` | Server-provided description |
| `serverAddress` | `String` | Address of the server hosting the share |

**Computed properties:**

- `id` → `"{serverAddress}/{name}"` (lowercased)
- `isHidden` → `true` if the share name ends with `$`
- `smbURL` → `"smb://{serverAddress}/{name}"`

#### ConnectionStabilityGrade

An enum assessing connection reliability over time:

| Case | Title |
|------|-------|
| `.insufficientHistory` | "Insufficient History" |
| `.low` | "Low" |
| `.medium` | "Medium" |
| `.high` | "High" |

#### ConnectionConfidenceLevel

An enum expressing how much data backs the stability assessment:

| Case | Title |
|------|-------|
| `.low` | "Low" |
| `.medium` | "Medium" |
| `.high` | "High" |

#### StabilityObservationWindow

An enum defining the time window for stability analysis:

| Case | Title |
|------|-------|
| `.session` | "Session" |
| `.last24Hours` | "24 Hours" |
| `.last7Days` | "7 Days" |

#### ConnectionErrorCategory

An enum classifying mount and runtime errors:

| Case | Title |
|------|-------|
| `.authentication` | "Authentication" |
| `.connectivity` | "Connectivity" |
| `.timeout` | "Timeout" |
| `.shareNotFound` | "Share Not Found" |
| `.mountPointBusy` | "Mount Point Busy" |
| `.benchmark` | "Benchmark" |
| `.unknown` | "Unknown" |

#### ConnectionTimelineEvent

An `Identifiable`, `Codable`, `Hashable` struct recording a notable event for a connection.

| Property | Type | Description |
|----------|------|-------------|
| `id` | `UUID` | Unique event identifier |
| `timestamp` | `Date` | When the event occurred |
| `kind` | `ConnectionTimelineEventKind` | `.status`, `.probe`, `.benchmark`, `.session`, or `.note` |
| `title` | `String` | Short event summary |
| `details` | `String` | Extended description |

#### SMBBenchmarkResult

A `Codable`, `Hashable` struct storing the outcome of a read/write throughput test.

| Property | Type | Description |
|----------|------|-------------|
| `timestamp` | `Date` | When the benchmark ran |
| `payloadSizeBytes` | `Int` | Size of the test file in bytes |
| `writeDuration` | `TimeInterval` | Time to write the payload |
| `readDuration` | `TimeInterval` | Time to read the payload back |

**Computed properties:**

- `writeThroughputMBps` → payload size (MB) / write duration
- `readThroughputMBps` → payload size (MB) / read duration

#### SMBConnectionRuntimeDetails

A `Codable`, `Hashable` struct containing comprehensive telemetry for a single connection. This is the primary data structure published by `MountService` and persisted to `runtime-details.json`.

| Property Group | Key Properties |
|---------------|----------------|
| Probe metrics | `lastProbeLatency`, `averageProbeLatency`, `probeLatencyJitter`, `recentProbeLatencies` |
| Mount counters | `successfulMounts`, `failedMounts`, `disconnectCount`, `automaticRetryCount` |
| Duration tracking | `totalConnectedDuration`, `totalDisconnectedDuration` |
| Volume details | `mountedVolumePath`, `volumeName`, `volumeTotalCapacityBytes`, `volumeAvailableCapacityBytes` |
| Session info | `protocolVersion`, `signingState`, `encryptionState`, `multichannelState`, `sessionAttributes` |
| Error tracking | `errorCounts: [String: Int]`, `lastErrorCategory` |
| Timeline | `timeline: [ConnectionTimelineEvent]` |
| Benchmark | `benchmarkResult`, `benchmarkStatusMessage`, `isBenchmarkRunning` |
| Stability | `stabilityGrade`, `confidenceLevel` |

**Computed properties:**

- `successRate` → `successfulMounts / (successfulMounts + failedMounts)`

#### ConnectionHealthSnapshot

An `Identifiable`, `Hashable` struct providing a summary view of a connection's health for the diagnostics UI.

| Property | Type | Description |
|----------|------|-------------|
| `id` | `UUID` | Connection identifier |
| `displayName` | `String` | Connection display name |
| `serverAddress` | `String` | Server address |
| `shareName` | `String` | Share name |
| `statusLabel` | `String` | Current connection status text |
| `stabilityLabel` | `String` | Stability grade text |
| `confidenceLabel` | `String` | Confidence level text |
| `successRate` | `Double` | Mount success ratio (0–1) |
| `lastProbeLatency` | `TimeInterval?` | Latest probe measurement |
| `topErrorCategory` | `String` | Most frequent error category |

## Services

### MountService

**File:** `SMBMountManager/Services/MountService.swift`

The central service managing all mount operations, status monitoring, telemetry, and benchmarking. Decorated with `@MainActor` and conforms to `ObservableObject`.

**Published state:**

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| `statuses` | `[UUID: ConnectionStatus]` | `[:]` | Drives all UI status updates via SwiftUI observation |
| `runtimeDetails` | `[UUID: SMBConnectionRuntimeDetails]` | Loaded from disk | Per-connection telemetry, persisted to `runtime-details.json` |
| `maximumAutomaticRetryCount` | `Int` | `5` | Maximum auto-reconnect attempts before stopping |
| `probeIntervalSeconds` | `Double` | `20` | Minimum seconds between passive probe measurements |
| `sessionRefreshIntervalSeconds` | `Double` | `60` | Minimum seconds between `smbutil` session detail refreshes |
| `stabilityObservationWindow` | `StabilityObservationWindow` | `.session` | Time window for stability grade computation |
| `benchmarkPayloadSizeMB` | `Int` | `4` | File size for read/write throughput tests |

All configurable properties are persisted to `UserDefaults` and restored on init.

**Private state (managed by extracted utility types):**

| Component | Purpose |
|-----------|---------|
| `MountRequestQueue` | Serializes mount operations — one active at a time, others queued in order |
| `AutomaticRetryTracker` | Per-connection retry counting with manual/automatic distinction and limit enforcement |
| `BackgroundRefreshPolicy` | Enforces probe and session refresh intervals, respects connection status |
| `consecutiveMissedChecks` | Per-connection count of refresh cycles where `isMounted` returned false |
| `telemetry` | Per-connection internal tracking state (timestamps, duration counters) |

**Timers:**

| Timer | Interval | Purpose |
|-------|----------|---------|
| `statusTimer` | 15 seconds | Refreshes mount status for all connections |
| `autoConnectTimer` | 30 seconds | Mounts any disconnected connection that has `autoConnect` enabled |

**Mount flow:**

1. Load password from `KeychainService`.
2. Create the mount point directory at `~/Volumes/{server}-{share}` if it does not exist.
3. Execute `/sbin/mount -t smbfs -o nobrowse,nopassprompt //user:pass@server/share mountPoint`.
4. Poll up to 15 times (once per second) for the mount to appear via `isMounted()`.
5. On success: schedule post-mount verification (3-second delay), force a session detail refresh, run a passive probe.
6. On failure: parse stderr to categorize the error (via `userFacingMountError`), register the failure in telemetry.
7. Mount requests are serialized — only one runs at a time; additional requests are queued and processed in order.

**Unmount flow:**

1. Resolve the actual mounted volume URL (may differ from the expected mount point).
2. Execute `/sbin/umount {mountedPath}`.
3. If that fails (non-zero exit), fall back to `/usr/sbin/diskutil unmount {mountedPath}`.

**Status check:**

- Checks the expected mount point and all mounted volumes for a matching `smbfs` volume.
- Uses `statfs()` for direct path checks and `FileManager.mountedVolumeURLs` for enumeration.
- A connected status requires **2 consecutive missed checks** (`missedCheckThreshold`) before downgrading to disconnected, preventing UI flickering from transient filesystem enumeration gaps.

**Telemetry subsystem:**

| Method | Description |
|--------|-------------|
| `runPassiveProbeIfNeeded(for:)` | Measures directory listing latency on the mounted volume at the configured probe interval. Updates `lastProbeLatency`, `averageProbeLatency`, `probeLatencyJitter`, and `recentProbeLatencies`. |
| `refreshSessionDetailsIfNeeded(for:)` | Runs `smbutil statshares -j` and `smbutil multichannel -j` to collect protocol version, signing state, encryption state, multichannel state, and session attributes. |
| `runBenchmark(for:)` | Writes a random-data temp file of `benchmarkPayloadSizeMB` to the mounted volume, reads it back, and records the `SMBBenchmarkResult`. |
| `healthSnapshots(for:)` | Produces `[ConnectionHealthSnapshot]` summaries for the diagnostics health view. |
| `exportHealthJSON(for:)` | Serializes health snapshots as a JSON string for clipboard export. |

### MountService Utility Types

**File:** `SMBMountManager/Services/MountService.swift`

These types are defined alongside `MountService` and encapsulate discrete responsibilities:

#### MountDiagnostics

An enum providing error message mapping and sensitive data redaction.

| Method | Description |
|--------|-------------|
| `userFacingMountError(_:)` | Maps raw mount/unmount errors to user-friendly messages |
| `redactSensitiveValue(_:)` | Regex-based password redaction, replacing credentials with `<redacted>` |

#### MountErrorClassifier

An enum that categorizes raw error strings into `ConnectionErrorCategory` values (`.authentication`, `.connectivity`, `.timeout`, `.shareNotFound`, `.mountPointBusy`, `.unknown`).

#### AutomaticRetryTracker

A struct tracking per-connection retry counts with support for manual vs. automatic retry distinction.

| Method | Description |
|--------|-------------|
| `registerFailure(for:isManual:)` | Resets counter to 1 for manual retries; increments for automatic |
| `canAutomaticallyRetry(for:maximum:)` | Returns `true` if current count is below the configured limit |
| `prune(keeping:)` | Removes tracking data for deleted connections |

#### MountRequestQueue

A struct managing pending and active mount requests with upgrade semantics.

| Method | Description |
|--------|-------------|
| `enqueue(_:)` | Adds a request; upgrades automatic→user-initiated if already queued |
| `dequeueNext()` | Returns the next pending request and marks it active |
| `finish(_:)` | Clears the active request |
| `prune(keeping:)` | Removes requests for deleted connections |

#### BackgroundRefreshPolicy

An enum enforcing interval-based guards for background operations.

| Method | Description |
|--------|-------------|
| `shouldRunProbe(for:interval:lastProbe:force:)` | Checks status and interval before allowing a probe |
| `shouldRefreshSessionDetails(for:interval:lastRefresh:)` | Independent interval guard for session detail collection |

### KeychainService

**File:** `SMBMountManager/Services/KeychainService.swift`

A static struct wrapping macOS Security framework APIs for password management.

| Method | Description |
|--------|-------------|
| `savePassword(_:for:)` | Deletes any existing entry, then adds a new one |
| `loadPassword(for:)` | Retrieves the stored password for a connection UUID |
| `deletePassword(for:)` | Removes the Keychain entry for a connection UUID |

**Configuration:**

- Service identifier: `"com.smb-mount-manager"`
- Account key: connection UUID string
- Access level: `kSecAttrAccessibleWhenUnlocked`
- Item class: `kSecClassGenericPassword`

### PersistenceService

**File:** `SMBMountManager/Services/PersistenceService.swift`

A static struct handling JSON serialization of connections and runtime details to disk.

| Method | Description |
|--------|-------------|
| `load()` | Reads and decodes `[SMBConnection]` from `connections.json` |
| `save(_:)` | Encodes connections and writes atomically to `connections.json` |
| `loadRuntimeDetails()` | Reads and decodes `[UUID: SMBConnectionRuntimeDetails]` from `runtime-details.json` using ISO 8601 date decoding |
| `saveRuntimeDetails(_:)` | Encodes runtime details with pretty printing, sorted keys, and ISO 8601 dates; writes atomically to `runtime-details.json` |

**Storage paths:**

| File | Path |
|------|------|
| `connections.json` | `~/Library/Application Support/SMBMountManager/connections.json` |
| `runtime-details.json` | `~/Library/Application Support/SMBMountManager/runtime-details.json` |

The directory is created automatically with `withIntermediateDirectories: true` on first save.

**PersistedConnectionState** — a nested `Codable` struct bundling `connections` and `runtimeDetails` for potential combined serialization.

#### PersistenceCodec

An enum defined in `PersistenceService.swift` providing standalone JSON encoding/decoding for connections and runtime details, used by `AppState` for import/export operations.

| Method | Description |
|--------|-------------|
| `encodeConnections(_:)` | Encodes `[SMBConnection]` to JSON `Data` |
| `decodeConnections(from:)` | Decodes `[SMBConnection]` from JSON `Data` |
| `encodeRuntimeDetails(_:)` | Encodes runtime details with ISO 8601 dates |
| `decodeRuntimeDetails(from:)` | Decodes runtime details with ISO 8601 date handling |

### LoggingService

**File:** `SMBMountManager/Services/LoggingService.swift`

A singleton `ObservableObject` providing centralized, structured logging across all services. Uses Apple's `OSLog` framework for system-level logging and maintains an in-memory buffer for the diagnostics UI.

**Key types:**

| Type | Description |
|------|-------------|
| `LogSeverity` | `.error`, `.warning`, `.info`, `.debug` |
| `LogCategory` | `.app`, `.mount`, `.discovery`, `.keychain`, `.persistence`, `.ui` |
| `LogVisibilityMode` | `.hidden`, `.errorsOnly`, `.standard`, `.all` — persisted via `UserDefaults` |
| `LogEntry` | Timestamp + severity + category + message |

**Configuration:**

- Maximum entries: 500 (oldest entries are discarded when the limit is exceeded)
- OSLog subsystem: `"com.matteo.SMBMountManager"`
- Visibility mode preference key: `"logVisibilityMode"`

**Methods:**

| Method | Description |
|--------|-------------|
| `record(_:category:message:)` | Appends an entry and writes to `OSLog` |
| `clear()` | Removes all in-memory entries |
| `exportText()` | Returns all entries as ISO 8601-formatted text |

#### LogExportFormatter

A static struct providing multi-format log export.

| Method | Description |
|--------|-------------|
| `export(_:format:)` | Exports `[LogEntry]` in the specified `LogExportFormat` |

**LogExportFormat** — an enum defining the available export formats:

| Case | Extension | Description |
|------|-----------|-------------|
| `.plainText` | `.txt` | ISO 8601 timestamps with `[SEVERITY] [CATEGORY]` format |
| `.json` | `.json` | Pretty-printed JSON array with sorted keys |
| `.csv` | `.csv` | Header row with properly escaped fields |
| `.markdown` | `.md` | Pipe-delimited table format |

### SMBDiscoveryService

**File:** `SMBMountManager/Services/SMBDiscoveryService.swift`

An `@MainActor` `ObservableObject` that browses the local network for SMB servers using Bonjour (`NetServiceBrowser`).

**Published state:**

- `hosts: [DiscoveredSMBHost]` — list of discovered servers, sorted alphabetically
- `isBrowsing: Bool` — whether a scan is in progress
- `errorMessage: String?` — set when the browser fails

**Behavior:**

- Searches for `_smb._tcp.` services in the `local.` domain.
- Each discovered service is resolved with a 5-second timeout to obtain the hostname and port.
- IP addresses are resolved using `getnameinfo()` with `NI_NUMERICHOST` on the service's socket addresses.
- Resolution duration is tracked via `resolveStartedAt` timestamps.
- Services that disappear from the network are automatically removed from the list.

**DiscoveredSMBHost** — a value type representing a discovered server:

| Property | Type | Description |
|----------|------|-------------|
| `serviceName` | `String` | Bonjour service name |
| `hostName` | `String` | Resolved hostname |
| `port` | `Int` | SMB port |
| `ipAddresses` | `[String]` | Resolved IP addresses (IPv4/IPv6) |
| `lastResolvedAt` | `Date` | Timestamp of the last successful resolution |
| `resolveDuration` | `TimeInterval?` | How long resolution took |

**Computed properties:** `displayName`, `normalizedHostName` (strips trailing dots), `secondaryDetails` (formatted IP addresses and port).

### SMBShareDiscoveryService

**File:** `SMBMountManager/Services/SMBShareDiscoveryService.swift`

A static struct that enumerates available shares on a given SMB server using the macOS `smbutil view` command.

| Method | Description |
|--------|-------------|
| `discoverShares(serverAddress:username:password:)` | Runs `smbutil view //user:pass@server` and parses the output |

Credentials are percent-encoded before being passed to `smbutil`. Output parsing is delegated to `SMBShareOutputParser`.

#### SMBShareOutputParser

An enum defined in `SMBShareDiscoveryService.swift` that parses the tabular output of `smbutil view`.

| Method | Description |
|--------|-------------|
| `parseShares(from:serverAddress:)` | Regex-based column splitting, deduplication by server+name, alphabetical sorting. Handles hidden shares (ending with `$`) and preserves server-provided comments. |

## Views

### ContentView

**File:** `SMBMountManager/Views/ContentView.swift`

The root view of the application. Receives services from `AppState` via the environment.

**State management:**

- `appState` — central state (connections, services, import/export) received from environment
- `@AppStorage connectSharesOnLaunch` — auto-connect on launch toggle
- `@AppStorage disconnectSharesOnQuit` — auto-disconnect on quit toggle
- `@State editingConnection` — triggers the edit sheet
- `@State selectedConnection` — triggers the connection details sheet
- `@State isAddingNew` — triggers the add sheet
- `@State isShowingDiagnostics` — triggers the diagnostics console sheet
- `@State isShowingDiscovery` — triggers the discovery panel sheet
- `@State suggestedHost` — pre-fills the connection form from a discovered host
- `@State hasAppliedLaunchBehavior` — ensures connect-on-launch runs once
- `@State searchText` — filter bar search input
- `@State statusFilter` — filter by connection status (all / connected / disconnected / errors / unstable)
- `@State sortMode` — sort connections (name / host / status / latency / stability)

**Filtering and sorting:**

The `filteredConnections` computed property implements a three-stage pipeline:
1. **Search** — matches connection name, server address, share name, or username against `searchText`.
2. **Status filter** — filters by `ConnectionStatusFilter` cases (All, Connected, Disconnected, Errors, Unstable).
3. **Sort** — orders by `ConnectionSortMode` (Name, Host, Status, Latency, Stability).

**Connection Details Sheet:**

An inline private struct (`ConnectionDetailsSheet`) opened when tapping a connection row. Displays five sections:
- **Live** — current status, mount point, volume capacity, protocol, signing, encryption, multichannel
- **Historical** — successful/failed mounts, disconnects, automatic retries, connected/disconnected duration
- **Estimated** — stability grade, confidence level, success rate, probe latency, jitter
- **Manual Benchmark** — read/write throughput with a "Run Benchmark" button
- **Timeline** — recent events sorted newest-first (status changes, probes, benchmarks, sessions)

**Lifecycle:**

- `onAppear`: loads connections from `PersistenceService`, starts monitoring, optionally connects auto-connect shares on launch.
- `onDisappear`: stops monitoring timers, optionally disconnects all shares on quit.

**Key behaviors:**

- Toolbar buttons: Connect All, Disconnect All, Discover SMB Servers, Diagnostics Console, Import Connections, Export Connections, Add Connection.
- Filter bar with search field, status picker, and sort picker.
- Import: `NSOpenPanel` with `.json` filter → `appState.importConnections()` → merge with duplicate detection, reports imported/skipped counts.
- Export: `NSSavePanel` with default filename `SMBMountManager-connections.json` → `appState.exportConnections()` → JSON without passwords.
- Sheet modals for add/edit, discovery, diagnostics, and connection details.
- Selecting a host from the discovery panel opens the add-connection form pre-filled with the host address.
- Swipe-to-delete with Keychain cleanup.
- Empty state display when no connections match the current filter.
- Minimum window size: 860×520.
- Bottom status bar with author link, connection summary, and build revision.

### ConnectionRow

**File:** `SMBMountManager/Views/ConnectionRow.swift`

A row component displaying a single connection's state, telemetry badges, and actions.

**Inputs:** `connection`, `status`, `runtimeDetails`, `onConnect`, `onDisconnect`, `onRunBenchmark`, `onRefreshDetails`, `onOpenMountPoint`, `onCopyURL`.

**Renders:**

- **Status indicator** (`StatusIndicator`) — a 10pt circle that animates between green and yellow (0.4s period) when connecting; otherwise shows the static status color.
- **Connection name** (falls back to share name if name is empty).
- **Badges** — capsule-shaped inline labels: "Hidden" (if share ends with `$`), protocol version (if available), "Unstable" (if stability grade is `.low`), "High Latency" (if probe latency ≥ 1 second).
- **Server path** as caption (e.g., `192.168.1.10/share`).
- **Telemetry line** — stability grade, probe latency, and success rate in a compact format.
- **Error message** — shown in orange when the status is `.error`.
- **Auto-connect badge** icon when enabled.
- **Action button** — "Connect", "Disconnect", "Retry", or disabled during connecting. Uses `lastStableStatus` to avoid button label flickering during brief `.connecting` transitions.

**Context menu:**

- Copy SMB URL
- Open Mount Point (disabled when not connected)
- Refresh Details
- Run Benchmark (disabled when not connected or already running)

### ConnectionEditView

**File:** `SMBMountManager/Views/ConnectionEditView.swift`

A modal form for creating or editing a connection.

**Fields:** Name, Server address, Share name, Username, Password (SecureField), Auto-connect (Toggle).

**Share Discovery section:** A "Discover Shares" button queries the server using `SMBShareDiscoveryService`. If shares are found, a picker lets the user select one, auto-filling the share name (and name, if empty). Enabled only when server, username, and password are filled in.

**Validation:** Server address, share name, username, and password must all be non-empty (after trimming whitespace). The Save button is disabled until valid.

**On edit:** Pre-fills all fields from the existing connection, including loading the password from Keychain.

**On new with suggested host:** When created from the discovery panel, pre-fills name and server address from the selected `DiscoveredSMBHost`.

**Keyboard shortcuts:** Esc to cancel, Return to save.

### DiscoveryView

**File:** `SMBMountManager/Views/DiscoveryView.swift`

A modal panel that displays SMB servers discovered on the local network via Bonjour.

**Inputs:** `discoveryService` (`SMBDiscoveryService`), `configuredHosts` (set of already-configured server addresses), `onSelectHost` closure.

**Behavior:**

- Starts browsing automatically on appear, stops on disappear.
- Displays each host with its display name, normalized hostname, IP addresses, and port.
- A **Use** button triggers the `onSelectHost` callback and dismisses the panel.
- **Refresh** restarts the scan. A progress indicator is shown while scanning.
- Empty state differentiates between "searching" and "no servers found".
- Minimum size: 520×360.

### DiagnosticsConsoleView

**File:** `SMBMountManager/Views/DiagnosticsConsoleView.swift`

A modal diagnostics panel with two tabs and a settings panel.

**Inputs:** `loggingService` (`LoggingService`), `mountService` (`MountService`), `connections` (`[SMBConnection]`).

**Tab layout:**

- **Logs tab** — segmented picker for `LogVisibilityMode` (Hidden / Errors Only / Standard / All). Displays log entries sorted newest-first with severity (color-coded), category, timestamp, and message in monospaced font. Text selection enabled.
- **Health tab** — `HSplitView` with connection health snapshots on the left (display name, server path, status/stability/confidence labels) and per-connection runtime details on the right (GroupBox per connection with status, success rate, probe history, error breakdown, latest error category, and up to 5 most recent timeline events).

**Settings panel:**

| Control | Type | Range |
|---------|------|-------|
| Automatic Retry Limit | Stepper | 1–20 attempts |
| Probe Interval | Slider | 10–120 seconds |
| Session Refresh Interval | Slider | 30–300 seconds |
| Stability Observation Window | Picker | Session / 24 Hours / 7 Days |
| Benchmark Payload Size | Stepper | 1–64 MB |
| Connect on Launch | Toggle | — |
| Disconnect on Quit | Toggle | — |

**Actions:**

- **Export Logs** — saves log entries to a file via `NSSavePanel` with format selection (Plain Text, JSON, CSV, Markdown). Uses `LogExportFormatter` for format conversion (Logs tab).
- **Copy Health JSON** — exports health snapshots as JSON (Health tab).
- **Clear** — removes all recorded log entries (Logs tab only).
- Esc to close.

**Minimum size:** 900×560.

### SettingsView

**File:** `SMBMountManager/SMBMountManagerApp.swift` (private struct)

A macOS native Settings scene accessible via the app menu (⌘,).

**Controls:**

| Control | Description |
|---------|-------------|
| Show Menu Bar Extra | Toggle controlling `appState.showMenuBarExtra` |
| Launch at Login | Toggle calling `appState.toggleLaunchAtLogin()` via `SMAppService.mainApp` |

Displays status messages when launch-at-login requires user approval, with a button to open System Settings > Login Items.

## Data Flow

```
User action (tap Connect, add connection, etc.)
    │
    ▼
ContentView calls AppState method (addConnection, connectAll, etc.)
    │
    ▼
AppState delegates to MountService → updates statuses (@Published)
    │
    ├──▶ SwiftUI observes change, re-renders affected views
    │
    ▼
AppState persists via PersistenceService.save() + MountService.updateConnections()
```

**Telemetry data flow:**

```
Status change (mount success/failure, disconnect)
    │
    ▼
MountService updates internal telemetry tracking
    │
    ▼
MountService publishes updated runtimeDetails (@Published)
    │
    ▼
PersistenceService.saveRuntimeDetails() writes to runtime-details.json
    │
    ▼
SwiftUI re-renders ConnectionRow badges, details sheet, health view
```

**Probe and session refresh flow:**

```
Status timer fires (every 15s) → refreshAllStatuses()
    │
    ├──▶ For each connected share: runPassiveProbeIfNeeded() → directory listing latency
    │
    └──▶ For each connected share: refreshSessionDetailsIfNeeded() → smbutil statshares/multichannel
```

**Benchmark flow:**

```
User triggers "Run Benchmark" (context menu or details sheet)
    │
    ▼
MountService.runBenchmark(for:) → write temp file → read temp file → measure durations
    │
    ▼
Update runtimeDetails with SMBBenchmarkResult → persist → re-render UI
```

## Entitlements and Info.plist

**File:** `SMBMountManager/SMBMountManager.entitlements`

| Entitlement | Value | Purpose |
|-------------|-------|---------|
| `com.apple.security.network.client` | `true` | Required for outbound network access to open SMB URLs |

The App Sandbox is **disabled** — this is necessary because mounting SMB shares requires direct filesystem and process access (`statfs`, `umount`, `diskutil`, `smbutil`, `/sbin/mount`) that sandboxed apps cannot perform.

**File:** `SMBMountManager/SMBMountManager/Info.plist`

| Key | Value | Purpose |
|-----|-------|---------|
| `NSBonjourServices` | `["_smb._tcp"]` | Declares the Bonjour service type the app browses for |
| `NSLocalNetworkUsageDescription` | Usage string | Shown to the user when the app requests local network access |

## Design Decisions and Constraints

1. **Mount point is derived from server and share name** (`~/Volumes/{sanitizedServer}-{sanitizedShare}`), placed in the user's home directory rather than `/Volumes`. This avoids conflicts between connections with the same share name on different servers and does not require admin privileges.

2. **`/sbin/mount -t smbfs`** is used directly with `-o nobrowse,nopassprompt` options. This provides deterministic mount points, eliminates Finder involvement, and gives fine-grained control over mount options compared to the previous `NSWorkspace.shared.open(url)` approach.

3. **Polling up to 15 seconds after mount** (one check per second) before declaring a timeout. On successful mount completion, a **3-second post-mount verification** is scheduled to catch transient mount appearances. Slow networks or servers may still need longer for the mount to appear.

4. **Credentials in the SMB URL** are percent-encoded and passed inline (`//user:pass@server/share`) as arguments to `/sbin/mount`. The credentials exist briefly in memory and in the process argument list but are not persisted.

5. **Polling-based monitoring** (15s status, 30s auto-connect) rather than filesystem event notifications. This is simpler and sufficient for the use case, though it means status updates are not instantaneous.

6. **No App Sandbox** is a deliberate choice to allow process execution (`mount`, `umount`, `diskutil`, `smbutil`) and `statfs()` system calls needed for mount and discovery management.

7. **Bonjour discovery** relies on servers publishing `_smb._tcp` services. Servers that do not advertise via mDNS will not appear in the discovery panel but can still be added manually.

8. **Share discovery via `smbutil view`** requires valid credentials. The command is executed as a child process; credentials are percent-encoded and passed inline. The process output is parsed heuristically, filtering out header rows.

9. **In-memory logging** with a 500-entry cap keeps memory usage bounded. Logs are also written to `OSLog` for inspection via Console.app. The visibility mode is persisted in `UserDefaults` so it survives app restarts.

10. **Runtime details persistence** — telemetry and health data are persisted to `runtime-details.json` separately from connection metadata, using ISO 8601 date encoding. This allows runtime data to survive app restarts while keeping the connection file clean and human-readable.

11. **Flicker prevention** — a connected status requires 2 consecutive missed checks (`missedCheckThreshold`) before downgrading to disconnected, preventing UI jitter from transient filesystem enumeration gaps during the 15-second polling cycle.

12. **Mount request serialization** — only one mount operation runs at a time; additional requests are queued in `pendingMountRequests` and processed in order. This avoids overwhelming the system or network with concurrent mount attempts.

13. **Passive probing** — probe latency is measured by listing the mounted volume's directory contents rather than sending network-level pings. This measures the actual I/O path the user experiences, including filesystem and protocol overhead.

14. **Session detail collection** — protocol version, signing state, encryption state, and multichannel state are collected via `smbutil statshares -j` and `smbutil multichannel -j` in JSON output mode. This avoids private APIs and leverages built-in macOS tools.

15. **Connection import/export** — exports use `PersistenceCodec` to serialize only connection metadata (no passwords). Imports detect duplicates by matching on server address, share name, and username, merging new connections and skipping existing ones.

16. **Sensitive data redaction** — `MountDiagnostics.redactSensitiveValue()` uses regex to replace passwords in SMB URLs and mount commands before they reach the logging subsystem, ensuring credentials never appear in logs or exports.

17. **Launch at login** — managed via `SMAppService.mainApp.register()` / `.unregister()`. The API may return `.requiresApproval` status on first registration, directing the user to System Settings > Login Items.

## Tests

**File:** `SMBMountManagerTests/MountDiagnosticsTests.swift`

Unit tests covering the extracted utility types:

| Test Suite | Coverage |
|------------|----------|
| `MountDiagnosticsTests` | Password redaction, error message mapping |
| `SMBShareOutputParserTests` | Output parsing, deduplication, comment preservation |
| `MountErrorClassifierTests` | All 6 error categories |
| `PersistenceCodecTests` | Round-trip JSON encoding/decoding with ISO 8601 dates |
| `MountRequestQueueTests` | Upgrade logic, queue promotion, pruning |
| `AutomaticRetryTrackerTests` | Manual/automatic retry distinction, limit enforcement |
| `BackgroundRefreshPolicyTests` | Interval guards, force bypass, status checking |
| `LogExportFormatterTests` | All 4 export formats (Plain Text, JSON, CSV, Markdown) |
