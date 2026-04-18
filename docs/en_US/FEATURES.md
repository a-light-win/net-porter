# Feature Status

## Core Architecture

- [x] Single global service (replaces per-user service instances)
- [x] Per-UID worker processes (systemd-run --scope, crash isolated)
- [x] Worker lifecycle management (spawn/stop/restart via pidfd)
- [x] Dynamic socket management via inotify monitoring /run/user/
- [x] Worker namespace isolation (setns + unshare + rslave)

## Network Support

- [x] macvlan network (bridge/vepa/private/passthru modes)
- [x] ipvlan network (L2/L3/L3s modes)
- [x] DHCP IPAM
- [x] Static IPAM with per-user IP range validation
- [x] IPv4 support
- [x] IPv6 support (static IP ranges)
- [x] Dual-stack static IP (IPv4 + IPv6 simultaneously)

## CNI Integration

- [x] Standard CNI 1.0 config format (.conf / .conflist)
- [x] CNI config directory (cni.d/)
- [x] Chained plugin support with prevResult
- [x] CNI plugin binary validation at load time
- [x] Attachment state persistence to disk
- [x] CNI config file size limit (1 MB)

## Access Control (ACL)

- [x] File-based ACL (acl.d/ directory)
- [x] Filename-based identity (<username>.json)
- [x] Shared rule collections (@<name>.json)
- [x] ACL hot-reload via inotify (no restart needed)
- [x] Per-resource grant model
- [x] Optional IP range constraints on grants
- [x] Two-phase atomic ACL reload (no downtime)

## DHCP Service

- [x] Per-user DHCP daemon (lazy start, auto-restart)
- [x] DHCP daemon lifecycle tied to user containers
- [x] DHCP socket in user namespace

## Security

- [x] SO_PEERCRED kernel-level identity authentication
- [x] Per-user socket isolation (0600 permissions)
- [x] nsenter eliminated (no privilege escalation vector)
- [x] CNI plugin directory read-only bind-mount in worker
- [x] CNI_NETNS path validation (prevent path traversal)
- [x] Container name validation (prevent injection)
- [x] Domain socket TOCTOU race fix (fd-based operations)
- [x] Generic error messages (prevent information leakage)
- [x] Default deny policy
- [x] Concurrent connection limiting

## Netavark Plugin

- [x] create (podman network create)
- [x] setup (container start)
- [x] teardown (container stop)
- [x] info (plugin metadata)

## Packaging & Deployment

- [x] deb package
- [x] rpm package
- [x] Arch Linux package
- [x] systemd service unit (hardened)
- [x] Containerized build (podman + just)
- [x] Local build (zig + nfpm)

## Planned / Not Yet Implemented

- [ ] CNI config hot-reload (currently requires restart)
- [ ] API versioning / backward compatibility contract
- [ ] Metrics / monitoring endpoint
- [ ] Configuration validation CLI (dry-run)
