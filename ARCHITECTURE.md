# Architecture Overview

This document describes the technical architecture of SMB Mount Manager for developers who want to understand or contribute to the codebase.

## Design Pattern

The application follows **MVVM (Model-View-ViewModel)**:

- **Model** — `SMBConnection` struct and `ConnectionStatus` enum
- **ViewModel** — `MountService` (shared `ObservableObject` managing state and business logic)
- **View** — SwiftUI views (`ContentView`, `ConnectionRow`, `ConnectionEditView`)

```
┌──────────────────────────────────────────────────────────┐
│  Views (SwiftUI)                                         │
│  ContentView · ConnectionRow · ConnectionEditView        │
└────────────────────────┬─────────────────────────────────┘
                         │ @StateObject / @Published
┌────────────────────────▼─────────────────────────────────┐
│  MountService (ObservableObject, @MainActor)             │
│  - statuses: [UUID: ConnectionStatus]                    │
│  - mount / unmount / status timers                       │
└────────┬──────────────────┬──────────────────┬───────────┘
         │                  │                  │
┌────────▼───────┐ ┌───────▼────────┐ ┌───────▼──────────┐
│ KeychainService│ │PersistenceServ.│ │ System APIs      │
│ (SecItem APIs) │ │ (JSON file)    │ │ NSWorkspace      │
│                │ │                │ │ umount / diskutil │
│                │ │                │ │ statfs()          │
└────────────────┘ └────────────────┘ └──────────────────┘
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
5. After a 5-second delay, verify mount via `statfs()`.

**Unmount flow:**

1. Execute `/sbin/umount {mountPoint}`.
2. If that fails (non-zero exit), fall back to `/usr/sbin/diskutil unmount {mountPoint}`.

**Status check:**

- Calls `statfs()` on the mount point path.
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

## Views

### ContentView

**File:** `SMBMountManager/Views/ContentView.swift`

The root view of the application. Owns the `MountService` instance and the connections array.

**State management:**

- `@StateObject mountService` — shared observable service
- `@State connections` — the array of saved connections
- `@State editingConnection` — triggers the edit sheet
- `@State isAddingNew` — triggers the add sheet

**Lifecycle:**

- `onAppear`: loads connections from `PersistenceService`, starts monitoring.
- `onDisappear`: stops monitoring timers.

**Key behaviors:**

- Toolbar buttons: Connect All, Disconnect All, Add Connection.
- Sheet modals for add/edit operations.
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

**Validation:** Server address, share name, username, and password must all be non-empty (after trimming whitespace). The Save button is disabled until valid.

**On edit:** Pre-fills all fields from the existing connection, including loading the password from Keychain.

**Keyboard shortcuts:** Esc to cancel, Return to save.

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

## Entitlements

**File:** `SMBMountManager/SMBMountManager.entitlements`

| Entitlement | Value | Purpose |
|-------------|-------|---------|
| `com.apple.security.network.client` | `true` | Required for outbound network access to open SMB URLs |

The App Sandbox is **disabled** — this is necessary because mounting SMB shares requires direct filesystem and process access (`statfs`, `umount`, `diskutil`) that sandboxed apps cannot perform.

## Design Decisions and Constraints

1. **Mount point is derived from share name** (`/Volumes/{shareName}`). Two connections with the same share name on different servers would target the same mount point and conflict.

2. **`NSWorkspace.shared.open(url)`** delegates the actual SMB mount to macOS/Finder. This provides a reliable, OS-native mount experience but means the app does not have fine-grained control over mount options (e.g., read-only, soft/hard mount).

3. **5-second delay after mount** before checking status is a heuristic. Slow networks or servers may need longer for the mount to appear.

4. **Credentials in the SMB URL** are percent-encoded and passed inline (`smb://user:pass@server/share`). This is the standard approach for `NSWorkspace` SMB mounting. The URL exists briefly in memory but is not persisted.

5. **Polling-based monitoring** (15s status, 30s auto-connect) rather than filesystem event notifications. This is simpler and sufficient for the use case, though it means status updates are not instantaneous.

6. **No App Sandbox** is a deliberate choice to allow process execution (`umount`, `diskutil`) and `statfs()` system calls needed for mount management.
