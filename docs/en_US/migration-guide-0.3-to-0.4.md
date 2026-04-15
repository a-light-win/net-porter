# Migration Guide: 0.3 → 0.4

This guide walks you through upgrading from net-porter 0.3.x to 0.4.0.

## Overview of Breaking Changes

| Area | 0.3.x | 0.4.0 |
|------|-------|-------|
| Service model | Per-user: `net-porter@<uid>.service` | Single global: `net-porter.service` |
| Socket | `domain_socket` config section (configurable path, owner, permissions) | Per-user at `/run/user/<uid>/net-porter.sock` (auto-managed) |
| CNI config | Separate files in `cni_dir` directory | Inline in resource definition |
| ACL | Flat `allow_users` / `allow_groups` arrays | Structured `acl` grant array |
| IPAM | Not configurable (DHCP only) | Tagged union: `dhcp` or `static` |
| User declaration | Implicit via systemd template `@<uid>` | Explicit `users` array at top level |
| CLI | `--uid` argument required | No `--uid` argument |
| Build | Zig 0.14.x | Zig >= 0.16.0 |

## Step-by-Step Migration

### 1. Stop existing services

```bash
# Stop and disable all per-user service instances
systemctl stop 'net-porter@*'
systemctl disable 'net-porter@*'
```

### 2. Install the new version

Install the 0.4.0 package (deb, rpm, or archlinux) as usual.

### 3. Rewrite configuration

The configuration format has changed significantly. Below is a field-by-field migration guide.

#### 3.1 Remove `domain_socket` and `cni_dir` sections

**0.3.x:**
```json
{
  "domain_socket": {
    "path": "/run/user/1000/net-porter.sock",
    "uid": 1000
  },
  "cni_dir": "/etc/net-porter/cni.d"
}
```

**0.4.0:** Remove both fields entirely. Socket paths are now derived automatically from the `users` field. CNI configuration is now defined inline within each resource (no longer read from a directory).

#### 3.2 Add `users` field

**0.4.0:** Add a top-level `users` array listing all users that need socket access.

> **Note:** In 0.3.x, each user ran their own service instance via `net-porter@<uid>.service` (with the `--uid` argument). You now need to list all users that previously had their own service instances in the `users` array:

```json
{
  "users": ["alice", "bob"]
}
```

Both usernames (strings) and numeric UIDs are supported, e.g. `["alice", "1001"]`.

#### 3.3 Rewrite resources

**0.3.x:**
```json
{
  "resources": [
    {
      "name": "macvlan-dhcp",
      "allow_users": ["alice", "bob"],
      "allow_groups": ["devops"]
    }
  ]
}
```

**0.4.0:** Each resource now requires inline `interface`, `ipam`, and `acl` fields:

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
      },
      "acl": [
        { "user": "alice" },
        { "user": "bob" },
        { "group": "devops" }
      ]
    }
  ]
}
```

Key changes:
- `allow_users` → individual `{ "user": "alice" }` grants in `acl` array
- `allow_groups` → individual `{ "group": "devops" }` grants in `acl` array
- `interface` is **required** — previously read from `cni.d/` files
- `ipam` is **required** — choose `"type": "dhcp"` or `"type": "static"`

#### 3.4 Remove CNI config directory

Delete the old CNI configuration directory. Its contents are no longer used:

```bash
rm -rf /etc/net-porter/cni.d/
```

All interface and IPAM settings are now defined inline in each resource.

### 4. Full configuration comparison

Below is a complete side-by-side comparison for a real-world scenario with two users, alice (UID 1000) and bob (UID 1001), each previously running their own service instance:

**0.3.x full configuration:**
```json
{
  "domain_socket": {},
  "cni_dir": "/etc/net-porter/cni.d",
  "cni_plugin_dir": "/usr/lib/cni",
  "resources": [
    {
      "name": "macvlan-dhcp",
      "allow_users": ["alice", "bob"],
      "allow_groups": ["devops"]
    }
  ],
  "log": {
    "level": "info"
  }
}
```

Along with a `macvlan-dhcp.conflist` file in the `cni.d/` directory defining the macvlan interface and DHCP IPAM.

Services were started per-user:
```bash
systemctl enable --now net-porter@1000
systemctl enable --now net-porter@1001
```

**0.4.0 equivalent configuration:**
```json
{
  "users": ["alice", "bob"],
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
      },
      "acl": [
        { "user": "alice" },
        { "user": "bob" },
        { "group": "devops" }
      ]
    }
  ],
  "log": {
    "level": "info"
  }
}
```

The macvlan and DHCP settings that were previously in `cni.d/macvlan-dhcp.conflist` are now defined inline in the resource's `interface` and `ipam` fields.

Now only a single command is needed to start the service:
```bash
systemctl enable --now net-porter
```

### 5. Complete configuration example

Here is a full 0.4.0 `config.json` showing both DHCP and static IP resources:

```json
{
  "users": ["alice", "bob"],
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
      },
      "acl": [
        { "user": "alice" },
        { "group": "devops" }
      ]
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
      },
      "acl": [
        { "user": "alice", "ips": ["192.168.1.10-192.168.1.20"] },
        { "user": "bob",   "ips": ["192.168.1.30-192.168.1.40"] }
      ]
    }
  ],
  "log": {
    "level": "info"
  }
}
```

### 6. Start the new service

```bash
systemctl enable --now net-porter
```

Verify it is running:
```bash
systemctl status net-porter
```

### 7. Recreate podman networks

The socket path has changed. Remove old networks and recreate them with the new per-user socket path:

```bash
# Remove old network (run as the rootless user)
podman network rm macvlan-net

# Recreate with per-user socket
podman network create \
  -d net-porter \
  -o net_porter_resource=macvlan-dhcp \
  -o net_porter_socket=/run/user/$(id -u)/net-porter.sock \
  macvlan-net
```

### 8. Verify

Run a test container as each user:
```bash
podman run -it --rm --network macvlan-net alpine ip addr
```

You should see the macvlan interface with an IP address.

## Troubleshooting

### Service fails to start

**Error**: `Resource has no ACL grants`
**Fix**: Every resource must have at least one `acl` grant entry. Add an `acl` array to each resource.

### Permission denied

**Error**: `Access denied for uid=1000`
**Fix**:
- Verify the user is listed in an `acl` grant for the requested resource.
- Ensure the user's UID is in the `users` array (required for socket creation).

### Socket not found

**Error**: `Failed to connect to /run/user/1000/net-porter.sock`
**Fix**:
- Verify the service is running: `systemctl status net-porter`
- Verify the user is listed in the `users` array in config.
- Check if the user has an active login session (`/run/user/<uid>/` must exist, created by `systemd-logind`).

### Static IP rejected

**Error**: `Static IP x.x.x.x not allowed for user`
**Fix**: Check the `ips` range in the user's ACL grant. Ensure the requested IP falls within the allowed range.
