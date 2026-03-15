# SMB Mount Manager

A native macOS application for managing SMB network share connections. Easily mount, unmount, and auto-reconnect to file servers with secure credential storage, real-time health monitoring, and connection telemetry.

## Features

- **Connection Management** — Add, edit, and delete SMB connections with a clean native interface
- **One-Click Mount/Unmount** — Connect or disconnect individual shares instantly
- **Bulk Operations** — Connect all or disconnect all shares from the toolbar
- **Auto-Connect** — Automatically reconnect to selected shares every 30 seconds when they drop, with a configurable retry limit (default: 5 attempts)
- **Real-Time Status Monitoring** — Connection status refreshes every 15 seconds with color-coded indicators:
  - Green: Connected
  - Yellow: Connecting (animated alternating green/yellow)
  - Red: Disconnected
  - Orange: Error
- **Secure Credential Storage** — Passwords are stored exclusively in the macOS Keychain, never written to disk
- **Network Discovery** — Automatically discover SMB servers on the local network via Bonjour (`_smb._tcp`), with IP address resolution and timing information. Select a discovered host to pre-fill the connection form
- **Share Discovery** — Query the list of available shares on a server directly from the connection form using `smbutil`
- **Search, Filter & Sort** — Search connections by name, server, share, or username. Filter by status (All, Connected, Disconnected, Errors, Unstable). Sort by Name, Host, Status, Latency, or Stability
- **Connection Details Sheet** — Click any connection to open a detail panel showing live metrics, historical stats, stability estimates, benchmark results, and an event timeline
- **Connection Health Monitoring** — Stability grades (Insufficient History / Low / Medium / High) with confidence levels, error categorization across 7 categories (authentication, connectivity, timeout, share not found, mount point busy, benchmark, unknown), and timeline event tracking
- **Connection Telemetry** — Passive probe latency measurement with jitter tracking, session detail collection (protocol version, signing, encryption, multichannel state), and volume capacity reporting
- **Performance Benchmarking** — On-demand read/write throughput measurement with configurable payload size (1–64 MB)
- **Runtime Details Badges** — Inline badges on each connection row showing protocol version, "Unstable" (low stability), "High Latency" (≥1 s), and "Hidden" (for `$` shares)
- **Context Menu Actions** — Right-click a connection for Copy SMB URL, Open Mount Point, Refresh Details, or Run Benchmark
- **Diagnostics Console** — Two-tab layout (Logs and Health). The Logs tab provides a log viewer with four visibility modes (Hidden, Errors Only, Standard, All). The Health tab displays connection health snapshots with per-connection runtime breakdown. Logs can be copied to clipboard or cleared; health data can be exported as JSON
- **Configurable Monitoring** — Settings panel in the Diagnostics Console for probe interval (10–120 s), session refresh interval (30–300 s), automatic retry limit (1–20), stability observation window (Session / 24 Hours / 7 Days), and benchmark payload size (1–64 MB)
- **Launch/Quit Behaviors** — Optional toggles to auto-connect shares on app launch and auto-disconnect on quit

## Screenshots

### Main Window
![Main Window](screenshots/main-window.png)

The main window displays all configured SMB connections in a filterable, sortable list. Each row shows the connection name, server path, a color-coded status indicator, runtime badges (protocol version, stability, latency), and live telemetry metrics (stability grade, probe latency, success rate). The toolbar provides quick actions: **Connect All** (bolt icon), **Disconnect All** (bolt slash icon), **Discover SMB Servers** (network icon), **Diagnostics Console** (stethoscope icon), and **Add Connection** (+). A filter bar at the top offers a search field, status filter, and sort picker.

### Add / Edit Connection
![Add Connection](screenshots/add-connection.png)

The connection form allows you to configure all the details for an SMB share: a friendly display name, the server address (IP or hostname), the share name, and authentication credentials. The **Auto-connect** toggle enables automatic reconnection every 30 seconds when the share drops. Passwords are securely stored in the macOS Keychain and never written to disk. The **Share Discovery** section lets you query available shares on the server using the current credentials.

## Requirements

- **macOS 13.0** (Ventura) or later
- **Xcode 15.0** or later (to build from source)
- Network access to one or more SMB file servers

## Installation

### Build from Source

1. Clone the repository:
   ```bash
   git clone <repository-url>
   cd SAMBA
   ```

2. Open the Xcode project:
   ```bash
   open SMBMountManager/SMBMountManager.xcodeproj
   ```

3. In Xcode, select your signing team under **Signing & Capabilities**.

4. Build and run with **Cmd+R**, or archive for a release build via **Product → Archive**.

> **Note:** The project uses only native Apple frameworks — no external dependencies or package managers are required.

## Usage

### Adding a Connection

1. Click the **+** button in the toolbar.
2. Fill in the connection details:
   - **Name** — A display label (e.g., "NAS - Shared"). Optional; defaults to the share name if left empty.
   - **Server address** — IP address or hostname of the SMB server.
   - **Share name** — The name of the shared folder on the server.
   - **Username** — Your SMB account username.
   - **Password** — Your SMB account password (stored in Keychain).
3. Optionally click **Discover Shares** to list the shares available on the server (requires server, username, and password to be filled in). Select a share from the dropdown to auto-fill the share name.
4. Optionally enable **Auto-connect** to automatically reconnect when the share drops.
5. Click **Save**.

### Discovering SMB Servers

1. Click the **network** icon in the toolbar to open the Discovery panel.
2. The app automatically scans the local network for SMB servers published via Bonjour.
3. Each discovered host displays its name, normalized hostname, IP addresses, and port.
4. Click **Use** next to a discovered server to pre-fill the connection form with its hostname.
5. Click **Refresh** to re-scan the network.

### Diagnostics Console

1. Click the **stethoscope** icon in the toolbar to open the Diagnostics Console.
2. Use the **Logs / Health** tab picker to switch between log viewing and health monitoring.
3. **Logs tab:**
   - Use the segmented control to switch between visibility modes: Hidden, Errors Only, Standard, All.
   - Click **Copy Logs** to copy all entries to the clipboard in ISO 8601 format.
   - Click **Clear** to remove all recorded entries.
4. **Health tab:**
   - View connection health snapshots on the left (status, stability, confidence).
   - View per-connection runtime details on the right (success rate, probe history, error breakdown, timeline events).
   - Click **Copy Health JSON** to export health data as JSON.
5. **Settings panel:**
   - Adjust the automatic retry limit, probe interval, session refresh interval, stability observation window, and benchmark payload size.
   - Toggle "Connect auto-connect shares when the app launches" and "Disconnect connected shares when the app quits."

### Connecting and Disconnecting

- Click the **Connect** button on any row to mount that share.
- Click the **Disconnect** button on a connected share to unmount it.
- Use the **bolt** toolbar button to connect all shares at once.
- Use the **bolt slash** toolbar button to disconnect all shares at once.

> **Mount point:** Shares are mounted at `~/Volumes/{server}-{share}` (inside the user's home directory). The server and share names are sanitized by replacing `/` and `:` with `-`.

### Viewing Connection Details

Click on any connection row to open the details sheet, which displays:
- Live metrics (status, mount point, volume capacity, protocol version, signing, encryption, multichannel)
- Historical stats (successful/failed mounts, disconnects, automatic retries, connected/disconnected duration)
- Estimated stability (stability grade, confidence level, success rate, probe latency, jitter)
- Benchmark results (read/write throughput; click **Run Benchmark** to trigger a new measurement)
- Event timeline (recent status changes, probes, benchmarks, and session refreshes)

### Editing a Connection

Click on any connection row to open the details sheet, then use the **Edit** option, or swipe and select edit. The edit sheet opens with pre-filled values, including the stored password.

### Deleting a Connection

Swipe left on a connection row to delete it. This also removes the associated password from the Keychain.

### Auto-Connect

When enabled for a connection, the app automatically attempts to mount the share every 30 seconds if it is not already connected. After the configured maximum retry count (default: 5), automatic retries stop until the connection is manually reconnected or the retry count resets on a successful mount.

## Data Storage

| Data | Location | Format |
|------|----------|--------|
| Connections (metadata) | `~/Library/Application Support/SMBMountManager/connections.json` | JSON |
| Runtime details (telemetry) | `~/Library/Application Support/SMBMountManager/runtime-details.json` | JSON (ISO 8601 dates) |
| Passwords | macOS Keychain (service: `com.smb-mount-manager`) | Encrypted |
| User preferences | `UserDefaults` | Various |

**UserDefaults keys:** `logVisibilityMode`, `maximumAutomaticRetryCount`, `probeIntervalSeconds`, `sessionRefreshIntervalSeconds`, `stabilityObservationWindow`, `benchmarkPayloadSizeMB`, `connectSharesOnLaunch`, `disconnectSharesOnQuit`.

- Passwords are **never** written to the JSON file — only the connection metadata (name, server, share, username, auto-connect flag) is persisted.
- Runtime details (telemetry, probe history, error counts, benchmark results) are persisted separately and survive app restarts.
- Deleting a connection also removes its Keychain entry.

## Project Structure

```
SAMBA/
├── SMBMountManager/
│   ├── SMBMountManager/
│   │   ├── SMBMountManagerApp.swift        # App entry point (@main)
│   │   ├── Models/
│   │   │   ├── SMBConnection.swift         # Data model + ConnectionStatus enum
│   │   │   └── SMBShareDetails.swift       # Health monitoring, telemetry, and benchmark types
│   │   ├── Views/
│   │   │   ├── ContentView.swift           # Main window with connection list, filtering, sorting
│   │   │   ├── ConnectionRow.swift         # Individual connection row with badges and context menu
│   │   │   ├── ConnectionEditView.swift    # Add/edit connection form + share discovery
│   │   │   ├── DiscoveryView.swift         # Bonjour SMB server discovery panel
│   │   │   └── DiagnosticsConsoleView.swift # Diagnostics console (logs + health monitoring)
│   │   ├── Services/
│   │   │   ├── MountService.swift          # Mount, unmount, status monitoring, telemetry, benchmarking
│   │   │   ├── KeychainService.swift       # Secure password CRUD via Keychain
│   │   │   ├── PersistenceService.swift    # JSON file persistence (connections + runtime details)
│   │   │   ├── LoggingService.swift        # Centralized logging with severity/category
│   │   │   ├── SMBDiscoveryService.swift   # Bonjour network browser with IP resolution
│   │   │   └── SMBShareDiscoveryService.swift # Share enumeration via smbutil
│   │   ├── Assets.xcassets/                # App icon assets
│   │   ├── Info.plist                      # Bonjour service declarations
│   │   └── SMBMountManager.entitlements    # Network client entitlement
│   ├── SMBMountManager.xcodeproj/          # Xcode project configuration
│   └── generate_icon.py                    # App icon generation script
├── ARCHITECTURE.md                         # Technical architecture reference
└── README.md                               # This file
```

For a detailed technical overview, see [ARCHITECTURE.md](ARCHITECTURE.md).

## Icon Generation

The `generate_icon.py` script generates all required macOS app icon sizes. It requires **Python 3** and the **Pillow** library:

```bash
pip install Pillow
cd SMBMountManager
python3 generate_icon.py
```

This produces icon PNGs at all standard macOS sizes (16×16 through 512×512, at 1× and 2× scales) and updates `Contents.json` in the asset catalog.

## Contributing

1. Fork the repository.
2. Create a feature branch (`git checkout -b feature/my-feature`).
3. Make your changes, following the existing code style (SwiftUI, MVVM, `@MainActor` for services).
4. Commit your changes and push to your fork.
5. Open a pull request.

## License

This project is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.
