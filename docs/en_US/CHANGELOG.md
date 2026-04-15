# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.4.0] - 2025-04-15

### Added

- **Single-service multi-user mode**: Replaced per-user service instances (`net-porter@<uid>.service`) with a single global `net-porter.service`. One root process now serves all users, reducing resource overhead and operational complexity.
- **Grant-based ACL model**: New per-resource `acl` field with structured grant entries (`{ "user": "alice" }`, `{ "group": "devops" }`) replaces the flat `allow_users`/`allow_groups` arrays. Grants support optional IP range restrictions for static IP resources.
- **Static IP support**: Added static IPAM type with inline `addresses`, `routes`, and `dns` configuration. User-requested static IPs are validated against their ACL grant's allowed IP ranges — no separate IPAM plugin or config files needed.
- **Inline CNI configuration**: Interface and IPAM settings are now defined directly within each resource definition in `config.json`. The `cni.d/` directory is no longer used; CNI plugin configs are generated dynamically from resource definitions.
- **Per-user socket with inotify dynamic management**: Automatically creates/removes per-user unix sockets at `/run/user/<uid>/net-porter.sock` by watching `/run/user/` via inotify. Each socket has `0600` permissions owned by the user, ensuring OS-level isolation.
- **Top-level `users` config**: New `users` field to explicitly declare which users need a socket entry, replacing the previous implicit derivation from ACL grants.
- **Multi-user container network isolation**: Despite the single-service architecture, each user's container network resources remain strictly isolated — users cannot interfere with or affect each other's containers.
- **Mandatory ACL validation at startup**: Service refuses to start if any resource lacks ACL configuration, preventing resources from being accidentally exposed without access controls.
- **Netns diagnostics in errors**: Network namespace information is now included in connection error messages returned to netavark, aiding troubleshooting.

### Changed

- **Build toolchain upgraded to Zig 0.16.0**: The entire codebase has been migrated to Zig 0.16.0's `std.Io` architecture. Building from source now requires Zig >= 0.16.0.
- **Systemd service simplified**: `net-porter@<uid>.service` template replaced with single `net-porter.service`. The `--uid` CLI argument has been removed.
- **Configuration format redesigned**: See the [Migration Guide (0.3 → 0.4)](migration-guide-0.3-to-0.4.md) for details.

### Removed

- **`domain_socket` config section**: Socket paths are now derived automatically from user UIDs; manual socket configuration is no longer needed.
- **`allow_users` / `allow_groups` fields on resources**: Replaced by the new `acl` grant array.
- **`cni.d/` directory**: CNI configuration files are no longer read from disk. All network settings are defined inline in `config.json`.
- **`net-porter@.service` template**: Replaced by the single `net-porter.service` unit file.
- **`--uid` CLI argument**: No longer needed with the single-service architecture.

---

## [0.3.4] - 2025-01-19

### Fixed

- Fixed net-porter failing to start on kernels that do not support `SO_REUSEPORT`.

## [0.3.3] - 2025-01-17

### Changed

- Default socket owner is now set to the UID of the accepted connection.

## [0.3.2] - 2025-01-15

### Fixed

- Fixed nfpm packaging dependency: changed dependency from `podman-netavark` to `podman` for compatibility with Alivstack packages.

## [0.3.1] - 2025-01-14

### Fixed

- Fixed `std_options` not taking effect due to missing `pub` annotation.

## [0.3.0] - 2025-01-14

### Added

- Runtime customizable log level.
- Additional diagnostic logging.

### Changed

- Refactored CNI logic from `server/` into dedicated `cni/` module.

## [0.2.0] - 2025-01-12

_Initial public release with per-user service architecture._

[0.4.0]: https://github.com/a-light-win/net-porter/compare/0.3.4...0.4.0
[0.3.4]: https://github.com/a-light-win/net-porter/compare/0.3.3...0.3.4
[0.3.3]: https://github.com/a-light-win/net-porter/compare/0.3.2...0.3.3
[0.3.2]: https://github.com/a-light-win/net-porter/compare/0.3.1...0.3.2
[0.3.1]: https://github.com/a-light-win/net-porter/compare/0.3.0...0.3.1
[0.3.0]: https://github.com/a-light-win/net-porter/compare/0.2.0...0.3.0
