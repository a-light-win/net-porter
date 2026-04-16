# 更新日志

本文件记录了项目的所有重要变更。

格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
本项目遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

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

[0.5.0]: https://github.com/a-light-win/net-porter/compare/0.4.0...0.5.0
[0.4.0]: https://github.com/a-light-win/net-porter/compare/0.3.4...0.4.0
[0.3.4]: https://github.com/a-light-win/net-porter/compare/0.3.3...0.3.4
[0.3.3]: https://github.com/a-light-win/net-porter/compare/0.3.2...0.3.3
[0.3.2]: https://github.com/a-light-win/net-porter/compare/0.3.1...0.3.2
[0.3.1]: https://github.com/a-light-win/net-porter/compare/0.3.0...0.3.1
[0.3.0]: https://github.com/a-light-win/net-porter/compare/0.2.0...0.3.0
