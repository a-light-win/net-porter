# net-porter

`net-porter` 是一个 [netavark](https://github.com/containers/netavark) 插件，
用于为 rootless podman 容器提供 macvlan/ipvlan 网络。

它由两个主要部分组成：

- `net-porter plugin`：运行在 rootless 环境中的 `netavark` 插件，由 `netavark` 调用。
- `net-porter server`：以 root 权限运行的服务端，负责通过 CNI 插件创建 macvlan/ipvlan 网络。

`net-porter server` 以单一全局 systemd 服务运行。它通过 inotify 监听 `/run/user/` 目录，
为每个 ACL 授权的用户自动创建独立的 unix socket。当容器启动时，
netavark 会调用 `net-porter plugin`，plugin 通过对应用户的 socket 连接到 `net-porter server`，
并将所需信息传递给服务端。

`net-porter server` 通过调用者的 `uid/gid`（通过内核 `SO_PEERCRED` 获取，不可伪造）进行身份认证，
并在用户具有权限时创建 macvlan/ipvlan 网络。

> **为什么使用 `/run/user/<uid>/` 下的每用户 socket？** Rootless podman 运行在隔离的挂载命名空间和独立的网络命名空间中（通过 pasta/slirp4netns）。`/run/` 下的文件系统 socket 和抽象 socket 都无法跨命名空间访问。但 `/run/user/<uid>/` 是由 `systemd-logind` 创建的每用户 tmpfs，会被 bind-mount 到用户命名空间中，因此在宿主机和 rootless podman 中均可访问。

## 功能特性

- **动态 Socket 管理**：通过 inotify 在用户登录/登出时自动创建/移除每用户 socket
- **单服务架构**：一个全局 root 服务服务所有用户，无需管理每用户服务实例
- **基于 Grant 的 ACL 控制**：每资源级别的授权，支持用户/组匹配及可选的静态 IP 范围限制
- **静态 IP 支持**：根据允许的 IP 范围校验用户请求的静态 IP —— 无需单独的 CNI 配置文件
- **安全加固**：内核级身份认证、网络命名空间归属验证、默认拒绝策略
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
│   ├── main.zig                  # 程序入口
│   ├── server/                   # 服务端实现
│   │   ├── Server.zig            # 服务端核心
│   │   ├── SocketManager.zig     # 多 Socket 管理（inotify + poll）
│   │   ├── Handler.zig           # 请求处理器
│   │   ├── AclManager.zig        # ACL 管理
│   │   └── Acl.zig               # ACL 验证
│   ├── cni/                      # CNI 集成
│   │   ├── Cni.zig               # CNI 执行逻辑
│   │   ├── CniManager.zig        # CNI 配置管理
│   │   ├── DhcpService.zig       # 每用户 DHCP 服务
│   │   └── DhcpManager.zig       # DHCP 服务管理器
│   ├── config/                   # 配置
│   │   ├── Config.zig            # 配置结构体
│   │   ├── Resource.zig          # Resource、Grant、Interface、Ipam 结构体
│   │   ├── ManagedConfig.zig     # 配置加载器
│   │   └── DomainSocket.zig      # Socket 路径工具
│   ├── plugin/                   # Netavark 插件实现
│   └── utils/                    # 工具模块
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
编辑 `/etc/net-porter/config.json` 定义资源。每个资源将接口、IPAM 和 ACL 合并在一处 —— 无需单独的 CNI 配置文件：

```json
{
  "users": ["alice"],
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
    }
  ]
}
```

将 `eth0` 替换为宿主机的物理接口。修改配置后重启服务：
```bash
systemctl restart net-porter
```

### 3. 创建 podman 网络
以 rootless 用户（如 `alice`）身份运行：
```bash
podman network create \
  -d net-porter \
  -o net_porter_resource=macvlan-dhcp \
  -o net_porter_socket=/run/user/$(id -u)/net-porter.sock \
  macvlan-net
```

### 4. 测试
运行一个测试容器：
```bash
podman run -it --rm --network macvlan-net alpine ip addr
```
你应该能看到 macvlan 接口及其从 DHCP 服务器获取的 IP 地址。

## 配置指南

### 服务端配置 (`/etc/net-porter/config.json`)
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
        { "user": "bob",   "ips": ["192.168.1.30"] }
      ]
    }
  ],
  "log": {
    "level": "info",
    "dump_env": {
      "enabled": false,
      "path": "/tmp/net-porter-dump"
    }
  }
}
```

> ⚠️ **重要**：每个资源**必须**至少有一个 ACL grant 条目。如果任何资源缺少访问控制配置，服务将拒绝启动。

### 资源字段

| 字段 | 说明 | 必填 |
|------|------|------|
| `name` | 资源名称，用于创建 podman 网络时引用 | ✅ |
| `interface` | 网络接口配置（见下文） | ✅ |
| `ipam` | IP 地址管理配置（见下文） | ✅ |
| `acl` | 访问控制列表 —— grant 数组（见下文） | ✅ |

### 接口配置

| 字段 | 说明 | 默认值 |
|------|------|--------|
| `type` | 接口类型：`macvlan` 或 `ipvlan` | — |
| `master` | 要附加的宿主机物理接口 | — |
| `mode` | macvlan 模式：`bridge`、`vepa`、`private`、`passthru`；ipvlan 模式：`l2`、`l3`、`l3s` | macvlan: `bridge`，ipvlan: `l2` |
| `mtu` | 接口的 MTU 大小 | 未设置（使用内核默认值） |

### IPAM 配置

| 字段 | 说明 | 必填 |
|------|------|------|
| `type` | IPAM 类型：`dhcp` 或 `static` | ✅ |

对于 `type: "static"`，还有以下字段：

| 字段 | 说明 | 必填 |
|------|------|------|
| `addresses` | `{ "address": "<cidr>", "gateway": "<ip>" }` 条目的数组 | static: ✅ |
| `routes` | `{ "dst": "<cidr>", "gw": "<ip>", "priority": <num> }` 路由数组 | static: 可选 |
| `dns` | `{ "nameservers": [...], "domain": "...", "search": [...] }` | static: 可选 |

### ACL Grant

`acl` 数组中的每个 grant 指定**谁**可以访问此资源，以及对于静态 IPAM，允许使用**哪些 IP**。

| 字段 | 说明 | 必填 |
|------|------|------|
| `user` | 用户名或数字 UID | `user` 或 `group` 二选一 |
| `group` | 组名或数字 GID | `user` 或 `group` 二选一 |
| `ips` | 允许的 IP 范围或单个 IP 的数组（仅静态 IPAM） | static: ✅ |

**IP 范围格式**（用于静态 IPAM）：
- 单个 IP：`"192.168.1.30"`
- IP 范围：`"192.168.1.10-192.168.1.20"`

当 IPAM 类型为 `static` 时，调用方必须请求特定 IP（通过 podman `--ip` 或 netavark static_ips 选项），net-porter 会根据用户允许的范围进行校验。

### 顶层选项

| 选项 | 说明 | 默认值 |
|------|------|--------|
| `users` | 需要 `net-porter.sock` 入口的用户名或数字 UID 数组。服务仅为列出的用户创建每用户 socket。 | `[]`（空） |
| `cni_plugin_dir` | CNI 插件二进制文件所在目录 | 自动检测（`/usr/lib/cni` 或 `/opt/cni/bin`） |
| `log.level` | 日志级别：`debug`、`info`、`warn`、`error` | `info` |
| `log.dump_env` | 调试用的环境信息导出 | 禁用 |

## 使用示例

### 示例 1：多用户使用不同网络
```json
{
  "users": ["alice", "bob"],
  "resources": [
    {
      "name": "vlan-100",
      "interface": { "type": "macvlan", "master": "eth0.100" },
      "ipam": { "type": "dhcp" },
      "acl": [
        { "user": "alice" },
        { "user": "bob" }
      ]
    },
    {
      "name": "vlan-200",
      "interface": { "type": "macvlan", "master": "eth0.200" },
      "ipam": { "type": "dhcp" },
      "acl": [
        { "group": "devops" }
      ]
    }
  ]
}
```
- `alice` 和 `bob` 可以使用 `vlan-100` 网络
- `devops` 组中的所有用户可以使用 `vlan-200` 网络

用户 alice 创建网络：
```bash
podman network create -d net-porter -o net_porter_resource=vlan-100 vlan100
```

### 示例 2：静态 IP 及每用户 IP 范围
```json
{
  "users": ["alice", "bob"],
  "resources": [
    {
      "name": "static-net",
      "interface": { "type": "macvlan", "master": "eth0" },
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
```json
{
  "users": ["alice"],
  "resources": [
    {
      "name": "ipvlan-l3",
      "interface": { "type": "ipvlan", "master": "eth0", "mode": "l3" },
      "ipam": { "type": "dhcp" },
      "acl": [
        { "user": "alice" }
      ]
    }
  ]
}
```
- `alice` 可以使用 `ipvlan-l3` 网络（ipvlan L3 模式）
- IPvLAN 共享父接口的 MAC 地址（每个容器没有独立的 MAC）

### 示例 4：IPvLAN 静态 IP
```json
{
  "users": ["alice", "bob"],
  "resources": [
    {
      "name": "ipvlan-static",
      "interface": { "type": "ipvlan", "master": "eth0", "mode": "l2", "mtu": 9000 },
      "ipam": {
        "type": "static",
        "addresses": [
          { "address": "10.0.0.0/24", "gateway": "10.0.0.1" }
        ],
        "routes": [{ "dst": "0.0.0.0/0" }]
      },
      "acl": [
        { "user": "alice", "ips": ["10.0.0.10-10.0.0.20"] },
        { "user": "bob",   "ips": ["10.0.0.30-10.0.0.40"] }
      ]
    }
  ]
}
```

### 示例 5：混合 macvlan 和 ipvlan 资源
```json
{
  "users": ["alice"],
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
      "name": "macvlan-static",
      "interface": { "type": "macvlan", "master": "eth0", "mode": "bridge", "mtu": 9000 },
      "ipam": {
        "type": "static",
        "addresses": [
          { "address": "10.0.0.0/24", "gateway": "10.0.0.1" }
        ],
        "routes": [{ "dst": "0.0.0.0/0" }]
      },
      "acl": [
        { "user": "alice", "ips": ["10.0.0.5-10.0.0.10"] }
      ]
    }
  ]
}
```

## 从 v0.x 升级（每用户服务架构）
版本 0.4.0 使用单一全局服务替代了每用户服务实例。升级步骤：

1. 停止并禁用所有每用户服务：
   ```bash
   systemctl stop net-porter@*
   systemctl disable net-porter@*
   ```
2. 安装新版本包
3. 使用新格式将每用户 ACL 配置合并到全局 `/etc/net-porter/config.json` 中（见[配置指南](#配置指南)）
4. 删除 `/etc/net-porter/cni.d/` 中的旧 CNI 配置文件 —— 接口和 IPAM 设置现在在资源中内联定义
5. 启动全局服务：
   ```bash
   systemctl enable --now net-porter
   ```
6. 使用新的每用户 socket 路径重建 podman 网络：
   ```bash
   # 删除旧网络
   podman network rm macvlan-net
   # 使用每用户 socket 重建
   podman network create \
     -d net-porter \
     -o net_porter_resource=macvlan-dhcp \
     -o net_porter_socket=/run/user/$(id -u)/net-porter.sock \
     macvlan-net
   ```

## 故障排查

### 常见问题

#### 1. 连接 socket 时权限被拒绝
**错误**：`Access denied for uid=1000`
**解决方案**：
- 检查用户在配置中是否有所请求资源的权限
- 验证 `/etc/net-porter/config.json` 中的 ACL grant 配置

#### 2. 插件无法连接到服务端
**错误**：`Failed to connect to domain socket /run/user/1000/net-porter.sock: ConnectionRefused`
**解决方案**：
- 确认服务正在运行：`systemctl status net-porter`
- 确认每用户 socket 存在：`ls -la /run/user/$(id -u)/net-porter.sock`
- 检查你的 uid 是否在某个 ACL grant 中

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
- 检查 `/etc/net-porter/config.json` 中是否存在该资源
- 确保 `name` 字段与你通过 `net_porter_resource` 传入的值匹配
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
1. **每用户 Socket 隔离**：每个用户在 `/run/user/<uid>/` 下拥有自己的 socket，权限为 0600，确保只有属主可以连接
2. **身份认证**：通过内核 `SO_PEERCRED` 获取调用者 UID/GID，不可伪造
3. **Socket 过滤**：用户没有任何资源权限时，连接立即被拒绝
4. **基于 Grant 的 ACL 校验**：每个请求都根据资源的 grant 列表进行验证 —— grant 支持用户/组匹配及可选的 IP 范围限制
5. **静态 IP 校验**：对于静态 IPAM 资源，请求的 IP 会根据用户允许的 IP 范围进行校验 —— 超出范围的请求被拒绝
6. **网络命名空间验证**：网络命名空间文件的属主必须与调用者 UID 匹配
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
- `-o net_porter_resource=macvlan-dhcp`：指定资源名称，应与服务端配置中的名称一致。
- `-o net_porter_socket=/run/user/$(id -u)/net-porter.sock`：指定由 `net-porter server` 创建的每用户 socket 路径。`$(id -u)` 展开为当前用户的 uid。
- `macvlan-net`：网络名称。
