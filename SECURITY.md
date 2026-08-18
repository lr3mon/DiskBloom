# Security Policy

## Supported versions

DiskBloom is currently an early open-source release. Security and deletion-safety fixes are applied to the latest `main` branch and the newest tagged release.

## Reporting a vulnerability

Please use GitHub's **Private vulnerability reporting** feature from the repository's **Security** tab.

Do not open a public issue for vulnerabilities involving:

- Unintended deletion or trashing of protected paths
- Symlink, mount-boundary, or path-normalization bypasses
- Unexpected cloud-placeholder downloads
- Exposure or transmission of local file metadata
- Full Disk Access or TCC permission handling

Include:

1. macOS version and architecture
2. DiskBloom commit or version
3. Reproduction steps
4. Expected and observed behavior
5. The smallest safe test fixture possible

Do not attach real cache snapshots or private directory listings. Replace personal paths and filenames with synthetic examples.

## Security model

DiskBloom is a local desktop utility. It intentionally has no account system, remote API, analytics, or telemetry. Full Disk Access must be granted manually by the user through macOS System Settings.

The path snapshot is stored in a `0700` Application Support directory with `0600` file permissions and is excluded from backups. Existing snapshots are hardened when they are loaded.

Deletion uses the macOS Trash API and is guarded by an explicit policy. The active scan root, filesystem root, home directory, protected system roots, mounted volume roots, synthetic nodes, and URL-less aggregate nodes are not eligible for trash operations.

## Release trust

The current local packaging script uses ad-hoc signing. Developer ID signing and Apple notarization are roadmap items. Until notarized releases are available, build from source and review the code when operating in sensitive environments.
