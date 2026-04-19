# 迁移指南：0.6 → 1.0

1.0.0 版本引入了每 UID Worker 架构和重大安全改进。服务端现在为每个允许的用户派生独立的 Worker 进程，而非直接处理连接。ACL 文件格式也发生了变更。

## 变更概览

| 旧版 (0.6) | 新版 (1.0) |
|---|---|
| 服务端直接处理所有连接 | 服务端通过 `systemd-run` 派生每 UID Worker 进程 |
| ACL 身份通过 `user`/`group` 字段识别 | ACL 身份通过文件名识别（`<用户名>.json` / `@<名称>.json`） |
| 无共享规则集合 | 新增 `groups` 字段引用 `@<名称>.json` 规则集合 |
| 组文件命名为 `devops.json` | 组文件重命名为 `@devops.json` |
| Worker 状态在 `/run/user/<uid>/` | Worker 状态在 root 专用的 `/run/net-porter/workers/<uid>/` |
| 使用 `nsenter` 进入命名空间 | 通过 `/proc/<catatonit_pid>/root/` 解析 netns |
| — | 新增 `net-porter-worker@.service` systemd 模板 |

## 分步迁移

### 步骤 1：重命名规则集合文件

如果你有共享的 ACL 文件（如 `devops.json`），需要将它们重命名为带 `@` 前缀的格式：

```bash
# 示例：重命名组 ACL 文件
mv /etc/net-porter/acl.d/devops.json /etc/net-porter/acl.d/@devops.json
mv /etc/net-porter/acl.d/admins.json /etc/net-porter/acl.d/@admins.json
```

> **注意**：`@` 前缀用于区分规则集合文件和用户 ACL 文件。用户文件保持不变（如 `alice.json` 不变）。

### 步骤 2：更新 ACL 文件格式

从 ACL 文件中删除 `user` 和 `group` 字段。这些字段会被静默忽略以保持向后兼容，因此此步骤是可选的，但建议执行以保持清晰。

**迁移前（0.6）：**

```json
{
  "user": "alice",
  "grants": [
    { "resource": "macvlan-dhcp" }
  ]
}
```

**迁移后（1.0）：**

```json
{
  "grants": [
    { "resource": "macvlan-dhcp" }
  ]
}
```

如果要引用共享的规则集合，添加 `groups` 字段：

```json
{
  "grants": [
    { "resource": "macvlan-dhcp" }
  ],
  "groups": ["devops"]
}
```

这会将 `@devops.json` 中的所有授权引入 alice 的有效权限中。

### 步骤 3：安装新版本

像往常一样安装 1.0.0 包（deb、rpm 或 archlinux）。新的 `net-porter-worker@.service` 模板会自动安装。

### 步骤 4：重新加载 systemd 并重启服务

```bash
systemctl daemon-reload
systemctl restart net-porter
```

确认服务正在运行：

```bash
systemctl status net-porter
```

你应该能在日志中看到为每个允许的用户派生 Worker 的消息：

```bash
journalctl -u net-porter -f
```

### 步骤 5：验证 Worker 服务

检查 Worker 服务是否在运行：

```bash
systemctl list-units 'net-porter-worker@*'
```

每个允许的用户应该有一个活跃的 Worker 实例。

## 不变的部分

- **CNI 配置**（`cni.d/` 目录）：无需任何更改，标准 CNI 1.0 配置文件继续按原有方式工作。
- **`config.json` 服务端设置**：无需任何更改，所有服务端级选项保持不变。
- **Podman 网络设置**：`net_porter_resource` 和 `net_porter_socket` 选项不变 —— podman 命令无需修改。
- **ACL 授权中的静态 IP 范围**：继续与静态 IPAM 资源配合使用。
- **ACL 热重载**：用户 ACL 文件继续通过 inotify 被监听变更。

## 新架构详情

### 每 UID Worker 架构

在 v1.0.0 中，服务端不再直接处理容器网络请求。取而代之的是：

1. **服务端** 扫描 `acl.d/` 将允许的用户名解析为 UID
2. 对每个允许的 UID，通过 `systemd-run` 派生一个 **Worker** 进程
3. 每个 **Worker** 在 `/run/user/<uid>/net-porter.sock` 创建自己的 socket
4. Worker 在宿主命名空间中处理所有 CNI 操作
5. Worker 以实例化的 systemd 服务（`net-porter-worker@<uid>.service`）运行，具备严格的安全加固

Worker 在服务端崩溃后仍能存活 —— 服务端仅管理其生命周期（派生/停止/重启），不会在自己的关闭时终止 Worker。

### 安全加固

服务端和 Worker 服务均通过 systemd unit 指令进行了安全加固：

**服务端（`net-porter.service`）：**
- 最小能力：仅 `CAP_SYS_PTRACE`
- `NoNewPrivileges=true`
- `RestrictNamespaces=yes`
- 系统调用过滤

**Worker（`net-porter-worker@<uid>.service`）：**
- 只读文件系统（`/run/user/<uid>/` 和 `/run/net-porter/workers/<uid>/` 除外）
- 受限能力：`CAP_NET_ADMIN`、`CAP_NET_RAW`、`CAP_SYS_ADMIN`、`CAP_SYS_PTRACE`、`CAP_DAC_OVERRIDE`、`CAP_CHOWN`、`CAP_FOWNER`
- 命名空间限制：仅允许 `CLONE_NEWNET`
- 系统调用过滤

### 新增文件和目录

| 路径 | 说明 |
|------|------|
| `/usr/lib/systemd/system/net-porter-worker@.service` | Worker systemd 模板（由安装包安装） |
| `/run/net-porter/workers/<uid>/` | Worker 状态目录（模式 0700，仅 root 可访问） |
| `/run/net-porter/workers/<uid>/worker.env` | Worker 环境文件（运行时创建） |

## 故障排查

### Worker 未启动

**症状**：`/run/user/<uid>/net-porter.sock` 未创建

**排查**：
1. 查看服务端日志：`journalctl -u net-porter -f`
2. 确认用户在 `/etc/net-porter/acl.d/` 中有 ACL 文件（如 `alice.json`）
3. 确认用户有活跃的登录会话（`/run/user/<uid>/` 必须存在，由 `systemd-logind` 创建）
4. 检查 Worker 服务状态：`systemctl status net-porter-worker@<uid>`

### 升级后权限被拒绝

**症状**：`Access denied for uid=1000`

**排查**：
1. 确认 ACL 文件存在：`ls /etc/net-porter/acl.d/alice.json`
2. 文件名必须与用户名匹配（去掉 `.json` 后缀）
3. 旧的 `user`/`group` 字段会被静默忽略 —— 身份由文件名决定

### 规则集合未生效

**症状**：`@devops.json` 中的授权未包含

**排查**：
1. 确认文件使用了 `@` 前缀：`ls /etc/net-porter/acl.d/@devops.json`
2. 确认用户的 ACL 文件中引用了它：`"groups": ["devops"]`（不带 `@`）
3. `groups` 字段引用的是集合名称（`@` 后面的部分）

### 旧版组 ACL 文件未被加载

**症状**：如 `devops.json`（不带 `@` 前缀）的文件被当作用户 ACL 处理

**说明**：在 v1.0.0 中，不带 `@` 前缀的文件被视为用户 ACL（用户名即文件名）。请将组文件重命名为 `@<名称>.json`。
