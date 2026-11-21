# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.5.4] - 2026-11-21

### Fixed

- **Dual-stack (IPv4+IPv6) CNI setup failed with read-only /proc/sys**: containernetworking/plugins >= v1.7.0 (PR #1155) unconditionally writes `net.ipv6.conf.<ifname>.keep_addr_on_down` via `/proc/sys` when configuring an IPv6 address and fails the whole ADD on any write error. The worker unit's `ProtectKernelTunables=true` mounts `/proc/sys` read-only, so every dual-stack CNI ADD failed with `open /proc/sys/net/ipv6/conf/eth0/keep_addr_on_down: read-only file system (code=999)` while IPv4-only setups worked (that sysctl path is never touched for IPv4). The worker unit now opens an exception with `ReadWritePaths=/proc/sys/net`: `net.*` sysctls are per-network-namespace and the worker already holds `CAP_NET_ADMIN`, so this adds no real attack surface.

## [1.5.3] - 2026-07-19

### Fixed

- **Pending UID recovery**: UIDs that appeared in `/run/user/<uid>` while not in the ACL allowed list were silently dropped if their username was not in the `unresolved_usernames` set. This caused workers to never start for newly created system users whose ACL file was created before the user existed (e.g., during automated deployment where `net_porter_acl` role runs before `setup` role creates the user). The server now unconditionally triggers an ACL re-scan when any pending UID is detected, ensuring newly resolvable usernames are picked up regardless of prior scan state.

## [1.5.2] - 2026-07-04

### Fixed

- **Worker not restarted after user recreation**: When a user session ends (e.g., during service undeploy) and the ACL scanner temporarily fails to resolve the username to a UID, the UID was removed from the allowed list. When the user was recreated (e.g., during redeploy), the worker was not restarted because the UID was no longer in the allowed list and no ACL file change triggered a re-scan. The server now tracks usernames that failed to resolve during ACL scanning, and when a `/run/user/<uid>` directory appears for a UID not in the allowed list, performs a reverse lookup (UID → username) and checks against the unresolved list. If matched, an ACL re-scan is triggered, restoring the UID to the allowed list and starting the worker.

### Changed

- **UidTracker reports pending UIDs**: `UidEvents` now includes a `pending` list containing UIDs whose `/run/user/<uid>` directories were created but are not in the allowed list. The server uses this to detect potential ACL users that were temporarily unresolvable.
- **AclScanner tracks unresolved usernames**: A new `scanUidsWithUnresolved()` method returns both resolved UIDs and usernames that could not be resolved to UIDs, enabling the server to retry resolution when the user reappears.
- **handleAclChange now calls scanExisting**: After updating the allowed UID list, existing `/run/user/` directories are re-scanned so that newly-allowed UIDs with active sessions immediately get tracked and their workers started.

[1.5.4]: https://github.com/a-light-win/net-porter/compare/1.5.3...1.5.4
[1.5.3]: https://github.com/a-light-win/net-porter/compare/1.5.2...1.5.3
[1.5.2]: https://github.com/a-light-win/net-porter/compare/1.5.1...1.5.2
