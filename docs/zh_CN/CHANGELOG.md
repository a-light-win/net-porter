# 更新日志

本文件记录了项目的所有重要变更。

格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
本项目遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [1.0.0] - 2025-04-18

### 安全

- **消除了 `nsenter` 提权风险**：先前版本使用 `nsenter` 命令进入容器命名空间执行 CNI 插件。root 进程执行 `nsenter` 是一个已知的提权攻击向量 —— 被入侵或恶意的命名空间可能利用 root 上下文进行提权。现在 Worker 直接运行在正确的命名空间中，CNI 插件的执行不再需要 `nsenter`。
- **加固了 CNI 插件执行环境**：CNI 插件目录在 Worker 命名空间中以只读方式 bind-mount，防止二进制文件被替换。
- **修复了安全审计中发现的 7 个攻击面**，包括通过 CNI_NETNS 的路径穿越、容器名注入、域 socket 创建的 TOCTOU 竞态条件，以及错误信息中的信息泄露。

### 变更

- **每 UID Worker 架构**：服务端现在为每个用户派生独立的 Worker 进程。Worker 运行在独立的 systemd scope 中 —— 即使服务端崩溃也能存活，且独立管理。此架构消除了 root 进程在用户控制的命名空间中执行命令的需求。
- **ACL 文件格式简化**：`user` 和 `group` 字段不再用于身份识别 —— 它们会被静默忽略以保持向后兼容。身份现在由文件名决定：`<用户名>.json` 用于用户，`@<名称>.json` 用于共享规则集合。
- **ACL 新增 `groups` 字段**：用户 ACL 文件可通过 `groups` 字段引用共享的规则集合。例如，`"groups": ["dhcp-users"]` 会引入 `@dhcp-users.json` 中的所有授权。这些**不是** Linux 用户组 —— 它们只是可复用的授权集合。
- **规则集合文件重命名**：共享规则集合文件现在使用 `@<名称>.json` 前缀（如 `devops.json` → `@devops.json`），以与用户 ACL 文件区分。

### 移除

- **`nsenter` 命令执行**：不再在任何地方使用。Worker 已经位于正确的命名空间中。
- **ACL 文件中的 `user` 和 `group` 字段**：被基于文件名的身份识别取代。包含这些字段的现有文件继续正常工作 —— 这些字段会被静默忽略。

---

## [0.6.0] - 2025-04-17

### 新增

- **标准 CNI 配置目录（`cni.d/`）**：网络资源现在通过 `/etc/net-porter/cni.d/` 目录下的标准 CNI 1.0 格式文件（`.conf` 和 `.conflist`）进行配置，支持单插件和链式插件。详见 [CNI 配置指南](cni-config.md)。
- **基于文件的 Attachment 持久化**：CNI attachment 状态现在持久化到磁盘 `/run/net-porter/{uid}/{container_id}_{ifname}.json`。这使得服务重启后仍能正确执行 teardown —— 此前重启的服务无法清理已有的 CNI attachment。
- **链式插件 prevResult 支持**：CNI 插件现在按照 CNI 1.0 规范通过 `prevResult` 字段正确传递链式结果。后续插件接收前一个插件的输出，支持多插件工作流（如 macvlan + bandwidth + firewall）。
- **CNI 配置加载校验**：插件二进制文件在加载时进行校验 —— 如果所需的插件缺失或不可执行，服务会报告明确的错误信息。
- **安装包自动创建 `cni.d/` 目录**：安装包会自动创建 `/etc/net-porter/cni.d/` 目录并安装标准 CNI 配置示例文件（`00-example.conflist.example`），包含 DHCP、静态 IP 和链式插件的用法指南。
- **配置文件大小限制**：CNI 配置文件限制为 1 MB，防止畸形或超大文件导致内存占用过高。
- **新增 `cni_dir` 配置选项**：允许自定义 CNI 配置目录路径（默认为 `{config_dir}/cni.d`）。

### 变更

- **网络配置迁移至 `cni.d/` 目录**：`config.json` 中的 `resources` 数组不再使用。每个网络资源现在是 `cni.d/` 目录下的标准 CNI 配置文件。这是一个**破坏性变更** —— 详见 [迁移指南（0.5 → 0.6）](migration-guide-0.5-to-0.6.md)。
- **CNI 配置格式改为标准 CNI 1.0**：自定义的 `interface` / `ipam` 结构替换为标准 CNI 字段（`type`、`master`、`mode`、`ipam` 等），直接位于插件配置内。CNI 配置中的未知字段会被静默忽略，提升了与标准 CNI 配置的兼容性。

### 移除

- **`config.json` 中的 `resources` 字段**：网络资源不再内联定义，改用 `cni.d/` 目录。

### 修复

- 增加配置文件大小限制（1 MB），防止畸形文件导致内存占用过高。

### 内部优化

- 将已弃用的 `std.fs` 和 `std.os.linux` 调用迁移至 Zig 0.16.0 的首选 API。
- 修复 Zig 0.16.0 stdlib API 兼容性问题。
- 修复 CNI 模块测试中的内存泄漏。
- 移除无用的 `user_sessions` 代码。

### 迁移

详见 [迁移指南（0.5 → 0.6）](migration-guide-0.5-to-0.6.md)。

---

## [0.5.0] - 2025-04-16

### 新增

- **IPvlan 网络支持**：新增 ipvlan 接口类型，与 macvlan 并列。支持 L2、L3、L3s 模式。IPvlan 共享父接口的 MAC 地址，适用于无法保证 MAC 地址唯一性的网络环境。
- **IPv6 静态 IP 范围支持**：静态 IP 的 ACL 规则现在支持 IPv6 地址和范围（如 `2001:db8::1-2001:db8::ff`），可实现 IPv4/IPv6 双栈配置。
- **双栈静态 IP 注入**：容器可以同时请求 IPv4 和 IPv6 静态地址。系统会根据地址族自动匹配对应的子网。
- **动态 ACL 目录（`acl.d/`）**：访问控制规则现在以独立的 JSON 文件存储在 `/etc/net-porter/acl.d/` 目录中。服务会自动监听该目录的变化，添加、修改或删除 ACL 文件后无需重启即可生效。

### 变更

- **访问控制迁移至 `acl.d/` 目录**：ACL 规则不再定义在 `config.json` 内部。每个用户或组在 `acl.d/` 目录下拥有独立的 JSON 文件。权限管理更加模块化——添加或撤销权限只需增删一个文件。
- **接口模式严格校验**：`mode` 字段现在按接口类型严格校验——macvlan 模式（`bridge`、`vepa`、`private`、`passthru`）和 ipvlan 模式（`l2`、`l3`、`l3s`）不可混用。此外，ipvlan L3/L3s 模式不支持 DHCP（需使用静态 IP）。
- **启动时显示版本号**：服务启动时现在会打印版本号。

### 移除

- **`config.json` 中的 `users` 字段**：需要 socket 的用户列表现在从 ACL 文件自动推导，无需手动指定。
- **资源定义中的 `acl` 字段**：访问控制不再在每个资源中内联定义，改用 `acl.d/` 目录管理。

### 迁移

详见 [迁移指南（0.4 → 0.5）](migration-guide-0.4-to-0.5.md)。

---

## [0.4.0] - 2025-04-15

### 新增

- **单服务多用户模式**：用单一全局服务 `net-porter.service` 替代了原先的每用户服务实例（`net-porter@<uid>.service`）。一个 root 进程即可服务所有用户，大幅降低资源开销和运维复杂度。
- **基于 Grant 的 ACL 模型**：新增 per-resource `acl` 字段，使用结构化的 grant 条目（`{ "user": "alice" }`、`{ "group": "devops" }`）替代原先扁平的 `allow_users`/`allow_groups` 数组。Grant 支持对静态 IP 资源的可选 IP 范围限制。
- **静态 IP 支持**：新增静态 IPAM 类型，支持内联配置子网、网关和路由。用户请求的静态 IP 会根据其 ACL grant 允许的 IP 范围进行校验——无需额外的 IPAM 插件或配置文件。
- **内联 CNI 配置**：网络接口和 IPAM 设置现在直接定义在 `config.json` 中的 resource 内。不再使用 `cni.d/` 目录；CNI 插件配置从 resource 定义动态生成。
- **每用户 Socket + inotify 动态管理**：通过 inotify 监听 `/run/user/` 目录，自动为用户创建/移除位于 `/run/user/<uid>/net-porter.sock` 的 unix socket。每个 socket 权限为 `0600`，属主为对应用户，确保 OS 级隔离。
- **顶层 `users` 配置**：新增 `users` 字段，用于显式声明哪些用户需要 socket 入口，替代之前从 ACL grant 隐式推导的方式。
- **多用户容器网络隔离**：合并为单服务后，各用户的容器网络资源仍严格隔离，不同用户之间无法互相干扰或影响对方的容器。
- **启动时强制校验 ACL**：如果任何 resource 缺少 ACL 配置，服务将拒绝启动，避免因配置遗漏导致无访问控制的资源暴露。
- **错误信息中包含 netns 诊断**：连接错误信息中现在包含网络命名空间信息，返回给 netavark，便于故障排查。

### 变更

- **构建工具链升级至 Zig 0.16.0**：整个代码库已迁移到 Zig 0.16.0 的 `std.Io` 架构。从源码构建现在需要 Zig >= 0.16.0。
- **Systemd 服务简化**：`net-porter@<uid>.service` 模板被替换为单一的 `net-porter.service`。CLI 参数 `--uid` 已移除。
- **配置格式重新设计**：详见 [迁移指南（0.3 → 0.4）](migration-guide-0.3-to-0.4.md)。

### 移除

- **`domain_socket` 配置段**：Socket 路径现在从用户 UID 自动派生，不再需要手动配置。
- **Resource 上的 `allow_users` / `allow_groups` 字段**：被新的 `acl` grant 数组替代。
- **`cni.d/` 目录**：不再从磁盘读取 CNI 配置文件。所有网络设置均在 `config.json` 中内联定义。
- **`net-porter@.service` 模板**：被单一的 `net-porter.service` 单元文件替代。
- **`--uid` CLI 参数**：在单服务架构下不再需要。

---

## [0.3.4] - 2025-01-19

### 修复

- 修复在不支持 `SO_REUSEPORT` 的内核上 net-porter 无法启动的问题。

## [0.3.3] - 2025-01-17

### 变更

- 默认 socket 属主现在设置为所接受连接的 UID。

## [0.3.2] - 2025-01-15

### 修复

- 修复 nfpm 打包依赖：将依赖从 `podman-netavark` 改为 `podman`，以兼容 Alivstack 打包格式。

## [0.3.1] - 2025-01-14

### 修复

- 修复因缺少 `pub` 注解导致 `std_options` 不生效的问题。

## [0.3.0] - 2025-01-14

### 新增

- 运行时可自定义日志级别。
- 增加更多诊断日志。

### 变更

- 将 CNI 逻辑从 `server/` 重构到独立的 `cni/` 模块。

## [0.2.0] - 2025-01-12

_初始公开发布，采用每用户服务架构。_

[1.0.0]: https://github.com/a-light-win/net-porter/compare/0.6.0...1.0.0
[0.6.0]: https://github.com/a-light-win/net-porter/compare/0.5.0...0.6.0
[0.5.0]: https://github.com/a-light-win/net-porter/compare/0.4.0...0.5.0
[0.4.0]: https://github.com/a-light-win/net-porter/compare/0.3.4...0.4.0
[0.3.4]: https://github.com/a-light-win/net-porter/compare/0.3.3...0.3.4
[0.3.3]: https://github.com/a-light-win/net-porter/compare/0.3.2...0.3.3
[0.3.2]: https://github.com/a-light-win/net-porter/compare/0.3.1...0.3.2
[0.3.1]: https://github.com/a-light-win/net-porter/compare/0.3.0...0.3.1
[0.3.0]: https://github.com/a-light-win/net-porter/compare/0.2.0...0.3.0
