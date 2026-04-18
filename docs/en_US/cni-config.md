# CNI Configuration Guide

> Version: v0.6.0+

net-porter manages CNI network configuration through the `/etc/net-porter/cni.d/` directory, supporting standard CNI 1.0 format (including chained plugins).

## Standard CNI Configuration

### Directory Structure

CNI configuration files are placed in `/etc/net-porter/cni.d/`. The installer package creates this directory automatically.

```
/etc/net-porter/cni.d/
├── 10-macvlan-dhcp.conflist
├── 20-macvlan-static.conf
└── 30-ipvlan-l3.conflist
```

### File Formats

Two standard CNI 1.0 formats are supported:

- **`.conf`** — Single plugin configuration
- **`.conflist`** — Multi-plugin configuration (chained plugins)

Files without `.conf` or `.conflist` suffixes are ignored (e.g., files with `.example` suffix).

### Single Plugin Config (.conf)

```json
{
  "cniVersion": "1.0.0",
  "name": "macvlan-dhcp",
  "type": "macvlan",
  "master": "eth0",
  "ipam": {
    "type": "dhcp"
  }
}
```

### Multi-Plugin Config (.conflist)

```json
{
  "cniVersion": "1.0.0",
  "name": "production-net",
  "plugins": [
    {
      "type": "macvlan",
      "master": "bond0",
      "mode": "bridge",
      "mtu": 1500,
      "ipam": {
        "type": "dhcp"
      }
    },
    {
      "type": "bandwidth",
      "ingressRate": 100000000,
      "egressRate": 100000000
    }
  ]
}
```

> **Tip**: Chained plugins execute in array order. Each plugin receives the previous plugin's output (prevResult).

### Configuration Requirements

| Field | Description | Required |
|-------|-------------|----------|
| `cniVersion` | CNI spec version, recommend `"1.0.0"` | ✅ |
| `name` | Network name, used for ACL grants and podman references | ✅ |
| `type` (.conf) | Plugin type, e.g. `macvlan`, `ipvlan` | ✅ |
| `plugins` (.conflist) | Array of plugins | ✅ |
| `plugins[].type` | Type for each plugin | ✅ |

> **Important**:
> - Each plugin binary must exist in `cni_plugin_dir` (default `/usr/lib/cni` or `/opt/cni/bin`)
> - The first plugin's `ipam` field determines the IPAM type (dhcp/static)
> - The network name (`name`) must match the `resource` name in ACL grants

### Configuration Examples

#### DHCP Network

`/etc/net-porter/cni.d/10-dhcp.conflist`:
```json
{
  "cniVersion": "1.0.0",
  "name": "dhcp-net",
  "plugins": [
    {
      "type": "macvlan",
      "master": "eth0",
      "ipam": { "type": "dhcp" }
    }
  ]
}
```

#### Static IP Network

`/etc/net-porter/cni.d/20-static.conflist`:
```json
{
  "cniVersion": "1.0.0",
  "name": "static-net",
  "plugins": [
    {
      "type": "macvlan",
      "master": "eth0",
      "mode": "bridge",
      "mtu": 9000,
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

#### Chained Plugins (Bandwidth Limiting)

`/etc/net-porter/cni.d/30-limited.conflist`:
```json
{
  "cniVersion": "1.0.0",
  "name": "limited-net",
  "plugins": [
    {
      "type": "macvlan",
      "master": "eth0",
      "ipam": { "type": "dhcp" }
    },
    {
      "type": "bandwidth",
      "ingressRate": 10000000,
      "egressRate": 10000000
    }
  ]
}
```

## ACL Association

The `name` field in CNI configs is linked to the `resource` field in ACL grants by name:

```
CNI Config (cni.d/)          ACL Grant (acl.d/)
┌─────────────────┐          ┌─────────────────┐
│ name: "dhcp-net"│◄────────►│ resource:       │
│                 │          │   "dhcp-net"    │
└─────────────────┘          └─────────────────┘
```

ACL grant example (`/etc/net-porter/acl.d/alice.json`):
```json
{
  "grants": [
    { "resource": "dhcp-net" },
    { "resource": "static-net", "ips": ["192.168.1.10-192.168.1.20"] }
  ]
}
```

## Configuration Options

| Option | Description | Default |
|--------|-------------|---------|
| `cni_dir` | Directory containing CNI config files | `{config_dir}/cni.d` |
| `cni_plugin_dir` | Directory containing CNI plugin binaries | auto-detected `/usr/lib/cni` or `/opt/cni/bin` |

Set explicitly in `config.json`:

```json
{
  "cni_dir": "/etc/net-porter/cni.d",
  "cni_plugin_dir": "/opt/cni/bin"
}
```

## Troubleshooting

### Config file not loaded

**Symptom**: Network name not found

**Steps**:
1. Verify the file suffix is `.conf` or `.conflist` (other suffixes are ignored)
2. Check JSON format: `jq < /etc/net-porter/cni.d/your-config.conflist`
3. Check logs for loading messages: `journalctl -u net-porter | grep cni_loader`

### Plugin not found

**Symptom**: Log shows `Plugin 'xxx' not found or not executable`

**Steps**:
1. Verify plugin binary exists: `ls -la /usr/lib/cni/macvlan`
2. Verify plugin is executable: `test -x /usr/lib/cni/macvlan && echo OK`
3. If plugins are in a different directory, set `cni_plugin_dir` in `config.json`

### Duplicate network name

**Symptom**: Log shows `Duplicate network name 'xxx'`

**Explanation**: When multiple config files use the same `name`, the first one loaded takes effect and subsequent duplicates are skipped. Files are loaded in directory traversal order.

### Changes not taking effect

**Note**: The `cni.d/` directory does not currently support hot-reloading. After adding or modifying CNI config files, restart the service:

```bash
systemctl restart net-porter
```
