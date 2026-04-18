# net-porter

`net-porter` 是一个 [netavark](https://github.com/containers/netavark) 插件，
用于为 rootless podman 容器提供 macvlan/ipvlan 网络。

它由两个主要部分组成：

- `net-porter plugin`：运行在 rootless 环境中的 `netavark` 插件，由 `netavark` 调用。
- `net-porter server`：以 root 权限运行的服务端，负责通过 CNI 插件创建 macvlan/ipvlan 网络。

`net-porter server` 以单一全局 systemd 服务运行。它扫描 ACL 目录（`acl.d/`）将允许的用户名解析为 UID，并通过 inotify 监听 `/run/user/` 目录的 UID 出现/消失事件。对于每个允许的 UID，服务端会通过 `systemd-run --scope` 派生一个独立的 **worker** 进程，该进程在 `/run/user/<uid>/net-porter.sock` 创建自己的 socket。

当容器启动时，netavark 会调用 `net-porter plugin`，plugin 连接到 worker 的 per-user socket 并传递所需信息。Worker 通过调用者的 `uid/gid`（通过内核 `SO_PEERCRED` 获取，不可伪造）进行身份认证，校验 ACL 授权，并在用户具有权限时创建 macvlan/ipvlan 网络。

> **为什么使用 `/run/user/<uid>/` 下的每用户 socket？** Rootless podman 运行在隔离的挂载命名空间和独立的网络命名空间中（通过 pasta/slirp4netns）。`/run/` 下的文件系统 socket 和抽象 socket 都无法跨命名空间访问。但 `/run/user/<uid>/` 是由 `systemd-logind` 创建的每用户 tmpfs，会被 bind-mount 到用户命名空间中，因此在宿主机和 rootless podman 中均可访问。

### 架构概览

```
┌──────────────────────────────────────────────────────────────┐
│                    net-porter.service (root)                  │
│                                                              │
│  Server                                                      │
│  ├── AclManager: 扫描 acl.d/ → 将用户名解析为 UID            │
│  ├── SocketManager: 通过 inotify 监听 /run/user/             │
│  └── WorkerManager: 派生/停止/重启每 UID worker              │
│                                                              │
│  为每个允许的 UID 通过 systemd-run 派生一个 worker：          │
│                                                              │
│  ┌──────────────── Worker（每 UID，独立 scope）────────────┐  │
│  │  1. 在 /run/user/<uid>/net-porter.sock 创建 socket     │  │
│  │  2. 进入容器挂载命名空间（setns + unshare）              │  │
│  │  3. 只读 bind-mount CNI 插件目录（安全加固）             │  │
│  │  4. 接受连接 → 派生处理线程                              │  │
│  │  5. 加载 ACL 授权 + 通过 inotify 热重载                  │  │
│  │  6. 在正确的命名空间中执行 CNI 插件                      │  │
│  └─────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────┘
```

Worker 运行在独立的 systemd scope 中，即使服务端崩溃也能存活。服务端仅管理其生命周期（派生/停止/重启），不会在自己的关闭时终止 worker。

## 功能特性

- **动态 Socket 管理**：通过 inotify 在用户登录/登出时自动创建/移除每用户 socket
- **单服务架构**：一个全局 root 服务服务所有用户，无需管理每用户服务实例
- **Per-UID Worker 进程**：每个用户拥有独立的 worker 进程（crash 隔离、独立命名空间）
- **基于 Grant 的 ACL 控制**：每资源级别的授权，支持可选的静态 IP 范围限制
- **ACL 规则集合**：用户 ACL 可引用共享的规则集合（`@<名称>.json`），授权自动合并
- **静态 IP 支持**：根据允许的 IP 范围校验用户请求的静态 IP —— 无需单独的 CNI 配置文件
- **标准 CNI 配置**：支持通过 `cni.d/` 目录使用标准 CNI 1.0 格式配置文件，包括链式插件（详见 [CNI 配置指南](cni-config.md)）
- **安全加固**：内核级身份认证、命名空间隔离、CNI 插件目录只读挂载、默认拒绝策略
- **DHCP 支持**：自动管理每用户 DHCP 服务实例
- **零信任**：所有请求必须通过多级验证后才能执行

## 安装

`net-porter` 仅支持 Linux 系统。

### 前置条件
- Linux 内核 >= 5.4
- Podman >= 4.0
- 已安装 CNI 插件（通常位于 `/usr/lib/cni` 或 `/opt/cni/bin`）

### 使用预构建包安装
我们在[发布页面](https://github.com/a-light-win/net-porter/releases)提供 deb、rpm 和 archlinux 包。

#### 使用 deb 包安装
```bash
apt install -f /path/to/net-porter.deb
```

#### 使用 rpm 包安装
```bash
rpm -i /path/to/net-porter.rpm
```

#### 使用 archlinux 包安装
```bash
pacman -U /path/to/net-porter.pkg.tar.zst
```

### 从源码构建
如果你希望从源码构建和打包 `net-porter`，有两种方式：

#### 方式 1：容器化构建（推荐）
此方式使用 podman 在一致的容器环境中运行所有构建步骤，无需在本地安装依赖：

**所需依赖：**
- [git](https://git-scm.com/)
- [just](https://github.com/casey/just)（任务运行器）
- [podman](https://github.com/containers/podman)（容器运行时）

构建所有包：
```bash
just pack-all
```
构建产物将输出到 `zig-out/` 目录。

#### 方式 2：本地构建
如果你希望直接在宿主机构建：

**所需依赖：**
- [Zig](https://ziglang.org/) 0.16.0（编译器）
- [nfpm](https://nfpm.goreleaser.com/) >= 2.30（打包工具，仅在构建包时需要）
- git
- just

##### 1. 仅编译二进制
```bash
# 编译 debug 版本
zig build

# 编译优化的 release 版本
zig build -Doptimize=ReleaseSafe

# 输出二进制位于：zig-out/bin/net-porter
```

针对特定架构构建：
```bash
# 构建 x86_64 版本
zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-musl

# 构建 aarch64 版本
zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-linux-musl
```

##### 2. 运行测试
```bash
zig build test
```

##### 3. 构建包
```bash
# 构建 deb 包
just pack-deb

# 构建 rpm 包
just pack-rpm

# 构建 archlinux 包
just pack-arch
```

所有构建产物将输出到 `zig-out/` 目录。

#### 构建选项
| 选项 | 说明 | 默认值 |
|------|------|--------|
| `-Doptimize=Debug` | 未优化的构建，包含调试符号 | ✓ |
| `-Doptimize=ReleaseSafe` | 优化构建，保留运行时安全检查 | 生产环境推荐 |
| `-Doptimize=ReleaseFast` | 最大优化构建，无运行时安全检查 | |
| `-Dtarget=<三元组>` | 交叉编译到目标架构 | 当前主机 |
| `-Dstrip=true` | 从二进制中去除调试符号 | `false` |

## 项目结构
```
net-porter/
├── src/
│   ├── main.zig                  # 程序入口 & CLI 调度
│   ├── server.zig                # 服务端模块（CLI: `net-porter server`）
│   ├── server/
│   │   ├── Server.zig            # 服务端核心 — ACL 扫描 + Worker 生命周期
│   │   ├── SocketManager.zig     # /run/user/ 监听（inotify），报告 UID 事件
│   │   ├── AclManager.zig        # 服务端 ACL 扫描器（用户名 → UID 解析）
│   │   ├── AclFile.zig           # ACL 文件格式（Grant、Entry、groups）
│   │   └── Acl.zig               # ACL 校验 & IP 范围匹配
│   ├── worker.zig                # Worker 模块（CLI: `net-porter worker`）
│   ├── worker/
│   │   ├── Worker.zig            # 每 UID worker 守护进程（运行在容器挂载命名空间中）
│   │   ├── WorkerManager.zig     # Worker 生命周期管理（通过 pidfd 派生/停止/重启）
│   │   ├── Handler.zig           # 请求处理器（每连接，多线程）
│   │   └── AclManager.zig        # Worker 端 ACL 加载器 + 热重载（inotify）
│   ├── cni.zig                   # CNI 模块导出
│   ├── cni/
│   │   ├── Cni.zig               # CNI 执行逻辑
│   │   ├── CniManager.zig        # CNI 配置管理
│   │   ├── CniLoader.zig         # CNI 配置文件加载 & 校验
│   │   ├── StateFile.zig         # CNI attachment 状态持久化
│   │   ├── DhcpService.zig       # 每用户 DHCP 服务
│   │   └── DhcpManager.zig       # DHCP 服务管理器
│   ├── config.zig                # 配置模块导出
│   ├── config/
│   │   ├── Config.zig            # 服务端配置结构体
│   │   ├── ManagedConfig.zig     # 配置文件加载器
│   │   └── DomainSocket.zig      # Socket 路径工具
│   ├── plugin.zig                # 插件模块（CLI: create/setup/teardown/info）
│   ├── plugin/
│   │   ├── NetavarkPlugin.zig    # Netavark 插件协议实现
│   │   └── Responser.zig         # 响应构建工具
│   ├── user.zig                  # UID/GID/用户名解析（libc 封装）
│   ├── json.zig                  # JSON 工具（解析、序列化）
│   ├── utils.zig                 # 工具模块导出
│   ├── utils/
│   │   ├── ArenaAllocator.zig    # 基于 Arena 的每请求内存分配器
│   │   ├── ErrorMessage.zig      # 结构化错误输出
│   │   ├── Logger.zig            # 运行时日志级别控制的自定义日志器
│   │   └── LogSettings.zig       # 日志配置
│   └── test_utils/
│       └── TempFileManager.zig   # 测试用临时文件管理器
├── misc/
│   ├── systemd/                  # Systemd 服务文件
│   └── nfpm/                     # nfpm 打包配置
├── build.zig                     # Zig 构建配置
└── justfile                      # Just 任务定义
```

## 快速开始

### 1. 启动服务
安装完成后，启用并启动全局服务：
```bash
systemctl enable --now net-porter
```

检查服务状态：
```bash
systemctl status net-porter
```

### 2. 配置网络资源

在 `/etc/net-porter/cni.d/` 目录下创建 CNI 配置文件（支持标准 CNI 1.0 格式，详见 [CNI 配置指南](cni-config.md)）：

`/etc/net-porter/cni.d/10-macvlan-dhcp.conflist`：
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

将 `eth0` 替换为宿主机的物理接口。修改配置后重启服务：
```bash
systemctl restart net-porter
```

### 3. 配置访问控制
为每个需要访问权限的用户在 `/etc/net-porter/acl.d/` 目录中创建 ACL 文件：

```bash
mkdir -p /etc/net-porter/acl.d
```

`/etc/net-porter/acl.d/alice.json`：
```json
{
  "grants": [
    { "resource": "macvlan-dhcp" }
  ]
}
```

> ACL 文件会被自动监听。添加、修改或删除文件后无需重启即可生效。文件名决定用户身份：`alice.json` → 用户 `alice`。

### 4. 创建 podman 网络
以 rootless 用户（如 `alice`）身份运行：
```bash
podman network create \
  -d net-porter \
  -o net_porter_resource=macvlan-dhcp \
  -o net_porter_socket=/run/user/$(id -u)/net-porter.sock \
  macvlan-net
```

### 5. 测试
以 rootless 用户（如 `alice`）身份运行：
```bash
podman run -it --rm --network macvlan-net alpine ip addr
```
你应该能看到 macvlan 接口及其从 DHCP 服务器获取的 IP 地址。

## 配置指南

### 服务端配置 (`/etc/net-porter/config.json`)
```json
{
  "cni_plugin_dir": "/usr/lib/cni",
  "log": {
    "level": "info",
    "dump_env": {
      "enabled": false,
      "path": "/tmp/net-porter-dump"
    }
  }
}
```

CNI 网络配置通过 `/etc/net-porter/cni.d/` 目录管理，详见 [CNI 配置指南](cni-config.md)。

访问控制在 `/etc/net-porter/acl.d/` 目录中单独配置 —— 详见下文 [ACL 配置](#acl-配置)。

### ACL 配置

访问控制通过 `/etc/net-porter/acl.d/` 目录中的独立 JSON 文件管理。服务会自动监听该目录，添加、修改或删除文件后无需重启即可生效。

#### ACL 文件命名约定

- **用户 ACL**：`acl.d/<用户名>.json` —— 授权 + 可选的 `groups` 引用
- **规则集合**：`acl.d/@<名称>.json` —— 共享的授权集合，可被用户 ACL 引用

用户名从文件名推导（去掉 `.json` 后缀）。旧版的 `user` 和 `group` 字段会被静默忽略，保持向后兼容。

> **注意**：`@<名称>.json` 文件**不是** Linux 用户组。它们只是命名的规则集合 —— 可复用的授权集，任何用户 ACL 都可通过 `groups` 字段引用。`@` 后面的名称是任意标签，不是 `/etc/group` 中的组名。

#### 用户 ACL 文件格式

`/etc/net-porter/acl.d/alice.json`：
```json
{
  "grants": [
    { "resource": "macvlan-dhcp" },
    { "resource": "static-net", "ips": ["192.168.1.10-192.168.1.20"] }
  ],
  "groups": ["dhcp-users"]
}
```

#### 规则集合文件格式

`/etc/net-porter/acl.d/@devops.json`：
```json
{
  "grants": [
    { "resource": "vlan-200" }
  ]
}
```

有效权限 = 用户授权 ∪ 所有引用的规则集合中的授权。

#### ACL 文件字段

| 字段 | 说明 | 必填 |
|------|------|------|
| `grants` | 资源授权数组 | ✅ |
| `grants[].resource` | 资源名称（须与 `cni.d/` 中 CNI 配置的 `name` 匹配） | ✅ |
| `grants[].ips` | 允许的 IP 范围或单个 IP 数组（用于静态 IP 资源） | 静态资源：✅ |
| `groups` | 要引用的规则集合名称数组（引用 `@<名称>.json` 文件） | ❌ |

#### IP 范围格式

- 单个 IPv4：`"192.168.1.30"`
- IPv4 范围：`"192.168.1.10-192.168.1.20"`
- 单个 IPv6：`"2001:db8::1"`
- IPv6 范围：`"2001:db8::1-2001:db8::ff"`

当 IPAM 类型为 `static` 时，调用方必须请求特定 IP（通过 podman `--ip` 或 netavark static_ips 选项），net-porter 会根据用户允许的范围进行校验。

> 💡 **提示**：用户名由文件名决定（如 `alice.json` → 用户 `alice`）。规则集合文件以 `@` 开头（如 `@devops.json` → 名为 `devops` 的规则集合）。多个用户可以引用同一个集合 —— 授权会自动合并。

### 顶层选项

| 选项 | 说明 | 默认值 |
|------|------|--------|
| `cni_plugin_dir` | CNI 插件二进制文件所在目录 | 自动检测（`/usr/lib/cni` 或 `/opt/cni/bin`） |
| `cni_dir` | 标准 CNI 配置文件所在目录 | `{config_dir}/cni.d` |
| `acl_dir` | ACL 文件所在目录 | `{config_dir}/acl.d` |
| `log.level` | 日志级别：`debug`、`info`、`warn`、`error` | `info` |
| `log.dump_env` | 调试用的环境信息导出 | 禁用 |

## 使用示例

### 示例 1：多用户使用不同网络

`/etc/net-porter/cni.d/10-vlan-100.conflist`：
```json
{
  "cniVersion": "1.0.0",
  "name": "vlan-100",
  "plugins": [
    { "type": "macvlan", "master": "eth0.100", "ipam": { "type": "dhcp" } }
  ]
}
```

`/etc/net-porter/cni.d/20-vlan-200.conflist`：
```json
{
  "cniVersion": "1.0.0",
  "name": "vlan-200",
  "plugins": [
    { "type": "macvlan", "master": "eth0.200", "ipam": { "type": "dhcp" } }
  ]
}
```

`/etc/net-porter/acl.d/alice.json`：
```json
{
  "grants": [
    { "resource": "vlan-100" }
  ]
}
```

`/etc/net-porter/acl.d/bob.json`：
```json
{
  "grants": [
    { "resource": "vlan-100" }
  ]
}
```

`/etc/net-porter/acl.d/@devops.json`：
```json
{
  "grants": [
    { "resource": "vlan-200" }
  ]
}
```
- `alice` 和 `bob` 可以使用 `vlan-100` 网络
- 任何在其 `groups` 字段中引用 `@devops` 规则集合的用户都可以使用 `vlan-200` 网络。例如，要授权 `charlie`：
  `/etc/net-porter/acl.d/charlie.json`：
  ```json
  {
    "grants": [],
    "groups": ["devops"]
  }
  ```

### 示例 2：静态 IP 及每用户 IP 范围

`/etc/net-porter/cni.d/10-static-net.conflist`：
```json
{
  "cniVersion": "1.0.0",
  "name": "static-net",
  "plugins": [
    {
      "type": "macvlan",
      "master": "eth0",
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

`/etc/net-porter/acl.d/alice.json`：
```json
{
  "grants": [
    { "resource": "static-net", "ips": ["192.168.1.10-192.168.1.20"] }
  ]
}
```

`/etc/net-porter/acl.d/bob.json`：
```json
{
  "grants": [
    { "resource": "static-net", "ips": ["192.168.1.30-192.168.1.40"] }
  ]
}
```
- `alice` 可以请求 `192.168.1.10` – `192.168.1.20` 范围内的任意 IP
- `bob` 可以请求 `192.168.1.30` – `192.168.1.40` 范围内的任意 IP
- 超出用户允许范围的 IP 请求将被拒绝

使用指定静态 IP 运行容器：
```bash
podman run -it --rm --network static-net --ip 192.168.1.15 alpine ip addr
```

### 示例 3：IPvLAN L3 模式

`/etc/net-porter/cni.d/10-ipvlan-l3.conflist`：
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

`/etc/net-porter/acl.d/alice.json`：
```json
{
  "grants": [
    { "resource": "ipvlan-l3", "ips": ["10.0.0.10-10.0.0.20"] }
  ]
}
```
- `alice` 可以使用 `ipvlan-l3` 网络（ipvlan L3 模式）
- IPvLAN 共享父接口的 MAC 地址（每个容器没有独立的 MAC）
- 注意：ipvlan L3/L3s 模式需要使用静态 IPAM（不支持 DHCP）

### 示例 4：IPvLAN L2 + DHCP

`/etc/net-porter/cni.d/10-ipvlan-dhcp.conflist`：
```json
{
  "cniVersion": "1.0.0",
  "name": "ipvlan-dhcp",
  "plugins": [
    {
      "type": "ipvlan",
      "master": "eth0",
      "mode": "l2",
      "mtu": 9000,
      "ipam": { "type": "dhcp" }
    }
  ]
}
```

`/etc/net-porter/acl.d/alice.json`：
```json
{
  "grants": [
    { "resource": "ipvlan-dhcp" }
  ]
}
```

### 示例 5：混合 macvlan 和 ipvlan

`/etc/net-porter/cni.d/10-macvlan-dhcp.conflist`：
```json
{
  "cniVersion": "1.0.0",
  "name": "macvlan-dhcp",
  "plugins": [
    { "type": "macvlan", "master": "eth0", "ipam": { "type": "dhcp" } }
  ]
}
```

`/etc/net-porter/cni.d/20-macvlan-static.conflist`：
```json
{
  "cniVersion": "1.0.0",
  "name": "macvlan-static",
  "plugins": [
    {
      "type": "macvlan",
      "master": "eth0",
      "mode": "bridge",
      "mtu": 9000,
      "ipam": {
        "type": "static",
        "addresses": [
          { "address": "10.0.0.0/24", "gateway": "10.0.0.1" }
        ],
        "routes": [{ "dst": "0.0.0.0/0" }]
      }
    }
  ]
}
```

`/etc/net-porter/acl.d/alice.json`：
```json
{
  "grants": [
    { "resource": "macvlan-dhcp" },
    { "resource": "macvlan-static", "ips": ["10.0.0.5-10.0.0.10"] }
  ]
}
```

### 示例 6：ACL 规则集合引用

`/etc/net-porter/acl.d/alice.json`（用户 ACL 引用规则集合）：
```json
{
  "grants": [
    { "resource": "macvlan-dhcp" }
  ],
  "groups": ["dhcp-users", "static-users"]
}
```

`/etc/net-porter/acl.d/@dhcp-users.json`（规则集合）：
```json
{
  "grants": [
    { "resource": "dhcp-net" }
  ]
}
```

`/etc/net-porter/acl.d/@static-users.json`（规则集合）：
```json
{
  "grants": [
    { "resource": "static-net", "ips": ["10.0.0.100-10.0.0.200"] }
  ]
}
```
- `alice` 的有效权限 = 自身的 `macvlan-dhcp` + 规则集合 `dhcp-users` 的 `dhcp-net` + 规则集合 `static-users` 的 `static-net`

## 从 v0.6 升级

1.0.0 版本引入了每 UID worker 架构。服务端现在为每个允许的用户派生独立的 worker 进程，而非直接处理连接。ACL 文件格式也发生了变更 —— `user`/`group` 字段被基于文件名的身份识别取代（`<用户名>.json` 用于用户），新增 `groups` 字段用于引用共享规则集合（`@<名称>.json`）。

快速步骤：

1. 更新 ACL 文件格式 —— 删除 `user`/`group` 字段（它们会被静默忽略以保持向后兼容）：
   ```json
   {
     "grants": [
       { "resource": "macvlan-dhcp" }
     ],
     "groups": ["dhcp-users"]
   }
   ```
2. 将规则集合文件重命名为 `@<名称>.json`（如 `devops.json` → `@devops.json`）
3. 重启服务：
   ```bash
   systemctl restart net-porter
   ```

## 从 v0.5 升级

0.6.0 版本将网络资源配置从内联 `resources` 数组迁移到 `cni.d/` 目录下的标准 CNI 1.0 格式文件。详见 [迁移指南（0.5 → 0.6）](migration-guide-0.5-to-0.6.md)。

快速步骤：

1. 根据现有的 `resources` 在 `cni.d/` 中创建 CNI 配置文件（详见 [CNI 配置指南](cni-config.md)）：
   ```bash
   mkdir -p /etc/net-porter/cni.d
   ```
2. 从 `/etc/net-porter/config.json` 中删除 `resources` 字段
3. 重启服务：
   ```bash
   systemctl restart net-porter
   ```

## 从 v0.4 升级

详见 [迁移指南（0.4 → 0.5）](migration-guide-0.4-to-0.5.md) 升级到 v0.5，然后再按上述步骤迁移到 v0.6。

## 从 v0.3 或更早版本升级

详见 [迁移指南（0.3 → 0.4）](migration-guide-0.3-to-0.4.md) 升级到 v0.4，然后依次按 0.4 → 0.5、0.5 → 0.6 的步骤迁移。

## 故障排查

### 常见问题

#### 1. 连接 socket 时权限被拒绝
**错误**：`Access denied for uid=1000`
**解决方案**：
- 检查用户在 `/etc/net-porter/acl.d/` 中的 ACL 文件是否有所请求资源的权限
- 验证 ACL 文件名与用户名匹配（如 `alice.json` → 用户 `alice`）
- 验证 ACL 文件中的授权配置

#### 2. 插件无法连接到服务端
**错误**：`Failed to connect to domain socket /run/user/1000/net-porter.sock: ConnectionRefused`
**解决方案**：
- 确认服务正在运行：`systemctl status net-porter`
- 确认每用户 socket 存在：`ls -la /run/user/$(id -u)/net-porter.sock`
- 确认已为该用户派生了 worker 进程
- 检查你的 uid 是否在某个 ACL 文件中

#### 3. DHCP 无法获取 IP
**错误**：`dhcp client: no ack received`
**解决方案**：
- 确认网络中有正在运行的 DHCP 服务器
- 检查 master 接口是否连接到正确的网络
- 确认网络交换机支持 macvlan 模式

#### 4. 静态 IP 被拒绝
**错误**：`Static IP x.x.x.x not allowed for user`
**解决方案**：
- 检查用户 ACL grant 中的 `ips` 范围
- 确认请求的 IP 在允许范围内
- 验证 IP 格式（单个 IP 或 `起始-结束` 范围格式）

#### 5. 找不到资源
**错误**：`Resource 'xxx' not found in config`
**解决方案**：
- 检查 `/etc/net-porter/cni.d/` 目录下是否有对应的 CNI 配置文件
- 确保配置文件中的 `name` 字段与你通过 `net_porter_resource` 传入的值匹配
- 确认文件后缀是 `.conf` 或 `.conflist`
- 修改配置后重启服务

### 日志
查看服务日志：
```bash
journalctl -u net-porter -f
```

启用 debug 日志：
编辑 `/etc/net-porter/config.json`：
```json
"log": {
  "level": "debug"
}
```
重启服务：`systemctl restart net-porter`

## 安全

### 安全模型
1. **服务端-Worker 隔离**：Worker 运行在独立的 systemd scope 中，即使服务端崩溃也能存活。服务端仅管理 Worker 生命周期，不干预其运行时行为
2. **每用户 Socket 隔离**：每个 Worker 在 `/run/user/<uid>/` 下拥有自己的 socket，权限为 0600，确保只有属主可以连接
3. **身份认证**：通过内核 `SO_PEERCRED` 获取调用者 UID/GID，不可伪造
4. **Worker 命名空间隔离**：Worker 通过 `setns + unshare` 进入容器的挂载命名空间。CNI 插件目录以只读方式 bind-mount，防止二进制文件被替换
5. **基于 Grant 的 ACL 校验**：每个请求都根据用户的授权 + 引用的规则集合中的授权进行验证 —— 支持可选的 IP 范围限制
6. **静态 IP 校验**：对于静态 IPAM 资源，请求的 IP 会根据用户允许的 IP 范围进行校验 —— 超出范围的请求被拒绝
7. **默认拒绝**：任何未明确匹配策略的请求都会被拒绝

### 加固建议
- 配置 ACL grant 时遵循最小权限原则
- 对于静态 IP 资源，为每个用户分配独占的 IP 范围 —— 不要在用户之间重叠范围
- 定期审计访问日志中的异常活动
- 保持 CNI 插件为最新版本

## 集成 `podman`

使用 `net-porter` 驱动创建容器网络，然后在 `podman` 中使用。

```bash
podman network create -d net-porter -o net_porter_resource=macvlan-dhcp -o net_porter_socket=/run/user/$(id -u)/net-porter.sock macvlan-net
```

- `-d net-porter`：使用 `net-porter` 驱动。
- `-o net_porter_resource=macvlan-dhcp`：指定资源名称，应与 CNI 配置中的名称一致。
- `-o net_porter_socket=/run/user/$(id -u)/net-porter.sock`：指定由 Worker 创建的每用户 socket 路径。`$(id -u)` 展开为当前用户的 uid。
- `macvlan-net`：网络名称。
