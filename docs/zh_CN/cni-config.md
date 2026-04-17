# CNI 配置指南

> 版本：v0.6.0+

net-porter 通过 `/etc/net-porter/cni.d/` 目录管理 CNI 网络配置，支持标准 CNI 1.0 格式（包括链式插件）。

## 标准CNI配置

### 目录结构

CNI 配置文件放在 `/etc/net-porter/cni.d/` 目录下，安装包会自动创建此目录。

```
/etc/net-porter/cni.d/
├── 10-macvlan-dhcp.conflist
├── 20-macvlan-static.conf
└── 30-ipvlan-l3.conflist
```

### 文件格式

支持标准 CNI 1.0 规范的两种格式：

- **`.conf`** — 单插件配置
- **`.conflist`** — 多插件配置（支持链式插件）

非 `.conf` 或 `.conflist` 后缀的文件会被忽略（如 `.example` 后缀的文件不会加载）。

### 单插件配置（.conf）

```json
{
  "cniVersion": "1.0.0",
  "name": "macvlan-dhcp",
  "type": "macvlan",
  "master": "eth0",
  "ipam": {
    "type": "dhcp"
  }
}
```

### 多插件配置（.conflist）

```json
{
  "cniVersion": "1.0.0",
  "name": "production-net",
  "plugins": [
    {
      "type": "macvlan",
      "master": "bond0",
      "mode": "bridge",
      "mtu": 1500,
      "ipam": {
        "type": "dhcp"
      }
    },
    {
      "type": "bandwidth",
      "ingressRate": 100000000,
      "egressRate": 100000000
    }
  ]
}
```

> **提示**：链式插件按数组顺序依次执行，前一个插件的输出（prevResult）会传递给下一个插件。

### 配置文件要求

| 字段 | 说明 | 必填 |
|------|------|------|
| `cniVersion` | CNI 规范版本，推荐 `"1.0.0"` | ✅ |
| `name` | 网络名称，用于 ACL 授权和 podman 引用 | ✅ |
| `type`（.conf）| 插件类型，如 `macvlan`、`ipvlan` | ✅ |
| `plugins`（.conflist）| 插件数组 | ✅ |
| `plugins[].type` | 每个插件的类型 | ✅ |

> **重要**：
> - 每个 plugin 的二进制文件必须存在于 `cni_plugin_dir`（默认 `/usr/lib/cni` 或 `/opt/cni/bin`）中
> - 第一个插件的 `ipam` 字段用于 IPAM 类型判断（dhcp/static）
> - 网络名称（`name`）必须与 ACL 授权中的 `resource` 名称一致

### 配置示例

#### DHCP 网络

`/etc/net-porter/cni.d/10-dhcp.conflist`：
```json
{
  "cniVersion": "1.0.0",
  "name": "dhcp-net",
  "plugins": [
    {
      "type": "macvlan",
      "master": "eth0",
      "ipam": { "type": "dhcp" }
    }
  ]
}
```

#### 静态 IP 网络

`/etc/net-porter/cni.d/20-static.conflist`：
```json
{
  "cniVersion": "1.0.0",
  "name": "static-net",
  "plugins": [
    {
      "type": "macvlan",
      "master": "eth0",
      "mode": "bridge",
      "mtu": 9000,
      "ipam": {
        "type": "static",
        "addresses": [
          { "address": "192.168.1.0/24", "gateway": "192.168.1.1" }
        ],
        "routes": [{ "dst": "0.0.0.0/0" }]
      }
    }
  ]
}
```

#### 链式插件（带宽限制）

`/etc/net-porter/cni.d/30-limited.conflist`：
```json
{
  "cniVersion": "1.0.0",
  "name": "limited-net",
  "plugins": [
    {
      "type": "macvlan",
      "master": "eth0",
      "ipam": { "type": "dhcp" }
    },
    {
      "type": "bandwidth",
      "ingressRate": 10000000,
      "egressRate": 10000000
    }
  ]
}
```

## 与ACL的关联

CNI 配置中的 `name` 字段与 ACL 授权中的 `resource` 字段通过名称关联：

```
CNI 配置（cni.d/）         ACL 授权（acl.d/）
┌─────────────────┐        ┌─────────────────┐
│ name: "dhcp-net"│◄──────►│ resource:       │
│                 │        │   "dhcp-net"    │
└─────────────────┘        └─────────────────┘
```

ACL 授权示例（`/etc/net-porter/acl.d/alice.json`）：
```json
{
  "user": "alice",
  "grants": [
    { "resource": "dhcp-net" },
    { "resource": "static-net", "ips": ["192.168.1.10-192.168.1.20"] }
  ]
}
```

## 配置选项

| 选项 | 说明 | 默认值 |
|------|------|--------|
| `cni_dir` | CNI 配置文件目录 | `{config_dir}/cni.d` |
| `cni_plugin_dir` | CNI 插件二进制文件目录 | 自动检测 `/usr/lib/cni` 或 `/opt/cni/bin` |

在 `config.json` 中显式指定：

```json
{
  "cni_dir": "/etc/net-porter/cni.d",
  "cni_plugin_dir": "/opt/cni/bin"
}
```

## 故障排查

### 配置文件未加载

**症状**：网络名称找不到

**排查**：
1. 确认文件后缀是 `.conf` 或 `.conflist`（其他后缀会被忽略）
2. 检查 JSON 格式是否正确：`jq < /etc/net-porter/cni.d/your-config.conflist`
3. 查看日志中的加载信息：`journalctl -u net-porter | grep cni_loader`

### 插件找不到

**症状**：日志中出现 `Plugin 'xxx' not found or not executable`

**排查**：
1. 确认插件二进制存在：`ls -la /usr/lib/cni/macvlan`
2. 确认插件可执行：`test -x /usr/lib/cni/macvlan && echo OK`
3. 如果插件在其他目录，在 `config.json` 中设置 `cni_plugin_dir`

### 重复网络名称

**症状**：日志中出现 `Duplicate network name 'xxx'`

**说明**：当多个配置文件使用相同的 `name` 时，第一个被加载的配置生效，后续重复的会被跳过。文件按目录遍历顺序加载。

### 修改配置后不生效

**说明**：`cni.d/` 目录目前不支持热加载。添加或修改 CNI 配置文件后需要重启服务：

```bash
systemctl restart net-porter
```
