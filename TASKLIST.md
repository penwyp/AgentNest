# AgentNest 开发任务清单与进度

> 真源：`prd.md` v2.1。状态：`[x]` 已完成并验证，`[~]` 已实现但仍缺发布级验证，`[ ]` 未完成，`[!]` 依赖外部确认或凭据。
>
> 完成定义：代码存在不等于完成；每项必须同时具备对应测试或可复现验收命令。总体完成还要求 `make build`、`make test`、`make e2e` 全部通过。

## P0 工程与质量门禁

- [x] 建立 Swift 6 / SwiftUI macOS 14 客户端分层工程（Presentation → Application → Domain → Infrastructure）。
- [x] 建立 Go License 服务端分层工程，服务端是 Trial、License、Machine 和 Receipt 的权威来源。
- [x] Makefile 提供 `build`、`test`、`e2e`、`check`、`clean`，默认产物不污染源码目录。
- [x] E2E 使用真实编译产物，覆盖客户端扫描和客户端—服务端授权主链路。
- [x] 自动化质量门禁覆盖格式、release 构建、Swift 核心检查、Go race 与真实二进制 E2E；剩余外部依赖见下文。

## P1 领域底座（PRD 4、16、17、18、19）

- [~] 定义不可变 `DeviceSnapshot`、AgentProduct、Installation、Home、Profile、Artifact、Skill、Finding、Coverage 与完整度模型；无证据时不伪造 Installation/Profile（Linked Artifact 发现仍待补齐）。
- [x] 使用 generation 隔离扫描；取消或迟到任务不能发布旧快照。
- [x] 文件物理身份使用 volume/device/inode/type；同一快照内硬链接、别名、重叠根只计一次。
- [x] 写计划与展示模型分离；路径、身份、generation 和活动保护在执行时复验。
- [x] 文件 I/O 和解析使用显式有界队列，取消能终止队列，不执行扫描到的脚本或二进制。
- [x] 日志与错误只暴露结构化代码和匿名计数，不记录 Skill 正文、License Key 或设备原始标识。

## P2 智能扫描与 Agent（FR-SCAN-01…12、FR-DISC-01…08、FR-ADAPTER-01…08、FR-CODEX-01…06）

- [x] 默认递归扫描当前 Home，包含隐藏目录，不跟随后代 symlink、不跨 volume。
- [x] 固定路径、环境变量、自定义路径和深度发现共享一次目录索引。
- [x] 扫描阶段、真实计数、当前位置、停止、部分结果和原子快照发布可用。
- [x] `schemaVersion: 1` Agent Definition 严格加载；未知字段/不兼容 schema 整份拒绝。
- [x] Codex 定义以可读取且可解析的根 `version.json` 为 required 指纹。
- [x] 默认、自定义、深层隐藏 Codex Home 分别展示；物理别名合并；相似目录只标为可能。
- [x] “可能”Home 可在 Agent 页按路径+产品形成仅本机 `userConfirmed` 来源，或加入遍历级忽略位置；均触发新 generation 重扫。
- [x] Claude Code、WorkBuddy 空定义合法加载但不扫描、不声明能力、不显示为已支持。
- [~] fixture 已覆盖正例、近似目录、畸形指纹、深层目录、symlink、硬链接、忽略位置、扫描中变化与 POSIX 不可读子树；独立挂载卷仍待补。

## P3 空间、日期与清理（PRD 9、12）

- [x] 空间账本同时记录逻辑字节与 `st_blocks × 512` 物理字节并按物理字节排序。
- [~] 物理资源台账已按卷/Product/Home/类别/共享归属建模并守恒去重；Home 外 Linked Artifact 发现仍待补。
- [x] 大小阈值与日期筛选作用于完整 Cleanup Unit，不改变风险等级。
- [x] 最后活动使用分级证据；未知、冲突或仅 atime 的对象不进入自动日期清理。
- [x] 活动中、writer 存在、引用未验证或目标变化的对象不可清理。
- [x] 清理计划包含目标、证据、风险、活动、删除方式、恢复性和预计物理字节。
- [x] 执行前复验 identity/type/symlink/generation；路径目标只走系统废纸篓，官方删除无执行器时 fail closed。
- [x] 批量逐项反馈成功/失败/跳过/取消；清理 UI 复核后只重扫受影响 Home，并按物理 identity 与未受影响快照保守合并。

## P4 Skill（FR-SKILL-01…12、FR-PATCH-01…09）

- [x] 索引目录型 `SKILL.md` 和定义声明格式；只读静态文本并限制大小、文件数、路径与 symlink。
- [x] 生成逻辑 Skill、Variant、安装副本、Coverage、缺失、冲突和无效状态。
- [~] 同名不同内容形成多个 Variant；全局作用域已实现，项目作用域仍待接入。
- [~] 创建、编辑、安装目录重命名、同格式补齐、替换和废纸篓删除执行器已实现；跨格式/二进制 materializer 尚未完成。
- [x] 创建/补齐使用同父目录 staging、文件 fsync、目录 fsync 和原子 rename；并发变化拒绝覆盖。
- [~] 补齐计划包含来源包和目标，支持跳过/替换/保留两份；跨格式 materializer 与用户 diff UI 尚未完成。
- [x] 独立预检拒绝越界 symlink/特殊文件/超预算内容；多目标串行批处理逐项目返回成功/失败/跳过。
- [x] 覆盖矩阵在写操作后自动重建，受影响位置即时反映。
- [x] 已测试 Variant、覆盖、目标变化、编辑保留附件、原子写入、独占重命名、冲突保留两份、批量取消、symlink 拒绝及带跨进程锁的 staging 崩溃恢复。

## P5 原生活动、卷、历史与报告（PRD 11、13）

- [x] 基础采集 CPU、物理磁盘、网络、卷和有界可见进程；首样本只建基线。
- [x] Agent 归因绑定 PID+启动时间，并只接受 Installation/Home/工作目录路径证据；PID 复用不串会话，不按进程名猜测。
- [x] 每项指标携带 available/partial/unavailable、观测时长与覆盖率；权限/退出/预算丢失计入 dropped count。
- [~] 文件打开与文件变化分开展示，当前打开文件来自有界 vnode 证据，未知活动归入“macOS 与其它进程”；最近变化仍待 Trace Helper。
- [ ] Trace Helper 双向验证签名身份、固定命令/参数、15 分钟上限、有界输出和 owner 断开回收。
- [x] 卷属性、IOKit 物理设备吞吐、BSD whole-disk 映射及有界缓存的 `diskutil -plist` SMART 状态已结构化展示，不可用/不支持不伪造结论。
- [x] 历史默认关闭；开启后仅分钟级写入 SQLite 脱敏聚合与 coverage，24 小时后 15 分钟、30 天后小时分层，预算绝对上限 160 MB。
- [x] CSV 使用稳定机器 schema；PDF 在本机生成、分页并按当前中英文 Locale 输出。
- [~] 已测试首样本、计数器回退、PID 复用、物理设备身份和 4096 进程证据风暴硬上限；Helper 无孤儿进程与 24 小时稳定性仍待验证。

## P6 License 客户端与服务端（PRD 14）

- [x] 服务端提供 7×24 小时设备级试用，卸载/重装不重置服务端起止时间。
- [x] 服务端持久管理 Policy/License/Machine/Trial/Entitlement/审计与设备额度；Bearer 管理 API 不返回 Key/refresh hash。
- [x] 服务端签发 Ed25519 `SignedEntitlementReceipt`，包含 schema、产品、机器 hash、功能和时间窗口。
- [x] 客户端固定公钥验签并校验 schema/产品/设备/功能/时间/版本，本地启动不等待网络。
- [x] Receipt 同目录原子替换、0600、排除备份；License/refresh credential 进入 Keychain。
- [x] 激活、刷新、停用、后台单飞、离线窗口、服务故障/授权无效状态分离、jitter 指数退避、网络恢复与显式重试已实现。
- [x] 试用只开放扫描与概要；写 Skill、补齐、清理、追踪、历史和导出由功能集统一门控。
- [x] 支付 webhook HMAC 验签、幂等落盘；购买/续费/退款/拒付/撤销收敛到授权状态。
- [x] E2E 覆盖试用持久、激活、Receipt 过期/防重放/篡改/跨设备、设备超限/停用释放、服务断开时本地验签及管理端撤销。
- [!] 接入正式 Keygen Cloud、支付平台、HSM/签名密钥轮换与支持后台（需要账号、区域、Policy 和 Secret）。

## P7 SwiftUI 客户端（PRD 5、6、15、20）

- [x] 原生主窗口包含首页、Agent、Skill、空间、活动、历史、设置七个导航入口。
- [x] 首页只保留主扫描动作、范围/隐私说明和最近快照摘要；扫描中展示六阶段和停止。
- [x] Agent/Skill/空间/活动结果可下钻且不可用不显示为 0；首页四组影响卡可直接跳转，空间支持 Product/Home/类别筛选。
- [~] Agent 多 Home、Skill Variant/安装副本/CRUD/补齐、唯一物理空间账本、安全清理复核、基础活动和历史已接 UI；当前打开文件已接入，变化事件仍待 Helper。
- [x] 菜单栏入口与状态可用；最近不可变快照以 0600 原子持久化恢复，扫描进度统一按阶段/250ms 节流。
- [x] License 无效/过期进入受限激活页并保留隐私、本地数据删除、关于和退出。
- [x] 设置已有自定义/忽略扫描范围、敏感路径遮蔽、活动采样、历史开关与保留期、权限入口、本地数据、License、Sparkle 更新、语言与登录启动。
- [~] `.app` 已内置简中/英文主流程资源并支持运行时切换；其它八种语言与全量动态文案仍待完成。
- [~] 已使用动态字体、文本+颜色状态、VoiceOver 标签/提示、键盘扫描命令并遵循 Reduce Motion；大字体、对比度与 Reduce Transparency 人工矩阵仍待验收。

## P8 发布工程（PRD 15、18、22）

- [~] Sparkle 2.9.5 固定依赖已接入，仅接受 HTTPS appcast + Ed25519 公钥；未配置不启动，更新会话与写操作互斥（正式 feed/key 待外部凭据）。
- [~] Makefile 已提供 App/CLI universal2、Hardened Runtime、Developer ID、notarytool、staple 与 Gatekeeper 门禁；签名/公证实跑待凭据。
- [~] Full Disk Access 提供系统设置入口，登录项展示 `SMAppService` 真实状态及恢复动作；签名 Trace Helper 尚未实现。
- [x] “删除本地数据并准备卸载”逐项停止服务，清除 Receipt/Keychain/快照/历史/登录项并报告残留，不删除第三方 Agent 数据。
- [ ] clean Mac 安装、更新、卸载和恢复演练通过。
- [!] Developer ID、notary profile、正式 appcast 与发布域名（需要发布凭据和渠道确认）。

## 待确认决策（来自 PRD 24）

- [!] Codex `version.json` 稳定字段以及 Skill/Artifact/会话/官方清理的匿名真实 fixture。
- [!] Claude Code、WorkBuddy 等新 Definition 的官方路径与 fixture；确认前保持空定义。
- [!] 7 天试用为概要能力还是全功能。
- [!] License 设备额度、换机、解绑、退款、永久/订阅规则。
- [!] Keygen 区域、SLA、成本、DPA、支付 webhook 部署与隐私文本。
- [!] 首发十语还是只开放简中/英文。
- [!] 是否继续正式支持 Intel（当前目标 universal2）。
- [!] App Store 或 Developer ID 独立分发（当前按独立分发设计）。

## 验证记录

| 时间 | 命令 | 结果 | 说明 |
| --- | --- | --- | --- |
| 2026-08-04 | `make build` | 通过 | SwiftUI 客户端、CLI、Go 服务端 release 编译 |
| 2026-08-04 | `swift run agentnest-core-tests` + `go test -race ./...` | 通过 | 79 个 Swift 核心检查；Go store/API/管理撤销测试与 race detector |
| 2026-08-04 | `make e2e` | 通过 | 多 Home/忽略位置、试用持久、离线过期、防重放、篡改/绑定、席位释放与撤销 |
| 2026-08-04 | `make check` | 通过 | 格式/资源 lint + release `.app`/CLI/服务端 + 79 项 Swift 检查 + Go race + 扩展 E2E |
| 2026-08-04 | `make build-universal` | 通过 | App、CLI 与 Sparkle.framework 均验证为 arm64+x86_64，App rpath 已校验 |
