# Netns Resolution Security Analysis

## Architecture Overview

### Previous Approach (mount namespace snapshot)

```
Worker startup:
  setns(catatonit mount ns) → unshare(CLONE_NEWNS) → mount --make-rslave /
  → bind mount CNI plugin dir read-only
  → bind mount ACL dir read-only

CNI_NETNS = /run/user/<uid>/netns/<name>
(resolved inside worker's mount namespace snapshot)
```

Security properties:
- Worker takes a **snapshot** of catatonit's mount namespace at startup
- Container user cannot affect the snapshot after `unshare` + `rslave`
- CNI plugin dir and ACL dir are bind-mounted read-only (anti-tampering)
- Changes in catatonit's namespace do NOT propagate back to the worker

### Current Approach (/proc/pid/root/ traversal)

```
Worker stays in host namespace (no setns, no unshare).

Per-request:
  CNI_NETNS = /proc/<catatonit_pid>/root/run/user/<uid>/netns/<name>
  (resolved through catatonit's mount namespace via /proc)

Defense-in-depth:
  verifyNetnsNsfs(CNI_NETNS) → statx(AT_SYMLINK_NOFOLLOW) + device 0:4 check
```

Security properties:
- Worker never enters mount namespace (simpler, less privilege required)
- `/proc/<pid>/root/` provides live view of catatonit's mount namespace
- statx pre-check validates the target is an nsfs file before passing to CNI
- No read-only bind mount protection for CNI plugin dir / ACL dir

## Attack Surface Comparison

### 1. CNI Plugin Binary Replacement

| | Previous | Current |
|---|---|---|
| Protection | ro bind mount | Host directory permissions |
| Risk | None (ro bind mount) | None (root-owned host directory) |

**Verdict: No regression.** CNI plugin dir (e.g., `/opt/cni/bin`) is root-owned on the host.
Container user cannot write to it. The ro bind mount was defense-in-depth for a scenario
that doesn't exist in practice.

### 2. ACL File Injection (hot-reload privilege escalation)

| | Previous | Current |
|---|---|---|
| Protection | ro bind mount | Host directory permissions |
| Risk | None (ro bind mount) | None (root-owned host directory) |

**Verdict: No regression.** ACL dir (e.g., `/etc/net-porter/acl.d`) is root-owned.
Container user cannot write malicious ACL files. Inotify hot-reload is safe.

### 3. CNI Plugin Filesystem Visibility

| | Previous | Current |
|---|---|---|
| Scope | Container rootfs + ro host dirs | Full host filesystem |

**Verdict: No material regression.** CNI plugins are admin-installed trusted code running
as root. A root process can always access host resources via `/proc/*/root/` regardless
of mount namespace. The namespace boundary is not a security boundary for root processes.

### 4. Netns Symlink Race (primary new attack surface)

| | Previous | Current |
|---|---|---|
| Snapshot | Startup snapshot, immutable after | Live view, per-request |
| Symlink attack | Blocked by snapshot | Mitigated by verifyNetnsNsfs |

**Attack scenario:**
1. Container user (has CAP_SYS_ADMIN in user namespace) unmounts nsfs at
   `/run/user/<uid>/netns/<name>` inside their mount namespace
2. Creates symlink: `/run/user/<uid>/netns/<name>` → `/proc/1/ns/net`
3. Worker constructs `/proc/<catatonit_pid>/root/run/user/<uid>/netns/<name>`
4. CNI plugin follows symlink to a different netns

**Why this is LOW risk:**
- Rootless containers have independent PID namespaces → `/proc/1/ns/net` is the
  container's own init netns, NOT the host's
- Mount namespace isolation → other users' netns paths are unreachable
- `verifyNetnsNsfs()` uses statx with AT_SYMLINK_NOFOLLOW:
  - Symlinks: statx returns the symlink's own filesystem metadata (device of the
    directory where the symlink lives, e.g., tmpfs 0:160), not the target's (nsfs 0:4)
    → caught by device check
  - Regular files replaced into the mount point: must be on nsfs (device 0:4) to pass
- CNI plugin's `setns()` validates the fd is actually a netns → fails with EINVAL on
  non-netns files
- Cross-user escalation is impossible due to namespace isolation

**Residual TOCTOU window:**
There is a time-of-check-to-time-of-use gap between `verifyNetnsNsfs()` and the CNI
plugin's `open()`. This is accepted because:
1. The attacker needs CAP_SYS_ADMIN + exact timing
2. Namespace isolation limits the attack target to the container's own resources
3. No meaningful privilege escalation is achievable within these constraints

### 5. PID Recycling

If catatonit dies and its PID is recycled to a new process, `/proc/<old_pid>/root/`
would resolve to the new process's root filesystem.

**Mitigation: per-request `verifyCatatonitProcess()`**

Before each setup/teardown request that uses the catatonit PID, the handler verifies:
1. `/proc/<pid>` exists and is owned by the caller's UID (statx UID check)
2. `/proc/<pid>/comm` contains "catatonit" (not a recycled process)

If either check fails, the request is rejected with "Network namespace unavailable".

**Combined with WorkerManager pidfd monitoring:**
- WorkerManager monitors catatonit via pidfd → immediate worker stop on exit
- `verifyCatatonitProcess()` catches any race between pidfd event and handler stop
- Even if pidfd notification is delayed, per-request verification prevents misuse

**Risk: Negligible.** Two-layer protection (pidfd + per-request verification) makes
PID recycling attacks impractical.

### 6. DHCP Socket Path

**Verdict: No regression.** DHCP daemon socket (`/run/user/<uid>/net-porter-dhcp.sock`)
is created by the worker in the host namespace. CNI dhcp plugin connects from host
namespace. No namespace traversal involved.

## Summary

| Attack Surface | Risk Level | Notes |
|---|---|---|
| CNI binary replacement | None | Host dir, root-owned |
| ACL injection | None | Host dir, root-owned |
| Plugin filesystem scope | None | Root processes bypass mount ns |
| **Netns symlink race** | **Low** | **Namespace isolation + statx pre-check** |
| PID recycling | Negligible | **pidfd + per-request verifyCatatonitProcess()** |
| DHCP socket | None | Same namespace |

The only new attack surface is the netns symlink race (item 4), which is mitigated to
LOW risk by:
1. `verifyCatatonitProcess()` per-request — confirms PID is still catatonit and owned
   by the correct UID before using it for path resolution
2. `verifyNetnsNsfs()` statx pre-check (AT_SYMLINK_NOFOLLOW + device 0:4)
3. PID namespace isolation (prevents cross-container targeting)
4. Mount namespace isolation (prevents cross-user targeting)
5. CNI plugin `setns()` validation (rejects non-netns fds)

## Defense-in-Depth Layers

```
Request arrives (socket credentials: uid, pid verified)
  │
  ├─ verifyCatatonitProcess(catatonit_pid, caller_uid)
  │   ├─ statx /proc/<pid> → check UID matches caller
  │   └─ read /proc/<pid>/comm → check "catatonit"
  │
  ├─ validateNetnsPath(netns, caller_uid)
  │   └─ Must match /run/user/<uid>/netns/<safe_name>
  │
  ├─ resolve: /proc/<catatonit_pid>/root/<netns>
  │
  ├─ verifyNetnsNsfs(resolved_path)
  │   └─ statx AT_SYMLINK_NOFOLLOW → device must be 0:4 (nsfs)
  │
  └─ CNI plugin exec
      └─ setns(fd, CLONE_NEWNET) → kernel validates fd is netns
```

## Decision Record

- **Accepted**: Remove mount namespace snapshot in favor of `/proc/pid/root/` traversal
- **Rationale**: Significant simplification (no setns/unshare/bind-mount) with no
  material security regression in rootless container environments
- **Mitigation**: `verifyCatatonitProcess()` + `verifyNetnsNsfs()` pre-checks as defense-in-depth
- **Residual risk**: TOCTOU between pre-check and CNI plugin open — accepted as
  impractical to exploit within namespace isolation constraints
