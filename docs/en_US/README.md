# net-porter

`net-porter` is a [netavark](https://github.com/containers/netavark) plugin
to provide macvlan/ipvlan network to rootless podman container.

It consists with two major part:

- `net-porter plugin`: the `netavark` plugin that called by `netavark`
  inside the rootless environment.
- `net-porter server`: the rootful server that responsible for creating
  the macvlan/ipvlan network via CNI plugins.

The `net-porter server` runs as a single global systemd service. It monitors `/run/user/` directories and automatically creates per-user unix sockets for each ACL-allowed user. When the container starts,
netavark will call the `net-porter plugin`. The plugin then
will connect to the `net-porter server` via the per-user socket,
and pass the required information to the `net-porter server`.

The `net-porter server` will authenticate the request
by the `uid/gid` of the caller (obtained via kernel `SO_PEERCRED`, cannot be forged). And then creates the macvlan/ipvlan network
if the user has the permission.

> **Why per-user sockets in `/run/user/<uid>/`?** Rootless podman runs in an isolated mount namespace and a separate network namespace (via pasta/slirp4netns). Neither filesystem sockets in `/run/` nor abstract sockets are visible across these boundaries. However, `/run/user/<uid>/` is a per-user tmpfs created by `systemd-logind` that is bind-mounted into the user namespace, making it accessible from both host and rootless podman.

## Features

- **Dynamic Socket Management**: Automatically creates/removes per-user sockets via inotify when users log in/out
- **Single Service Architecture**: One global root service for all users, no need to manage per-user services
- **Grant-based ACL Control**: Per-resource grants with user/group matching and optional static IP range restrictions
- **Static IP Support**: Validate user-requested static IPs against allowed ranges — no separate CNI config files needed
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
│   ├── main.zig                  # Program entry point
│   ├── server/                   # Server implementation
│   │   ├── Server.zig            # Server core
│   │   ├── SocketManager.zig     # Multi-socket management (inotify + poll)
│   │   ├── Handler.zig           # Request handler
│   │   ├── AclManager.zig        # ACL management (file-based, hot-reload)
│   │   ├── AclFile.zig           # ACL file format definition
│   │   ├── Acl.zig               # ACL validation
│   │   └── version.zig           # Version string
│   ├── cni/                      # CNI integration
│   │   ├── Cni.zig               # CNI execution logic
│   │   ├── CniManager.zig        # CNI config management
│   │   ├── DhcpService.zig       # Per-user DHCP service
│   │   └── DhcpManager.zig       # DHCP service manager
│   ├── config/                   # Configuration
│   │   ├── Config.zig            # Config struct
│   │   ├── Resource.zig          # Resource, Grant, Interface, Ipam structs
│   │   ├── ManagedConfig.zig     # Config loader
│   │   └── DomainSocket.zig      # Socket path helpers
│   ├── plugin/                   # Netavark plugin implementation
│   ├── version.zig               # Version string
│   └── utils/                    # Utilities
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
Edit `/etc/net-porter/config.json` to define resources. Each resource combines interface and IPAM in one place — no separate CNI config files needed:

```json
{
  "resources": [
    {
      "name": "macvlan-dhcp",
      "interface": {
        "type": "macvlan",
        "master": "eth0"
      },
      "ipam": {
        "type": "dhcp"
      }
    }
  ]
}
```

Replace `eth0` with your host physical interface. Restart service after modifying configuration:
```bash
systemctl restart net-porter
```

### 3. Configure access control
Create an ACL file in `/etc/net-porter/acl.d/` for each user or group that should have access:

```bash
mkdir -p /etc/net-porter/acl.d
```

`/etc/net-porter/acl.d/alice.json`:
```json
{
  "user": "alice",
  "grants": [
    { "resource": "macvlan-dhcp" }
  ]
}
```

> ACL files are watched for changes. Adding, modifying, or deleting files takes effect automatically — no restart needed.

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
  "resources": [
    {
      "name": "macvlan-dhcp",
      "interface": {
        "type": "macvlan",
        "master": "eth0"
      },
      "ipam": {
        "type": "dhcp"
      }
    },
    {
      "name": "macvlan-static",
      "interface": {
        "type": "macvlan",
        "master": "eth0",
        "mode": "bridge",
        "mtu": 9000
      },
      "ipam": {
        "type": "static",
        "addresses": [
          { "address": "192.168.1.0/24", "gateway": "192.168.1.1" }
        ],
        "routes": [{ "dst": "0.0.0.0/0" }]
      }
    }
  ],
  "log": {
    "level": "info",
    "dump_env": {
      "enabled": false,
      "path": "/tmp/net-porter-dump"
    }
  }
}
```

Access control is configured separately in the `/etc/net-porter/acl.d/` directory — see [ACL Configuration](#acl-configuration) below.

### Resource Fields

| Field | Description | Required |
|-------|-------------|----------|
| `name` | Resource name, used to reference this resource in podman network creation | ✅ |
| `interface` | Network interface configuration (see below) | ✅ |
| `ipam` | IP address management configuration (see below) | ✅ |

### Interface Configuration

| Field | Description | Default |
|-------|-------------|---------|
| `type` | Interface type: `macvlan` or `ipvlan` | — |
| `master` | Host physical interface to attach to | — |
| `mode` | macvlan mode: `bridge`, `vepa`, `private`, `passthru`; ipvlan mode: `l2`, `l3`, `l3s` | macvlan: `bridge`, ipvlan: `l2` |
| `mtu` | MTU size for the interface | unset (use kernel default) |

> ⚠️ **Note**: ipvlan L3/L3s modes do not support DHCP (no ARP layer). Use static IPAM with these modes.

### IPAM Configuration

| Field | Description | Required |
|-------|-------------|----------|
| `type` | IPAM type: `dhcp` or `static` | ✅ |

For `type: "static"`, additional fields:

| Field | Description | Required |
|-------|-------------|----------|
| `addresses` | Array of `{ "address": "<cidr>", "gateway": "<ip>" }` entries | static: ✅ |
| `routes` | Array of `{ "dst": "<cidr>", "gw": "<ip>", "priority": <num> }` routes | static: optional |
| `dns` | `{ "nameservers": [...], "domain": "...", "search": [...] }` | static: optional |

### ACL Configuration

Access control is managed through individual JSON files in the `/etc/net-porter/acl.d/` directory. The service watches this directory and applies changes automatically — no restart needed.

#### ACL file format

Each file must end in `.json` and follow this structure:

```json
{
  "user": "alice",
  "grants": [
    { "resource": "macvlan-dhcp" },
    { "resource": "static-net", "ips": ["192.168.1.10-192.168.1.20"] }
  ]
}
```

#### ACL file fields

| Field | Description | Required |
|-------|-------------|----------|
| `user` | Username or numeric UID | one of `user` or `group` |
| `group` | Group name or numeric GID | one of `user` or `group` |
| `grants` | Array of resource grants | ✅ |
| `grants[].resource` | Resource name (must match a resource in `config.json`) | ✅ |
| `grants[].ips` | Array of allowed IP ranges or single IPs (for static IPAM resources) | static: ✅ |

#### IP range formats

- Single IPv4: `"192.168.1.30"`
- IPv4 range: `"192.168.1.10-192.168.1.20"`
- Single IPv6: `"2001:db8::1"`
- IPv6 range: `"2001:db8::1-2001:db8::ff"`

When IPAM type is `static`, the caller must request a specific IP (via podman `--ip` or netavark static_ips option), and net-porter validates it against the user's allowed ranges.

> 💡 **Tip**: You can name ACL files however you like. A common convention is to use the user or group name (e.g., `alice.json`, `devops.json`). Multiple files can reference the same resource — grants are merged automatically.

### Top-level Options

| Option | Description | Default |
|--------|-------------|---------|
| `cni_plugin_dir` | Directory containing CNI plugin binaries | auto-detected (`/usr/lib/cni` or `/opt/cni/bin`) |
| `acl_dir` | Directory containing ACL files | `{config_dir}/acl.d` |
| `log.level` | Log level: `debug`, `info`, `warn`, `error` | `info` |
| `log.dump_env` | Environment dump for debugging | disabled |

## Usage Examples

### Example 1: Multiple users with different networks

`/etc/net-porter/config.json`:
```json
{
  "resources": [
    {
      "name": "vlan-100",
      "interface": { "type": "macvlan", "master": "eth0.100" },
      "ipam": { "type": "dhcp" }
    },
    {
      "name": "vlan-200",
      "interface": { "type": "macvlan", "master": "eth0.200" },
      "ipam": { "type": "dhcp" }
    }
  ]
}
```

`/etc/net-porter/acl.d/alice.json`:
```json
{
  "user": "alice",
  "grants": [
    { "resource": "vlan-100" }
  ]
}
```

`/etc/net-porter/acl.d/bob.json`:
```json
{
  "user": "bob",
  "grants": [
    { "resource": "vlan-100" }
  ]
}
```

`/etc/net-porter/acl.d/devops.json`:
```json
{
  "group": "devops",
  "grants": [
    { "resource": "vlan-200" }
  ]
}
```
- `alice` and `bob` can use the `vlan-100` network
- All users in `devops` group can use the `vlan-200` network

User alice creates network:
```bash
podman network create -d net-porter -o net_porter_resource=vlan-100 vlan100
```

### Example 2: Static IP with per-user ranges

`/etc/net-porter/config.json`:
```json
{
  "resources": [
    {
      "name": "static-net",
      "interface": { "type": "macvlan", "master": "eth0" },
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
  "user": "alice",
  "grants": [
    { "resource": "static-net", "ips": ["192.168.1.10-192.168.1.20"] }
  ]
}
```

`/etc/net-porter/acl.d/bob.json`:
```json
{
  "user": "bob",
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

`/etc/net-porter/config.json`:
```json
{
  "resources": [
    {
      "name": "ipvlan-l3",
      "interface": { "type": "ipvlan", "master": "eth0", "mode": "l3" },
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
  "user": "alice",
  "grants": [
    { "resource": "ipvlan-l3", "ips": ["10.0.0.10-10.0.0.20"] }
  ]
}
```
- `alice` can use the `ipvlan-l3` network with ipvlan L3 mode
- IPvLAN shares the parent interface's MAC address (no separate MAC per container)
- Note: ipvlan L3/L3s modes require static IPAM (DHCP is not supported)

### Example 4: IPvLAN L2 with DHCP

`/etc/net-porter/config.json`:
```json
{
  "resources": [
    {
      "name": "ipvlan-dhcp",
      "interface": { "type": "ipvlan", "master": "eth0", "mode": "l2", "mtu": 9000 },
      "ipam": { "type": "dhcp" }
    }
  ]
}
```

`/etc/net-porter/acl.d/alice.json`:
```json
{
  "user": "alice",
  "grants": [
    { "resource": "ipvlan-dhcp" }
  ]
}
```

### Example 5: Mixed macvlan and ipvlan resources

`/etc/net-porter/config.json`:
```json
{
  "resources": [
    {
      "name": "macvlan-dhcp",
      "interface": { "type": "macvlan", "master": "eth0" },
      "ipam": { "type": "dhcp" }
    },
    {
      "name": "macvlan-static",
      "interface": { "type": "macvlan", "master": "eth0", "mode": "bridge", "mtu": 9000 },
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
  "user": "alice",
  "grants": [
    { "resource": "macvlan-dhcp" },
    { "resource": "macvlan-static", "ips": ["10.0.0.5-10.0.0.10"] }
  ]
}
```

## Upgrade from v0.4

Version 0.5.0 moves access control from inline `acl` fields to a separate `acl.d/` directory. See the [Migration Guide (0.4 → 0.5)](migration-guide-0.4-to-0.5.md) for detailed instructions.

Quick steps:

1. Create the ACL directory:
   ```bash
   mkdir -p /etc/net-porter/acl.d
   ```
2. Create an ACL file for each user/group based on your existing `acl` grants (see [ACL Configuration](#acl-configuration))
3. Remove `users` and `acl` fields from `/etc/net-porter/config.json`
4. Restart the service:
   ```bash
   systemctl restart net-porter
   ```

## Upgrade from v0.3 or earlier

See the [Migration Guide (0.3 → 0.4)](migration-guide-0.3-to-0.4.md) for upgrading from v0.3 or earlier. Then follow the v0.4 → v0.5 migration above.

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
- Check if the resource exists in `/etc/net-porter/config.json`
- Ensure the `name` field matches what you pass via `net_porter_resource`
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
1. **Per-User Socket Isolation**: Each user gets their own socket under `/run/user/<uid>/` with 0600 permissions, ensuring only the owner can connect
2. **Identity Authentication**: Caller UID/GID is obtained via `SO_PEERCRED` from kernel, cannot be forged
3. **Socket Filtering**: Connection is immediately rejected if the user has no permission on any resource
4. **Grant-based ACL Check**: Each request is validated against the resource's grant list — grants support user/group matching with optional IP range restrictions
5. **Static IP Validation**: For static IPAM resources, the requested IP is validated against the user's allowed IP ranges — requests outside the range are rejected
6. **Netns Verification**: The network namespace file owner must match the caller UID
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
