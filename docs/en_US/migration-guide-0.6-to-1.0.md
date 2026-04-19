# Migration Guide: 0.6 → 1.0

Version 1.0.0 introduces a per-UID worker architecture with significant security improvements. The server now spawns independent worker processes for each allowed user instead of handling connections directly. The ACL file format has also changed.

## Summary of Changes

| Before (0.6) | After (1.0) |
|---|---|
| Server handles all connections directly | Server spawns per-UID worker processes via `systemd-run` |
| ACL identity from `user`/`group` fields | ACL identity from filename (`<username>.json` / `@<name>.json`) |
| No shared rule collections | New `groups` field references `@<name>.json` rule collections |
| Group files named `devops.json` | Group files renamed to `@devops.json` |
| Worker state in `/run/user/<uid>/` | Worker state in root-only `/run/net-porter/workers/<uid>/` |
| `nsenter` for namespace entry | Netns resolution via `/proc/<catatonit_pid>/root/` |
| New `net-porter-worker@.service` template | — |

## Step-by-Step Migration

### Step 1: Rename rule collection files

If you have shared ACL files (e.g., `devops.json`), rename them to use the `@` prefix:

```bash
# Example: rename group ACL files
mv /etc/net-porter/acl.d/devops.json /etc/net-porter/acl.d/@devops.json
mv /etc/net-porter/acl.d/admins.json /etc/net-porter/acl.d/@admins.json
```

> **Note**: The `@` prefix distinguishes rule collection files from user ACL files. User files remain unchanged (e.g., `alice.json` stays as is).

### Step 2: Update ACL file format

Remove the `user` and `group` fields from your ACL files. These fields are silently ignored for backward compatibility, so this step is optional but recommended for clarity.

**Before (0.6):**

```json
{
  "user": "alice",
  "grants": [
    { "resource": "macvlan-dhcp" }
  ]
}
```

**After (1.0):**

```json
{
  "grants": [
    { "resource": "macvlan-dhcp" }
  ]
}
```

If you want to reference shared rule collections, add the `groups` field:

```json
{
  "grants": [
    { "resource": "macvlan-dhcp" }
  ],
  "groups": ["devops"]
}
```

This includes all grants from `@devops.json` into alice's effective permissions.

### Step 3: Install the new version

Install the 1.0.0 package (deb, rpm, or archlinux) as usual. The new `net-porter-worker@.service` template will be installed automatically.

### Step 4: Restart the service

```bash
systemctl restart net-porter
```

Verify it is running:

```bash
systemctl status net-porter
```

You should see log messages about workers being spawned for each allowed user:

```bash
journalctl -u net-porter -f
```

### Step 5: Verify worker services

Check that worker services are running:

```bash
systemctl list-units 'net-porter-worker@*'
```

Each allowed user should have an active worker instance.

## What Stays the Same

- **CNI configuration** (`cni.d/` directory): No changes needed. Standard CNI 1.0 config files continue to work as before.
- **`config.json` server settings**: No changes needed. All server-level options remain the same.
- **Podman network setup**: The `net_porter_resource` and `net_porter_socket` options remain unchanged — no changes to podman commands.
- **Static IP ranges in ACL grants**: Continue to work with static IPAM resources.
- **ACL hot-reload**: User ACL files continue to be watched for changes via inotify.

## New Architecture Details

### Per-UID Worker Architecture

In v1.0.0, the server no longer handles container network requests directly. Instead:

1. The **server** scans `acl.d/` to resolve allowed usernames to UIDs
2. For each allowed UID, it spawns a **worker** process via `systemd-run`
3. Each **worker** creates its own per-user socket at `/run/user/<uid>/net-porter.sock`
4. Workers handle all CNI operations in the host namespace
5. Workers run as instantiated systemd services (`net-porter-worker@<uid>.service`) with strict security hardening

Workers survive server crashes — the server only manages their lifecycle (spawn/stop/restart), it does NOT kill workers on its own shutdown.

### Security Hardening

Both the server and worker services are hardened via systemd unit directives:

**Server (`net-porter.service`):**
- Minimal capabilities: `CAP_SYS_PTRACE` only
- `NoNewPrivileges=true`
- `RestrictNamespaces=yes`
- Syscall filtering

**Worker (`net-porter-worker@<uid>.service`):**
- Read-only filesystem (except `/run/user/<uid>/` and `/run/net-porter/workers/<uid>/`)
- Restricted capabilities: `CAP_NET_ADMIN`, `CAP_NET_RAW`, `CAP_SYS_ADMIN`, `CAP_SYS_PTRACE`, `CAP_DAC_OVERRIDE`, `CAP_CHOWN`, `CAP_FOWNER`
- Namespace restriction: only `CLONE_NEWNET` allowed
- Syscall filtering

### New Files and Directories

| Path | Description |
|------|-------------|
| `/usr/lib/systemd/system/net-porter-worker@.service` | Worker systemd template (installed by package) |
| `/run/net-porter/workers/<uid>/` | Worker state directory (mode 0700, root-only) |
| `/run/net-porter/workers/<uid>/worker.env` | Worker environment file (created at runtime) |

## Troubleshooting

### Worker not starting

**Symptom**: No socket created at `/run/user/<uid>/net-porter.sock`

**Steps**:
1. Check server logs: `journalctl -u net-porter -f`
2. Verify the user has an ACL file in `/etc/net-porter/acl.d/` (e.g., `alice.json`)
3. Verify the user has an active login session (`/run/user/<uid>/` must exist, created by `systemd-logind`)
4. Check worker service status: `systemctl status net-porter-worker@<uid>`

### Permission denied after upgrade

**Symptom**: `Access denied for uid=1000`

**Steps**:
1. Verify the ACL file exists: `ls /etc/net-porter/acl.d/alice.json`
2. The filename must match the username (without `.json` suffix)
3. Old `user`/`group` fields are silently ignored — identity comes from filename

### Rule collection not applied

**Symptom**: Grants from `@devops.json` not included

**Steps**:
1. Verify the file is named with `@` prefix: `ls /etc/net-porter/acl.d/@devops.json`
2. Verify the user's ACL file references it: `"groups": ["devops"]` (without `@`)
3. The `groups` field references the collection name (the part after `@`)

### Old group ACL file not loaded

**Symptom**: A file like `devops.json` (without `@` prefix) is being treated as a user ACL

**Explanation**: In v1.0.0, files without `@` prefix are treated as user ACLs (the username is the filename). Rename group files to `@<name>.json`.
