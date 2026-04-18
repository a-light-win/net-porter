# 特性状态

## 核心架构

- [x] 单一全局服务（取代每用户服务实例）
- [x] 每 UID Worker 进程（systemd-run --scope，crash 隔离）
- [x] Worker 生命周期管理（通过 pidfd 派生/停止/重启）
- [x] 通过 inotify 监听 /run/user/ 动态管理 socket
- [x] Worker 命名空间隔离（setns + unshare + rslave）

## 网络支持

- [x] macvlan 网络（bridge/vepa/private/passthru 模式）
- [x] ipvlan 网络（L2/L3/L3s 模式）
- [x] DHCP IPAM
- [x] 静态 IPAM（每用户 IP 范围校验）
- [x] IPv4 支持
- [x] IPv6 支持（静态 IP 范围）
- [x] 双栈静态 IP（IPv4 + IPv6 同时使用）

## CNI 集成

- [x] 标准 CNI 1.0 配置格式（.conf / .conflist）
- [x] CNI 配置目录（cni.d/）
- [x] 链式插件支持（prevResult）
- [x] CNI 插件二进制加载时校验
- [x] Attachment 状态持久化到磁盘
- [x] CNI 配置文件大小限制（1 MB）

## 访问控制（ACL）

- [x] 基于文件的 ACL（acl.d/ 目录）
- [x] 基于文件名的身份识别（<用户名>.json）
- [x] 共享规则集合（@<名称>.json）
- [x] ACL 热重载（inotify，无需重启）
- [x] 每资源级别授权模型
- [x] 可选的 IP 范围限制
- [x] 两阶段原子 ACL 重载（无中断）

## DHCP 服务

- [x] 每用户 DHCP 守护进程（惰性启动，自动重启）
- [x] DHCP 守护进程生命周期与用户容器绑定
- [x] DHCP socket 位于用户命名空间

## 安全

- [x] SO_PEERCRED 内核级身份认证
- [x] 每用户 socket 隔离（0600 权限）
- [x] 已消除 nsenter（无提权攻击向量）
- [x] CNI 插件目录在 Worker 中只读 bind-mount
- [x] CNI_NETNS 路径校验（防止路径穿越）
- [x] 容器名校验（防止注入）
- [x] 域 socket TOCTOU 竞态修复（基于 fd 的操作）
- [x] 通用错误消息（防止信息泄露）
- [x] 默认拒绝策略
- [x] 并发连接数限制

## Netavark 插件

- [x] create（podman network create）
- [x] setup（容器启动）
- [x] teardown（容器停止）
- [x] info（插件元数据）

## 打包与部署

- [x] deb 包
- [x] rpm 包
- [x] Arch Linux 包
- [x] systemd 服务单元（已加固）
- [x] 容器化构建（podman + just）
- [x] 本地构建（zig + nfpm）

## 计划中 / 尚未实现

- [ ] CNI 配置热重载（当前需要重启）
- [ ] API 版本控制 / 向后兼容契约
- [ ] 指标 / 监控端点
- [ ] 配置校验 CLI（dry-run）
