# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.4.0] - 2026-06-08

### Security

- **Bounded systemctl output allocation**: `WorkerManager` previously allocated unbounded heap for systemctl stdout/stderr. A misbehaving `systemd` could exhaust server memory. All three call sites now share a single helper capped at 64 KiB.
- **Log settings applied immediately at startup**: A window existed between the initial boot log and the late-stage config load where log level was not enforced, allowing security-relevant events to be emitted (or dropped) regardless of configuration. Log settings are now applied as the first action after config becomes available, in both server and worker.
- **Network namespace diagnostics gated behind explicit opt-in**: Worker logs previously emitted diagnostic netns information by default. This output is now produced only when explicitly requested, reducing information disclosure to systemd-journal or stdout.
- **OOM propagation in `getUsername`**: Out-of-memory errors during username resolution were masked as a null result, which could silently skip authorization checks. Errors now propagate correctly to the caller.
- **CNI plugin type validated against whitelist**: Plugin type validation now uses a strict whitelist, preventing use of unexpected plugin types via malformed CNI configurations.
- **Visibility into ACL watcher failures**: `setupInotify()` and inotify read errors were silently swallowed, leaving operators running with stale ACL state and no warning that hot-reload was disabled. Both classes of failure now emit explicit warnings.
- **Safe fallbacks for `unreachable` code paths**: Several CNI accessors and utils helpers previously used `unreachable` for unexpected inputs (e.g. corrupted state files bypassing `init()` validation), which is undefined behavior in release builds. These now return null or a safe fallback to avoid memory corruption.

### Added

- **Graceful shutdown on SIGTERM/SIGINT**: The server now catches SIGTERM and SIGINT and performs a clean shutdown instead of being forcibly killed, improving reliability during system updates and container restarts.

### Fixed

- **CNI double-free in `Cni.deinit`**: The `Cni` struct is allocated inside its arena, but `deinit()` additionally called `allocator.destroy(self)` after `arena.deinit()`, freeing already-released memory. The bug was masked under `page_allocator` but caused invalid-free panics under `DebugAllocator`/`GeneralPurposeAllocator`.
- **CNI plugin execution time bounded**: A hanging CNI plugin binary would block `process.wait` indefinitely. With the default 64 handler slots, 64 stuck plugins exhausted the worker pool and caused denial of service. Plugin execution is now bounded by a 60-second timeout via `pidfd_open` + poll on Linux >= 5.3.
- **Handler drain synchronized during shutdown**: `Worker.deinit()` previously tore down the DHCP service without waiting for in-flight handler threads, racing with handlers that call `dhcp_service.ensureStarted()` / `stop()` mid-request. A `shutting_down` flag and `active_handlers` counter now ensure handlers complete before shared resources are freed.
- **Default `config_dir` used when path derivation fails**: When the configured path had no directory component (e.g. a bare `config.json` on fresh installs), `postInit()` returned `InvalidPath`, aborting startup. The default `/etc/net-porter` is now used as a safe fallback.
- **Pre-allocated monitored file descriptors**: Under high load, file descriptor monitoring could silently lose events when capacity was exceeded. Capacity is now pre-allocated to the maximum up front.
- **Stale file descriptor detection via `POLL.NVAL`**: The poll event mask was missing `POLL.NVAL`, leaving stale file descriptors undetected and causing the worker to spin on closed fds. The mask now includes `NVAL` and invalid fds are properly handled.
- **Arena ownership hardened in `ManagedConfig.load`**: The arena ownership contract is now documented and the `FileNotFound` fallback defers `ManagedConfig` construction until after `postInit()` succeeds, eliminating a fragile dual-tracking window where the arena could be cleaned up twice.
- **CNI teardown partial failure visibility**: Partial failures during CNI teardown were silently dropped, hiding real configuration or permission problems. Errors are now logged with full context.
- **Arena key waste on `put` failure**: Keys inserted into the arena before a failed `workers.put` were not cleaned up, slowly leaking memory under sustained allocation pressure. The insert is now ordered to avoid waste on failure.
- **Oversized path handling in `StateFile.statExists`**: File paths exceeding `PATH_MAX` previously triggered undefined behavior in the underlying syscall. Oversized paths are now rejected with a clear error.

### Internal

- **DebugAllocator enabled in debug builds**: Both server and worker now use `std.heap.DebugAllocator` in `Debug`/`ReleaseSafe` builds, catching leaks and double-frees at runtime. `page_allocator` is still used in `ReleaseFast`/`ReleaseSmall` for performance. The GPA lives in the caller and is passed via `Opts.allocator` so it outlives all sub-objects.
- **Test infrastructure uses cryptographic randomness**: Test helpers in `AclScanner.zig` and `TempFileManager.zig` previously seeded `DefaultPrng` from PID alone, making `/tmp` paths predictable and prone to collision in concurrent CI runs. Replaced with `io.random()` to match production code.
- **Thread-safety contract documented for unlocked worker read methods**: Methods that rely on external locking now carry explicit documentation, preventing accidental misuse from future contributors.
- **Build step checks for `kcov` availability**: The `cover` step now detects whether `kcov` is installed before invoking it, producing a clearer error instead of a confusing build failure.

---

## [1.3.0] - 2026-05-29

### Security

- **Restored network namespace verification**: Re-enabled NSFS-based verification of resolved network namespace paths to prevent mount replacement attacks. This protection was accidentally disabled in a previous update.
- **Fixed ACL authorization bypass on resource errors**: When network resource resolution encountered an error, subsequent operations could proceed without proper authorization checks. Errors are now correctly propagated and access is properly denied.
- **Fixed memory safety issue in ACL directory watcher**: The ACL watcher thread could access freed memory during shutdown, potentially causing crashes or undefined behavior. The thread now performs a clean shutdown via a dedicated signaling pipe.
- **Improved secure random number generation**: Temporary file creation now uses `std.io.random` for seed generation, eliminating the risk of using partially-initialized random data.

### Changed

- **Static IPAM now requires explicit `addresses` field**: When using static IPAM (`"type": "static"`), the `addresses` array must be explicitly specified in the CNI configuration. Previously, missing addresses were silently inferred, which could lead to unexpected network behavior.

### Fixed

- **Fixed service hang on shutdown**: The service could hang indefinitely during shutdown when the ACL directory watcher was active, requiring a forced kill.
- **Fixed worker becoming unresponsive after socket errors**: Fatal socket errors during connection acceptance could leave the worker process in a zombie-like state, unable to accept new connections.
- **Fixed log configuration not taking effect in worker**: Log level settings from the configuration file were not applied to worker processes — workers always used the default log level regardless of configuration.
- **Fixed DHCP service misdetecting static IP configurations**: The DHCP start/stop logic incorrectly used ACL IP ranges instead of the CNI config's IPAM type to determine whether a resource uses static IP, potentially causing DHCP to be started or stopped unnecessarily.
- **Fixed potential crash on malformed CNI configuration**: Empty or malformed plugin arrays in CNI configuration files could cause the service to panic and crash.
- **Fixed multiple integer overflow issues**: Several timestamp calculations and event loop counters could overflow on long-running or heavily loaded systems, causing incorrect behavior or crashes.
- **Fixed resource leaks in CNI plugin setup**: File descriptors were leaked when setting up CNI plugin directories, and memory was leaked during CNI attachment state serialization.
- **Fixed memory leak in ACL manager**: Out-of-memory conditions during ACL manager initialization were not properly handled, leaking previously allocated resources.
- **Fixed connection hang from error handling gap**: Certain request processing errors were silently swallowed, causing client connections to hang indefinitely without a response.
- **Fixed heap corruption when spawning workers**: A double-free bug during worker process spawning could corrupt the heap and cause unpredictable crashes.
- **Fixed deadlock during shutdown under load**: The shutdown signal could deadlock if the system call was interrupted by a signal, preventing clean service shutdown.
- **Fixed DHCP mutex state corruption**: The DHCP service mutex could be unlocked without being locked first during cleanup, causing undefined behavior.
- **Fixed multiple reliability issues in worker management**: Worker lifecycle management had edge cases causing out-of-bounds access, memory leaks, and incorrect worker death detection.

### Internal

- Added unit tests for CNI static IPAM type detection.
- Replaced non-standard API calls to comply with project coding standards.
- Added build-id to the executable for easier debugging.
- Removed dead code and improved error propagation in internal modules.

---

## [1.2.0] - 2026-05-27

### Security

- **Fixed 6 security issues** covering verification bypass, path traversal, process spoofing, UID reuse, and input validation:
  - NSFS verification now uses `statfs` instead of a hardcoded device number, preventing verification bypass on systems with different device numbers.
  - Added strict username validation (`a-zA-Z0-9_-`) to prevent path traversal via malicious NSS/LDAP entries returning crafted usernames.
  - Improved catatonit process verification to resist PID recycling and process name spoofing attacks.
  - Added UID reuse detection: when a user account is deleted and recreated with the same UID but a different username, the old worker is stopped to prevent ACL inheritance.
  - Fixed integer underflow in IPv6 address parsing.
  - Added validation for random seed generation to prevent use of uninitialized values.

### Added

- **Dynamic ACL management**: The service now watches the `acl.d/` directory in real-time. Adding, modifying, or removing ACL files automatically starts or stops the corresponding workers — no manual intervention needed. Previously, ACL changes required a service restart to take effect.

### Fixed

- Fixed potential out-of-bounds read when processing file system events that could cause crashes.
- Fixed service panic when more than 8 users or ACL events were processed simultaneously.
- Fixed several memory leaks in the ACL watcher.
- Fixed incorrect error detection for certain system calls, which could cause operations to fail silently or report wrong errors.
- Fixed transient I/O errors during user scanning causing all workers to be stopped.
- Fixed event ordering: ACL changes are now processed before user login events, ensuring new users are recognized before their socket events arrive.
- Improved ACL watcher efficiency by skipping non-user files (group rule collections and hidden dotfiles).

### Internal

- Added test coverage for UID reuse detection.
- Code formatting cleanup.

---

## [1.1.0] - 2026-04-22

### Security

- **Fixed 9 security vulnerabilities** covering path traversal, TOCTOU race conditions, information leakage, and thread safety:
  - Prevented symlink TOCTOU privilege escalation in unix socket creation.
  - Prevented ACL IP restriction bypass via duplicate resource names.
  - Added CNI identifier validation for `net_porter_resource` to prevent injection.
  - Added path traversal validation for plugin type in CNI config loader.
  - Added path traversal validation for group name in ACL loading.
  - Heap-allocated handler to prevent thread data race.
  - Used `getrandom` + `O_EXCL` for secure temporary state file creation.
  - Set umask before state directory creation to restrict permissions.
  - Avoided leaking CNI plugin details (paths, types) to clients in error messages.

### Added

- **Simplified plugin parameter names**: `net_porter_socket` → `socket`, `net_porter_resource` → `resource`. Old parameter names still work but print a deprecation warning.

### Changed

- **`socket` is now a required parameter**: Rootless podman invokes netavark plugins inside a user namespace where `getuid()` returns the mapped UID (0), making automatic socket path detection unreliable. The `socket` path must now be explicitly specified in `podman network create`.

- **CNI module architecture reorganized**: The monolithic `Cni.zig` (1500+ lines) has been split into four focused modules — `Cni`, `CniConfig`, `PluginConf`, and `Attachment` — for better maintainability.
- **Module layout restructured**: Moved `Acl`/`AclFile` to `acl/`, `ManagedType` and `Responser` to `common/`, and shared inotify constants to `utils/Inotify.zig`.

### Fixed

- Fixed use-after-free in CNI `deserializeState` caused by premature `parsed.deinit()`.
- Fixed memory leak of `env_map` in CNI setup and teardown paths.
- Fixed DHCP daemon process not closing stdin/stdout/stderr.
- Fixed stale process reference in DHCP `isAlive` after reaping child process.
- Fixed missing mutex protection for `group_names` in inotify event processing.
- Fixed OOM in `workers.put` not closing pid file descriptors.
- Fixed OOM returning unresolved netns path instead of explicit error.
- Fixed reversed IP ranges (e.g. `10.0.0.10-10.0.0.1`) being silently accepted in `parseIpRange`.
- Fixed ACL initial load errors being silently swallowed instead of logged.
- Fixed rejected IP not included in error log and incorrect log scope.
- Reduced CNI identifier max length from 256 to 128 for consistency.

### Internal

- Merged `setDefaultAclDir`/`setDefaultCniDir` into generic `setDefaultSubDir`.
- Removed redundant `discoverCatatonitPid`, consolidated to `discoverAllCatatonitPids`.
- Removed trivial `Worker.pageAllocator()` wrapper, using `std.heap.page_allocator` directly.
- Removed unused `json.zig`, inlined its single call in `main`.
- Merged identical catatonit/worker branches in `processPollEvents`.
- Extracted `getIpamType`/`getIpamObject` helpers to deduplicate `PluginConf` methods.
- Removed duplicate `shadowCopyObjectMap`, reusing `PluginConf.shadowCopy`.
- Removed empty `AclScanner.deinit` and its call sites.
- Made test step depend on compilation to catch build errors early.

---

## [1.0.0] - 2026-04-19

### Security

- **Eliminated privilege escalation risk from namespace entry**: Previous versions ran CNI plugins inside container namespaces as root — a well-known attack vector. This is no longer the case. The root process now never enters any user-controlled namespace.
- **Hardened process isolation**: The server and per-user workers now run under strict systemd security restrictions — each worker has its own isolated service unit with read-only filesystem, minimal Linux capabilities, and syscall filtering. Even if a worker is compromised, the blast radius is severely limited.
- **Fixed 7 security vulnerabilities** found in audit, including path traversal, container name injection, race conditions on socket creation, and information leakage in error messages.
- **Multi-IP static IP validation**: When a container requests multiple static IPs, all of them are now validated against the user's allowed IP ranges (previously only the first IP was checked).
- **Worker internal data protected**: Worker state files are now stored in a root-only directory, preventing regular users from accessing or tampering with them.

### Added

- **Independent per-user worker processes**: The server now spawns a separate worker process for each user. Workers are fully independent — if the server crashes, all workers keep running and serving their users. When the server restarts, it reconnects to existing workers without disruption.
- **Automatic worker restart after package upgrade**: When you upgrade the net-porter package, the server detects that workers are running the old binary and automatically restarts them with the new version.
- **Automatic worker recovery**: If a worker's associated podman infrastructure container restarts, the server detects this and automatically restarts the worker to reconnect.

### Changed

- **ACL identity now based on filename**: The `user` and `group` fields inside ACL files are no longer used — they are silently ignored for backward compatibility. Identity is now determined solely by the filename: `<username>.json` for users, `@<name>.json` for shared rule collections.
- **New `groups` field in ACL**: User ACL files can reference shared rule collections via the `groups` field. For example, `"groups": ["dhcp-users"]` includes all grants from `@dhcp-users.json`. These are NOT Linux user groups — they are simply reusable grant sets.
- **Rule collection files renamed**: Shared rule collection files now use the `@<name>.json` prefix (e.g., `devops.json` → `@devops.json`) to distinguish them from user ACL files.

### Removed

- **`user` and `group` fields from ACL files**: Replaced by filename-based identity. Existing files with these fields continue to work — the fields are silently ignored.
- **`nsenter` dependency**: The `nsenter` command is no longer used or required.
- **`dumpEnv` configuration option**: Removed to reduce attack surface.

### Migration

See the [Migration Guide (0.6 → 1.0)](migration-guide-0.6-to-1.0.md) for step-by-step upgrade instructions.

---

## [0.6.0] - 2026-04-17

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

## [0.5.0] - 2026-04-16

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

## [0.4.0] - 2026-04-15

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

[1.4.0]: https://github.com/a-light-win/net-porter/compare/1.3.0...1.4.0
[1.3.0]: https://github.com/a-light-win/net-porter/compare/1.2.0...1.3.0
[1.2.0]: https://github.com/a-light-win/net-porter/compare/1.1.0...1.2.0
[1.1.0]: https://github.com/a-light-win/net-porter/compare/1.0.0...1.1.0
[1.0.0]: https://github.com/a-light-win/net-porter/compare/0.6.0...1.0.0
[0.6.0]: https://github.com/a-light-win/net-porter/compare/0.5.0...0.6.0
[0.5.0]: https://github.com/a-light-win/net-porter/compare/0.4.0...0.5.0
[0.4.0]: https://github.com/a-light-win/net-porter/compare/0.3.4...0.4.0
[0.3.4]: https://github.com/a-light-win/net-porter/compare/0.3.3...0.3.4
[0.3.3]: https://github.com/a-light-win/net-porter/compare/0.3.2...0.3.3
[0.3.2]: https://github.com/a-light-win/net-porter/compare/0.3.1...0.3.2
[0.3.1]: https://github.com/a-light-win/net-porter/compare/0.3.0...0.3.1
[0.3.0]: https://github.com/a-light-win/net-porter/compare/0.2.0...0.3.0
