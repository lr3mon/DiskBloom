# Changelog

All notable changes to DiskBloom are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project intends to use [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Planned

- Developer ID signing and Apple notarization
- Snapshot freshness and volume identity validation
- Security-scoped bookmarks for user-selected folders

## [0.3.2] - 2026-08-18

### Added

- Public repository documentation, CI, issue forms, and contribution/security guides
- Path-based protection for filesystem roots, the user's home directory, system roots, and mounted volume roots
- Regression tests for protected deletion targets

### Security

- Restricted the snapshot directory to `0700` and the cache file to `0600`
- Excluded the local path snapshot from system backups

### Changed

- Polished README branding and documented source-build trust boundaries

## [0.3.1] - 2026-08-11

### Fixed

- Removed a race between SwiftUI `WindowGroup` creation and an AppKit fallback window that could show duplicate app windows
- Switched to a single named SwiftUI window scene

## [0.3.0] - 2026-08-10

### Added

- Direct sunburst navigation: click slices to enter and the center to move outward
- Spring-based radial reveal animations and lightweight hover feedback
- Full-row sidebar hit targets and location accessibility identifiers

### Improved

- Cached sunburst segment layouts and depth-indexed hit testing
- Reduced sidebar navigation invalidation and repeated hover work

## [0.2.1] - 2026-08-10

### Added

- First-launch Full Disk Access guidance and permission verification
- Permission-aware full rescans and limited-access fallback

## [0.2.0] - 2026-08-06

### Added

- Cache-first local storage snapshots
- Cloud, network, backup, and APFS special-volume exclusions
- Parallel local-volume scanning with bounded display trees
- Finder, Quick Look, and Trash integration

## [0.1.0] - 2026-08-05

### Added

- Initial SwiftUI disk usage explorer, scanner core, CLI, tests, app icon, and local packaging script
