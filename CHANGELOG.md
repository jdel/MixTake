# Changelog

## 0.1.0 - 2026-10-27

### Features

- Show elapsed time while recording.

### Fixes

- Preserve session packages and restore a stable state after load failures.
- Treat mixer changes as unexported work after an earlier export.
- Reject session media paths that escape the package.
- Replace existing session packages atomically.
- Avoid ambiguous audio-device name matches.

### Maintenance

- Raise the minimum supported version to macOS 15 and modernize media APIs.
- Add automated regression coverage and repository agent guidelines.
