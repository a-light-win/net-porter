# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2025-04-18

### Security

- **Eliminated `nsenter` privilege escalation risk**: Previous versions used the `nsenter` command to enter container namespaces for CNI plugin execution. A root process executing `nsenter` is a well-known privilege escalation vector — a compromised or malicious namespace could exploit the root context. Workers now run directly in the correct namespace, so CNI plugins execute without `nsenter`.
- **Hardened CNI plugin execution**: CNI plugin directory is bind-mounted read-only inside the worker namespace, preventing binary replacement attacks.
- **Fixed 7 attack surfaces** found in security audit, including path traversal via CNI_NETNS, container name injection, TOCTOU race on domain socket creation, and information leakage in error messages.

### Changed

- **Per-UID worker architecture**: The server now spawns an independent worker process for each user. Workers run in isolated systemd scopes — they survive server crashes and are independently managed. This architecture eliminates the need for the root process to execute commands inside user-controlled namespaces.
- **ACL file format simplified**: The `user` and `group` fields are no longer used for identity — they are silently ignored for backward compatibility. Identity is now determined by the filename: `<username>.json` for users, `@<name>.json` for shared rule collections.
- **New `groups` field in ACL**: User ACL files can reference shared rule collections via the `groups` field. For example, `"groups": ["dhcp-users"]` includes all grants from `@dhcp-users.json`. These are NOT Linux user groups — they are simply reusable grant sets.
- **Group ACL files renamed**: Shared rule collection files now use the `@<name>.json` prefix (e.g., `devops.json` → `@devops.json`) to distinguish them from user ACL files.

### Removed

- **`nsenter` command execution**: No longer used anywhere. Workers are already in the correct namespace.
- **`user` and `group` fields from ACL files**: Replaced by filename-based identity. Existing files with these fields continue to work — the fields are silently ignored.

---

## [0.6.0] - 2025-04-17

### Added

- **Standard CNI configuration directory (`cni.d/`)**: Network resources are now configured using standard CNI 1.0 format files (`.conf` and `.conflist`) in `/etc/net-porter/cni.d/`. Supports single-plugin and chained-plugin configurations. See [CNI Configuration Guide](cni-config.md) for details.
- **File-based attachment persistence**: CNI attachment state is now persisted to disk at `/run/net-porter/{uid}/{container_id}_{ifname}.json`. This enables proper teardown after server restart — previously, a restarted server could not clean up existing CNI attachments.
- **Chained plugin support with `prevResult`**: CNI plugins now properly chain results using the `prevResult` field per CNI 1.0 spec. Each subsequent plugin receives the previous plugin's output, enabling multi-plugin workflows (e.g., macvlan + bandwidth + firewall).
- **CNI config loader validation**: Plugin binaries are validated at load time — the service reports clear errors if a required plugin is missing or not executable.
- **Installer creates `cni.d/` directory**: The package now auto-creates `/etc/net-porter/cni.d/` and installs a standard CNI config example (`00-example.conflist.example`) with DHCP, static IP, and chained plugin usage guides.
- **Config file size limit**: CNI config files are limited to 1 MB to prevent excessive memory usage from malformed or oversized files.
- **New `cni_dir` configuration option**: Allows customizing the CNI config directory path (defaults to `{config_dir}/cni.d`).

### Changed

- **Network configuration moved to `cni.d/` directory**: The `resources` array in `config.json` is no longer used. Each network resource is now a standard CNI config file in `cni.d/`. This is a **breaking change** — see the [Migration Guide (0.5 → 0.6)](migration-guide-0.5-to-0.6.md).
- **CNI config format is now standard CNI 1.0**: The custom `interface` / `ipam` structure has been replaced by standard CNI fields (`type`, `master`, `mode`, `ipam`, etc.) directly in the plugin config. Unknown fields in CNI configs are silently ignored for better compatibility with standard CNI configurations.

### Removed

- **`resources` field from `config.json`**: Network resources are no longer defined inline. Use the `cni.d/` directory instead.

### Fixed

- Added config file size limit (1 MB) to prevent excessive memory usage from malformed files.

### Internal

- Migrated deprecated `std.fs` and `std.os.linux` calls to preferred Zig 0.16.0 APIs.
- Resolved Zig 0.16.0 stdlib API compatibility issues.
- Fixed test memory leaks in CNI module.
- Removed dead `user_sessions` code.

### Migration

See the [Migration Guide (0.5 → 0.6)](migration-guide-0.5-to-0.6.md) for step-by-step upgrade instructions.

---

## [0.5.0] - 2025-04-16

### Added

- **IPvlan network support**: Added ipvlan as a new interface type alongside macvlan. Supports L2, L3, and L3s modes. IPvlan shares the parent interface's MAC address and is useful in environments where MAC address uniqueness cannot be guaranteed.
- **IPv6 support for static IP ranges**: Static IP ACL rules now support IPv6 addresses and ranges (e.g., `2001:db8::1-2001:db8::ff`), enabling dual-stack IPv4/IPv6 configurations.
- **Dual-stack static IP**: Containers can now request both IPv4 and IPv6 static addresses simultaneously. Each address is automatically matched to the correct subnet by address family.
- **Dynamic ACL directory (`acl.d/`)**: Access control rules are now stored as individual JSON files in `/etc/net-porter/acl.d/`. The service watches this directory and applies changes automatically — no restart needed when adding, modifying, or removing ACL files.

### Changed

- **Access control moved to `acl.d/` directory**: ACL rules are no longer defined inside `config.json`. Each user or group has a separate JSON file in `acl.d/`. This makes permission management more modular — add or revoke access by simply adding or removing a file.
- **Stricter interface mode validation**: The `mode` field is now validated per interface type — macvlan modes (`bridge`, `vepa`, `private`, `passthru`) and ipvlan modes (`l2`, `l3`, `l3s`) cannot be mixed. Additionally, ipvlan L3/L3s modes cannot be used with DHCP (use static IP instead).
- **Version shown at startup**: The service now prints its version number at startup.

### Removed

- **`users` field from `config.json`**: The list of users who need sockets is now automatically derived from ACL files.
- **`acl` field from resource definitions**: Access control is no longer defined inline in each resource. Use the `acl.d/` directory instead.

### Migration

See the [Migration Guide (0.4 → 0.5)](migration-guide-0.4-to-0.5.md) for step-by-step upgrade instructions.

---

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

[1.0.0]: https://github.com/a-light-win/net-porter/compare/0.6.0...1.0.0
[0.6.0]: https://github.com/a-light-win/net-porter/compare/0.5.0...0.6.0
[0.5.0]: https://github.com/a-light-win/net-porter/compare/0.4.0...0.5.0
[0.4.0]: https://github.com/a-light-win/net-porter/compare/0.3.4...0.4.0
[0.3.4]: https://github.com/a-light-win/net-porter/compare/0.3.3...0.3.4
[0.3.3]: https://github.com/a-light-win/net-porter/compare/0.3.2...0.3.3
[0.3.2]: https://github.com/a-light-win/net-porter/compare/0.3.1...0.3.2
[0.3.1]: https://github.com/a-light-win/net-porter/compare/0.3.0...0.3.1
[0.3.0]: https://github.com/a-light-win/net-porter/compare/0.2.0...0.3.0
