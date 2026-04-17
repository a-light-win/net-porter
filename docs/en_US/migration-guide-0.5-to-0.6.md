# Migration Guide: 0.5 → 0.6

Version 0.6.0 moves network resource configuration from the inline `resources` array in `config.json` to standard CNI 1.0 format files in the `cni.d/` directory. This makes net-porter compatible with the standard CNI ecosystem and enables chained plugin support (e.g., macvlan + bandwidth + firewall).

## Summary of Changes

| Before (0.5) | After (0.6) |
|---|---|
| Network resources defined inline in `config.json` | Network resources as standard CNI files in `cni.d/` directory |
| Custom `interface` + `ipam` structure | Standard CNI 1.0 plugin format |
| Single plugin per resource | Chained plugins supported via `.conflist` |
| No state persistence across restarts | Attachment state persisted to `/run/net-porter/` |
| Resource name from `name` field | Resource name from CNI `name` field |

## Configuration Changes

### Step 1: Create the `cni.d/` directory

The installer package creates this directory automatically. If upgrading manually:

```bash
mkdir -p /etc/net-porter/cni.d
```

### Step 2: Convert each resource to a CNI config file

For each entry in the `resources` array in `config.json`, create a corresponding `.conflist` file in `/etc/net-porter/cni.d/`.

#### Before (0.5 — inline in `config.json`):

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
    },
    {
      "name": "static-net",
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
    },
    {
      "name": "ipvlan-l3",
      "interface": {
        "type": "ipvlan",
        "master": "eth0",
        "mode": "l3"
      },
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

#### After (0.6 — CNI files in `cni.d/`):

**`/etc/net-porter/cni.d/10-macvlan-dhcp.conflist`**:

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

**`/etc/net-porter/cni.d/20-static-net.conflist`**:

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

**`/etc/net-porter/cni.d/30-ipvlan-l3.conflist`**:

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

### Conversion rules

When converting from the old format to CNI files, follow these rules:

| Old field (0.5) | New field (0.6) | Notes |
|---|---|---|
| `name` | `name` (top-level) | Unchanged — must match ACL `resource` names |
| *(new)* | `cniVersion: "1.0.0"` | Required in CNI format |
| `interface.type` | `plugins[0].type` | Moved into plugin config |
| `interface.master` | `plugins[0].master` | Moved into plugin config |
| `interface.mode` | `plugins[0].mode` | Moved into plugin config |
| `interface.mtu` | `plugins[0].mtu` | Moved into plugin config |
| `ipam` | `plugins[0].ipam` | Moved into plugin config, format unchanged |

### Step 3: Clean up `config.json`

Remove the `resources` array from `/etc/net-porter/config.json`. The file should now only contain server-level settings:

```json
{
  "log": {
    "level": "info"
  }
}
```

### Step 4: Restart the service

```bash
systemctl restart net-porter
```

Verify the networks are loaded:

```bash
journalctl -u net-porter | grep "Loaded.*CNI network"
```

## What Stays the Same

- **ACL configuration** (`acl.d/` directory): No changes needed. ACL files continue to work as before.
- **`cni_plugin_dir` option**: Still auto-detected or configurable in `config.json`.
- **Podman network setup**: The `net_porter_resource` option still references the network `name` — no changes to podman commands.
- **Static IP ranges in ACL grants**: Continue to work with static IPAM resources.

## New Features Available After Migration

### Chained Plugins

You can now chain multiple CNI plugins in a single network:

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

### Attachment Persistence

If the service restarts, it can now properly tear down existing CNI attachments using the persisted state in `/run/net-porter/`. Previously, a restart meant orphaned network interfaces.

### Standard CNI Compatibility

Since configs now use standard CNI 1.0 format, you can use existing CNI config files from other tools (e.g., Kubernetes CNI configs) with minimal or no modification. Unknown fields are silently ignored.

## Troubleshooting

### "Network 'xxx' not found" after migration

1. Check the file exists in `cni.d/`: `ls /etc/net-porter/cni.d/`
2. Verify the file suffix is `.conf` or `.conflist` (other suffixes are ignored)
3. Verify the `name` field matches what you pass via `net_porter_resource`
4. Restart the service after adding new CNI config files

### "Plugin 'xxx' not found or not executable"

1. Check plugin binary exists: `ls -la /usr/lib/cni/macvlan`
2. Check plugin is executable: `test -x /usr/lib/cni/macvlan && echo OK`
3. If plugins are in a different directory, set `cni_plugin_dir` in `config.json`

### Config file not loaded

1. Verify the file suffix is `.conf` or `.conflist`
2. Validate JSON format: `jq < /etc/net-porter/cni.d/your-config.conflist`
3. Check logs: `journalctl -u net-porter | grep cni_loader`
