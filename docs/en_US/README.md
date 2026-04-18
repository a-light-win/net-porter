# net-porter

`net-porter` is a [netavark](https://github.com/containers/netavark) plugin
to provide macvlan/ipvlan network to rootless podman container.

It consists with two major part:

- `net-porter plugin`: the `netavark` plugin that called by `netavark`
  inside the rootless environment.
- `net-porter server`: the rootful server that responsible for creating
  the macvlan/ipvlan network via CNI plugins.

The `net-porter server` runs as a single global systemd service. It scans the ACL directory (`acl.d/`) to resolve allowed usernames to UIDs, and monitors `/run/user/` via inotify for UID directory appearances/disappearances. For each allowed UID, the server spawns a dedicated **worker** process (via `systemd-run --scope`) that creates its own per-user socket at `/run/user/<uid>/net-porter.sock`.

When a container starts, netavark will call the `net-porter plugin`. The plugin connects to the worker's per-user socket and passes the required information. The worker authenticates the request by the `uid/gid` of the caller (obtained via kernel `SO_PEERCRED`, cannot be forged), validates ACL grants, and creates the macvlan/ipvlan network if the user has the permission.

> **Why per-user sockets in `/run/user/<uid>/`?** Rootless podman runs in an isolated mount namespace and a separate network namespace (via pasta/slirp4netns). Neither filesystem sockets in `/run/` nor abstract sockets are visible across these boundaries. However, `/run/user/<uid>/` is a per-user tmpfs created by `systemd-logind` that is bind-mounted into the user namespace, making it accessible from both host and rootless podman.

### Architecture Overview

```
┌──────────────────────────────────────────────────────────────┐
│                    net-porter.service (root)                  │
│                                                              │
│  Server                                                      │
│  ├── AclManager: scan acl.d/ → resolve usernames to UIDs    │
│  ├── UidTracker: monitor /run/user/ via inotify              │
│  └── WorkerManager: spawn/stop/restart per-UID workers       │
│                                                              │
│  For each allowed UID, spawns a worker via systemd-run:      │
│                                                              │
│  ┌──────────────── Worker (per-UID, independent scope) ────┐ │
│  │  1. Create socket at /run/user/<uid>/net-porter.sock    │ │
│  │  2. Enter container mount namespace (setns + unshare)    │ │
│  │  3. Bind-mount CNI plugin dir read-only (security)       │ │
│  │  4. Accept connections → spawn handler threads           │ │
│  │  5. Load ACL grants + hot-reload via inotify             │ │
│  │  6. Execute CNI plugins in the correct namespace         │ │
│  └──────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────┘
```

Workers run in independent systemd scopes and survive server crashes. The server only manages their lifecycle (spawn/stop/restart) but does NOT kill workers on its own shutdown.

## Features

- **Dynamic Socket Management**: Automatically creates/removes per-user sockets via inotify when users log in/out
- **Single Service Architecture**: One global root service for all users, no need to manage per-user services
- **Per-UID Worker Processes**: Each user gets an independent worker process (crash isolation, independent namespace)
- **Grant-based ACL Control**: Per-resource grants with optional static IP range restrictions
- **ACL Rule Collections**: User ACLs can reference shared rule collections (`@<name>.json`), grants are merged automatically
- **Static IP Support**: Validate user-requested static IPs against allowed ranges — no separate CNI config files needed
- **Standard CNI Config**: Support standard CNI 1.0 format config files via `cni.d/` directory, including chained plugins (see [CNI Configuration Guide](cni-config.md))
- **Security Hardened**: Kernel level identity authentication, netns ownership verification, default deny policy
- **DHCP Support**: Automatically manage per-user DHCP service instances
- **Zero Trust**: All requests must pass multi-level validation before execution

## Installation

The `net-porter` can only running on the linux system.

### Prerequisites
- Linux kernel >= 5.4
- Podman >= 4.0
- CNI plugins installed (usually at `/usr/lib/cni` or `/opt/cni/bin`)

### Install with pre-built packages
We provide deb, rpm, and archlinux packages on the [release page](https://github.com/a-light-win/net-porter/releases).

#### Install with deb package
```bash
apt install -f /path/to/net-porter.deb
```

#### Install with rpm package
```bash
rpm -i /path/to/net-porter.rpm
```

#### Install with archlinux package
```bash
pacman -U /path/to/net-porter.pkg.tar.zst
```

### Build from source
If you want to build and package `net-porter` from source,
you have two options:

#### Option 1: Containerized build (recommended)
This method uses podman to run all build steps inside a consistent container environment, no need to install dependencies locally:

**Dependencies required:**
- [git](https://git-scm.com/)
- [just](https://github.com/casey/just) (task runner)
- [podman](https://github.com/containers/podman) (container runtime)

Build all packages:
```bash
just pack-all
```
Packages will be output to `zig-out/` directory.

#### Option 2: Local build
If you want to build directly on your host:

**Dependencies required:**
- [Zig](https://ziglang.org/) 0.16.0 (compiler)
- [nfpm](https://nfpm.goreleaser.com/) >= 2.30 (packaging tool, required only for building packages)
- git
- just

##### 1. Compile binary only
```bash
# Compile debug binary
zig build

# Compile optimized release binary
zig build -Doptimize=ReleaseSafe

# Output binary will be at: zig-out/bin/net-porter
```

Build for specific architecture:
```bash
# Build for x86_64
zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-musl

# Build for aarch64
zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-linux-musl
```

##### 2. Run tests
```bash
zig build test
```

##### 3. Build packages
```bash
# Build deb package
just pack-deb

# Build rpm package
just pack-rpm

# Build archlinux package
just pack-arch
```

All packages will be placed in `zig-out/` directory.

#### Build options
| Option | Description | Default |
|--------|-------------|---------|
| `-Doptimize=Debug` | Unoptimized build with debug symbols | ✓ |
| `-Doptimize=ReleaseSafe` | Optimized build with runtime safety checks | Recommended for production |
| `-Doptimize=ReleaseFast` | Maximum optimized build without runtime safety checks | |
| `-Dtarget=<triplet>` | Cross compile to target architecture | Native host |
| `-Dstrip=true` | Strip debug symbols from binary | `false` |

## Project Structure
```
net-porter/
├── src/
│   ├── main.zig                  # Program entry point & CLI dispatch
│   ├── server.zig                # Server module (CLI: `net-porter server`)
│   ├── server/
│   │   ├── Server.zig            # Server core — ACL scanner + worker lifecycle
│   │   ├── UidTracker.zig         # /run/user/ monitor (inotify), reports UID events
│   │   ├── AclManager.zig        # Server-side ACL scanner (username → UID resolution)
│   │   ├── AclFile.zig           # ACL file format (Grant, Entry, groups)
│   │   └── Acl.zig               # ACL validation & IP range matching
│   ├── worker.zig                # Worker module (CLI: `net-porter worker`)
│   ├── worker/
│   │   ├── Worker.zig            # Per-UID worker daemon (runs in container mount ns)
│   │   ├── WorkerManager.zig     # Worker lifecycle manager (spawn/stop/restart via pidfd)
│   │   ├── Handler.zig           # Request handler (per-connection, threaded)
│   │   └── AclManager.zig        # Worker-side ACL loader + hot-reload (inotify)
│   ├── cni.zig                   # CNI module re-exports
│   ├── cni/
│   │   ├── Cni.zig               # CNI execution logic
│   │   ├── CniManager.zig        # CNI config management
│   │   ├── CniLoader.zig         # CNI config file loader & validation
│   │   ├── StateFile.zig         # CNI attachment state persistence
│   │   ├── DhcpService.zig       # Per-user DHCP service
│   │   └── DhcpManager.zig       # DHCP service manager
│   ├── config.zig                # Config module re-exports
│   ├── config/
│   │   ├── Config.zig            # Server config struct
│   │   ├── ManagedConfig.zig     # Config file loader
│   │   └── DomainSocket.zig      # Socket path helpers
│   ├── plugin.zig                # Plugin module (CLI: create/setup/teardown/info)
│   ├── plugin/
│   │   ├── NetavarkPlugin.zig    # Netavark plugin protocol implementation
│   │   └── Responser.zig         # Response builder helpers
│   ├── user.zig                  # UID/GID/username resolution (libc wrappers)
│   ├── json.zig                  # JSON utilities (parse, stringify)
│   ├── utils.zig                 # Utils module re-exports
│   ├── utils/
│   │   ├── ArenaAllocator.zig    # Arena-based allocator for per-request handling
│   │   ├── ErrorMessage.zig      # Structured error output
│   │   ├── Logger.zig            # Custom logger with runtime level control
│   │   └── LogSettings.zig       # Log configuration
│   └── test_utils/
│       └── TempFileManager.zig   # Test helper for temporary files
├── misc/
│   ├── systemd/                  # Systemd service files
│   └── nfpm/                     # nfpm packaging configuration
├── build.zig                     # Zig build configuration
└── justfile                      # Just task definitions
```

## Quick Start

### 1. Start service
After installation, enable and start the global service:
```bash
systemctl enable --now net-porter
```

Check service status:
```bash
systemctl status net-porter
```

### 2. Configure network resource

Create CNI config files in `/etc/net-porter/cni.d/` (supports standard CNI 1.0 format, see [CNI Configuration Guide](cni-config.md)):

`/etc/net-porter/cni.d/10-macvlan-dhcp.conflist`:
```json
{
  "cniVersion": "1.0.0",
  "name": "macvlan-dhcp",
  "plugins": [
    {
      "type": "macvlan",
      "master": "eth0",
      "ipam": { "type": "dhcp" }
    }
  ]
}
```

Replace `eth0` with your host physical interface. Restart service after modifying configuration:
```bash
systemctl restart net-porter
```

### 3. Configure access control
Create an ACL file in `/etc/net-porter/acl.d/` for each user that should have access:

```bash
mkdir -p /etc/net-porter/acl.d
```

`/etc/net-porter/acl.d/alice.json`:
```json
{
  "grants": [
    { "resource": "macvlan-dhcp" }
  ]
}
```

> ACL files are watched for changes. Adding, modifying, or deleting files takes effect automatically — no restart needed. The filename determines the user: `alice.json` → user `alice`.

### 4. Create podman network
Run this command as the rootless user (e.g., `alice`):
```bash
podman network create \
  -d net-porter \
  -o net_porter_resource=macvlan-dhcp \
  -o net_porter_socket=/run/user/$(id -u)/net-porter.sock \
  macvlan-net
```

### 4. Test it out
Run this command as the rootless user (e.g., `alice`):
```bash
podman run -it --rm --network macvlan-net alpine ip addr
```
You should see the macvlan interface with an IP address from your DHCP server.

## Configuration Guide

### Server Configuration (`/etc/net-porter/config.json`)
```json
{
  "cni_plugin_dir": "/usr/lib/cni",
  "log": {
    "level": "info",
    "dump_env": {
      "enabled": false,
      "path": "/tmp/net-porter-dump"
    }
  }
}
```

CNI network configuration is managed through the `/etc/net-porter/cni.d/` directory. See [CNI Configuration Guide](cni-config.md) for details.

Access control is configured separately in the `/etc/net-porter/acl.d/` directory — see [ACL Configuration](#acl-configuration) below.

### ACL Configuration

Access control is managed through individual JSON files in the `/etc/net-porter/acl.d/` directory. The service watches this directory and applies changes automatically — no restart needed.

#### ACL file naming convention

- **User ACL**: `acl.d/<username>.json` — grants + optional `groups` references
- **Rule Collection**: `acl.d/@<name>.json` — shared grant sets that users can include

The username is derived from the filename (without `.json` suffix). The `user` and `group` fields from older versions are silently ignored for backward compatibility.

> **Note**: The `@<name>.json` files are **not** Linux user groups. They are simply named rule collections — reusable grant sets that any user ACL can reference via the `groups` field. The name after `@` is an arbitrary label, not a group name from `/etc/group`.

#### User ACL file format

`/etc/net-porter/acl.d/alice.json`:
```json
{
  "grants": [
    { "resource": "macvlan-dhcp" },
    { "resource": "static-net", "ips": ["192.168.1.10-192.168.1.20"] }
  ],
  "groups": ["dhcp-users"]
}
```

#### Rule collection file format

`/etc/net-porter/acl.d/@devops.json`:
```json
{
  "grants": [
    { "resource": "vlan-200" }
  ]
}
```

Effective permissions = user grants ∪ all grants from referenced rule collections.

#### ACL file fields

| Field | Description | Required |
|-------|-------------|----------|
| `grants` | Array of resource grants | ✅ |
| `grants[].resource` | Resource name (must match a CNI config `name` in `cni.d/`) | ✅ |
| `grants[].ips` | Array of allowed IP ranges or single IPs (for static IPAM resources) | static: ✅ |
| `groups` | Array of rule collection names to include (references `@<name>.json` files) | ❌ |

#### IP range formats

- Single IPv4: `"192.168.1.30"`
- IPv4 range: `"192.168.1.10-192.168.1.20"`
- Single IPv6: `"2001:db8::1"`
- IPv6 range: `"2001:db8::1-2001:db8::ff"`

When IPAM type is `static`, the caller must request a specific IP (via podman `--ip` or netavark static_ips option), and net-porter validates it against the user's allowed ranges.

> 💡 **Tip**: The username is determined by the filename (e.g., `alice.json` → user `alice`). Rule collections start with `@` (e.g., `@devops.json` → collection named `devops`). Multiple users can reference the same collection — grants are merged automatically.

### Top-level Options

| Option | Description | Default |
|--------|-------------|---------|
| `cni_plugin_dir` | Directory containing CNI plugin binaries | auto-detected (`/usr/lib/cni` or `/opt/cni/bin`) |
| `cni_dir` | Directory containing standard CNI config files | `{config_dir}/cni.d` |
| `acl_dir` | Directory containing ACL files | `{config_dir}/acl.d` |
| `log.level` | Log level: `debug`, `info`, `warn`, `error` | `info` |
| `log.dump_env` | Environment dump for debugging | disabled |

## Usage Examples

### Example 1: Multiple users with different networks

`/etc/net-porter/cni.d/10-vlan-100.conflist`:
```json
{
  "cniVersion": "1.0.0",
  "name": "vlan-100",
  "plugins": [
    { "type": "macvlan", "master": "eth0.100", "ipam": { "type": "dhcp" } }
  ]
}
```

`/etc/net-porter/cni.d/20-vlan-200.conflist`:
```json
{
  "cniVersion": "1.0.0",
  "name": "vlan-200",
  "plugins": [
    { "type": "macvlan", "master": "eth0.200", "ipam": { "type": "dhcp" } }
  ]
}
```

`/etc/net-porter/acl.d/alice.json`:
```json
{
  "grants": [
    { "resource": "vlan-100" }
  ]
}
```

`/etc/net-porter/acl.d/bob.json`:
```json
{
  "grants": [
    { "resource": "vlan-100" }
  ]
}
```

`/etc/net-porter/acl.d/@devops.json`:
```json
{
  "grants": [
    { "resource": "vlan-200" }
  ]
}
```
- `alice` and `bob` can use the `vlan-100` network
- Any user who references the `@devops` rule collection in their `groups` field can use the `vlan-200` network. For example, to grant `charlie` access:
  `/etc/net-porter/acl.d/charlie.json`:
  ```json
  {
    "grants": [],
    "groups": ["devops"]
  }
  ```

User alice creates network:
```bash
podman network create -d net-porter -o net_porter_resource=vlan-100 vlan100
```

### Example 2: Static IP with per-user ranges

`/etc/net-porter/cni.d/10-static-net.conflist`:
```json
{
  "cniVersion": "1.0.0",
  "name": "static-net",
  "plugins": [
    {
      "type": "macvlan",
      "master": "eth0",
      "ipam": {
        "type": "static",
        "addresses": [
          { "address": "192.168.1.0/24", "gateway": "192.168.1.1" }
        ],
        "routes": [{ "dst": "0.0.0.0/0" }]
      }
    }
  ]
}
```

`/etc/net-porter/acl.d/alice.json`:
```json
{
  "grants": [
    { "resource": "static-net", "ips": ["192.168.1.10-192.168.1.20"] }
  ]
}
```

`/etc/net-porter/acl.d/bob.json`:
```json
{
  "grants": [
    { "resource": "static-net", "ips": ["192.168.1.30-192.168.1.40"] }
  ]
}
```
- `alice` can request any IP in `192.168.1.10` – `192.168.1.20`
- `bob` can request any IP in `192.168.1.30` – `192.168.1.40`
- Requests with IPs outside the user's range are rejected

Run a container with a specific static IP:
```bash
podman run -it --rm --network static-net --ip 192.168.1.15 alpine ip addr
```

### Example 3: IPvLAN with L3 mode

`/etc/net-porter/cni.d/10-ipvlan-l3.conflist`:
```json
{
  "cniVersion": "1.0.0",
  "name": "ipvlan-l3",
  "plugins": [
    {
      "type": "ipvlan",
      "master": "eth0",
      "mode": "l3",
      "ipam": {
        "type": "static",
        "addresses": [
          { "address": "10.0.0.0/24", "gateway": "10.0.0.1" }
        ]
      }
    }
  ]
}
```

`/etc/net-porter/acl.d/alice.json`:
```json
{
  "grants": [
    { "resource": "ipvlan-l3", "ips": ["10.0.0.10-10.0.0.20"] }
  ]
}
```
- `alice` can use the `ipvlan-l3` network with ipvlan L3 mode
- IPvLAN shares the parent interface's MAC address (no separate MAC per container)
- Note: ipvlan L3/L3s modes require static IPAM (DHCP is not supported)

### Example 4: IPvLAN L2 with DHCP

`/etc/net-porter/cni.d/10-ipvlan-dhcp.conflist`:
```json
{
  "cniVersion": "1.0.0",
  "name": "ipvlan-dhcp",
  "plugins": [
    {
      "type": "ipvlan",
      "master": "eth0",
      "mode": "l2",
      "mtu": 9000,
      "ipam": { "type": "dhcp" }
    }
  ]
}
```

`/etc/net-porter/acl.d/alice.json`:
```json
{
  "grants": [
    { "resource": "ipvlan-dhcp" }
  ]
}
```

### Example 5: Mixed macvlan and ipvlan

`/etc/net-porter/cni.d/10-macvlan-dhcp.conflist`:
```json
{
  "cniVersion": "1.0.0",
  "name": "macvlan-dhcp",
  "plugins": [
    { "type": "macvlan", "master": "eth0", "ipam": { "type": "dhcp" } }
  ]
}
```

`/etc/net-porter/cni.d/20-macvlan-static.conflist`:
```json
{
  "cniVersion": "1.0.0",
  "name": "macvlan-static",
  "plugins": [
    {
      "type": "macvlan",
      "master": "eth0",
      "mode": "bridge",
      "mtu": 9000,
      "ipam": {
        "type": "static",
        "addresses": [
          { "address": "10.0.0.0/24", "gateway": "10.0.0.1" }
        ],
        "routes": [{ "dst": "0.0.0.0/0" }]
      }
    }
  ]
}
```

`/etc/net-porter/acl.d/alice.json`:
```json
{
  "grants": [
    { "resource": "macvlan-dhcp" },
    { "resource": "macvlan-static", "ips": ["10.0.0.5-10.0.0.10"] }
  ]
}
```

## Upgrade from v0.6

Version 1.0.0 introduces a per-UID worker architecture. The server now spawns independent worker processes for each allowed user instead of handling connections directly. The ACL file format has also changed — the `user`/`group` fields are replaced by filename-based identity (`<username>.json` for users), and a new `groups` field enables referencing shared rule collections (`@<name>.json`).

Quick steps:

1. Update ACL file format — remove `user`/`group` fields (they are silently ignored for backward compatibility):
   ```json
   {
     "grants": [
       { "resource": "macvlan-dhcp" }
     ],
     "groups": ["dhcp-users"]
   }
   ```
2. Rename rule collection files to `@<name>.json` (e.g., `devops.json` → `@devops.json`)
3. Restart the service:
   ```bash
   systemctl restart net-porter
   ```

## Upgrade from v0.5

Version 0.6.0 moves network resource configuration from the inline `resources` array to standard CNI 1.0 files in the `cni.d/` directory. See the [Migration Guide (0.5 → 0.6)](migration-guide-0.5-to-0.6.md) for detailed instructions.

Quick steps:

1. Create CNI config files in `cni.d/` from your existing `resources` (see [CNI Configuration Guide](cni-config.md)):
   ```bash
   mkdir -p /etc/net-porter/cni.d
   ```
2. Remove the `resources` field from `/etc/net-porter/config.json`
3. Restart the service:
   ```bash
   systemctl restart net-porter
   ```

## Upgrade from v0.4

See the [Migration Guide (0.4 → 0.5)](migration-guide-0.4-to-0.5.md) for upgrading from v0.4. Then follow the v0.5 → 0.6 migration above.

## Upgrade from v0.3 or earlier

See the [Migration Guide (0.3 → 0.4)](migration-guide-0.3-to-0.4.md) for upgrading from v0.3 or earlier. Then follow the v0.4 → 0.5 and v0.5 → 0.6 migrations in order.

## Troubleshooting

### Common issues

#### 1. Permission denied when connecting to socket
**Error**: `Access denied for uid=1000`
**Solutions**:
- Check if the user has an ACL file in `/etc/net-porter/acl.d/` granting access to the requested resource
- Verify the ACL grants in the user's ACL file

#### 2. Plugin cannot connect to server
**Error**: `Failed to connect to domain socket /run/user/1000/net-porter.sock: ConnectionRefused`
**Solutions**:
- Verify the server is running: `systemctl status net-porter`
- Verify the per-user socket exists: `ls -la /run/user/$(id -u)/net-porter.sock`
- Check your uid is in an ACL grant

#### 3. DHCP failed to get IP
**Error**: `dhcp client: no ack received`
**Solutions**:
- Verify DHCP server is running on your network
- Check if the master interface is connected to the correct network
- Ensure macvlan mode is supported by your network switch

#### 4. Static IP rejected
**Error**: `Static IP x.x.x.x not allowed for user`
**Solutions**:
- Check the user's `ips` range in the ACL grant
- Ensure the requested IP falls within the allowed range
- Verify the IP format (single IP or range in `start-end` format)

#### 5. Resource not found
**Error**: `Resource 'xxx' not found in config`
**Solutions**:
- Check if a CNI config file for this network exists in `/etc/net-porter/cni.d/`
- Ensure the `name` field matches what you pass via `net_porter_resource`
- Confirm the file suffix is `.conf` or `.conflist`
- Restart the service after modifying configuration

### Logs
Check service logs:
```bash
journalctl -u net-porter -f
```

Enable debug logging:
Edit `/etc/net-porter/config.json`:
```json
"log": {
  "level": "debug"
}
```
Restart service: `systemctl restart net-porter`

## Security

### Security Model
1. **Server-Worker Isolation**: Workers run in independent systemd scopes — they survive server crashes. The server only manages worker lifecycle, not their runtime
2. **Per-User Socket Isolation**: Each worker creates its own socket under `/run/user/<uid>/` with 0600 permissions, ensuring only the owner can connect
3. **Identity Authentication**: Caller UID/GID is obtained via `SO_PEERCRED` from kernel, cannot be forged
4. **Worker Namespace Isolation**: Workers enter the container's mount namespace via `setns + unshare`. CNI plugin dir is bind-mounted read-only to prevent binary replacement
5. **Grant-based ACL Check**: Each request is validated against the user's grants + grants from referenced rule collections — supports optional IP range restrictions
6. **Static IP Validation**: For static IPAM resources, the requested IP is validated against the user's allowed IP ranges — requests outside the range are rejected
7. **Default Deny**: Any request that doesn't explicitly match a policy is rejected

### Hardening Recommendations
- Follow the principle of least privilege when configuring ACL grants
- For static IP resources, assign each user their own exclusive IP range — do not overlap ranges between users
- Regularly audit access logs for unusual activity
- Keep CNI plugins updated to latest version

## Integrate with `podman`

Create a container network with `net-porter` driver, and use it with `podman`.

```bash
podman network create -d net-porter -o net_porter_resource=macvlan-dhcp -o net_porter_socket=/run/user/$(id -u)/net-porter.sock macvlan-net
```

- `-d net-porter`: use the `net-porter` driver.
- `-o net_porter_resource=macvlan-dhcp`: specify the resource name, should be
  the same with server configuration.
- `-o net_porter_socket=/run/user/$(id -u)/net-porter.sock`: specify the
  per-user socket path created by `net-porter server`. `$(id -u)` expands
  to the current user's uid.
- `macvlan-net`: the network name.
