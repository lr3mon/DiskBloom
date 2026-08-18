<p align="center">
  <a href="README.md">한국어</a> · <strong>English</strong>
</p>

<p align="center">
  <img src=".github/assets/readme-hero-ko.svg" alt="DiskBloom — local-first disk space explorer for macOS" width="100%">
</p>

<p align="center">
  <a href="https://github.com/lr3mon/DiskBloom/actions/workflows/ci.yml"><img src="https://github.com/lr3mon/DiskBloom/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-11151D?logo=apple&logoColor=white" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-5.10-F05138?logo=swift&logoColor=white" alt="Swift 5.10">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-66D9B7" alt="MIT License"></a>
  <img src="https://img.shields.io/badge/network-none-6EA8FE" alt="No network or telemetry">
</p>

<p align="center">
  <strong>A native, private-by-design disk space explorer for macOS.</strong><br>
  Scan locally, navigate instantly, and understand what is filling your Mac—without sending file metadata anywhere.
</p>

<p align="center">
  <a href="#quick-start">Quick start</a> ·
  <a href="#privacy--safety">Privacy & safety</a> ·
  <a href="#architecture">Architecture</a> ·
  <a href="#roadmap">Roadmap</a> ·
  <a href="CONTRIBUTING.md">Contributing</a>
</p>

---

## Why DiskBloom?

Disk space tools need broad file-system access. DiskBloom is designed around that responsibility: the scan runs on your Mac, the snapshot stays on your Mac, and destructive actions are deliberately constrained.

| Explore | Stay private | Act safely |
| --- | --- | --- |
| Animated sunburst navigation, instant cached locations, large-file lists, and path search | No accounts, servers, analytics, telemetry, or network requests | Trash only—never permanent deletion. Filesystem roots, home, system roots, synthetic nodes, and volume roots are protected |

> DiskBloom is an independent implementation. It does not use DaisyDisk code or assets and is not affiliated with DaisyDisk.

## Highlights

- **Native macOS UI** built with SwiftUI and AppKit
- **Allocated-size scanning** for folders and mounted local volumes
- **Cache-first startup** from `~/Library/Application Support/DiskBloom/local-storage-snapshot.json`
- **Instant sidebar navigation** to storage, home, Downloads, Documents, and Applications
- **Direct sunburst navigation**: click a slice to dive in; click the center to go back
- **Cloud-safe defaults** that skip iCloud placeholders and common file-provider roots
- **APFS-aware exclusions** to avoid duplicate system/data volume accounting
- **Quick Look and Finder integration**
- **Safe trash workflow** with confirmation and protected-root policies
- **Large-tree controls**: symlink avoidance, tree compression, cancellation, and bounded UI depth
- **CLI scanner** for terminal workflows and debugging

## How it works

```text
Mounted local volumes
        │
        ├── target discovery + cloud/APFS exclusions
        │
        ├── bounded parallel scan
        │      ├── allocated byte totals
        │      ├── compressed display tree
        │      └── top-file heap
        │
        └── local JSON snapshot
               ├── instant sidebar locations
               ├── animated sunburst map
               └── Finder / Quick Look / Trash
```

The first full scan creates a local snapshot. Later launches restore it immediately; a new disk walk only happens when you explicitly choose **Rescan all local storage**.

## Interaction model

| Action | Result |
| --- | --- |
| Click anywhere on a sidebar location row | Switch to that cached location without rescanning |
| Click a sunburst folder/disk slice | Enter immediately |
| Click the sunburst center | Move one level outward |
| Click a file or terminal slice | Select and inspect it |
| Double-click a row | Enter a cached folder |
| `⌘O` | Scan a chosen folder temporarily |
| `⌘R` | Rescan all local storage |

## Quick start

### Requirements

- macOS 14 Sonoma or newer
- Xcode 15.3+ or a Swift 5.10 toolchain
- Python 3 with [Pillow](https://pypi.org/project/pillow/) for icon generation

### Build and run

```bash
git clone https://github.com/lr3mon/DiskBloom.git
cd DiskBloom
python3 -m pip install --user Pillow
swift test
chmod +x Scripts/build_app.sh
./Scripts/build_app.sh
open dist/DiskBloom.app
```

Build artifacts:

```text
dist/DiskBloom.app
dist/DiskBloom.zip
```

The local build script uses an ad-hoc signature. Public release signing and Apple notarization are not configured yet, so Gatekeeper may require **Control-click → Open** for a locally shared build. See the [roadmap](#roadmap).

### CLI

```bash
swift run diskbloom-scan ~/Downloads
```

## Full Disk Access

macOS does not allow an app to grant Full Disk Access to itself. DiskBloom checks access before the first automatic scan and opens the correct System Settings pane when needed.

1. Open **System Settings → Privacy & Security → Full Disk Access**
2. Enable DiskBloom; use `+` to add `/Applications/DiskBloom.app` if it is not listed
3. Return to DiskBloom and choose **Check permission**

You can continue with limited access, but protected folders will be skipped and counted as unreadable.

## Privacy & safety

### Data handling

- File names, paths, sizes, and scan results never leave the Mac
- No network client, analytics SDK, account system, or telemetry endpoint is included
- Snapshots are stored only under the current user's Application Support directory
- The snapshot directory is restricted to `0700`, the cache file to `0600`, and the snapshot is excluded from backups
- iCloud placeholders are skipped rather than downloaded for analysis

### Default scan exclusions

- `~/Library/CloudStorage`
- `~/Library/Mobile Documents`
- iCloud ubiquitous items and file-provider placeholders
- OneDrive, Dropbox, and Google Drive provider roots
- Network and backup volumes
- APFS Preboot, VM, Update, and duplicate/special volume paths
- `/.nofollow`, `/.resolve`, `/.vol`, and `/.file`

### Deletion policy

DiskBloom never performs permanent deletion. It uses the macOS Trash API after confirmation and blocks:

- The active scan root
- `/`, the user's home directory, and protected system roots
- Mounted volume roots under `/Volumes`
- Synthetic/aggregate nodes and nodes without a real URL

If you find a safety issue, please follow [SECURITY.md](SECURITY.md) instead of posting exploit details publicly.

## Architecture

```text
DiskBloom/
├── Sources/
│   ├── DiskBloom/          # SwiftUI app, navigation, cache orchestration, AppKit bridges
│   ├── DiskBloomCore/      # Scanner, models, cancellation, formatting, deletion policy
│   └── DiskBloomScan/      # CLI executable
├── Tests/
│   └── DiskBloomCoreTests/ # Scanner, cache, exclusions, safety-policy tests
├── Resources/              # Info.plist
├── Scripts/                # App packaging and original icon generation
└── .github/                # CI, issue forms, templates, and branding
```

The scanner core is separated from the UI so it can be tested and reused by the CLI. The app remains intentionally dependency-light; Pillow is needed only to generate the icon during packaging.

## Development

```bash
swift test
swift build --product DiskBloom
swift build --product diskbloom-scan
```

For a full packaged-app check:

```bash
./Scripts/build_app.sh
codesign --verify --deep --strict dist/DiskBloom.app
plutil -lint dist/DiskBloom.app/Contents/Info.plist
```

Read [CONTRIBUTING.md](CONTRIBUTING.md) before submitting a pull request.

## Roadmap

- [ ] Developer ID signing and Apple notarization
- [ ] DMG installer and verified GitHub Releases
- [ ] Cache freshness/volume identity validation
- [ ] Security-scoped bookmarks for persistent user-selected folders
- [ ] More tests for permission changes, corrupted snapshots, and multi-volume edge cases
- [ ] Instruments-based performance baselines and regression thresholds
- [ ] Localization beyond the current Korean-first app UI
- [ ] VoiceOver and keyboard-navigation audit

See [CHANGELOG.md](CHANGELOG.md) for shipped changes.

## License

DiskBloom is available under the [MIT License](LICENSE).

Copyright © 2026 stpd_fx.
