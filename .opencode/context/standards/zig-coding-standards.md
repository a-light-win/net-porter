# Zig Coding Standards (0.16.0)

## 规则 1：I/O 模块优先级

```
std.Io → std.posix → std.os.linux
（首选）  （有就用）  （std.posix 没有才用）
```

- **`std.Io`**：所有文件/目录/网络操作。必须传 `io: std.Io` 参数。
- **`std.posix`**：不完整，有就用。
- **`std.os.linux`**：`std.posix` 没有的 POSIX 函数 + Linux 专属功能。
- **`std.fs`**：deprecated，禁止用于操作。常量迁移到 `std.Io`。

## 规则 2：禁止事项

- ❌ `std.fs` 做文件操作（用 `std.Io`）
- ❌ `std.fs.max_path_bytes`（用 `std.Io.Dir.max_path_bytes`）
- ❌ 把 `std.os.linux` 无故替换为 `std.posix`（先确认存在）
- ❌ `std.Io` 调用漏传 `io` 参数
