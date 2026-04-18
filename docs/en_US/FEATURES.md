# Feature Status

## Network

- [x] macvlan network for rootless containers
- [x] ipvlan network for rootless containers
- [x] DHCP IP auto-assignment
- [x] Static IP assignment with per-user range restriction
- [x] IPv4 and IPv6 dual-stack

## Access Control

- [x] Per-user network access authorization
- [x] Per-user static IP range restriction
- [x] Reusable grant sets for batch authorization
- [x] Hot-reload ACL without service restart
- [x] User isolation — one user cannot affect another's containers

## CNI

- [x] Standard CNI 1.0 config format (.conf / .conflist)
- [x] Chained plugins (e.g., macvlan + bandwidth + firewall)
- [x] Service restart preserves existing network state

## Service Management

- [x] Single service instance for all users
- [x] Automatic user detection — no per-user setup needed
- [x] deb / rpm / Arch Linux packages

## Planned

- [ ] CNI config hot-reload (currently requires service restart)
- [ ] Configuration dry-run validation
