# net-porter

`net-porter` is a [netavark](https://github.com/containers/netavark) plugin
to provide macvlan network to rootless podman container.

It consists with two major part:

- `net-porter plugin`: the `netavark` plugin that called by `netavark`
  inside the rootless environment.
- `net-porter server`: the rootful server that responsible for creating
  the macvlan network via CNI plugins.

The `net-porter server` runs as a single global systemd service. It monitors `/run/user/` directories and automatically creates per-user unix sockets for each ACL-allowed user. When the container starts,
netavark will call the `net-porter plugin`. The plugin then
will connect to the `net-porter server` via the per-user socket,
and pass the required information to the `net-porter server`.

The `net-porter server` will authenticate the request
by the `uid/gid` of the caller (obtained via kernel `SO_PEERCRED`, cannot be forged). And then creates the macvlan network
if the user has the permission.

> **Why per-user sockets in `/run/user/<uid>/`?** Rootless podman runs in an isolated mount namespace and a separate network namespace (via pasta/slirp4netns). Neither filesystem sockets in `/run/` nor abstract sockets are visible across these boundaries. However, `/run/user/<uid>/` is a per-user tmpfs created by `systemd-logind` that is bind-mounted into the user namespace, making it accessible from both host and rootless podman.

## Features

✅ **Dynamic Socket Management**: Automatically creates/removes per-user sockets via inotify when users log in/out
✅ **Single Service Architecture**: One global root service for all users, no need to manage per-user services
✅ **Fine-grained ACL Control**: Per resource allow lists for users and groups
✅ **Security Hardened**: Kernel level identity authentication, netns ownership verification, default deny policy
✅ **DHCP Support**: Automatically manage per-user DHCP service instances
✅ **Zero Trust**: All requests must pass multi-level validation before execution

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
- [Zig](https://ziglang.org/) >= 0.15.2 (compiler)
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
│   │   ├── AclManager.zig        # ACL management
│   │   └── Acl.zig               # ACL validation
│   ├── cni/                      # CNI integration
│   │   ├── Cni.zig               # CNI execution logic
│   │   ├── CniManager.zig        # CNI config management
│   │   ├── DhcpService.zig       # Per-user DHCP service
│   │   └── DhcpManager.zig       # DHCP service manager
│   ├── config/                   # Configuration
│   │   ├── Config.zig            # Config struct
│   │   ├── ManagedConfig.zig     # Config loader
│   │   └── DomainSocket.zig      # Socket path helpers
│   ├── plugin/                   # Netavark plugin implementation
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
Create CNI configuration for your macvlan network at `/etc/net-porter/cni.d/macvlan-dhcp.json`:
```json
{
  "cniVersion": "1.0.0",
  "name": "macvlan-dhcp",
  "plugins": [
    {
      "type": "macvlan",
      "master": "eth0", // Replace with your host physical interface
      "linkInContainer": false,
      "ipam": {
        "type": "dhcp"
      }
    }
  ]
}
```

### 3. Configure ACL
Edit `/etc/net-porter/config.json` to configure access permissions:
```json
{
  "resources": [
    {
      "name": "macvlan-dhcp",
      "allow_users": ["alice", "bob"], // Allow these users to use this network
      "allow_groups": ["docker"]       // Allow users in this group to use this network
    }
  ]
}
```
Restart service after modifying configuration:
```bash
systemctl restart net-porter
```

### 4. Create podman network
Run this command as the rootless user (e.g., `alice`):
```bash
podman network create \
  -d net-porter \
  -o net_porter_resource=macvlan-dhcp \
  -o net_porter_socket=/run/user/$(id -u)/net-porter.sock \
  macvlan-net
```

### 5. Test it out
Run a test container:
```bash
podman run -it --rm --network macvlan-net alpine ip addr
```
You should see the macvlan interface with an IP address from your DHCP server.

## Configuration Guide

### Server Configuration (`/etc/net-porter/config.json`)
```json
{
  "cni_dir": "/etc/net-porter/cni.d",   // CNI config directory, optional
  "cni_plugin_dir": "/usr/lib/cni",     // CNI plugin directory, optional (auto detected)
  "resources": [
    {
      "name": "macvlan-dhcp",           // Resource name, must match CNI config file name
      "allow_users": ["alice", "1002"], // Allowed users: username or numeric uid
      "allow_groups": ["devops"]        // Allowed groups: group name or numeric gid
    },
    {
      "name": "macvlan-static",
      "allow_users": ["bob"]
    }
  ],
  "log": {
    "level": "info",                     // Log level: debug, info, warn, error
    "dump_env": {
      "enabled": false,                  // Enable environment dump for debugging
      "path": "/tmp/net-porter-dump"     // Dump directory
    }
  }
}
```

> ⚠️ **Important Note**: Each resource **must** have at least one `allow_users` or `allow_groups` entry. The service will fail to start if any resource has no access controls configured.

### CNI Configuration
Put your CNI configuration files under `/etc/net-porter/cni.d/`, the filename must be `<resource-name>.json`.

Common macvlan configuration options:
| Option | Description |
|--------|-------------|
| `master` | Host physical interface to use for macvlan |
| `mode` | Macvlan mode: `bridge` (default), `vepa`, `private`, `passthru` |
| `mtu` | MTU size for the interface |
| `ipam.type` | IPAM type: `dhcp`, `static`, `host-local` |

## Usage Examples

### Example 1: Multiple users with different networks
Configuration:
```json
// /etc/net-porter/config.json
{
  "resources": [
    {
      "name": "vlan-100",
      "allow_users": ["alice", "bob"]
    },
    {
      "name": "vlan-200",
      "allow_groups": ["devops"]
    }
  ]
}
```
- `alice` and `bob` can use the `vlan-100` network
- All users in `devops` group can use the `vlan-200` network

User alice creates network:
```bash
podman network create -d net-porter -o net_porter_resource=vlan-100 vlan100
```

### Example 2: Static IP configuration
CNI config (`/etc/net-porter/cni.d/static-net.json`):
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
          {
            "address": "192.168.1.10/24",
            "gateway": "192.168.1.1"
          }
        ],
        "routes": [
          { "dst": "0.0.0.0/0" }
        ]
      }
    }
  ]
}
```

### Example 3: Multiple IP configurations
```json
{
  "cniVersion": "1.0.0",
  "name": "dual-stack",
  "plugins": [
    {
      "type": "macvlan",
      "master": "eth0",
      "ipam": {
        "type": "dhcp",
        "addresses": [
          { "address": "10.0.0.0/24" },
          { "address": "2001:db8::/64" }
        ]
      }
    }
  ]
}
```

## Upgrade from v0.x (per-user service architecture)
Version 1.0 uses single global service instead of per-user service instances. To upgrade:

1. Stop and disable all per-user services:
   ```bash
   systemctl stop net-porter@*
   systemctl disable net-porter@*
   ```
2. Install the new version package
3. Merge your per-user ACL configurations into the global `/etc/net-porter/config.json`
4. Start the global service:
   ```bash
   systemctl enable --now net-porter
   ```
5. Recreate podman networks with the new abstract socket path:
   ```bash
   # Remove old network
   podman network rm macvlan-net
   # Recreate with abstract socket
   podman network create \
     -d net-porter \
     -o net_porter_resource=macvlan-dhcp \
     -o net_porter_socket=/run/user/$(id -u)/net-porter.sock \
     macvlan-net
   ```

## Troubleshooting

### Common issues

#### 1. Permission denied when connecting to socket
**Error**: `Access denied for uid=1000`
**Solutions**:
- Check if the user has permission for the requested resource in the config
- Verify the ACL configuration in `/etc/net-porter/config.json`

#### 2. Plugin cannot connect to server
**Error**: `Failed to connect to domain socket /run/user/1000/net-porter.sock: ConnectionRefused`
**Solutions**:
- Verify the server is running: `systemctl status net-porter`
- Verify the per-user socket exists: `ls -la /run/user/$(id -u)/net-porter.sock`
- Check your uid is in the ACL configuration

#### 3. DHCP failed to get IP
**Error**: `dhcp client: no ack received`
**Solutions**:
- Verify DHCP server is running on your network
- Check if the master interface is connected to the correct network
- Ensure macvlan mode is supported by your network switch

#### 4. CNI configuration not found
**Error**: `Failed to load CNI for resource=xxx`
**Solutions**:
- Check if `/etc/net-porter/cni.d/xxx.json` exists
- Verify the JSON syntax is valid
- Ensure the `name` field in CNI config matches the resource name

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
4. **Resource ACL Check**: Each request is validated against the resource's allow list
5. **Netns Verification**: The network namespace file owner must match the caller UID
6. **Default Deny**: Any request that doesn't explicitly match a policy is rejected

### Hardening Recommendations
- Follow the principle of least privilege when configuring ACLs
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
