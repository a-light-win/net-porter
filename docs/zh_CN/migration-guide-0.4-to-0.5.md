# 迁移指南：0.4 → 0.5

0.5.0 版本将访问控制从 `config.json` 中的内联 `acl` 字段迁移到了独立的 `acl.d/` 目录。这样无需修改主配置文件即可管理用户/组权限，并且支持 ACL 规则热加载（无需重启服务）。

## 变更概览

| 旧版 (0.4) | 新版 (0.5) |
|---|---|
| ACL 规则内联在每个资源定义中 | ACL 规则存储为 `acl.d/` 目录下的独立文件 |
| `config.json` 中有 `users` 字段列出 socket 用户 | 用户列表从 ACL 文件自动推导 |
| 资源有 `acl` 数组字段 | 资源不再有 `acl` 字段 |
| ACL 变更需要重启服务 | ACL 变更自动生效 |
| 静态 IP 仅支持 IPv4 范围 | 同时支持 IPv4 和 IPv6 范围 |
| 仅支持 macvlan 接口类型 | 同时支持 macvlan 和 ipvlan |

## 配置变更

### 步骤 1：创建 `acl.d/` 目录

```bash
mkdir -p /etc/net-porter/acl.d
```

### 步骤 2：将内联 ACL 转换为独立文件

为每个拥有 ACL 授权的用户或组在 `/etc/net-porter/acl.d/` 中创建一个 JSON 文件。

#### 迁移前（0.4 — 内联在 `config.json` 中）：

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

#### 迁移后（0.5）：

**`/etc/net-porter/config.json`**：

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

**`/etc/net-porter/acl.d/alice.json`**：

```json
{
  "user": "alice",
  "grants": [
    { "resource": "macvlan-dhcp" },
    { "resource": "static-net", "ips": ["192.168.1.10-192.168.1.20"] }
  ]
}
```

**`/etc/net-porter/acl.d/bob.json`**：

```json
{
  "user": "bob",
  "grants": [
    { "resource": "static-net", "ips": ["192.168.1.30-192.168.1.40"] }
  ]
}
```

**`/etc/net-porter/acl.d/devops.json`**：

```json
{
  "group": "devops",
  "grants": [
    { "resource": "macvlan-dhcp" }
  ]
}
```

### 步骤 3：重启服务

```bash
systemctl restart net-porter
```

完成首次重启后，后续的 ACL 变更（在 `acl.d/` 中增删改文件）将自动生效，无需再次重启。

## ACL 文件格式

`acl.d/` 中的每个文件必须是 `.json` 后缀，结构如下：

```json
{
  "user": "<用户名或 UID>",
  "group": "<组名或 GID>",
  "grants": [
    { "resource": "<资源名称>" },
    { "resource": "<资源名称>", "ips": ["<IP范围>", ...] }
  ]
}
```

| 字段 | 说明 | 必填 |
|------|------|------|
| `user` | 用户名或数字 UID | `user` 或 `group` 二选一 |
| `group` | 组名或数字 GID | `user` 或 `group` 二选一 |
| `grants` | 资源授权数组 | 是 |
| `grants[].resource` | 资源名称（须与 `config.json` 中的资源匹配） | 是 |
| `grants[].ips` | 允许的 IP 范围或单个 IP 数组（用于静态 IP 资源） | 静态资源：是 |

**IP 范围格式**（现在支持 IPv6）：
- 单个 IPv4：`"192.168.1.30"`
- IPv4 范围：`"192.168.1.10-192.168.1.20"`
- 单个 IPv6：`"2001:db8::1"`
- IPv6 范围：`"2001:db8::1-2001:db8::ff"`

### 文件命名

文件可以随意命名（只要以 `.json` 结尾）。常见做法是使用用户名或组名，如 `alice.json`、`devops.json`。非 `.json` 文件会被忽略。

### 同时指定用户和组

单个文件可以同时指定 `user` 和 `group`：

```json
{
  "user": "alice",
  "group": "devops",
  "grants": [
    { "resource": "shared-net" }
  ]
}
```

这会同时按 UID 授予 `alice` 权限，以及按 GID 授予 `devops` 组所有成员权限。

### 多用户访问同一资源

多个 ACL 文件可以引用同一资源，授权会自动合并：

```
acl.d/
├── alice.json    → 授权访问 "macvlan-dhcp"
├── bob.json      → 授权访问 "macvlan-dhcp"
└── devops.json   → 授权访问 "macvlan-dhcp"
```

## 迁移后可用的新功能

### 热加载

迁移到 `acl.d/` 目录后，可以无需重启管理 ACL：

```bash
# 添加新用户
cp /path/to/newuser.json /etc/net-porter/acl.d/

# 移除用户权限
rm /etc/net-porter/acl.d/olduser.json

# 修改权限
vim /etc/net-porter/acl.d/alice.json
```

变更会自动检测并生效。

### IPv6 静态 IP 范围

现在可以在 IP 范围中使用 IPv6 地址：

```json
{
  "user": "alice",
  "grants": [
    { "resource": "ipv6-net", "ips": ["2001:db8::10-2001:db8::ff"] }
  ]
}
```

### IPvlan 接口类型

现在可以使用 `ipvlan` 作为接口类型（L3/L3s 模式需要使用静态 IP）：

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
