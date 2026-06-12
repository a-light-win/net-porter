# 更新日志

本文件记录了项目的所有重要变更。

格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
本项目遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [1.5.0] - 2026-06-12

### 新增

- **MAC 地址访问控制**：ACL 规则支持 MAC 地址范围限制。可在 ACL grant 中定义允许的 MAC 地址范围，系统在 CNI setup 时校验容器 MAC 地址。
- **SLAAC IPv6 自动检测**：新增 SlaacDetector 模块，自动检测 macvlan 接口上 SLAAC 分配的 IPv6 地址，无需手动配置静态 IP 即可获得 IPv6 连通性。
- **`static_mac` 网络配置字段**：NetworkOptions 新增 `static_mac` 字段，支持为容器指定静态 MAC 地址。
- **MAC 地址注入 CNI 插件**：容器 MAC 地址现在通过 JSON 配置注入到 CNI 插件中，支持 SLAAC IPv6 检测和 MAC ACL 校验。

### 内部优化

- 构建优化模式改为 ReleaseSafe。
- 提取 `reapChild` 辅助函数简化 SlaacDetector 子进程清理。
- IPv6 CIDR 格式化改为展开表示法。

---

## [1.4.0] - 2026-06-08

### 安全

- **限制 systemctl 输出分配大小**：`WorkerManager` 此前为 systemctl 的 stdout/stderr 分配无界堆内存。异常的 `systemd` 可能借此耗尽服务端内存。三处调用点现在共享同一个 64 KiB 上限的辅助函数。
- **启动时立即应用日志设置**：在初始启动日志和后期配置加载之间存在一个时间窗口，此期间日志级别未生效，安全相关事件可能被无视配置地输出（或丢弃）。服务端和 Worker 现在都在配置可用后第一时间应用日志设置。
- **网络命名空间诊断改为显式开启**：Worker 日志默认输出 netns 诊断信息。该输出现在仅在显式请求时才产生，减少向 systemd-journal 或 stdout 的信息泄露。
- **`getUsername` 正确传播内存不足错误**：用户名解析期间的 OOM 错误此前被掩盖为 null 结果，可能静默跳过授权检查。错误现在正确传播给调用方。
- **CNI 插件类型采用白名单校验**：插件类型校验现在使用严格白名单，防止通过畸形 CNI 配置使用预期外的插件类型。
- **ACL 监听器失败可见化**：`setupInotify()` 和 inotify 读取错误此前被静默吞掉，运维人员在 hot-reload 被禁用且 ACL 状态陈旧时收不到任何警告。两类失败现在都会输出明确的警告日志。
- **`unreachable` 路径采用安全回退**：多个 CNI 访问器和 utils 辅助函数此前对意外输入使用 `unreachable`（例如绕过 `init()` 校验的损坏状态文件），在 release 构建中是未定义行为。这些位置现在返回 null 或安全回退值，避免内存损坏。

### 新增

- **SIGTERM/SIGINT 优雅关闭**：服务端现在捕获 SIGTERM 和 SIGINT 并执行干净关闭，而不是被强制杀死，提升系统升级和容器重启期间的可靠性。

### 修复

- **CNI `deinit` 中的 double-free**：`Cni` 结构体在其 arena 内分配，但 `deinit()` 在 `arena.deinit()` 之后又调用了 `allocator.destroy(self)`，释放了已经归还的内存。该缺陷在 `page_allocator` 下被掩盖，但在 `DebugAllocator`/`GeneralPurposeAllocator` 下会触发 invalid-free panic。
- **CNI 插件执行时间受限**：卡住的 CNI 插件二进制文件此前会无限阻塞 `process.wait`。在默认 64 个 handler 槽位下，64 个卡住的插件会耗尽 Worker 池并造成拒绝服务。插件执行现在通过 `pidfd_open` + poll 在 Linux >= 5.3 上设置 60 秒超时上限。
- **关闭期间同步 handler 排空**：`Worker.deinit()` 此前未等待进行中的 handler 线程就销毁 DHCP 服务，与请求处理中调用 `dhcp_service.ensureStarted()` / `stop()` 的 handler 竞态。新增 `shutting_down` 标志和 `active_handlers` 计数器，确保共享资源在 handler 完成后才被释放。
- **路径派生失败时使用默认 `config_dir`**：当配置路径没有目录部分（例如全新安装时的裸文件名 `config.json`），`postInit()` 此前返回 `InvalidPath` 中止启动。现在改用 `/etc/net-porter` 作为安全回退。
- **预分配受监控的文件描述符**：高负载下，文件描述符监控可能在容量超限时静默丢失事件。容量现在预先按最大值分配。
- **通过 `POLL.NVAL` 检测陈旧文件描述符**：poll 事件掩码此前缺少 `POLL.NVAL`，导致陈旧文件描述符无法被检测，Worker 在已关闭 fd 上空转。掩码现已包含 `NVAL`，无效 fd 会被正确处理。
- **加固 `ManagedConfig.load` 中的 arena 所有权**：arena 所有权契约现已文档化，`FileNotFound` 回退分支将 `ManagedConfig` 构造延迟到 `postInit()` 成功之后，消除此前 arena 可能被双重清理的脆弱双轨窗口。
- **CNI teardown 部分失败可见化**：CNI teardown 期间的部分失败此前被静默丢弃，掩盖了真实的配置或权限问题。错误现在会带完整上下文被记录。
- **`put` 失败时的 arena key 泄漏**：在 `workers.put` 失败之前插入到 arena 的 key 未被清理，在持续分配压力下缓慢泄漏内存。插入顺序现已调整以避免失败时的浪费。
- **`StateFile.statExists` 处理超长路径**：超过 `PATH_MAX` 的文件路径此前在底层 syscall 中触发未定义行为。超长路径现在会以明确的错误被拒绝。

### 内部优化

- **Debug 构建启用 DebugAllocator**：服务端和 Worker 现在在 `Debug`/`ReleaseSafe` 构建中使用 `std.heap.DebugAllocator`，可在运行时捕获内存泄漏和 double-free。`ReleaseFast`/`ReleaseSmall` 构建仍使用 `page_allocator` 以保证性能。GPA 由调用方持有并通过 `Opts.allocator` 传入，确保其生命周期长于所有子对象。
- **测试基础设施改用密码学随机源**：`AclScanner.zig` 和 `TempFileManager.zig` 中的测试辅助函数此前仅使用 PID 作为 `DefaultPrng` 种子，导致 `/tmp` 路径可预测且在并发 CI 运行中易冲突。已替换为 `io.random()`，与生产代码保持一致。
- **文档化 Worker 非锁定读取方法的线程安全契约**：依赖外部锁定的方法现已添加明确文档，防止未来的贡献者误用。
- **构建步骤检查 `kcov` 可用性**：`cover` 步骤现在在调用前检测 `kcov` 是否已安装，给出更清晰的错误信息，而不是令人困惑的构建失败。

---

## [1.3.0] - 2026-05-29

### 安全

- **恢复网络命名空间验证**：重新启用基于 NSFS 的网络命名空间路径验证，防止挂载替换攻击。此保护机制在之前的更新中被意外禁用。
- **修复资源错误时的 ACL 授权绕过**：当网络资源解析遇到错误时，后续操作可能在没有正确授权检查的情况下继续执行。现在错误会被正确传播，访问会被适当拒绝。
- **修复 ACL 目录监听器的内存安全问题**：ACL 监听线程在关闭期间可能访问已释放的内存，可能导致服务崩溃或未定义行为。监听线程现在通过专用信号管道执行干净关闭。
- **加强安全随机数生成**：临时文件创建现在使用 `std.io.random` 生成种子，消除了使用部分未初始化随机数据的风险。

### 变更

- **静态 IPAM 现在要求显式 `addresses` 字段**：使用静态 IPAM（`"type": "static"`）时，必须在 CNI 配置中显式指定 `addresses` 数组。此前，缺失的地址信息会被静默推断，可能导致意外的网络行为。

### 修复

- **修复关闭时服务挂起**：当 ACL 目录监听器处于活动状态时，服务在关闭期间可能无限挂起，需要强制终止。
- **修复 socket 错误后 Worker 无响应**：连接接受期间的致命 socket 错误可能导致 Worker 进程进入僵尸状态，无法接受新连接。
- **修复 Worker 日志配置不生效**：配置文件中的日志级别设置未应用到 Worker 进程——Worker 始终使用默认日志级别，无论配置如何。
- **修复 DHCP 服务对静态 IP 的误判**：DHCP 启停逻辑错误地使用 ACL IP 范围而非 CNI 配置的 IPAM 类型来判断资源是否使用静态 IP，可能导致 DHCP 被不必要地启动或停止。
- **修复畸形 CNI 配置可能导致崩溃**：CNI 配置文件中的空或畸形插件数组可能导致服务 panic 崩溃。
- **修复多处整数溢出问题**：多个时间戳计算和事件循环计数器在长时间运行或高负载系统上可能溢出，导致行为异常或崩溃。
- **修复 CNI 插件设置中的资源泄漏**：设置 CNI 插件目录时文件描述符泄漏，CNI attachment 状态序列化时内存泄漏。
- **修复 ACL 管理器的内存泄漏**：ACL 管理器初始化期间的内存不足条件未被正确处理，导致已分配资源泄漏。
- **修复错误处理遗漏导致的连接挂起**：某些请求处理错误被静默吞掉，导致客户端连接无限挂起而无响应。
- **修复 Worker 启动时的堆损坏**：Worker 进程启动期间的 double-free 错误可能损坏堆内存，导致不可预测的崩溃。
- **修复高负载下关闭时的死锁**：如果系统调用被信号中断，关闭信号可能死锁，导致服务无法正常关闭。
- **修复 DHCP 互斥锁状态损坏**：DHCP 服务互斥锁在清理期间可能在未锁定的情况下被解锁，导致未定义行为。
- **修复 Worker 管理中的多处可靠性问题**：Worker 生命周期管理存在边界情况，可能导致越界访问、内存泄漏和错误的 Worker 死亡检测。

### 内部优化

- 新增 CNI 静态 IPAM 类型检测的单元测试。
- 替换不符合项目编码规范的 API 调用。
- 为可执行文件添加 build-id 以便于调试。
- 移除无用代码并改进内部模块的错误传播。

---

## [1.2.0] - 2026-05-27

### 安全

- **修复了 NSFS 验证绕过风险**：NSFS 验证改用 statfs 获取实际设备号，替代之前硬编码设备号的方式。在设备号不同的系统上，旧版本可能跳过验证。
- **加强用户名校验**：新增严格的用户名格式校验（仅允许字母、数字、下划线和连字符），防止通过 NSS/LDAP 返回的恶意用户名进行路径穿越攻击。
- **加固 catatonit 进程验证**：改进了进程身份验证逻辑，可抵抗 PID 回收和进程名伪造攻击。
- **新增 UID 复用检测**：当用户账户被删除并以相同 UID 但不同用户名重新创建时，服务会自动停止该 UID 的旧 Worker，防止权限继承导致越权访问。
- **修复 IPv6 地址解析的整数下溢漏洞**。
- **加强随机种子校验**：新增对随机种子生成的校验，防止使用未初始化的值。

### 新增

- **动态 ACL 管理**：服务现在实时监听 `acl.d/` 目录的变化。添加、修改或删除 ACL 文件后，对应的 Worker 会自动启动或停止——无需手动干预。此前，ACL 变更需要重启服务才能生效。

### 修复

- **修复 inotify 事件处理的越界读取**：可能导致服务崩溃。
- **修复并发事件处理的崩溃问题**：当超过 8 个用户或 ACL 事件同时发生时，服务可能崩溃。
- **修复 ACL 监听器的多个内存泄漏**。
- **修复系统调用错误检测不正确的问题**：可能导致操作静默失败或报告错误信息。
- **修复瞬态 I/O 错误导致的 Worker 异常停止**：用户扫描过程中出现临时 I/O 错误时，不再误停止所有 Worker。
- **修复事件处理顺序**：ACL 变更现在优先于用户登录事件处理，确保新用户在对应的 socket 事件到达前已被识别。
- **优化 ACL 监听效率**：跳过非用户文件（共享规则集合和隐藏文件），减少不必要的处理。

### 内部优化

- 新增 UID 复用检测的测试覆盖。
- 代码格式清理。

---

## [1.1.0] - 2026-04-22

### 安全

- **修复了 9 个安全漏洞**，涵盖路径穿越、TOCTOU 竞态条件、信息泄露和线程安全：
  - 防止 Unix socket 创建时的符号链接 TOCTOU 提权攻击。
  - 防止通过重复资源名绕过 ACL IP 限制。
  - 对 `net_porter_resource` 参数添加 CNI 标识符校验，防止注入攻击。
  - 对 CNI 配置加载器中的插件类型添加路径穿越校验。
  - 对 ACL 加载中的 group_name 添加路径穿越校验。
  - 堆分配 handler 以防止线程数据竞争。
  - 使用 `getrandom` + `O_EXCL` 安全创建状态临时文件。
  - 在创建状态目录前设置 umask 以限制权限。
  - 避免在错误消息中向客户端泄露 CNI 插件细节（路径、类型）。

### 新增

- **简化插件参数名**：`net_porter_socket` → `socket`，`net_porter_resource` → `resource`。旧参数名仍可使用，但会打印 deprecated 警告。

### 变更

- **`socket` 参数改为必选**：Rootless podman 在用户命名空间内调用 netavark 插件，`getuid()` 返回映射后的 UID（0），导致自动检测 socket 路径不可靠。创建 podman 网络时必须显式指定 `socket` 路径。

- **CNI 模块架构重组**：将 1500+ 行的单体 `Cni.zig` 拆分为四个独立模块 —— `Cni`、`CniConfig`、`PluginConf` 和 `Attachment`，提升可维护性。
- **模块布局调整**：将 `Acl`/`AclFile` 移至 `acl/`，`ManagedType` 和 `Responser` 移至 `common/`，共享 inotify 常量移至 `utils/Inotify.zig`。

### 修复

- 修复 CNI `deserializeState` 中因过早调用 `parsed.deinit()` 导致的 use-after-free。
- 修复 CNI setup/teardown 路径中 `env_map` 的内存泄漏。
- 修复 DHCP 守护进程未关闭 stdin/stdout/stderr。
- 修复 DHCP `isAlive` 在回收子进程后残留的过期进程引用。
- 修复 inotify 事件处理中 `group_names` 缺少互斥锁保护。
- 修复 `workers.put` OOM 时未关闭 pid 文件描述符。
- 修复 OOM 时返回未解析的 netns 路径而非明确错误。
- 修复反向 IP 范围（如 `10.0.0.10-10.0.0.1`）被静默接受的问题。
- 修复 ACL 初始加载错误被静默吞掉而非记录日志。
- 修复错误日志中缺少被拒绝的 IP 信息及日志范围不正确。
- CNI 标识符最大长度从 256 降至 128 以保持一致性。

### 内部优化

- 合并 `setDefaultAclDir`/`setDefaultCniDir` 为通用的 `setDefaultSubDir`。
- 移除冗余的 `discoverCatatonitPid`，统一使用 `discoverAllCatatonitPids`。
- 移除 `Worker.pageAllocator()` 包装，直接使用 `std.heap.page_allocator`。
- 移除未使用的 `json.zig`，将其唯一调用内联到 `main`。
- 合并 `processPollEvents` 中相同的 catatonit/worker 分支。
- 提取 `getIpamType`/`getIpamObject` 辅助函数，去重 `PluginConf` 方法。
- 移除重复的 `shadowCopyObjectMap`，复用 `PluginConf.shadowCopy`。
- 移除空的 `AclScanner.deinit` 及其调用点。
- 使测试步骤依赖编译步骤，以便尽早捕获构建错误。

---

## [1.0.0] - 2026-04-19

### 安全

- **消除了进入容器命名空间的提权风险**：先前版本以 root 身份在容器命名空间内执行 CNI 插件 —— 这是一个已知的提权攻击途径。现在 root 进程不再进入任何用户控制的命名空间。
- **加固了进程隔离**：服务端和每用户 Worker 现在运行在严格的 systemd 安全限制下 —— 每个 Worker 拥有独立的隔离服务单元，文件系统只读、Linux 能力最小化、系统调用受过滤。即使 Worker 被攻破，影响范围也被严格限制。
- **修复了安全审计中发现的 7 个安全漏洞**，包括路径穿越、容器名注入、Socket 创建的竞态条件，以及错误信息中的信息泄露。
- **多 IP 静态地址校验**：当容器请求多个静态 IP 时，所有 IP 现在都会根据用户允许的 IP 范围进行校验（此前仅校验第一个 IP）。
- **Worker 内部数据保护**：Worker 状态文件现在存储在仅 root 可访问的目录中，防止普通用户访问或篡改。

### 新增

- **独立的每用户 Worker 进程**：服务端现在为每个用户派生一个独立的 Worker 进程。Worker 完全独立 —— 即使服务端崩溃，所有 Worker 也会继续运行并为用户服务。服务端重启后会自动重新连接到已有的 Worker，不会中断服务。
- **包升级后 Worker 自动重启**：升级 net-porter 包后，服务端会检测到 Worker 仍在运行旧版二进制文件，并自动用新版本重启它们。
- **Worker 自动恢复**：当 Worker 关联的 podman 基础设施容器重启时，服务端会检测到这一变化并自动重启 Worker 以重新连接。

### 变更

- **ACL 身份识别改为基于文件名**：ACL 文件内的 `user` 和 `group` 字段不再使用 —— 它们会被静默忽略以保持向后兼容。身份现在完全由文件名决定：`<用户名>.json` 用于用户，`@<名称>.json` 用于共享规则集合。
- **ACL 新增 `groups` 字段**：用户 ACL 文件可通过 `groups` 字段引用共享的规则集合。例如，`"groups": ["dhcp-users"]` 会引入 `@dhcp-users.json` 中的所有授权。这些**不是** Linux 用户组 —— 它们只是可复用的授权集合。
- **规则集合文件重命名**：共享规则集合文件现在使用 `@<名称>.json` 前缀（如 `devops.json` → `@devops.json`），以与用户 ACL 文件区分。

### 移除

- **ACL 文件中的 `user` 和 `group` 字段**：被基于文件名的身份识别取代。包含这些字段的现有文件继续正常工作 —— 这些字段会被静默忽略。
- **`nsenter` 依赖**：不再使用或需要 `nsenter` 命令。
- **`dumpEnv` 配置选项**：移除以减少攻击面。

### 迁移

详见 [迁移指南（0.6 → 1.0）](migration-guide-0.6-to-1.0.md)。

---

## [0.6.0] - 2026-04-17

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

## [0.5.0] - 2026-04-16

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

## [0.4.0] - 2026-04-15

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

[1.5.0]: https://github.com/a-light-win/net-porter/compare/1.4.0...1.5.0
[1.4.0]: https://github.com/a-light-win/net-porter/compare/1.3.0...1.4.0
[1.3.0]: https://github.com/a-light-win/net-porter/compare/1.2.0...1.3.0
[1.2.0]: https://github.com/a-light-win/net-porter/compare/1.1.0...1.2.0
[1.1.0]: https://github.com/a-light-win/net-porter/compare/1.0.0...1.1.0
[1.0.0]: https://github.com/a-light-win/net-porter/compare/0.6.0...1.0.0
[0.6.0]: https://github.com/a-light-win/net-porter/compare/0.5.0...0.6.0
[0.5.0]: https://github.com/a-light-win/net-porter/compare/0.4.0...0.5.0
[0.4.0]: https://github.com/a-light-win/net-porter/compare/0.3.4...0.4.0
[0.3.4]: https://github.com/a-light-win/net-porter/compare/0.3.3...0.3.4
[0.3.3]: https://github.com/a-light-win/net-porter/compare/0.3.2...0.3.3
[0.3.2]: https://github.com/a-light-win/net-porter/compare/0.3.1...0.3.2
[0.3.1]: https://github.com/a-light-win/net-porter/compare/0.3.0...0.3.1
[0.3.0]: https://github.com/a-light-win/net-porter/compare/0.2.0...0.3.0
