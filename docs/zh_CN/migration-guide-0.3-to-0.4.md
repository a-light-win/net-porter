# 迁移指南：0.3 → 0.4

本指南将帮助你从 net-porter 0.3.x 升级到 0.4.0。

## 破坏性变更概览

| 领域 | 0.3.x | 0.4.0 |
|------|-------|-------|
| 服务模型 | 每用户独立服务：`net-porter@<uid>.service` | 单一全局服务：`net-porter.service` |
| Socket | `domain_socket` 配置段（可配置路径、属主、权限） | 每用户自动管理：`/run/user/<uid>/net-porter.sock` |
| CNI 配置 | `cni_dir` 指向的目录中的独立文件 | 在 resource 定义中内联配置 |
| ACL | 扁平的 `allow_users` / `allow_groups` 数组 | 结构化的 `acl` grant 数组 |
| IPAM | 不可配置（仅 DHCP） | Tagged union：`dhcp` 或 `static` |
| 用户声明 | 通过 systemd 模板 `@<uid>` 隐式指定 | 顶层 `users` 数组显式声明 |
| CLI | 需要 `--uid` 参数 | 无需 `--uid` 参数 |
| 构建 | Zig 0.14.x | Zig >= 0.16.0 |

## 分步迁移

### 1. 停止现有服务

```bash
# 停止并禁用所有每用户服务实例
systemctl stop 'net-porter@*'
systemctl disable 'net-porter@*'
```

### 2. 安装新版本

像往常一样安装 0.4.0 包（deb、rpm 或 archlinux）。

### 3. 重写配置

配置格式发生了重大变化。以下是逐字段的迁移指南。

#### 3.1 移除 `domain_socket` 和 `cni_dir` 配置段

**0.3.x：**
```json
{
  "domain_socket": {
    "path": "/run/user/1000/net-porter.sock",
    "uid": 1000
  },
  "cni_dir": "/etc/net-porter/cni.d"
}
```

**0.4.0：** 完全移除这两个字段。Socket 路径现在从 `users` 字段自动派生，CNI 配置现在内联在每个 resource 中（不再从目录读取）。

#### 3.2 新增 `users` 字段

**0.4.0：** 在顶层添加 `users` 数组，列出所有需要 socket 访问的用户。

> **注意**：在 0.3.x 中，每个用户通过各自的 `net-porter@<uid>.service` 实例运行服务（传入 `--uid` 参数）。现在需要在 `users` 数组中列出所有之前通过服务模板运行的用户名或 UID：

```json
{
  "users": ["alice", "bob"]
}
```

支持用户名（字符串）或数字 UID，例如 `["alice", "1001"]`。

#### 3.3 重写 resources

**0.3.x：**
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

**0.4.0：** 每个 resource 现在需要内联的 `interface`、`ipam` 和 `acl` 字段：

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

关键变化：
- `allow_users` → `acl` 数组中的 `{ "user": "alice" }` grant 条目
- `allow_groups` → `acl` 数组中的 `{ "group": "devops" }` grant 条目
- `interface` 为**必填**——之前从 `cni.d/` 文件读取
- `ipam` 为**必填**——选择 `"type": "dhcp"` 或 `"type": "static"`

#### 3.4 移除 CNI 配置目录

删除旧的 CNI 配置目录，其内容不再使用：

```bash
rm -rf /etc/net-porter/cni.d/
```

所有接口和 IPAM 设置现在在每个 resource 中内联定义。

### 4. 完整配置对照

以下是一个真实场景的完整对照，假设之前为两个用户 alice（UID 1000）和 bob（UID 1001）运行了各自的服务实例：

**0.3.x 完整配置：**
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

同时 `cni.d/` 目录下有 `macvlan-dhcp.conflist` 文件定义了 macvlan 接口和 DHCP IPAM。

之前通过以下命令为每个用户启动服务：
```bash
systemctl enable --now net-porter@1000
systemctl enable --now net-porter@1001
```

**0.4.0 对应配置：**
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

原来 `cni.d/macvlan-dhcp.conflist` 中的 macvlan 和 DHCP 配置，现在直接内联到 resource 的 `interface` 和 `ipam` 字段中。

现在只需一条命令启动服务：
```bash
systemctl enable --now net-porter
```

### 5. 完整配置示例

以下是一个完整的 0.4.0 `config.json`，同时展示了 DHCP 和静态 IP 资源：

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

### 6. 启动新服务

```bash
systemctl enable --now net-porter
```

确认服务正在运行：
```bash
systemctl status net-porter
```

### 7. 重建 podman 网络

Socket 路径已变更。删除旧网络并使用新的每用户 socket 路径重新创建：

```bash
# 删除旧网络（以 rootless 用户身份运行）
podman network rm macvlan-net

# 使用每用户 socket 重建
podman network create \
  -d net-porter \
  -o net_porter_resource=macvlan-dhcp \
  -o net_porter_socket=/run/user/$(id -u)/net-porter.sock \
  macvlan-net
```

### 8. 验证

以每个用户身份运行测试容器：
```bash
podman run -it --rm --network macvlan-net alpine ip addr
```

你应该能看到 macvlan 接口及其 IP 地址。

## 常见问题

### 服务启动失败

**错误**：`Resource has no ACL grants`
**解决**：每个 resource 必须至少有一个 `acl` grant 条目。为每个 resource 添加 `acl` 数组。

### 权限被拒绝

**错误**：`Access denied for uid=1000`
**解决**：
- 确认用户在所请求 resource 的 `acl` grant 中有记录。
- 确认用户的 UID 在 `users` 数组中（创建 socket 所需）。

### Socket 未找到

**错误**：`Failed to connect to /run/user/1000/net-porter.sock`
**解决**：
- 确认服务正在运行：`systemctl status net-porter`
- 确认用户在配置的 `users` 数组中。
- 检查用户是否有活跃的登录会话（`/run/user/<uid>/` 必须存在，由 `systemd-logind` 创建）。

### 静态 IP 被拒绝

**错误**：`Static IP x.x.x.x not allowed for user`
**解决**：检查用户 ACL grant 中的 `ips` 范围，确保请求的 IP 在允许的范围内。
