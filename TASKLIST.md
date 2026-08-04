# AgentNest 开发任务清单与进度

> 真源：`prd.md` v2.1。状态：`[x]` 已完成并验证，`[~]` 已实现但仍缺发布级验证，`[ ]` 未完成，`[!]` 依赖外部确认或凭据。
>
> 完成定义：代码存在不等于完成；每项必须同时具备对应测试或可复现验收命令。总体完成还要求 `make build`、`make test`、`make e2e` 全部通过。

## P0 工程与质量门禁

- [x] 建立 Swift 6 / SwiftUI macOS 14 客户端分层工程（Presentation → Application → Domain → Infrastructure）。
- [x] 建立 Go License 服务端分层工程，服务端是 Trial、License、Machine 和 Receipt 的权威来源。
- [x] Makefile 提供 `build`、`test`、`e2e`、`check`、`clean`，默认产物不污染源码目录。
- [x] E2E 使用真实编译产物，覆盖客户端扫描和客户端—服务端授权主链路。
- [x] 两轮自审完成；当前已实现范围内的阻断问题已修正，剩余未实现/外部依赖见下文。

## P1 领域底座（PRD 4、16、17、18、19）

- [~] 定义不可变 `DeviceSnapshot`、Agent、Home、Artifact、Skill、Finding、Coverage 与完整度模型（安装/Profile/Linked Artifact 仍待补齐）。
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
- [x] Claude Code、WorkBuddy 空定义合法加载但不扫描、不声明能力、不显示为已支持。
- [~] fixture 已覆盖正例、近似目录、畸形指纹、深层目录、symlink 与硬链接；跨卷、不可读、扫描中变化仍待补。

## P3 空间、日期与清理（PRD 9、12）

- [x] 空间账本同时记录逻辑字节与 `st_blocks × 512` 物理字节并按物理字节排序。
- [~] 已按 Agent/Home 汇总并可下钻；类别/卷、共享与未归属 Linked Artifact 仍待补。
- [x] 大小阈值与日期筛选作用于完整 Cleanup Unit，不改变风险等级。
- [x] 最后活动使用分级证据；未知、冲突或仅 atime 的对象不进入自动日期清理。
- [x] 活动中、writer 存在、引用未验证或目标变化的对象不可清理。
- [x] 清理计划包含目标、证据、风险、活动、删除方式、恢复性和预计物理字节。
- [x] 执行前复验 identity/type/symlink/generation；路径目标只走系统废纸篓，官方删除无执行器时 fail closed。
- [~] 批量逐项反馈成功/失败/跳过/取消；执行后单来源重扫尚未接入 UI。

## P4 Skill（FR-SKILL-01…12、FR-PATCH-01…09）

- [x] 索引目录型 `SKILL.md` 和定义声明格式；只读静态文本并限制大小、文件数、路径与 symlink。
- [x] 生成逻辑 Skill、Variant、安装副本、Coverage、缺失、冲突和无效状态。
- [~] 同名不同内容形成多个 Variant；全局作用域已实现，项目作用域仍待接入。
- [~] 创建、同格式补齐和删除执行器已实现；编辑、重命名、二进制替换尚未完成。
- [x] 创建/补齐使用同父目录 staging、文件 fsync、目录 fsync 和原子 rename；并发变化拒绝覆盖。
- [~] 补齐计划包含来源包和目标并默认不覆盖；跨格式 materializer、用户 diff/冲突决策 UI 尚未完成。
- [~] 独立预检拒绝越界 symlink/特殊文件/超预算内容；多目标串行批处理尚未完成。
- [~] 覆盖矩阵在重扫后可验证；写操作与受影响位置自动重扫尚未串联。
- [~] 已测试 Variant、覆盖、目标变化、原子写入、symlink 拒绝；完整 CRUD/staging 崩溃恢复仍待补。

## P5 原生活动、卷、历史与报告（PRD 11、13）

- [~] 基础采集 CPU 与网络；首样本只建基线。物理磁盘、卷和可见进程仍待补。
- [ ] Agent 归因绑定进程启动身份、安装实例与 Home/工作区证据，防止 PID 复用串会话。
- [~] 每项指标携带 available/partial/unavailable、观测时长与覆盖率；dropped count 仍待补。
- [ ] 文件打开与文件变化分开展示；未知活动归入“macOS 与其它进程”。
- [ ] Trace Helper 双向验证签名身份、固定命令/参数、15 分钟上限、有界输出和 owner 断开回收。
- [ ] 卷、物理设备映射及 `diskutil -plist` 健康字段结构化展示，不伪造健康结论。
- [~] 历史默认关闭；开启后使用 SQLite 保存脱敏聚合与 coverage，并设 160 MB 硬上限；长期分层降采样仍待补。
- [~] CSV 稳定 schema 已完成；本机分页 PDF 尚未完成。
- [~] 已测试首样本和计数器回退；事件风暴、Helper 无孤儿进程与 24 小时稳定性仍待验证。

## P6 License 客户端与服务端（PRD 14）

- [x] 服务端提供 7×24 小时设备级试用，卸载/重装不重置服务端起止时间。
- [~] 服务端管理 License/Machine/Trial/审计与设备额度；Entitlement/Policy 后台管理 API 仍待补。
- [x] 服务端签发 Ed25519 `SignedEntitlementReceipt`，包含 schema、产品、机器 hash、功能和时间窗口。
- [x] 客户端固定公钥验签并校验 schema/产品/设备/功能/时间/版本，本地启动不等待网络。
- [x] Receipt 同目录原子替换、0600、排除备份；License/refresh credential 进入 Keychain。
- [~] 激活、刷新、停用、后台单飞、离线窗口和服务故障/授权无效状态分离已实现；jitter 退避与网络恢复触发待补。
- [x] 试用只开放扫描与概要；写 Skill、补齐、清理、追踪、历史和导出由功能集统一门控。
- [x] 支付 webhook HMAC 验签、幂等落盘；购买/续费/退款/拒付/撤销收敛到授权状态。
- [~] E2E 覆盖试用持久、激活、Receipt 篡改/跨设备和设备超限；过期、防重放、断网、撤销仍待扩展。
- [!] 接入正式 Keygen Cloud、支付平台、HSM/签名密钥轮换与支持后台（需要账号、区域、Policy 和 Secret）。

## P7 SwiftUI 客户端（PRD 5、6、15、20）

- [x] 原生主窗口包含首页、Agent、Skill、空间、活动、历史、设置七个导航入口。
- [x] 首页只保留主扫描动作、范围/隐私说明和最近快照摘要；扫描中展示六阶段和停止。
- [~] Agent/Skill/空间/活动结果可下钻且不可用不显示为 0；首页四组影响排序卡片仍待补。
- [~] Agent 多 Home、Skill Variant、空间排序、基础活动和历史已接 UI；Skill 三视角、清理复核、活动文件证据仍待补。
- [~] 菜单栏入口与状态可用；持久状态恢复和统一节流器待补。
- [x] License 无效/过期进入受限激活页并保留隐私、本地数据删除、关于和退出。
- [~] 设置已有隐私、活动、权限、历史和本地数据删除；自定义范围、Agent/Skill、更新、语言、登录启动仍待补。
- [~] `.app` 已内置简中/英文主流程资源；动态文案、运行时切换、其它八种语言与布局验收仍待完成。
- [ ] 键盘、VoiceOver、大字体、对比度、Reduce Motion/Transparency 和非颜色状态语义验收通过。

## P8 发布工程（PRD 15、18、22）

- [ ] Sparkle 2 固定 HTTPS appcast 与 Ed25519 更新签名集成，更新与写/追踪任务互斥。
- [ ] App + Helper universal2、Hardened Runtime、Developer ID 签名、公证、staple、Gatekeeper 验证通过。
- [ ] Full Disk Access、Helper、登录项分别展示真实权限与恢复动作。
- [ ] “删除本地数据并准备卸载”逐项停止服务、删除或报告 Receipt/Keychain/快照/历史/Helper 残留。
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
| 2026-08-04 | `swift run agentnest-core-tests` + `go test -race ./...` | 通过 | 34 个 Swift 核心检查；Go store/API 测试与 race detector |
| 2026-08-04 | `make e2e` | 通过 | 多 Home 扫描、试用持久、签名激活、篡改/设备绑定/设备上限 |
| 2026-08-04 | `make check` | 通过 | release `.app`/CLI/服务端编译 + 34 项 Swift 检查 + Go 测试 + E2E |
| 待执行 | `make check` | - | 格式、静态检查、测试与 E2E 汇总 |
