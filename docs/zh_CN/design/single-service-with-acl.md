# 单服务 + ACL 方案设计

> 状态：实施中
> 版本：基于 v0.4.0-rc.1

## 1. 背景与动机

当前 net-porter 通过 systemd 模板 `net-porter@<uid>.service` 为每个用户提供独立的服务实例。当用户数量增多时：

- 每个用户占用一个 root 进程，资源开销线性增长
- 运维需要为每个用户单独管理服务实例
- systemd 服务列表膨胀

本方案将多服务实例合并为单一服务，通过 ACL 保障安全等价。

## 2. 安全分析

### 2.1 当前安全架构（三层纵深防御）

| 防线 | 机制 | 代码位置 |
|------|------|---------|
| L1 OS 级隔离 | Socket 文件 `0o660` + `fchownat` 属主为 UID | `DomainSocket.zig:81-94` |
| L2 服务级硬门 | `accepted_uid` 精确匹配 | `AclManager.zig:46` |
| L3 资源级 ACL | per-resource `allow_users` / `allow_groups` | `Acl.zig:38-50` |
| 附加 命名空间验证 | `checkNetns()` 验证 netns 文件属主 | `Handler.zig:198-215` |

### 2.2 方案 B：单服务 + Socket 前置过滤

合并后，L1 和 L2 发生变化，L3 和命名空间验证保持不变：

```
Socket: /run/net-porter.sock (root:net-porter, mode 0660)

连接建立时：
  1. SO_PEERCRED → 获取真实 uid/gid（不可伪造）
  2. 遍历所有 resource 的 ACL，检查该 uid 是否在任何 resource 中有权限
     → 无任何权限：立即断开连接（前置过滤）
     → 有权限：继续处理请求
  3. Resource 级 ACL 检查（per-request）
  4. Netns 归属验证（per-request）
```

### 2.3 安全保障点

- **身份不可伪造**：`SO_PEERCRED` 是内核级机制
- **默认拒绝**：`Acl.isAllowed()` 在无 `allow_users`/`allow_groups` 时返回 `false`
- **启动时校验**：无 ACL 配置的 resource 将导致服务拒绝启动
- **命名空间验证**：`checkNetns()` 不受架构变更影响
- **Socket 组权限**：只有 `net-porter` 组的用户才能连接（额外的 OS 级门控）

## 3. 架构变更

### 3.1 整体对比

```
改造前：
  net-porter@1000.service → DhcpService(1000) + AclManager(1000) + CniManager
  net-porter@1001.service → DhcpService(1001) + AclManager(1001) + CniManager
  net-porter@1002.service → DhcpService(1002) + AclManager(1002) + CniManager

改造后：
  net-porter.service → DhcpManager → {DhcpService(1000), DhcpService(1001), DhcpService(1002)}
                     + AclManager (全局，无 accepted_uid)
                     + CniManager (共享)
```

### 3.2 CNI 为什么可以共享

CNI 不需要 per-UID：

- **CNI config**：网络拓扑定义（如 macvlan 配置），所有用户共享同一物理网络
- **Attachment key**：`(container_id, ifname)` 是 podman 生成的全局唯一 ID，不冲突
- **CNI 执行**：`nsenter -t <pid> --mount` 中的 PID 来自请求，天然 per-request
- **DHCP socket 注入**：`setDhcpSocketPath(request.user_id)` 已按请求动态设置

### 3.3 DHCP 为什么必须 per-UID

DHCP daemon 通过 `nsenter -t <catatonit_pid> --mount` 进入用户的 podman infra 容器 namespace。每个用户有独立的 catatonit 进程，DHCP daemon 无法共享。

## 4. 组件改动清单

### 4.1 新增组件

#### `DhcpManager` (`src/cni/DhcpManager.zig`)

per-UID DHCP 实例管理器，惰性创建 + 自动重启：

```
DhcpManager
  ├── allocator: Allocator
  ├── cni_plugin_dir: []const u8
  ├── mutex: Thread.Mutex
  └── services: HashMap(u32, *DhcpService)
        ├── 1000 → DhcpService(uid=1000)
        ├── 1001 → DhcpService(uid=1001)
        └── ...
```

生命周期策略：**健康检查 + 惰性重启**
- 不主动停止 DHCP daemon
- `DhcpService.ensureStarted()` 内置 `isAlive()` 检查，daemon 死亡时自动重启
- 用户停止所有容器后，catatonit 退出 → namespace 消失 → daemon 自动死亡
- 服务关闭时统一清理所有实例

### 4.2 修改组件

| 组件 | 改动 | 说明 |
|------|------|------|
| `AclManager.zig` | 去掉 `accepted_uid` 字段和硬门检查 | 第一行 `uid != accepted_uid` 删除，改为全局 ACL 匹配 |
| `Acl.zig` | 增加 `hasAnyAllow()` 方法 | 启动时校验：无 ACL 的 resource 拒绝加载 |
| `DhcpService.zig` | 修复 PID 缓存过期 bug | `start()` 中每次重新获取 catatonit PID |
| `Server.zig` | 使用 `DhcpManager` 替代 `DhcpService` | `Opts` 去掉 `uid` 字段 |
| `Handler.zig` | 传递 `caller_uid` 到 `execAction` | `dhcp_manager.ensureStarted(uid)` |
| `server.zig` (CLI) | 去掉 `--uid` 选项 | 不再需要 |
| `DomainSocket.zig` | 默认路径改为全局 + 组权限 | `/run/net-porter.sock`，group 权限 |
| `Config.zig` | `postInit` 去掉 `accepted_uid` 参数 | 配置不再绑定 UID |
| `ManagedConfig.zig` | `load` 去掉 `uid` 参数 | 同上 |

### 4.3 基础设施变更

| 文件 | 变更 |
|------|------|
| `net-porter@.service` → `net-porter.service` | 去掉模板参数 `%i`，单实例服务 |
| `nfpm.yaml` | 更新 service 文件名，增加 `net-porter` 组创建 |

## 5. 配置变更

### 5.1 domain_socket 配置

```json
{
  "domain_socket": {
    "path": "/run/net-porter.sock",
    "group": "net-porter",
    "mode": "0660"
  }
}
```

### 5.2 resources 配置（强制 ACL）

```json
{
  "resources": [
    {
      "name": "vlan-100",
      "allow_users": ["alice", "bob"],
      "allow_groups": ["netdev"]
    },
    {
      "name": "vlan-200",
      "allow_users": ["charlie"]
    }
  ]
}
```

**重要**：每个 resource 必须配置 `allow_users` 或 `allow_groups` 中的至少一个。否则服务启动时将报错拒绝加载。

## 6. 数据流

```
podman (任意用户)
  └── netavark → net-porter plugin (rootless)
                    │
                    └── connect /run/net-porter.sock
                          │
                    ┌─────▼─────────────────────────────────────┐
                    │ net-porter.service (root, single instance) │
                    │                                            │
                    │ 1. SO_PEERCRED → uid/gid (不可伪造)       │
                    │                                            │
                    │ 2. Socket 前置过滤：                       │
                    │    该 uid 是否在任何 resource ACL 中？      │
                    │    → 否：断开连接                           │
                    │    → 是：继续                               │
                    │                                            │
                    │ 3. Resource ACL：                          │
                    │    该 uid 是否有该 resource 的权限？        │
                    │    → 否：AccessDenied                      │
                    │                                            │
                    │ 4. Netns 归属：                            │
                    │    netns 文件属主 == uid？                  │
                    │    → 否：AccessDenied                      │
                    │                                            │
                    │ 5. DhcpManager.ensureStarted(uid)          │
                    │    → 惰性创建 per-UID DHCP daemon          │
                    │                                            │
                    │ 6. CNI 执行 (共享)                         │
                    │    → nsenter into container namespace      │
                    └────────────────────────────────────────────┘
```

## 7. 回滚方案

保留 `net-porter@.service` 模板不删除（重命名为 `net-porter@.service.example`）。如需回滚：

1. 恢复使用模板服务
2. 恢复 `--uid` CLI 参数
3. 恢复 `accepted_uid` 硬门
4. 恢复 per-UID socket 路径
