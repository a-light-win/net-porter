# Zig Coding Standards

This document defines coding rules and conventions for the net-porter Zig project.
All agents and contributors **must** follow these standards.

**Target Zig version**: 0.16.0

---

## 1. I/O Module Selection: `std.Io` vs `std.fs` vs `std.posix` vs `std.os.linux`

### Zig 0.16.0 I/O Layer Hierarchy

```
┌──────────────────────────────────────────────────────┐
│  std.Io         高层统一 I/O 模块（首选）              │
│    .Dir           目录操作（已取代 std.fs.Dir）         │
│    .File          文件操作（已取代 std.fs.File）         │
│    .File.Writer   写入器                                │
│    .net           网络操作（已取代 std.net）              │
│    .Mutex         I/O 互斥锁                            │
│    .Timestamp     时间戳                                │
├──────────────────────────────────────────────────────┤
│  std.fs         旧文件系统模块（0.16.0 中仅保留常量）    │
├──────────────────────────────────────────────────────┤
│  std.posix      中层 POSIX 系统调用                     │
├──────────────────────────────────────────────────────┤
│  std.os.linux   底层 Linux 专属 syscall                 │
└──────────────────────────────────────────────────────┘
```

### Rule 1a: Always prefer `std.Io` for file, directory, and network operations

Zig 0.14+ 引入了 `std.Io`（大写 I）统一 I/O 模块，**已取代 `std.fs`** 中的
`Dir`、`File` 等类型，以及 `std.net` 网络模块。

关键 API 变化：**所有 I/O 操作都需要显式传入 `io: std.Io` 参数**。

```zig
// 正确：使用 std.Io（Zig 0.16.0）
var file = try std.Io.Dir.cwd().openFile(io, "data.txt", .{});
var dir = try std.Io.Dir.cwd().openDir(io, "src", .{ .iterate = true });
var writer = std.Io.File.stdout().writer(io, &buffer);

// 错误：使用旧版 std.fs API（已过时）
var file = try std.fs.cwd().openFile("data.txt", .{});
var dir = try std.fs.cwd().openDir("src", .{ .iterate = true });
```

### Rule 1b: Never use `std.fs` for operations (use `std.Io` instead)

`std.fs` 在 0.16.0 中仅保留少量常量，**不得用于文件/目录操作**。

```zig
// 可接受：std.fs 仅用于常量
var buf: [std.fs.max_path_bytes]u8 = undefined;

// 错误：用 std.fs 做文件操作
var dir = try std.fs.cwd().openDir("src", .{});  // ❌ 过时 API
```

### Rule 1c: Always prefer `std.posix` over `std.os.linux`

**Default**: Use `std.posix` for all OS-level operations.

**Exception**: Use `std.os.linux` **only** when you need Linux-specific features
that have no POSIX equivalent.

| | `std.posix` | `std.os.linux` |
|---|---|---|
| **When** | Default choice for all OS operations | Only for Linux-exclusive features |
| **Scope** | Cross-platform (Linux, macOS, BSD) | Linux-only |
| **Style** | Type-safe, Zig-idiomatic | Thin syscall wrappers |

#### When to use `std.posix` (default)

All common OS operations:
- File I/O: `open`, `read`, `write`, `close`, `stat`, `mkdir`
- Networking: `socket`, `bind`, `listen`, `accept`, `connect`, `send`, `recv`
- Processes: `fork`, `execve`, `waitpid`, `pipe`
- Signals: `sigaction`, `kill`
- Memory: `mmap`, `munmap`

#### When `std.os.linux` is acceptable (exceptions)

Linux-exclusive syscalls with **no** POSIX equivalent:
- `epoll` family: `epoll_create1`, `epoll_ctl`, `epoll_wait`
- `io_uring` family: `io_uring_setup`, `io_uring_enter`
- `signalfd`, `timerfd`, `eventfd`
- `bpf` syscall
- `clone` (lower-level than `fork`)

Linux-exclusive flags:
- `O_DIRECT`, `O_NOATIME` (open flags)
- `MAP_LOCKED`, `MAP_HUGETLB` (mmap flags)

### Complete decision flowchart

```
你需要某个 I/O 或 OS 功能
  │
  ├─ std.Io 能做吗？（文件/目录/网络/流式读写）
  │   ├─ 能 → 用 std.Io ✅（最高优先级）
  │   └─ 不能
  │       ├─ std.posix 能做吗？
  │       │   ├─ 能 → 用 std.posix ✅
  │       │   └─ 不能
  │       │       └─ Linux 专属？ → 用 std.os.linux
  │       └─ std.fs 有常量？ → 仅用于常量（如 max_path_bytes）
  │
  └─ 绝对不要：std.fs 做文件操作、std.os.linux 替代 std.posix
```

### Do NOT do this

```zig
// 错误：使用过时的 std.fs API
var file = try std.fs.cwd().openFile("path", .{});

// 错误：把 std.posix 无故替换成 std.os.linux
const fd = std.os.linux.open("/path", std.os.linux.O.RDONLY, 0);

// 错误：忘记传 io 参数
var dir = try std.Io.Dir.cwd().openDir("src", .{});  // 缺少 io 参数
```

### Correct

```zig
// 正确：std.Io + 显式 io 参数
var file = try std.Io.Dir.cwd().openFile(io, "path", .{});
var dir = try std.Io.Dir.cwd().openDir(io, "src", .{ .iterate = true });
const writer = std.Io.File.stdout().writer(io, &buffer);

// 正确：std.posix 用于底层 OS 操作
const fd = try std.posix.open("/path", .{ .ACCMODE = .RDONLY }, 0);
defer std.posix.close(fd);
```

---

## Changelog

- **v3** — 补充 Zig 0.16.0 `std.Io` 统一 I/O 模块说明，修正之前遗漏的
  `std.Io` vs `std.fs` 规则。此前一个 agent 曾把 `std.posix` 错误替换为
  `std.os.linux`，另一次建议中错误推荐了已过时的 `std.fs` API。
