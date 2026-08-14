# Jade (bad_query)

A sandbox escape file manager and system tweaker for iOS 26.0 – 26.6.1 / 27.0 beta. Built on the `bad_query` path-traversal sandbox escape (credited to Taj C), Jade extends the PoC into a full-featured SwiftUI app for browsing and modifying iOS system containers — with optional MobileHouseArrest (MHA) identity bypass for unrestricted container access.

> **Disclaimer**: This is a proof-of-concept for security research and personal device management. It uses private APIs and identity impersonation. Use only on devices you own or are authorized to test.

---

## Features

### File Browser (`File` tab)

Browse iOS system containers that are normally sandboxed off:

| Container | Path | iOS |
|-----------|------|-----|
| Application Containers | `/var/mobile/Containers/Data/Application/*` | 26+ |
| InternalDaemon Containers | `/var/mobile/Containers/Data/InternalDaemon/*` | 26+ |
| PluginKitPlugin Containers | `/var/mobile/Containers/Data/PluginKitPlugin/*` | 26+ |
| App Groups | `/var/mobile/Containers/Shared/AppGroup/*` | 26 (sacrifice) / 27 (direct) |
| System Data Containers | `/var/containers/Data/System/*` | 27+ |
| System Groups | `/var/containers/Shared/SystemGroup/*` | 27+ |

**Capabilities:**
- Directory listing with file metadata (size, modified date)
- File preview (text, plist, JSON, images, hex dump)
- File operations (create, rename, delete)
- Inode-scan fallback for hidden/denied directories (with adaptive range caching)
- Container metadata resolution (bundle ID from `.com.apple.mobile_container_manager.metadata.plist`)
- Activity log with timestamped extension activations

### Apps (`Apps` tab)

Browse installed apps by their data containers:

- **App discovery** — three-tier strategy:
  1. csstore parsing (iOS 26 primary) — activates `com.apple.lsd` class-10 container, parses `com.apple.LaunchServices-*-v2.csstore`
  2. `MCMEnumerateIdentifiersForClass(2)` — direct MCM enumeration (supplement)
  3. inode scan fallback — bad_query on `/var/mobile/Containers/Data/Application`
- **Display name resolution** — `LSApplicationProxy.localizedName` → MCM metadata plist `MCMMetadataDisplayName` → bundle ID
- **Open apps** — long-press context menu to launch via `LSApplicationWorkspace.openApplication`
- **Search** — filter by name, bundle ID, or UUID

### MobileGestalt Editor (`Gestalt` tab)

Edit `MobileGestalt.plist` device properties:

- Device artwork, software features, hardware features
- Eligibility toggles (Apple Intelligence, etc.)
- iPadOS features, internal flags
- Advanced field editor for CacheExtra keys
- Apply / Revert with backup
- Accesses the systemgroup `systemgroup.com.apple.mobilegestaltcache` container (class 13)

### PosterBoard (`Poster` tab)

Import and manage PosterBoard wallpapers (lock screen / home screen):

- Import `.tendies` wallpaper packages
- Browse installed wallpapers
- Accesses the PosterBoard system container
---

## How It Works

### bad_query Sandbox Escape

The core escape uses a path-traversal technique in `bad_query.c`:

1. `bad_query(path, create, group_identifier, is_group)` activates a sandbox extension for the target path
2. The extension is per-path (not recursive) — each file needs its own extension
3. Extensions are cached and released on exit
4. Fallback through App Group (`group.com.jason.bqtools`) for iOS 26 App Group containers

### MobileHouseArrest (MHA) Bypass

When the app is signed with bundle ID `com.apple.mobile.MobileHouseArrest`, `containermanagerd` treats it as the `lockdownd` client, granting access to **all container classes** (2/4/6/7/10/12/13/15):

| Class | Container Type | Example |
|-------|---------------|---------|
| 2 | App Data | `com.apple.mobilesafari` |
| 4 | Extension Data | `com.example.widget.extension` |
| 7 | App Group | `group.com.apple.notes` |
| 10 | Service Data | `com.apple.lsd` |
| 12 | System Data | `com.apple.geod` |
| 13 | System Group | `systemgroup.com.apple.mobilegestaltcache` |
| 15 | Protected Data | `com.apple.*.protected` |

**MHA limitations (Manual §10.2):**
- ❌ App Bundle directories (`/var/containers/Bundle/Application/`) — MCM does not issue extensions
- ❌ System binaries (`/Applications`, `/System`) — SSV protected
- ❌ Keychain, TCC, other processes' memory

### iOS 26 Specifics

- `containermanagerd` lacks `genericExtensionsAllowedForAll` — sandbox token activation often fails, but the container path is still returned
- `MCMEnumerateIdentifiersForClass(2)` returns near-empty — csstore parsing is the primary discovery method
- Third-party apps can be hidden from enumeration — inode scan is the last resort

---

## Build

### Prerequisites

- macOS with Xcode (or Xcode-beta)
- iOS 26.0+ SDK
- For MHA version: a way to install ad-hoc signed IPAs (TrollStore, or a paid developer certificate)

### Build Script

```bash
./build_ipa.sh
```

Generates two ad-hoc signed IPAs in `build/`:

| IPA | Bundle ID | Purpose |
|-----|-----------|---------|
| `Jade.ipa` | `com.jason.Jade` | Standard version — bad_query escape only |
| `Jade-MHA.ipa` | `com.apple.mobile.MobileHouseArrest` | MHA version — full container bypass |

The MHA version sets the **CodeDirectory identifier** via `codesign --identifier`, which is what `containermanagerd` checks via `SecTaskCopySigningIdentifier` (not `Bundle.main.bundleIdentifier`).

### Manual Build

```bash
# Build unsigned .app
xcodebuild build \
    -project Jade.xcodeproj \
    -scheme Jade \
    -configuration Debug \
    -derivedDataPath build/DerivedData \
    -destination 'generic/platform=iOS' \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" DEVELOPMENT_TEAM=""

# Ad-hoc sign with MHA identity
codesign -f -s - --identifier "com.apple.mobile.MobileHouseArrest" \
    --entitlements bad_query/bad_query.entitlements \
    build/DerivedData/Build/Products/Debug-iphoneos/Jade.app

# Package IPA
mkdir -p build/Payload
cp -R build/DerivedData/Build/Products/Debug-iphoneos/Jade.app build/Payload/
cd build && zip -r Jade-MHA.ipa Payload
```

---

## Installation

### TrollStore (recommended)

1. Install `Jade-MHA.ipa` via TrollStore
2. The app runs with MHA identity — full container access enabled

### Paid Developer Certificate

1. Sign `Jade-MHA.ipa` with a certificate that allows custom bundle IDs
2. Install via standard sideloading tools

> **Free Personal Team / Auto-bundle-ID sideloaders will NOT work** — Apple rejects `com.apple.mobile.MobileHouseArrest` as an App ID (error 9400/9401).

---

## Project Structure

```
bad_query/
├── bad_query.c              # Core sandbox escape (path traversal)
├── bad_query.h              # C API
├── MCMBridge.h/.m           # libsystem_containermanager dlopen + MCMLease
├── BQMCMIntegration.h/.m    # High-level MHA container access (lease cache, csstore)
├── BQFileSystem.swift       # File manager engine (extensions, inode scan, metadata)
├── BQRootView.swift         # Main UI (File tab, session controls)
├── BQAppListView.swift      # Apps tab (discovery, name resolution)
├── BQDirectoryView.swift    # Directory browser
├── BQMobileGestalt.swift    # MobileGestalt.plist engine
├── BQMobileGestaltView.swift # Gestalt tab UI
├── BQPoster.swift/.swift    # PosterBoard wallpaper engine
├── BQSandboxPoCView.swift   # Sandbox PoC demonstrations
├── BQWallpaperAPI.swift     # Wallpaper API
├── BQWallpaperBrowserView.swift # Wallpaper browser
├── id2name.swift            # Bundle ID → display name resolver
├── Respring.swift           # Respring utility
├── bad_query-Bridging-Header.h # ObjC/Swift interop (CoreServices, MCM, helpers)
└── CoreServices/            # Private LaunchServices headers
```

---

## Key APIs

### bad_query (C)

```c
// Activate a sandbox extension for a path
int64_t bad_query(char *path, bool create, char *group_identifier, bool is_group);

// Inode-based container discovery (for hidden directories)
char *bad_query_list(char *path, int64_t max_inode);
char *bad_query_list_range(char *path, int64_t start_inode, int64_t end_inode);

// Release an extension
void bad_query_release(int64_t handle);
```

### BQMCMIntegration (ObjC)

```objc
// Activate a container's sandbox extension (cached lease)
NSString *BQMCMActivate(uint64_t containerClass, NSString *identifier,
                        BOOL group, NSString **error);

// Query container path WITHOUT activating token (iOS 26-friendly)
NSString *BQMCMDataContainerPathQuery(NSString *identifier, NSString **error);

// App discovery: parse lsd csstore for candidate bundle IDs
NSArray<NSString *> *BQMCMLaunchServicesStoreIdentifiers(void);

// Enumerate registered identifiers (iOS 26: near-empty)
NSArray<NSString *> *BQMCMEnumerateIdentifiersForClass(
    uint64_t containerClass, NSUInteger limit, NSString **error);
```

---

## Error Codes

| Code | Meaning |
|------|---------|
| -255 | Path is not absolute |
| -254 | Path does not exist |
| -1 | Failed to resolve containermanager functions |
| -2 | Failed to create container query |
| -3 | `containermanagerd` refused the query (unsupported path?) |
| -4 | Kernel refused the sandbox extension |
| -5 | Internal error building the query |

---

## Limitations

- **iOS 26/27 hardened MHA authorization** — development-signed apps may be rejected even with the correct CodeDirectory identifier string
- **Sandbox extensions are process-lifetime** — no persistence after app exit
- **Per-path extensions** — each file/directory needs its own extension; 200+ active extensions slow down syscalls (~20× `fsgetpath` overhead)
- **No root privilege escalation** — MHA only bypasses the sandbox (MAC), not UID restrictions (DAC)
- **Bundle directories inaccessible** — `/var/containers/Bundle/Application/` cannot be read via MCM

---

## Credits

- **bad_query sandbox escape** — Taj C
- **MCM integration pattern** — FilzaSlop (MCMFilzaIntegration)
- **Apps Manager fallback strategy** — FilzaSlop (3-hook data-source degradation)
- **MobileGestalt editor** — mond / GestaltEdit

---

## License

Proof-of-concept for security research. Use responsibly on devices you own or are authorized to test.
