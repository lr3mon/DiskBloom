## Summary

<!-- What changed and why? -->

## User-visible behavior

<!-- Describe the interaction before and after this PR. -->

## Privacy and safety

- [ ] No local file metadata is transmitted over the network
- [ ] No permanent-delete path was added
- [ ] Scan-root, filesystem-root, home, system-root, volume-root, and synthetic-node protections remain intact
- [ ] Cloud placeholders are not downloaded for analysis
- [ ] Permission or exclusion changes include regression coverage, or are not applicable

## Performance

<!-- Note main-thread work, scan cost, cache impact, and any measurements. -->

## Verification

- [ ] `swift test`
- [ ] `swift build --product DiskBloom`
- [ ] `swift build --product diskbloom-scan`
- [ ] Packaged app tested when UI/packaging changed
- [ ] No private paths, filenames, or cache snapshots are included

## Screenshots / recordings

<!-- Add sanitized visuals for UI changes. -->
