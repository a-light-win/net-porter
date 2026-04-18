# 特性状态

## 网络

- [x] Rootless 容器使用 macvlan 网络
- [x] Rootless 容器使用 ipvlan 网络
- [x] DHCP 自动分配 IP
- [x] 静态 IP 分配（每用户可限 IP 范围）
- [x] IPv4 / IPv6 双栈

## 访问控制

- [x] 按用户授权网络访问
- [x] 按用户限制静态 IP 范围
- [x] 可复用的授权集合，批量授权
- [x] ACL 热重载，无需重启服务
- [x] 用户隔离 — 用户之间互不影响

## CNI

- [x] 标准 CNI 1.0 配置格式（.conf / .conflist）
- [x] 链式插件（如 macvlan + bandwidth + firewall）
- [x] 服务重启后保留现有网络状态

## 服务管理

- [x] 单一服务实例服务所有用户
- [x] 自动检测用户 — 无需逐用户配置
- [x] deb / rpm / Arch Linux 软件包

## 计划中

- [ ] CNI 配置热重载（当前需重启服务）
- [ ] 配置文件 dry-run 校验
