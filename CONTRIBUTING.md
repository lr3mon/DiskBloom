# Contributing to DiskBloom

Thanks for helping improve DiskBloom. The project prioritizes filesystem safety, privacy, predictable macOS behavior, and measurable performance.

## Before opening an issue

- Search existing issues first.
- Use the bug or feature issue form when possible.
- For vulnerabilities or deletion-safety issues, follow [SECURITY.md](SECURITY.md) and do not publish exploit details.

## Development setup

Requirements:

- macOS 14+
- Xcode 15.3+ or Swift 5.10+
- Python 3 and Pillow for packaged-app/icon builds

```bash
git clone https://github.com/lr3mon/DiskBloom.git
cd DiskBloom
python3 -m pip install --user Pillow
swift test
swift build --product DiskBloom
```

## Pull requests

1. Create a focused branch such as `fix/cache-validation` or `feat/keyboard-navigation`.
2. Keep the core scanner independent from SwiftUI where practical.
3. Add or update tests for scanner, cache, exclusion, or deletion-policy changes.
4. Run the verification commands below.
5. Explain user-visible behavior, privacy impact, and performance impact in the PR.

```bash
swift test
swift build --product DiskBloom
swift build --product diskbloom-scan
./Scripts/build_app.sh
codesign --verify --deep --strict dist/DiskBloom.app
plutil -lint dist/DiskBloom.app/Contents/Info.plist
```

## Safety rules

- Never replace Trash with permanent deletion.
- Never allow scan roots, filesystem roots, home, system roots, mounted volume roots, or synthetic nodes to be trashed.
- Never follow symbolic links during scanning.
- Never trigger cloud-placeholder downloads for analysis.
- Never add telemetry, analytics, or network transmission of file metadata without an explicit public design discussion and opt-in model.
- Treat changes to exclusions, path normalization, APFS handling, and permissions as high-risk changes requiring regression tests.

## Code style

- Prefer small, focused Swift types and explicit state transitions.
- Keep heavy filesystem work off the main actor.
- Avoid `@unchecked Sendable` unless ownership and mutation are clearly isolated.
- Preserve cancellation and per-item error isolation.
- Use Korean for the current app UI and English for public code/documentation when practical.

## Reporting performance

Include the scan root shape, item count, elapsed time, peak memory if available, macOS version, and hardware architecture. Do not attach snapshots containing private local file paths.
