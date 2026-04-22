# net-porter 安全排查报告

**日期**: 2026-04-22
**项目**: net-porter (Zig netavark plugin)
**Zig版本**: 0.16.0
**测试状态**: 159/159 测试通过

---

## 执行摘要

经过对 `net-porter` 项目全部 32 个 Zig 源文件的系统性安全审查，项目整体安全 posture **良好**，尤其在**路径遍历防护、TOCTOU 防护、netns 安全验证、PID 回收攻击防护**等方面表现出成熟的安全意识。发现 **2 个中危问题** 和 **4 个低危/建议项**，未发现可直接利用的高危远程代码执行或权限提升漏洞。

---

## 1. 内存安全

### 1.1 分配器策略

**状态**: ⚠️ 需改进

项目大量使用 `std.heap.page_allocator` 而非 `std.heap.GeneralPurposeAllocator(GPA)`：
- `src/server/Server.zig:24` — Server 主分配器
- `src/worker/Worker.zig:70` — Worker 主分配器
- `src/worker/AclManager.zig:205` — ACL 解析使用 page_allocator

**风险**: page_allocator 无泄漏检测能力，长期运行的 server/worker 进程中的内存泄漏无法被发现。

**建议**:
```zig
// 生产代码建议使用 GPA
var gpa = std.heap.GeneralPurposeAllocator(.{ .safety = true }){};
defer std.debug.assert(gpa.deinit() == .ok);
const allocator = gpa.allocator();
```

### 1.2 Arena 内存管理

**状态**: ✅ 良好

`ArenaAllocator` 封装正确，`deinit()` 释放 arena 及其内部所有分配。`CniLoader`、`CniManager`、`Attachment` 等模块使用 arena 管理复杂生命周期，减少了 UAF 风险。

### 1.3 defer / errdefer 使用

**状态**: ✅ 良好

关键路径上 defer/errdefer 覆盖率高：
- `Cni.initFromConfig:147` — `errdefer arena.deinit()`
- `StateFile.read:48` — `defer allocator.free(path)`
- `DomainSocket.listen:45` — `errdefer server.deinit(io)`

### 1.4 未初始化内存

**状态**: ⚠️ 发现1处

`src/cni/StateFile.zig:66-70`:
```zig
var seed_bytes: [8]u8 = undefined;
_ = std.os.linux.getrandom(&seed_bytes, seed_bytes.len, 0);
```
`getrandom` 返回值被忽略。若系统调用失败（如内核不支持或 entropy 不足），`seed_bytes` 保持未初始化状态，导致临时文件名可预测。

**建议**:
```zig
const rc = std.os.linux.getrandom(&seed_bytes, seed_bytes.len, 0);
if (rc != 8) return error.Unexpected; // 或回退到其他随机源
```

---

## 2. 输入验证

### 2.1 JSON 解析

**状态**: ✅ 良好

- `ManagedConfig.parseConfig` 设置 `.ignore_unknown_fields = false`，拒绝未知字段
- `CniLoader.loadConfig` 设置 `.ignore_unknown_fields = true`（合理，因为 CNI 配置可能有扩展字段）
- 多处配置设置 `.max_value_len` 或 `.limited()` 限制输入大小

### 2.2 IP 地址解析

**状态**: ⚠️ 发现整数下溢

`src/acl/Acl.zig:140`:
```zig
const zeros_needed = 8 - groups - right_groups;
```

若输入类似 `a:a:a:a:a:a:a:a::1`（8个组 + `::` + 后缀），`groups + right_groups > 8` 导致 `u32` 下溢。

**影响分析**:
- Debug/ReleaseSafe: panic（安全，但可用性影响）
- ReleaseFast: 回绕为极大值，后续 `zeros_needed > 8` 检查触发 `InvalidIp`（逻辑正确但依赖副作用）

**建议**（显式饱和检查）:
```zig
if (groups + right_groups > 8) return error.InvalidIp;
const zeros_needed = 8 - groups - right_groups;
```

### 2.3 CNI 标识符验证

**状态**: ✅ 优秀

`src/worker/Handler.zig:376-389`:
```zig
fn validateCniIdentifier(value: []const u8, field_name: []const u8) !void {
    if (value.len == 0) return error.InvalidParameter;
    if (value.len > 128) return error.InvalidParameter;
    for (value) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '.' => {},
            else => return error.InvalidParameter,
        }
    }
    if (std.mem.indexOf(u8, value, "..") != null) return error.InvalidParameter;
}
```

严格的白名单策略，有效防御路径遍历。

### 2.4 netns 路径验证

**状态**: ✅ 优秀

`validateNetnsPath` 强制前缀 `/run/user/<uid>/netns/`，其中 `uid` 来自 **socket credentials**（`SO_PEERCRED`），而非信任用户输入。文件名使用白名单字符集。

---

## 3. 整数安全

### 3.1 整数溢出

| 位置 | 状态 | 说明 |
|------|------|------|
| `Acl.parseIpv4ToInt` | ✅ | `parseUnsigned(u8, ...)` 限制字节值 |
| `Acl.parseIpv6ToInt` | ⚠️ | `zeros_needed` 下溢（见 2.2） |
| `WorkerManager.nextRetryTimeoutMs` | ✅ | 显式检查 `remaining_ms > maxInt(i32)` |
| `Server.run` | ✅ | `total_fds > poll_buf.len` 边界检查 |

### 3.2 除零检查

**状态**: ✅ 未发现除零风险

---

## 4. 错误处理

### 4.1 危险 unwrap

**状态**: ⚠️ 2处

`src/plugin/NetavarkPlugin.zig`:
```zig
pub fn resource(self: Request) []const u8 {
    return self.network().options.resolveResource() catch unreachable;
}

pub fn requestExec(self: Request) NetworkPluginExec {
    return switch (self.request) {
        .network => unreachable,  // 💥
        .exec => |net_exec| net_exec,
    };
}
```

**缓解**: `Handler.zig:104-119` 已在上游添加 action/request 一致性校验，阻止恶意 JSON 到达这些路径。

**建议**: 即使上游有防护，将 `unreachable` 替换为安全错误返回，防止未来代码重构引入漏洞：
```zig
.network => {
    log.err("requestExec called on network request");
    return error.InvalidRequest;
}
```

### 4.2 静默错误忽略

**状态**: ⚠️ 多处

```zig
// AclScanner.zig:43
while (iter.next(io) catch null) |entry| { ... }

// AclManager.zig:56, 176, 177
... catch continue;
```

目录迭代或 ACL 加载失败时静默跳过，可能导致安全策略未生效。

**建议**: 至少记录错误日志，关键路径考虑返回错误而非继续。

---

## 5. 并发安全

### 5.1 Mutex 使用

**状态**: ✅ 良好

- `Cni.mutex` — 保护 setup/teardown 串行化
- `WorkerManager.mutex` — 保护 workers map / pending list
- `AclManager.mutex` — 保护 ACL 热重载

### 5.2 数据竞争

**状态**: ✅ 未发现明显数据竞争

`UidTracker.processInotifyEvents` 中的 `event_buf` 由调用者提供（栈缓冲区），无跨线程共享风险。

### 5.3 资源限制

**状态**: ✅ 良好

`Worker.zig:159-165`:
```zig
if (self.active_handlers.fetchAdd(1, .acquire) >= max_concurrent_handlers) {
    _ = self.active_handlers.fetchSub(1, .release);
    conn_stream.close(io);
    continue;
}
```

限制最大并发 handler 数量为 64，防止资源耗尽攻击。

---

## 6. 文件系统安全

### 6.1 权限设置

**状态**: ✅ 优秀

| 资源 | 权限 | 位置 |
|------|------|------|
| State 目录 | 0700 | `StateFile.ensureDir` |
| State 文件 | 0600 + O_EXCL | `StateFile.writeFileContent` |
| Socket 文件 | 0600, uid=owner | `DomainSocket.listen` |
| Worker env 文件 | 0600 | `WorkerManager.writeEnvFile` |

### 6.2 TOCTOU 防护

**状态**: ✅ 优秀

- `DomainSocket.listen`: bind 前后两次 `isSymlink()` 检查 + `fchownat(AT_SYMLINK_NOFOLLOW)`
- `StateFile.write`: `O_CREAT | O_EXCL` 原子创建，防止 symlink 跟随
- `Handler.verifyNetnsNsfs`: `statx(AT_SYMLINK_NOFOLLOW)` 拒绝 symlink

### 6.3 路径遍历防护

**状态**: ✅ 优秀

- CNI plugin type: 拒绝 `"/"` 和 `".."` (`CniLoader:116-121`, `Attachment:300-301`)
- Group name: 白名单 `[a-zA-Z0-9\-_]`，长度 ≤ 64 (`AclManager:285-294`)
- Resource name: 白名单 `[a-zA-Z0-9\-_.]`，长度 ≤ 128 (`Handler:376-389`)

---

## 7. 网络与进程安全

### 7.1 PID 回收攻击防护

**状态**: ✅ 优秀

`Handler.verifyCatatonitProcess` 执行双重验证：
1. `statx(/proc/<pid>, UID)` — 确认进程 UID 匹配
2. `read(/proc/<pid>/comm)` — 确认进程名仍为 `"catatonit"`

有效防止 catatonit 死亡后 PID 被其他用户进程重用导致的 `/proc/<pid>/root/` 解析错误。

### 7.2 netns 验证

**状态**: ✅ 优秀

`Handler.verifyNetnsNsfs` 验证：
- `statx(AT_SYMLINK_NOFOLLOW)` — 拒绝 symlink
- `dev_major == 0 && dev_minor == 4` — 确认是 nsfs 设备

**注意**: 代码注释已明确说明存在 TOCTOU 窗口（检查与 CNI 插件 open 之间），但认为利用难度高且 CNI 插件会做二次验证。这是合理的风险接受。

### 7.3 Socket 认证

**状态**: ✅ 良好

`Handler.authClient` 双重检查：
1. `SO_PEERCRED` 获取 socket 对端 UID
2. 比对 worker 目标 UID
3. 检查 ACL 权限

即使 socket 权限（0600）被绕过（如 `CAP_DAC_OVERRIDE`），显式 UID 校验提供 defense-in-depth。

---

## 8. 依赖与构建安全

### 8.1 依赖锁定

**状态**: ✅ 良好

`build.zig.zon`:
```zig
.cli = .{
    .url = "git+https://github.com/sam701/zig-cli#4841cdaed94b920c91ea171beed159976264270a",
    .hash = "cli-0.10.0-2eKe_1sIAQDecE0Bz5gAm7aLcWz5wBAc8KxlP1YQPEWr",
},
```

使用固定 git commit hash 和 package hash，防止供应链攻击。

### 8.2 构建脚本

**状态**: ✅ 安全

`build.zig` 中 `kcov` / `rm` 仅用于测试覆盖率步骤（`zig build cover`），不影响生产构建。

### 8.3 优化模式

**状态**: ⚠️ 建议

`build.zig:36`:
```zig
const optimize = b.standardOptimizeOption(.{});
```

未默认使用 `ReleaseSafe`。对于涉及网络配置和进程管理的系统组件，建议：
```zig
const optimize = b.standardOptimizeOption(.{
    .preferred_optimize_mode = .ReleaseSafe,
});
```

---

## 9. 问题汇总与修复优先级

| 优先级 | 问题 | 文件 | 修复建议 |
|--------|------|------|----------|
| **P1** | `getrandom` 返回值被忽略，临时文件种子可能未初始化 | `StateFile.zig:68` | 检查返回值，失败时返回错误 |
| **P1** | IPv6 解析 `u32` 下溢 | `Acl.zig:140` | 添加前置检查 `groups + right_groups > 8` |
| **P2** | 全局使用 `page_allocator`，无泄漏检测 | 多处 | 生产环境使用 `GeneralPurposeAllocator` |
| **P2** | `catch null` / `catch continue` 静默忽略错误 | `AclScanner`, `AclManager` | 记录错误日志，关键路径返回错误 |
| **P3** | `Request.resource()` / `requestExec()` 使用 `unreachable` | `NetavarkPlugin.zig:183,192` | 替换为安全错误返回 |
| **P3** | 未默认使用 `ReleaseSafe` | `build.zig:36` | 设置默认优化模式为 `ReleaseSafe` |

---

## 10. 安全亮点

以下实践值得肯定和维护：

1. **多层 netns 验证**: 路径格式 → catatonit 存活 + UID + comm → nsfs 设备类型
2. **Symlink TOCTOU 防护**: DomainSocket / StateFile / verifyNetnsNsfs 均使用 `AT_SYMLINK_NOFOLLOW`
3. **原子文件写入**: StateFile 使用 temp + rename 模式，O_EXCL 防止覆盖
4. **PID 回收防护**: verifyCatatonitProcess 的 statx + comm 双重验证
5. **CNI 标识符白名单**: 严格的字符集和长度限制
6. **资源限制**: 并发 handler 限制、配置大小限制、请求大小限制
7. **错误传播设计**: Handler.handle() 中几乎每个失败点都返回错误给客户端而非 panic
8. **测试覆盖安全场景**: 包含 action/request 一致性攻击、symlink 拒绝、路径遍历拒绝等测试用例

---

*报告生成完成。建议在修复 P1/P2 问题后重新运行 `zig build test` 验证。*
