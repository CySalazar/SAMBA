# Architecture Overview

This document describes the technical architecture of SMB Mount Manager for developers who want to understand or contribute to the codebase.

## Design Pattern

The application follows **MVVM (Model-View-ViewModel)**:

- **Model** — `SMBConnection` struct and `ConnectionStatus` enum
- **ViewModel** — `MountService`, `SMBDiscoveryService`, `LoggingService` (shared `ObservableObject` instances managing state and business logic)
- **View** — SwiftUI views (`ContentView`, `ConnectionRow`, `ConnectionEditView`, `DiscoveryView`, `DiagnosticsConsoleView`)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  Views (SwiftUI)                                                            │
│  ContentView · ConnectionRow · ConnectionEditView                           │
│  DiscoveryView · DiagnosticsConsoleView                                     │
└──────────┬──────────────────┬──────────────────┬────────────────────────────┘
           │ @StateObject     │ @StateObject     │ @StateObject
┌──────────▼────────┐ ┌──────▼───────────┐ ┌────▼─────────────────────┐
│  MountService     │ │SMBDiscoveryServ. │ │ LoggingService (shared)  │
│  (mount/unmount)  │ │(Bonjour browser) │ │ (centralized logging)    │
└────┬────┬────┬────┘ └──────────────────┘ └──────────────────────────┘
     │    │    │
┌────▼──┐ ┌▼───────────┐ ┌▼────────────────┐
│Keychn.│ │Persistence │ │ System APIs     │
│Service│ │Service     │ │ NSWorkspace     │
│       │ │(JSON file) │ │ umount/diskutil │
│       │ │            │ │ statfs/smbutil  │
└───────┘ └────────────┘ └─────────────────┘
```

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

- `mountPoint` → `/Volumes/{shareName}`
- `smbURL` → `smb://{serverAddress}/{shareName}`

### ConnectionStatus

An enum representing the runtime state of a connection:

| Case | Indicator Color | Description |
|------|----------------|-------------|
| `.disconnected` | Red | Share is not mounted |
| `.connecting` | Yellow | Mount or unmount in progress |
| `.connected` | Green | Share is mounted and verified as `smbfs` |
| `.error(String)` | Orange | Operation failed with a message |

`ConnectionStatus` is `Equatable` but **not** `Codable` — it is runtime-only state, never persisted.

## Services

### MountService

**File:** `SMBMountManager/Services/MountService.swift`

The central service managing all mount operations and status monitoring. Decorated with `@MainActor` and conforms to `ObservableObject`.

**Published state:**

- `statuses: [UUID: ConnectionStatus]` — drives all UI updates via SwiftUI's observation system.

**Timers:**

| Timer | Interval | Purpose |
|-------|----------|---------|
| `statusTimer` | 15 seconds | Refreshes mount status for all connections |
| `autoConnectTimer` | 30 seconds | Mounts any disconnected connection that has `autoConnect` enabled |

**Mount flow:**

1. Load password from `KeychainService`.
2. Percent-encode username and password for URL safety.
3. Construct URL: `smb://user:pass@server/share`.
4. Call `NSWorkspace.shared.open(url)` to delegate mounting to macOS.
5. Poll up to 15 times (once per second) for the mount to appear via `statfs()`.

**Unmount flow:**

1. Execute `/sbin/umount {mountPoint}`.
2. If that fails (non-zero exit), fall back to `/usr/sbin/diskutil unmount {mountPoint}`.

**Status check:**

- First checks the default mount point (`/Volumes/{shareName}`) via `statfs()`.
- If not found, enumerates all mounted volumes and matches by `volumeURLForRemountingKey` (host + share name comparison).
- Verifies the filesystem type string is `"smbfs"`.

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

A static struct handling JSON serialization of connections to disk.

| Method | Description |
|--------|-------------|
| `load()` | Reads and decodes `[SMBConnection]` from JSON file |
| `save(_:)` | Encodes connections and writes atomically to JSON file |

**Storage path:** `~/Library/Application Support/SMBMountManager/connections.json`

The directory is created automatically with `withIntermediateDirectories: true` on first save.

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
- Services that disappear from the network are automatically removed from the list.

**DiscoveredSMBHost** — a value type with `serviceName`, `hostName`, and `port`. The `normalizedHostName` strips trailing dots from Bonjour hostnames.

### SMBShareDiscoveryService

**File:** `SMBMountManager/Services/SMBShareDiscoveryService.swift`

A static struct that enumerates available shares on a given SMB server using the macOS `smbutil view` command.

| Method | Description |
|--------|-------------|
| `discoverShares(serverAddress:username:password:)` | Runs `smbutil view //user:pass@server` and parses the output |

Credentials are percent-encoded before being passed to `smbutil`. The output is parsed line-by-line, filtering out header rows and extracting share names. Results are deduplicated and sorted alphabetically.

## Views

### ContentView

**File:** `SMBMountManager/Views/ContentView.swift`

The root view of the application. Owns the `MountService`, `LoggingService`, and `SMBDiscoveryService` instances and the connections array.

**State management:**

- `@StateObject mountService` — mount/unmount observable service
- `@StateObject loggingService` — shared logging singleton
- `@StateObject discoveryService` — Bonjour browser
- `@State connections` — the array of saved connections
- `@State editingConnection` — triggers the edit sheet
- `@State isAddingNew` — triggers the add sheet
- `@State isShowingDiagnostics` — triggers the diagnostics console sheet
- `@State isShowingDiscovery` — triggers the discovery panel sheet
- `@State suggestedHost` — pre-fills the connection form from a discovered host

**Lifecycle:**

- `onAppear`: loads connections from `PersistenceService`, starts monitoring, records app log entry.
- `onDisappear`: stops monitoring timers, records app log entry.

**Key behaviors:**

- Toolbar buttons: Connect All, Disconnect All, Discover SMB Servers, Diagnostics Console, Add Connection.
- Sheet modals for add/edit, discovery, and diagnostics operations.
- Selecting a host from the discovery panel opens the add-connection form pre-filled with the host address.
- Swipe-to-delete with Keychain cleanup.
- Empty state display when no connections exist.
- Minimum window size: 500×300.

### ConnectionRow

**File:** `SMBMountManager/Views/ConnectionRow.swift`

A stateless row component receiving its data and callbacks via properties.

**Inputs:** `connection`, `status`, `onConnect` closure, `onDisconnect` closure.

**Renders:**

- Color-coded status circle (10pt).
- Connection name (falls back to share name if name is empty).
- Server address and share name as caption.
- Auto-connect badge icon when enabled.
- Context-aware button: "Connect", "Disconnect", "Retry", or "Connecting..." (disabled).

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

**Inputs:** `discoveryService` (`SMBDiscoveryService`), `onSelectHost` closure.

**Behavior:**

- Starts browsing automatically on appear, stops on disappear.
- Displays each host with its display name and normalized hostname.
- A **Use** button triggers the `onSelectHost` callback and dismisses the panel.
- **Refresh** restarts the scan. A progress indicator is shown while scanning.
- Empty state differentiates between "searching" and "no servers found".
- Minimum size: 520×360.

### DiagnosticsConsoleView

**File:** `SMBMountManager/Views/DiagnosticsConsoleView.swift`

A modal log viewer displaying entries from `LoggingService`.

**Controls:**

- Segmented picker for `LogVisibilityMode` (Hidden / Errors Only / Standard / All).
- **Copy Logs** — copies all entries to the system pasteboard in ISO 8601 format.
- **Clear** — removes all recorded entries.
- Esc to close.

**Display:**

- Each entry shows severity (color-coded), category, timestamp, and message in a monospaced font.
- Entries are sorted newest-first.
- Text selection is enabled for individual log messages.
- Empty state varies by visibility mode.
- Minimum size: 760×420.

## Data Flow

```
User action (tap Connect, add connection, etc.)
    │
    ▼
ContentView calls MountService method or updates connections array
    │
    ▼
MountService updates statuses dictionary (@Published)
    │
    ▼
SwiftUI observes change, re-renders affected views
    │
    ▼
ContentView calls saveAndRefresh() → PersistenceService.save() + MountService.updateConnections()
```

## Entitlements and Info.plist

**File:** `SMBMountManager/SMBMountManager.entitlements`

| Entitlement | Value | Purpose |
|-------------|-------|---------|
| `com.apple.security.network.client` | `true` | Required for outbound network access to open SMB URLs |

The App Sandbox is **disabled** — this is necessary because mounting SMB shares requires direct filesystem and process access (`statfs`, `umount`, `diskutil`, `smbutil`) that sandboxed apps cannot perform.

**File:** `SMBMountManager/SMBMountManager/Info.plist`

| Key | Value | Purpose |
|-----|-------|---------|
| `NSBonjourServices` | `["_smb._tcp"]` | Declares the Bonjour service type the app browses for |
| `NSLocalNetworkUsageDescription` | Usage string | Shown to the user when the app requests local network access |

## Design Decisions and Constraints

1. **Mount point is derived from share name** (`/Volumes/{shareName}`). Two connections with the same share name on different servers would target the same mount point and conflict.

2. **`NSWorkspace.shared.open(url)`** delegates the actual SMB mount to macOS/Finder. This provides a reliable, OS-native mount experience but means the app does not have fine-grained control over mount options (e.g., read-only, soft/hard mount).

3. **Polling up to 15 seconds after mount** (one check per second) before declaring a timeout. Slow networks or servers may still need longer for the mount to appear.

4. **Credentials in the SMB URL** are percent-encoded and passed inline (`smb://user:pass@server/share`). This is the standard approach for `NSWorkspace` SMB mounting. The URL exists briefly in memory but is not persisted.

5. **Polling-based monitoring** (15s status, 30s auto-connect) rather than filesystem event notifications. This is simpler and sufficient for the use case, though it means status updates are not instantaneous.

6. **No App Sandbox** is a deliberate choice to allow process execution (`umount`, `diskutil`, `smbutil`) and `statfs()` system calls needed for mount and discovery management.

7. **Bonjour discovery** relies on servers publishing `_smb._tcp` services. Servers that do not advertise via mDNS will not appear in the discovery panel but can still be added manually.

8. **Share discovery via `smbutil view`** requires valid credentials. The command is executed as a child process; credentials are percent-encoded and passed inline. The process output is parsed heuristically, filtering out header rows.

9. **In-memory logging** with a 500-entry cap keeps memory usage bounded. Logs are also written to `OSLog` for inspection via Console.app. The visibility mode is persisted in `UserDefaults` so it survives app restarts.
