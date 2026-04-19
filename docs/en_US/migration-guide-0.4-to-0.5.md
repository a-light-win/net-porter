# Migration Guide: 0.4 → 0.5

> **Note**: The ACL file format described in this guide (`user`/`group` fields) was further changed in v1.0.0.
> In v1.0.0, identity is determined by the filename instead of `user`/`group` fields.
> See the [Migration Guide (0.6 → 1.0)](migration-guide-0.6-to-1.0.md) for the latest changes.

Version 0.5.0 moves access control from inline `acl` fields in `config.json` to a separate `acl.d/` directory. This makes it easier to manage user/group permissions without modifying the main configuration file, and enables hot-reloading of ACL rules without restarting the service.

## Summary of Changes

| Before (0.4) | After (0.5) |
|---|---|
| ACL rules defined inline in each resource | ACL rules stored as individual files in `acl.d/` directory |
| `users` field in `config.json` lists socket users | User list derived automatically from ACL files |
| Resource has `acl` array field | Resource no longer has `acl` field |
| ACL changes require service restart | ACL changes take effect automatically |
| Only IPv4 ranges supported for static IP | IPv4 and IPv6 ranges both supported |
| Only macvlan interface type | macvlan and ipvlan both supported |

## Configuration Changes

### Step 1: Create the `acl.d/` directory

```bash
mkdir -p /etc/net-porter/acl.d
```

### Step 2: Convert inline ACL grants to individual files

For each user or group that has ACL grants, create a JSON file in `/etc/net-porter/acl.d/`.

#### Before (0.4 — inline in `config.json`):

```json
{
  "users": ["alice", "bob"],
  "resources": [
    {
      "name": "macvlan-dhcp",
      "interface": { "type": "macvlan", "master": "eth0" },
      "ipam": { "type": "dhcp" },
      "acl": [
        { "user": "alice" },
        { "group": "devops" }
      ]
    },
    {
      "name": "static-net",
      "interface": { "type": "macvlan", "master": "eth0" },
      "ipam": {
        "type": "static",
        "addresses": [
          { "address": "192.168.1.0/24", "gateway": "192.168.1.1" }
        ]
      },
      "acl": [
        { "user": "alice", "ips": ["192.168.1.10-192.168.1.20"] },
        { "user": "bob", "ips": ["192.168.1.30-192.168.1.40"] }
      ]
    }
  ]
}
```

#### After (0.5):

**`/etc/net-porter/config.json`**:

```json
{
  "resources": [
    {
      "name": "macvlan-dhcp",
      "interface": { "type": "macvlan", "master": "eth0" },
      "ipam": { "type": "dhcp" }
    },
    {
      "name": "static-net",
      "interface": { "type": "macvlan", "master": "eth0" },
      "ipam": {
        "type": "static",
        "addresses": [
          { "address": "192.168.1.0/24", "gateway": "192.168.1.1" }
        ]
      }
    }
  ]
}
```

**`/etc/net-porter/acl.d/alice.json`**:

```json
{
  "user": "alice",
  "grants": [
    { "resource": "macvlan-dhcp" },
    { "resource": "static-net", "ips": ["192.168.1.10-192.168.1.20"] }
  ]
}
```

**`/etc/net-porter/acl.d/bob.json`**:

```json
{
  "user": "bob",
  "grants": [
    { "resource": "static-net", "ips": ["192.168.1.30-192.168.1.40"] }
  ]
}
```

**`/etc/net-porter/acl.d/devops.json`**:

```json
{
  "group": "devops",
  "grants": [
    { "resource": "macvlan-dhcp" }
  ]
}
```

### Step 3: Restart the service

```bash
systemctl restart net-porter
```

After this initial restart, future ACL changes (add/modify/delete files in `acl.d/`) will take effect automatically without restarting.

## ACL File Format

Each file in `acl.d/` must be a `.json` file with the following structure:

```json
{
  "user": "<username or UID>",
  "group": "<group name or GID>",
  "grants": [
    { "resource": "<resource-name>" },
    { "resource": "<resource-name>", "ips": ["<ip-range>", ...] }
  ]
}
```

| Field | Description | Required |
|-------|-------------|----------|
| `user` | Username or numeric UID | one of `user` or `group` |
| `group` | Group name or numeric GID | one of `user` or `group` |
| `grants` | Array of resource grants | yes |
| `grants[].resource` | Name of the resource (must match a resource in `config.json`) | yes |
| `grants[].ips` | Array of allowed IP ranges or single IPs (for static IPAM resources) | static resources: yes |

**IP range formats** (now supports IPv6):
- Single IPv4: `"192.168.1.30"`
- IPv4 range: `"192.168.1.10-192.168.1.20"`
- Single IPv6: `"2001:db8::1"`
- IPv6 range: `"2001:db8::1-2001:db8::ff"`

### File naming

You can name the files however you like (as long as they end in `.json`). A common convention is to use the user or group name, e.g., `alice.json`, `devops.json`. Non-`.json` files are ignored.

### Combining user and group

A single file can specify both `user` and `group`:

```json
{
  "user": "alice",
  "group": "devops",
  "grants": [
    { "resource": "shared-net" }
  ]
}
```

This grants access to `alice` by UID and to all members of `devops` by GID.

### Multiple users on the same resource

Multiple ACL files can reference the same resource. The grants are automatically merged:

```
acl.d/
├── alice.json    → grants access to "macvlan-dhcp"
├── bob.json      → grants access to "macvlan-dhcp"
└── devops.json   → grants access to "macvlan-dhcp"
```

## New Features Available After Migration

### Hot-reload

Once migrated to the `acl.d/` directory, you can manage ACLs without restarting:

```bash
# Add a new user
cp /path/to/newuser.json /etc/net-porter/acl.d/

# Remove a user's access
rm /etc/net-porter/acl.d/olduser.json

# Modify permissions
vim /etc/net-porter/acl.d/alice.json
```

Changes are detected and applied automatically.

### IPv6 static IP ranges

You can now use IPv6 addresses in IP ranges:

```json
{
  "user": "alice",
  "grants": [
    { "resource": "ipv6-net", "ips": ["2001:db8::10-2001:db8::ff"] }
  ]
}
```

### IPvlan interface type

You can now use `ipvlan` as an interface type (requires static IP for L3/L3s modes):

```json
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
```
