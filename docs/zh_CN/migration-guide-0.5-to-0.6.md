# 迁移指南：0.5 → 0.6

0.6.0 版本将网络资源配置从 `config.json` 中的内联 `resources` 数组迁移到 `cni.d/` 目录下的标准 CNI 1.0 格式文件。这使得 net-porter 兼容标准 CNI 生态，并支持链式插件（如 macvlan + bandwidth + firewall）。

## 变更概览

| 旧版 (0.5) | 新版 (0.6) |
|---|---|
| 网络资源内联在 `config.json` 中 | 网络资源以标准 CNI 文件存储在 `cni.d/` 目录 |
| 自定义 `interface` + `ipam` 结构 | 标准 CNI 1.0 插件格式 |
| 每个资源仅支持单插件 | 通过 `.conflist` 支持链式插件 |
| 重启后状态丢失 | Attachment 状态持久化到 `/run/net-porter/` |
| 资源名来自 `name` 字段 | 资源名来自 CNI `name` 字段 |

## 配置变更

### 步骤 1：创建 `cni.d/` 目录

安装包会自动创建此目录。如果是手动升级：

```bash
mkdir -p /etc/net-porter/cni.d
```

### 步骤 2：将每个资源转换为 CNI 配置文件

为 `config.json` 中 `resources` 数组的每个条目，在 `/etc/net-porter/cni.d/` 中创建对应的 `.conflist` 文件。

#### 迁移前（0.5 — 内联在 `config.json` 中）：

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
      }
    },
    {
      "name": "static-net",
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
      }
    },
    {
      "name": "ipvlan-l3",
      "interface": {
        "type": "ipvlan",
        "master": "eth0",
        "mode": "l3"
      },
      "ipam": {
        "type": "static",
        "addresses": [
          { "address": "10.0.0.0/24", "gateway": "10.0.0.1" }
        ]
      }
    }
  ]
}
```

#### 迁移后（0.6 — `cni.d/` 目录下的 CNI 文件）：

**`/etc/net-porter/cni.d/10-macvlan-dhcp.conflist`**：

```json
{
  "cniVersion": "1.0.0",
  "name": "macvlan-dhcp",
  "plugins": [
    {
      "type": "macvlan",
      "master": "eth0",
      "ipam": { "type": "dhcp" }
    }
  ]
}
```

**`/etc/net-porter/cni.d/20-static-net.conflist`**：

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

**`/etc/net-porter/cni.d/30-ipvlan-l3.conflist`**：

```json
{
  "cniVersion": "1.0.0",
  "name": "ipvlan-l3",
  "plugins": [
    {
      "type": "ipvlan",
      "master": "eth0",
      "mode": "l3",
      "ipam": {
        "type": "static",
        "addresses": [
          { "address": "10.0.0.0/24", "gateway": "10.0.0.1" }
        ]
      }
    }
  ]
}
```

### 转换规则

从旧格式转换为 CNI 文件时，请遵循以下规则：

| 旧字段 (0.5) | 新字段 (0.6) | 说明 |
|---|---|---|
| `name` | `name`（顶层） | 不变 —— 必须与 ACL 中的 `resource` 名称匹配 |
| *(新增)* | `cniVersion: "1.0.0"` | CNI 格式必需 |
| `interface.type` | `plugins[0].type` | 移入插件配置 |
| `interface.master` | `plugins[0].master` | 移入插件配置 |
| `interface.mode` | `plugins[0].mode` | 移入插件配置 |
| `interface.mtu` | `plugins[0].mtu` | 移入插件配置 |
| `ipam` | `plugins[0].ipam` | 移入插件配置，格式不变 |

### 步骤 3：清理 `config.json`

从 `/etc/net-porter/config.json` 中删除 `resources` 数组。该文件现在只需包含服务级设置：

```json
{
  "log": {
    "level": "info"
  }
}
```

### 步骤 4：重启服务

```bash
systemctl restart net-porter
```

验证网络已加载：

```bash
journalctl -u net-porter | grep "Loaded.*CNI network"
```

## 不变的部分

- **ACL 配置**（`acl.d/` 目录）：无需任何更改，ACL 文件继续按原有方式工作。
- **`cni_plugin_dir` 选项**：仍然自动检测或可在 `config.json` 中配置。
- **Podman 网络设置**：`net_porter_resource` 选项仍然引用网络 `name` —— podman 命令无需修改。
- **ACL 授权中的静态 IP 范围**：继续与静态 IPAM 资源配合使用。

## 迁移后可用的新功能

### 链式插件

现在可以在单个网络中链式组合多个 CNI 插件：

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

### Attachment 持久化

如果服务重启，它现在可以通过 `/run/net-porter/` 中持久化的状态正确执行已有 CNI attachment 的 teardown。此前，重启意味着留下孤立的网络接口。

### 标准 CNI 兼容性

由于配置现在使用标准 CNI 1.0 格式，你可以直接使用来自其他工具的现有 CNI 配置文件（如 Kubernetes CNI 配置），无需修改或仅需极少修改。未知字段会被静默忽略。

## 故障排查

### 迁移后出现 "Network 'xxx' not found"

1. 检查 `cni.d/` 中是否有对应文件：`ls /etc/net-porter/cni.d/`
2. 确认文件后缀是 `.conf` 或 `.conflist`（其他后缀会被忽略）
3. 确认 `name` 字段与你通过 `net_porter_resource` 传入的值匹配
4. 添加新的 CNI 配置文件后重启服务

### 出现 "Plugin 'xxx' not found or not executable"

1. 检查插件二进制是否存在：`ls -la /usr/lib/cni/macvlan`
2. 检查插件是否可执行：`test -x /usr/lib/cni/macvlan && echo OK`
3. 如果插件在其他目录，在 `config.json` 中设置 `cni_plugin_dir`

### 配置文件未加载

1. 确认文件后缀是 `.conf` 或 `.conflist`
2. 验证 JSON 格式是否正确：`jq < /etc/net-porter/cni.d/your-config.conflist`
3. 查看日志：`journalctl -u net-porter | grep cni_loader`
