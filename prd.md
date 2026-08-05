# AgentNest 产品需求文档

> 产品名称：AgentNest  
> 文档版本：v2.2
> 文档状态：重构目标稿  
> 更新日期：2026-08-05
> 目标平台：macOS 14 及以上，Apple silicon 与 Intel  
> 客户端技术：Swift 6、SwiftUI，必要处使用 AppKit  
> 基线来源：原 FindDiskKiller PRD 及本次 Agent 管理需求  
> 数据策略：本机优先、默认无遥测、破坏性操作必须复核

## 0. 文档说明

### 0.1 文档目的

本文定义 AgentNest 的完整产品目标、信息架构、功能边界、核心模型、交互流程、安全约束、技术架构和验收标准，作为产品设计、研发、测试和发布的共同真源。

AgentNest 不是在 FindDiskKiller 上增加几个 Agent 页面，而是一次产品中心的重建：产品从“解释磁盘活动”转为“发现、理解、维护和清理整台 Mac 上的 Agent 环境”。原 PRD 中成熟的实时监控、磁盘健康、空间分析、历史报告和安全清理能力，作为 Agent 治理的证据与执行底座继续保留。

### 0.2 已确定的产品决策

- 产品正式命名为 **AgentNest**，中文可称“Agent 管家”，不再使用 FindDiskKiller 作为用户可见名称。
- 只支持 macOS，不设计 Windows/Linux 抽象、路径或兼容层。
- 客户端必须使用 Swift 开发并提供原生 GUI。
- 首页采用“一键智能扫描”心智；高级范围和权限放在二级入口，不要求普通用户先理解目录结构。
- Agent、Agent Home、Profile 和安装实例是不同概念；同一 Agent 的多个 Home 必须分别识别和管理。
- 扫描只从 Agent Definition、环境变量和用户明确添加的 Agent Home 生成候选；不递归搜索整个用户 Home。
- Skill 以全机虚拟索引统一展示，但真实文件仍留在各 Agent 的原生位置；虚拟视图不是新的物理仓库。
- Skill 的“Patch”是产品术语，中文主文案使用“补齐”；它是经过适配、预检和原子写入的复制，不是对旧格式打兼容补丁。
- 按日期清理以“完整可清理单元的最后活动时间”为准，绝不逐个删除目录内较老文件。
- 监控数据只作为证据，不凭一次 CPU、I/O 或路径事件自动删除内容。
- License 的试用起点、订阅和设备额度由服务端权威记录；客户端保存由服务端签名、绑定设备且有有效期的本地授权凭证，以便快速启动和有限离线使用，但不信任可直接篡改的布尔状态。
- 不迁移旧数据库、缓存、Helper 协议或 FindDiskKiller 页面状态；如未来需要升级迁移，另立专项需求。

### 0.3 Agent 适配边界

- v1.0 首个完整内置定义为 **OpenAI Codex**：默认 Home 候选为 `~/.codex`，根目录中的 `version.json` 是必要指纹文件。
- Claude Code、WorkBuddy 和其它 Agent 先保留空的声明式定义槽位；在目录、指纹和能力得到确认前，不对外宣称已支持，也不猜测其文件结构。
- 新增一个常规 Agent 应以“增加一份声明式定义 + fixture”为主，不得要求修改扫描器、领域模型或页面；只有关系解析、格式转换或官方清理等高级能力才新增 Swift Adapter。
- 业界新增 Agent 时可以通过发布内置定义或签名规则目录更新识别能力；远程规则不得包含脚本或可执行代码。

## 1. 产品定义

### 1.1 一句话定义

AgentNest 是一款原生 macOS Agent 管理工具：一键发现已声明位置中的 Agent、Home、Skill、会话和空间占用，解释正在发生的资源活动，并帮助用户安全地补齐 Skill、清理陈旧数据和维护 Agent 环境。

### 1.2 用户问题

安装多个 AI Agent 后，用户通常无法回答：

1. 这台 Mac 上到底装过或使用过哪些 Agent？它们的数据分别在哪里？
2. 同一 Agent 是否存在多个 Home/Profile，是否还有隐藏或遗忘的数据目录？
3. 哪个 Agent 占用了最多空间，空间增长来自会话、缓存、日志、运行时还是 Skill？
4. 哪些数据已经长期不用，哪些正在运行，哪些能够安全清理？
5. 全机有哪些 Skill，它们覆盖了哪些 Agent，版本是否一致，谁缺了什么？
6. 如何把一个 Agent 中好用的 Skill 安全补齐到另一个 Agent？
7. 当 Mac 发热、卡顿、磁盘持续写入或外接盘被唤醒时，是否与某个 Agent 有关？

### 1.3 产品价值

- **看得准**：固定目录、环境变量和用户明确添加的 Home 统一验证，不用全盘搜索换取虚假的“覆盖率”。
- **看得懂**：将文件树转成 Agent、Skill、会话、缓存、运行时和风险级别。
- **管得住**：Skill 增删改查、跨 Agent 补齐、陈旧数据清理和来源级重扫形成闭环。
- **不误删**：清理前复核身份、活动、引用与路径，优先移入废纸篓，结果以重扫确认。
- **有证据**：把 CPU、磁盘、网络、打开文件、文件变化、卷和设备健康放回 Agent 上下文。

## 2. 目标用户与核心场景

### 2.1 目标用户

- 同时使用两个及以上 Coding Agent 的开发者；
- 使用本地个人 Agent、办公 Agent 或知识工作 Agent 的普通用户；
- 需要维护团队 Skill、规则和自动化能力的高级用户；
- 经常遇到磁盘空间不足、Agent 缓存膨胀或持续资源占用的 macOS 用户；
- 需要排查 Agent 对项目目录、外接盘和系统资源影响的创作者与运维人员。

### 2.2 核心场景

- 新用户打开 AgentNest，点击一次“扫描”，看到 Agent 数、总占用、可清理候选和 Skill 覆盖问题。
- 用户发现 Codex 有三个符合其指纹的 Home，其中两个来自 `CODEX_HOME` 和用户明确添加的位置。
- 用户按“90 天未活动”筛选会话/缓存，在复核后批量清理。
- 用户按大小查看 Agent 占用，定位到某个 Agent 的会话归档或浏览器运行时。
- 用户在全局 Skill 视图看到 `release` Skill 覆盖两个已配置 Agent Home，但第三个已配置目标缺失，点击“补齐”完成复制。
- 用户发现同名 Skill 在三个 Agent 中内容不同，通过版本/内容差异选择正确来源。
- 用户看到某个 Agent 正在持续写盘，进入活动详情定位到工作区和文件证据，因此暂缓清理。

## 3. 产品目标、非目标与成功标准

### 3.1 产品目标

- G1：通过一次扫描建立已配置 Agent 资产清单，覆盖 Definition 默认路径、环境变量和用户明确添加的多 Home。
- G2：统一衡量 Agent 空间并支持按来源、大小、类别和最后活动日期分析。
- G3：建立全机 Skill 虚拟索引，准确表达覆盖、缺失、重复、冲突和无效状态。
- G4：完成 Skill 的创建、查看、编辑、删除和跨 Agent 补齐闭环。
- G5：将现有资源监控与 Agent 身份关联，作为诊断和清理保护证据。
- G6：所有写操作可预览、可解释、可取消或可恢复，并在执行前重新验证。
- G7：通过 7 天设备级试用、设备激活和本地可验证授权凭证支持未来商业化。

### 3.2 非目标

- 不运行或调度 Agent，不替代 Agent 客户端、IDE 或终端。
- 不提供 Prompt 市场、Skill 商店、云同步或团队分发平台。
- 不执行 Skill 中包含的脚本，不判断 Skill 的业务效果是否正确。
- 不自动改写 Agent 的认证信息、API Key、模型配置或权限策略。
- 不上传会话内容、Skill 内容、项目路径、进程列表或空间扫描结果。
- 不自动杀进程，不将高资源占用等同于恶意行为。
- 不支持远程控制、企业 MDM、合规取证或 Windows/Linux。
- 不承诺客户端授权“绝对不可破解”；目标是服务端权威、提高篡改成本并控制密钥泄露影响。

### 3.3 用户成功标准

- 首次用户无需选择目录即可发现所有已配置且通过 fixture 验证的 Agent；未配置定义的 Agent 不制造“已支持”假象。
- 用户能区分“Agent 产品”“安装实例”“Home/Profile”和“数据位置”。
- 任意占用数字均可下钻到来源、类别和证据，不出现无法解释的重复计算。
- 用户能在 3 次点击内从扫描结果进入最大占用项或 Skill 缺失项。
- 用户能在补齐前看到来源、目标、格式转换、冲突和预计写入文件。
- 用户能在清理前知道目标是否正在使用、如何删除、能否恢复、会保留什么。

### 3.4 产品质量指标

默认不采集使用遥测，因此 v1 以本地测试和发布质量指标作为硬门槛：

- 受支持适配器 fixture 识别准确率 100%，不得把无关目录识别为已确认 Agent Home；
- 空间物理字节在卷内守恒，硬链接和重叠根不重复计算；
- Skill 覆盖矩阵与磁盘真实文件一致，增删改补齐后重扫一致；
- 所有破坏性自动化测试均验证越界、symlink、身份变化和活动目标保护；
- 24 小时运行无无界内存、任务、文件描述符、子进程或数据库增长。

License 服务可统计试用创建、授权成功、到期和设备额度事件，但不得携带扫描、Agent 或路径信息。商业转化目标由商业计划另行定义。

## 4. 核心概念与统一模型

| 概念 | 定义 |
| --- | --- |
| Agent Product | 用户认知中的产品，如 Codex、Claude Code、WorkBuddy |
| Agent Installation | 由 Bundle、可执行文件、包管理器或明确元数据确认的安装实例 |
| Agent Home | 一个 Agent 实际读取/写入数据的根目录；同一产品可有多个 |
| Profile | Agent Home 内可独立管理的账号、工作区或配置域；无此概念的 Agent 不伪造 Profile |
| Location | Home 下或外部被 Agent 引用的实际目录 |
| Adapter | 描述某类 Agent 如何识别 Home、分类空间、发现 Skill 和执行官方清理的适配器 |
| Artifact | 会话、缓存、日志、运行时、数据库、Skill、配置等可测量资源 |
| Linked Artifact | 位于 Agent Home 外、但由可验证会话/工作区关系归属给 Agent 的 worktree、容器对象、Simulator 或构建环境 |
| Skill | 一个 Agent 可发现的技能包；通常含主清单/说明文件及支持文件 |
| Skill Variant | 同一逻辑 Skill 的一种内容或版本实现 |
| Coverage | 某 Skill Variant 在哪些 Agent Home/Profile 中有效存在 |
| Finding | 扫描产生的缺失、冲突、无效、超大、陈旧、不可读或活动中等结论 |
| Cleanup Unit | 能够整体复验和处理的最小清理单元，禁止拆散内部文件随意清理 |
| Snapshot | 某次扫描生成的不可变结果，带 generation、范围、时间和完整度 |

所有列表、选择、清理和补齐必须基于稳定身份，不得以展示名称或字符串路径作为唯一主键。路径类资源至少使用标准化路径、volume identity、device、inode、类型和扫描 generation 组合确认。

## 5. 产品范围与优先级

### 5.1 v1.0 必须交付

- 原生 Swift/SwiftUI macOS 应用、菜单栏入口和状态恢复；
- 7 天试用、License 激活、设备绑定、本地签名凭证和后台续期；
- 首页一键智能扫描、实时阶段进度、停止与重新扫描；
- Codex 默认识别、可扩展 Agent Definition、多 Home、环境变量和自定义位置；
- Agent 空间汇总、按大小分析、按日期筛选与安全清理；
- 全机 Skill 虚拟视图、覆盖矩阵、冲突/缺失/无效状态；
- Skill 创建、查看、编辑、删除和跨 Agent 补齐；
- Agent 级 CPU/磁盘/网络活动，文件证据、卷映射与活动目标保护；
- 默认关闭的本机历史、趋势与 CSV/PDF 导出；
- 权限、隐私、更新、卸载和本地数据删除流程；
- 简体中文与英文完整可用，架构支持原基线十种语言。

### 5.2 后续版本候选

- 用户主动添加的远程 Skill Catalog；
- 团队策略、Skill 签名和可信发布者；
- Agent/Skill 健康建议和重复配置合并；
- 经用户明确同意的加密导出/导入；
- 为 Claude Code、WorkBuddy、办公 Agent 和其它新 Agent 补充经过验证的定义与 Adapter。

## 6. 信息架构与极简 UI

### 6.1 全局导航

主窗口采用克制的侧栏，不复制相同能力：

1. **首页**：品牌视觉、一键扫描、最近一次扫描摘要；
2. **Agent**：安装/Home/Profile 清单与详情；
3. **Skill**：全机虚拟视图、覆盖矩阵和管理入口；
4. **空间**：按大小、日期、类别和卷分析，进入统一清理；
5. **活动**：Agent 活动、应用/进程、文件、卷与磁盘健康证据；
6. **历史**：趋势、对比、报告与导出；
7. **设置**：扫描范围、隐私、权限、License、更新与卸载。

默认进入首页。License 过期时只显示激活页，并保留隐私说明、支持、关于和卸载入口。

菜单栏只提供低认知负担的状态入口：显示扫描/监控状态、当前最高活动 Agent、打开主窗口、开始/停止基础采集和退出。异常、停止、License 到期与数据不可用不能只靠颜色表达；菜单栏不得复刻完整扫描结果或触发无复核清理。

### 6.2 首页

视觉可参考 CleanMyMac 的低认知负担，而不是复制其布局或素材：

- 中央使用一个明确的主按钮：“扫描”；
- 主按钮周围可使用低干扰动态视觉表达待机、扫描、完成和风险；
- 扫描前只显示范围摘要与“完全在本机分析”；
- 有历史快照时显示上次扫描时间、Agent 数、占用、Skill 问题和清理结果；
- 不在首屏堆叠进程表、复杂树或多个同级 CTA；
- 支持 Reduce Motion，动画关闭后状态语义完整保留。

### 6.3 扫描进度

点击扫描后留在同一视觉中心，依次展示：

1. 发现 Agent；
2. 验证 Home/Profile；
3. 索引 Skill；
4. 测量空间；
5. 生成安全与活动结论；
6. 对账并完成。

要求：

- 未知总工作量时使用不确定进度和真实计数；完成发现后才可展示可计算百分比；
- 展示当前阶段、正在分析的 Agent/位置、已发现数量、已处理条目和字节；
- 可停止；停止后丢弃当前 generation，立即恢复上一份完整快照；
- 重扫期间保留旧快照可浏览，新 generation 完成后原子替换；
- 扫描结束提供“查看结果”，并按影响排序展示结果卡片。

### 6.4 扫描结果

结果分为四组，顺序按是否需要行动动态调整：

- Agent：已发现、未确认、多 Home、不可读；
- Skill：总数、缺失、冲突、无效；
- 空间：总占用、最大来源、陈旧候选、可安全清理候选；
- 活动：当前高占用 Agent、正在使用目标、磁盘/权限异常。

每个结果必须能下钻到对应专页；无问题时给出具体已检查范围，而不是只显示“很安全”。

## 7. 智能扫描

### 7.1 扫描范围

- FR-SCAN-01：默认只检查 Agent Definition 声明的 Home 候选，并递归扫描通过指纹验证的 Agent Home。
- FR-SCAN-02：用户可明确添加其它 Agent Home；自定义路径是精确候选，不是新的递归搜索范围。
- FR-SCAN-03：不得将当前用户 Home、磁盘根目录或自定义候选的父目录作为通用发现根。
- FR-SCAN-04：范围预览必须说明预计访问的位置、是否可能需要 Full Disk Access，以及不会上传内容。
- FR-SCAN-05：支持全量扫描、单 Agent 重扫、单 Home 重扫、仅 Skill 重扫和仅空间重算。
- FR-SCAN-06：所有任务带 generation；取消或迟到结果不得覆盖更新快照。

### 7.2 扫描管线

- FR-SCAN-07：先发现候选根，再对候选做浅层指纹验证，最后才读取适配器需要的元数据和内容。
- FR-SCAN-08：文件系统遍历使用有界 I/O 并发；目录枚举、内容解析和大小测量分离，不能重复遍历整棵树。
- FR-SCAN-09：每个已确认 Agent Home 只建立一次目录索引，并由 Skill 发现和空间账本共享。
- FR-SCAN-10：读取失败保留其它结果，并记录路径、原因、影响范围和恢复动作。
- FR-SCAN-11：扫描前后身份、类型、大小或修改时间变化的项标记为不稳定；相关精确结论被抑制。
- FR-SCAN-12：扫描不执行 Agent、Skill 脚本或未知二进制，不加载动态插件代码。

### 7.3 完整度

每份快照分别展示：

- 目录覆盖：完整/部分/不可用；
- Agent 识别覆盖：已确认/可能/未知；
- 空间覆盖：已测量字节、不可读位置、冲突字节；
- Skill 覆盖：已读取、无效、不可读、远程引用未下载；
- 活动覆盖：可归因、部分和不可用。

未知或不可读不能显示为 0，也不能用一个总百分比掩盖不同维度的缺口。

## 8. Agent 发现与识别

### 8.1 v1.0 定义状态

| Agent | 定义状态 | v1.0 行为 |
| --- | --- | --- |
| OpenAI Codex | 已定义 | 默认候选 `~/.codex`；支持 `CODEX_HOME` 和用户添加的精确 Home；以根目录 `version.json` 为必要指纹 |
| Claude Code | 空定义 | 只保留稳定 ID、显示名和图标槽位；路径、指纹、Skill、空间与清理能力为空 |
| WorkBuddy | 空定义 | 只保留稳定 ID、显示名和图标槽位；路径、指纹、Skill、空间与清理能力为空 |
| 其它 Agent | 未定义 | 通过新增 Agent Definition 接入；未接入前最多作为用户确认的未知来源，不标注具体产品 |

“空定义”不是产品支持。界面、官网和发布说明只能列出已定义、通过 fixture 且能力验收完成的 Agent。

### 8.2 发现来源

- 固定默认目录和 macOS Application Support/Containers 路径；
- 已安装 App 的 Bundle ID、签名、容器和可执行文件；
- 当前用户 shell 环境、launchd 环境及 Agent 明确支持的 Home 环境变量；
- Agent 配置文件中声明的数据、XDG、Skill 或工作区目录；
- 正在运行进程的可执行路径、参数和打开位置（只读、按权限）；
- 用户添加的位置；
- 用户显式加入的 Agent Home。

### 8.3 定向发现规则

- FR-DISC-01：候选只来自 Definition 默认路径、声明的环境变量、用户添加路径和本机确认记录。
- FR-DISC-02：候选先做浅层指纹验证；只有已确认 Agent Home 才递归，不跟随后代 symlink、不跨 volume，并跳过 App bundle、Git object 和依赖包等明确无关内容。
- FR-DISC-03：候选验证只读取 Definition 声明的有限结构指纹；禁止遍历候选父目录或对无关目录打开数据库。
- FR-DISC-04：识别证据由 Agent Definition 声明为 required/optional/negative；每个已支持 Agent 必须通过正例、近似目录和反例 fixture 决定最低确认条件。
- FR-DISC-05：只有满足定义中的全部 required 指纹且不命中 negative 指纹才标为“已确认”；单纯目录名相似只能标为“可能的 Agent Home”。
- FR-DISC-06：用户可确认、忽略或为“可能”目录指定 Agent 类型；确认只形成本机自定义来源，不改变全局适配器。
- FR-DISC-07：多个路径指向同一 inode/root 时合并；嵌套 Home 按适配器归属规则处理，未决重叠进入冲突账本。
- FR-DISC-08：同一产品的默认 Home、自定义 Home、旧 Home 和嵌入式 Home 分别显示，不静默合并数据。

### 8.4 Agent Definition 与 Adapter

适配体系分为两层：

1. **Agent Definition（声明式）**：定义产品身份、Home 候选、环境变量、指纹、Skill 位置、Artifact 路径规则和能力开关。
2. **Agent Adapter（Swift 代码）**：只处理声明无法表达的数据库关系、会话 family、格式转换、活动归因和官方清理。

Agent Definition 使用带 `schemaVersion` 的 JSON。每个 Agent 一份资源文件，示意如下：

```json
{
  "schemaVersion": 1,
  "id": "openai.codex",
  "displayName": "Codex",
  "homeDiscovery": {
    "defaultPaths": ["~/.codex"],
    "environmentVariables": ["CODEX_HOME"]
  },
  "fingerprints": {
    "required": [
      { "kind": "jsonFile", "relativePath": "version.json" }
    ],
    "optional": [],
    "negative": []
  },
  "skills": [],
  "artifacts": [],
  "capabilities": {
    "space": false,
    "skills": false,
    "activity": false,
    "cleanup": false
  }
}
```

示例只固定当前已知的 Home 和必要指纹；Codex 的 Skill、Artifact 与清理规则必须在真实 fixture 验证后逐项开启，不能因发现 `version.json` 就自动开放写入或清理。

- FR-ADAPTER-01：扫描器只依赖通用 Definition 模型；新增普通 Agent 不修改扫描核心或 UI switch。
- FR-ADAPTER-02：Definition 支持 default path、环境变量和明确的 Home 候选，不把 Home 规则硬编码到 View。
- FR-ADAPTER-03：指纹类型使用固定白名单，如文件/目录存在、JSON/plist 字段、SQLite 只读 schema 和有限文本模式；定义不能携带任意正则灾难模式、命令或代码。
- FR-ADAPTER-04：空定义必须合法加载，但不参与扫描、不产生候选、不声明能力。
- FR-ADAPTER-05：Definition schema 不兼容、字段未知或签名无效时整份拒绝，回退到最近有效内置目录。
- FR-ADAPTER-06：在线目录更新使用离线签名，只能更新声明式数据；Swift Adapter 仍随签名 App 版本发布。
- FR-ADAPTER-07：每个定义必须提供默认 Home、环境变量 Home、自定义 Home、未声明深层目录、缺失指纹、畸形指纹和重叠根 fixture。
- FR-ADAPTER-08：外部格式或版本未知时 fail closed，显示“已发现，待适配”，不猜测关系、Skill 格式或开放清理。

### 8.5 Codex 识别规则

- FR-CODEX-01：`~/.codex` 是默认候选，而不是唯一 Home。
- FR-CODEX-02：环境变量和用户添加的精确路径只要满足同一 Definition，都可成为独立 Codex Home。
- FR-CODEX-03：候选根必须包含可读取且可解析为 JSON 的 `version.json`；具体字段约束由真实 Codex fixture 补充，未确认前不在 PRD 中虚构。
- FR-CODEX-04：仅路径名为 `.codex` 但缺少/损坏 `version.json` 时显示“疑似 Codex”，不得计入已确认 Agent 总数。
- FR-CODEX-05：未被 Definition、环境变量或用户操作声明的目录，即使包含 `version.json` 或名为 `.codex`，也不得被扫描或计入疑似结果。
- FR-CODEX-06：多个已确认 Codex Home 分别展示来源、版本证据、物理身份和占用；同一物理根的别名只计一次。

## 9. Agent 空间占用管理

### 9.1 空间总览

- FR-SPACE-01：展示 Agent 总占用、按 Agent/Home/Profile/卷分布、可清理候选和最近增长。
- FR-SPACE-02：支持列表、分组条形图和大小排序；首版不以复杂 Treemap 作为唯一入口。
- FR-SPACE-03：任一数字可下钻到会话、缓存、日志、运行时、浏览器、数据库、Skill、配置、未归属和目录开销。
- FR-SPACE-04：支持最小大小阈值、类别、Agent、Home、卷、风险和活动状态筛选。
- FR-SPACE-05：扫描结果显示逻辑大小与物理分配大小，默认排序使用物理分配大小。
- FR-SPACE-06：Agent 在 Home 外创建的 worktree、项目环境、容器对象、Simulator 或构建缓存仅在存在可验证关系时显示为 Linked Artifact；没有关系证据时留在未归属，不因“最近由 Agent 进程打开”就取得所有权。
- FR-SPACE-07：Linked Artifact 的宿主文件物理占用与 Docker/Podman/Simulator 等 Provider 报告值分开显示，禁止相加为虚假总量。

### 9.2 空间测量

- 文件系统占用以 `st_blocks × 512` 的物理分配字节为主，保留逻辑大小；
- 以 device + inode 去重硬链接、alias 和重叠根；
- 配置根可解析 symlink，但后代 symlink 不跟随；
- Agent 报告值、数据库逻辑归因和文件系统物理值分别展示，不直接相加；
- 跨 Agent 共用目录进入“共享”，归属不明进入“未归属”，二者均只计一次；
- 数据库以只读方式打开，不 checkpoint、不创建 sidecar、不阻塞现有 writer；
- 目录、文件或数据库在扫描中变化时降低完整度。

### 9.3 按日期分析与清理

- FR-DATE-01：支持今天、7/30/90/180/365 天未活动、自定义截止日期和日期区间。
- FR-DATE-02：日期作用于完整 Cleanup Unit，例如会话 family、归档、日志轮转包或独立缓存对象，不作用于其内部散落文件。
- FR-DATE-03：最后活动时间证据优先级为 Agent 官方元数据、会话/对象元数据、内容最大有效修改时间、根目录修改时间。
- FR-DATE-04：仅有不可靠 atime、时间冲突或未知时间的目标不进入自动日期清理集合。
- FR-DATE-05：结果必须显示采用的日期字段和证据等级；“创建于”“最后活动”“最后修改”不可混用。
- FR-DATE-06：活动中、最近被打开、存在 writer 或关系未验证的单元始终不可清理，即使满足日期条件。

### 9.4 按大小扫描

- FR-SIZE-01：支持按 Agent、Home、类别和 Cleanup Unit 从大到小排序。
- FR-SIZE-02：支持“超过 100 MB/500 MB/1 GB/5 GB”和自定义阈值。
- FR-SIZE-03：大文件/目录扫描复用统一空间账本，不另起一套 `du` 结果。
- FR-SIZE-04：展示前 N 项时同时展示总项数、已覆盖字节和其它项，不在模型层静默截断。
- FR-SIZE-05：大小只是分析维度，不改变风险等级；大配置、Skill、认证或活跃会话不会因此变成安全清理项。

### 9.5 关联开发环境

- Git 仓库、worktree、共享 common git dir、分支和 commit 关系按需发现，不阻塞 Agent Home 的首批扫描结果；
- 当前进程工作目录所在仓库不可清理，主仓库存在关联 worktree 时不可直接移除；worktree 只通过 `git worktree remove` 处理；
- Docker/Podman 镜像、容器、Volume 和构建缓存必须按 Provider 独立建模；运行容器不可删除，Volume 默认为受保护持久数据，禁止 `--force`；
- Simulator device/runtime 只通过 `simctl` 处理，已下载未安装的明确 asset 才可作为文件目标；
- AgentNest 只有在 Agent 会话元数据、创建记录或稳定工作区关系能够证明归属时，才将这些资源计入某个 Agent；否则作为未归属开发环境展示；
- 所有官方对象执行前重新查询存在性、运行状态和引用；CLI 失败不得降级为手工删除底层文件。

## 10. Agent Skill 管理

### 10.1 Skill 发现与状态

- FR-SKILL-01：扫描所有已确认 Agent Home/Profile 的全局 Skill 和已发现项目范围内的项目 Skill。
- FR-SKILL-02：支持目录型 `SKILL.md`、适配器声明的单文件 Skill，以及产品原生等价格式。
- FR-SKILL-03：索引主文件、frontmatter/manifest、支持文件列表、总大小、修改时间、内容哈希、来源和作用域。
- FR-SKILL-04：只解析静态文本和目录结构，不执行 Skill 脚本、安装依赖或发起网络请求。
- FR-SKILL-05：状态至少包含：有效、无效、不可读、重复、内容冲突、被覆盖、禁用、不兼容、远程引用和缺失。
- FR-SKILL-06：校验名称、描述、目录名、必需文件、相对路径、symlink 越界、目标 Agent 能力和格式限制。

### 10.2 全机虚拟视图

虚拟视图将相同逻辑 Skill 聚合为一行，不移动真实文件。

- 顶部展示逻辑 Skill 总数、Variant 总数、安装副本数、覆盖 Agent 数、缺失数、冲突数和无效数；
- 主表按 Skill 展示来源 Variant、覆盖的 Agent Home/Profile 和缺失目标；
- 可切换“按 Skill”“按 Agent”“覆盖矩阵”三种视角；
- 同名但内容不同的 Skill 不合并成一个版本，展示为多个 Variant；
- Skill 稳定身份优先使用规范化 manifest ID；没有 ID 时使用规范名称 + 结构化内容指纹；
- 格式化差异可单独忽略，但正文、脚本和引用文件差异必须形成 Variant；
- 全局 Skill 与项目 Skill 分开统计，避免把某个项目内 Skill 误报为全机覆盖。

### 10.3 Skill CRUD

- FR-SKILL-07 创建：选择目标 Agent/Home/Profile、作用域和格式，生成最小有效结构；创建前验证重名与目标可写。
- FR-SKILL-08 查看：提供渲染预览、原文、文件树、元数据、覆盖和诊断；脚本只按文本查看。
- FR-SKILL-09 编辑：允许修改主文件和支持文本文件；二进制只可替换/移除；保存前展示校验错误和变更 diff。
- FR-SKILL-10 删除：默认将整个 Skill Cleanup Unit 移入废纸篓，不做逐文件删除；远程只读来源不可删除。
- FR-SKILL-11 重命名视为一次经验证的整体迁移，必须同步 manifest ID/目录名约束；不支持原地重命名的格式禁用该操作。
- FR-SKILL-12 所有写入使用同目录 staging、fsync 和原子替换；目标在编辑期间变化则拒绝覆盖并要求重载。

### 10.4 补齐（Patch）

- FR-PATCH-01：用户可从一个有效 Skill Variant 选择一个或多个缺失的 Agent Home/Profile 作为目标。
- FR-PATCH-02：相同格式可复制完整 Skill 包；不同格式必须通过目标适配器生成目标原生结构，不能裸拷贝后声称成功。
- FR-PATCH-03：预览页展示来源、目标、兼容性、格式转换、将创建/覆盖的文件、内容 diff 和风险。
- FR-PATCH-04：默认只允许补到“缺失”目标；存在同名 Variant 时进入冲突解决，不静默覆盖。
- FR-PATCH-05：支持“保留目标”“替换目标”“另存为新名称”；替换必须将旧 Skill 移入废纸篓或提供等价恢复点。
- FR-PATCH-06：禁止复制越界 symlink、socket、device、FIFO、权限异常文件和超出预算的内容。
- FR-PATCH-07：补齐不执行安装脚本、不修改 Agent 认证/全局权限、不自动重启 Agent。
- FR-PATCH-08：批量目标独立预检、串行提交；一个失败不污染其它目标；完成后只重扫受影响 Skill 位置。
- FR-PATCH-09：只有目标 Agent 实际重新发现且内容指纹一致/转换结果有效，才显示成功。

## 11. 活动监控整合

### 11.1 产品定位

原监控能力统一进入“活动”，服务三个目的：

1. 解释某个 Agent 为什么占用 CPU、磁盘或网络；
2. 将进程、文件、工作区、卷和物理磁盘证据关联回 Agent；
3. 在清理或 Skill 写入前识别活动目标并阻止危险操作。

活动不是第二套首页，Smart Scan 也不等待长期监控才完成。

### 11.2 基础采集

- FR-ACT-01：授权有效时启动基础 CPU、物理磁盘、网络、卷和可见进程采集，无需管理员权限。
- FR-ACT-02：默认采样间隔 3 秒，可设 1–60 秒；首样本仅建立基线。
- FR-ACT-03：Agent 归因使用进程启动身份 + 安装实例 + Home/工作区证据，PID 复用不得串会话。
- FR-ACT-04：整机指标与应用/Agent 指标口径分开；进程请求写入不等于物理设备写入。
- FR-ACT-05：每个指标独立携带 available/partial/unavailable、观测时长和覆盖率；未知不显示为 0。
- FR-ACT-06：无法归因的活动进入“macOS 与其它进程”，不强行分配给 Agent。
- FR-ACT-07：睡眠、唤醒、进程退出、设备重连和计数器回退重建基线，不制造尖峰。

### 11.3 Agent 活动详情

- 当前/区间 CPU、读取、写入、下载、上传和峰值；
- 关联进程、安装实例、Home、工作区和样本是否仍存活；
- 当前打开文件与最近变化作为两类证据展示；
- 可搜索路径、按活动/大小排序，并在 Finder 中显示；
- 权限、预算、事件丢失和进程结束分别显示；
- 同一 Agent 多进程按已验证宿主聚合，可下钻成员会话。

### 11.4 深度文件/目录追踪

用户可从 Agent 活动详情显式追踪一个文件或目录：

- 使用受限签名 Helper 调用固定系统追踪能力；
- 展示累计请求读写、最近五秒速率、会话峰值、最近事件和验证进程；
- 文件精确匹配，目录仅匹配自身与后代，`/foo` 不匹配 `/foobar`；
- 路径或输出格式无法验证时 fail closed，停止并隐藏精确数值；
- 离开工作区、App 退出、睡眠、超时或 owner 断开时停止；
- 最长会话默认 15 分钟；全局只允许一个高成本追踪会话；
- 追踪结果只在有界内存保存，不进入普通历史。

### 11.5 卷与磁盘健康

- 展示挂载卷、容量、可用空间、本地/可写/可移除属性和物理设备映射；
- 多卷共享设备时物理吞吐只计一次，网络卷/磁盘映像不伪造本地吞吐；
- 可显式追踪本地卷访问来源，但“最早观察到”不得表述为物理唤醒原因证明；
- 通过结构化 `diskutil -plist`/IOKit 展示系统实际报告的 SMART/NVMe 字段；
- 不支持、缺失、失败、断开和陈旧是不同状态；SMART Verified 不等于完整健康诊断；
- 不预测硬盘剩余寿命或确定故障日期。

## 12. 统一清理与写操作安全

### 12.1 风险分级

| 等级 | 示例 | 默认行为 |
| --- | --- | --- |
| 可重建 | 明确缓存、临时索引、可重新下载资源 | 可进入安全清理候选，仍需复核 |
| 重建昂贵/共享 | 运行时、浏览器数据、共享数据库、镜像 | 默认不选，解释代价与引用 |
| 用户内容 | 会话、归档、项目、Skill | 仅在详情中主动选择 |
| 受保护 | 配置、认证、密钥、活动会话、未知数据 | 不可清理 |

### 12.2 统一规则

- FR-CLEAN-01：只有具备真实 `CleanupTarget`、明确边界和验证策略的 Artifact 才可选择。
- FR-CLEAN-02：按日期和按大小只负责筛选，不降低风险等级。
- FR-CLEAN-03：所有清理进入复核页，列出目标、证据、预计候选占用、活动状态、删除方式、可恢复性和保留数据。
- FR-CLEAN-04：执行前重新验证 volume/device/inode、类型、symlink、路径边界、Home 身份、引用和活动状态。
- FR-CLEAN-05：路径目标优先移入系统废纸篓；Agent 官方对象使用官方 API/CLI；官方永久删除不得描述为废纸篓。
- FR-CLEAN-06：Agent 官方删除失败不得降级为直接改数据库或删除 transcript。
- FR-CLEAN-07：目标变化、活动中、引用不明或适配器版本不支持时跳过并要求重扫。
- FR-CLEAN-08：批量操作逐项反馈成功、失败、跳过和取消；取消停止尚未开始项，不回滚已经成功项。
- FR-CLEAN-09：外部命令有固定 executable、参数白名单、超时、输出上限、取消和子进程回收。
- FR-CLEAN-10：完成后只重扫受影响来源，以新快照确认；扫描前大小不承诺等于实际立即释放空间。

## 13. 历史、趋势与报告

- 历史默认关闭；关闭时不得创建历史数据库或写入聚合。
- 开启后只保存分钟级整机、设备和 Agent 聚合，不保存 PID、完整路径、会话标题、Skill 内容或追踪事件。
- 支持 7 天、30 天和 1 年；最近 24 小时分钟级，长期按 15 分钟/小时分层。
- 每项指标保存 coverage；不可用不能写 0，图表在缺口断线。
- Agent 空间快照只保存分类汇总与匿名稳定标识，默认不保存真实 Home 路径。
- 报告展示 Agent 空间增长、主要活动 Agent、磁盘/CPU/网络趋势和数据质量。
- CSV 使用稳定机器 schema；PDF 本机生成、分页并跟随应用语言。
- 历史数据库预算采用 32/64/128 MB，绝对上限 160 MB；临近上限先降采样明细，不能静默停止。
- 用户可“仅停止”或“停止并删除”；删除同时清除数据库、WAL/SHM 和历史匿名身份材料。

## 14. License、激活与 7 天试用

### 14.1 方案选择

AgentNest 采用桌面付费软件常见的 **设备激活 + 服务端权威 + 本地签名授权凭证 + 周期后台续期** 模式：

- v1.0 优先使用成熟 Licensing Service，默认技术选型为 **Keygen Cloud**，不自建 License 密码协议；
- 支付/开票系统与授权系统解耦，支付成功、续费、退款或拒付通过服务端 webhook 幂等地创建、续期、暂停或撤销 License；
- Swift 客户端只持有产品/账户公开标识和验签公钥，绝不内置管理 API Token、签名私钥或支付平台 Secret；
- 领域层使用 `LicenseProvider` 边界，v1.0 只有一个 Keygen 实现；该边界用于隔离外部服务，不建设多供应商通用框架；
- 本地保存的是服务端签名的授权结论，而不是自行写入的 `isActivated=true`。

选择依据：成熟服务已提供 node-locked/machine activation、激活上限、试用、订阅状态、签名 License/Machine 文件、离线校验、撤销和设备管理。AgentNest 只实现产品策略与 Swift 集成，避免自行发明密钥分发、签名格式和管理后台。

| 方案 | 官方能力侧重 | AgentNest 决策 |
| --- | --- | --- |
| Keygen | Machine activation、签名 License/Machine 文件、TTL 与离线验签、API-first | v1.0 默认授权服务；最贴合 Swift 自行实现轻量客户端和本地 Receipt |
| Cryptlex | Node-locked、试用、订阅、本地 SDK 状态和周期同步 | 备选；能力完整，但首版不额外引入其跨平台激活 SDK |
| LicenseSpring | 在线、离线、air-gapped、浮动授权和本地 License 文件 | 备选；企业/隔离网能力超出 v1.0 主要场景 |
| Lemon Squeezy License API | 购买关联的 License Key、激活、验证、停用和激活次数 | 可作为支付/销售候选；若单独使用，仍需服务端补充签名 Receipt 才满足本地可信结论 |

### 14.2 授权状态

状态必须明确区分：

- 未开始试用；
- 试用中（本地凭证有效/正在后台刷新）；
- 已激活（本地凭证有效/正在后台刷新）；
- 离线可用（显示最晚联网日期）；
- 凭证即将到期；
- 试用或订阅到期；
- License 无效、暂停、撤销或设备数超限；
- 本地凭证损坏、签名无效、设备不匹配或版本不支持；
- 网络不可用/授权服务不可用且本地凭证仍有效；
- 网络不可用/授权服务不可用且本地凭证已过期；
- 本机时间回退异常。

网络错误不能显示为 License 无效；存在有效本地凭证时，启动和核心功能不得等待网络。

### 14.3 本地授权凭证

服务端激活或刷新成功后签发 `SignedEntitlementReceipt`，至少包含：

```text
schemaVersion, provider, licenseId, machineIdHash, productId,
plan, features, issuedAt, refreshAfter, offlineUntil,
subscriptionExpiresAt?, minAppVersion?, receiptId, signature
```

- FR-LIC-01：Receipt 由授权服务私钥签名；客户端使用 App 内固定公钥验证签名、字段和产品身份。
- FR-LIC-02：Receipt 保存于 `~/Library/Application Support/AgentNest/License/entitlement.receipt`，使用原子替换，权限仅当前用户可读写，并排除系统备份。
- FR-LIC-03：License Key/refresh credential 保存于 macOS Keychain；UserDefaults 只保存非权威 UI 偏好，不保存授权结论。
- FR-LIC-04：本地授权结论只有在签名、schema、产品、设备、功能集、时间窗口和版本策略全部通过时有效；修改任一字段都会导致验签失败。
- FR-LIC-05：Receipt 可读但不含支付资料、邮箱、姓名、完整 License Key、设备原始标识或任何 Agent 扫描数据。
- FR-LIC-06：Receipt 缺失或损坏时尝试通过 Keychain 凭证联网恢复；不得回退到历史布尔值、缓存 JSON 响应或默认已激活。

### 14.4 启动与后台刷新

1. 启动时实时派生设备机器码；
2. 从磁盘读取 Receipt 并在本机验签；
3. Receipt 有效时立即进入对应功能集，License 决策目标 100 ms 内完成，不阻塞首屏等待网络；
4. 到达 `refreshAfter`、网络恢复或用户手动刷新时，在后台合并为一次验证请求；
5. 服务端返回新 Receipt 后先验签、再原子替换旧 Receipt；刷新失败保留仍有效的旧 Receipt；
6. 服务端明确返回过期、暂停、撤销或设备解绑时，立即以新的权威状态替换本地状态，不能继续消费旧 Receipt。

- FR-LIC-07：后台正常刷新默认每日一次；同一进程内请求单飞，失败使用带 jitter 的指数退避，不在每次窗口激活或每个功能入口请求服务端。
- FR-LIC-08：订阅 License 默认 `refreshAfter` 为 24 小时、`offlineUntil` 为签发后 7 天；永久 License 默认离线窗口 30 天。数值由服务端 Policy 签发，可按商业方案调整。
- FR-LIC-09：试用 Receipt 的 `offlineUntil` 不超过试用总到期时间，默认允许最长 72 小时连续离线；恢复联网后继续使用原服务端试用起止时间。
- FR-LIC-10：授权服务故障且 Receipt 仍在 `offlineUntil` 内时继续使用，并非阻断启动；超过离线窗口后进入受限激活页。
- FR-LIC-11：App 退出和重启不丢失有效本地授权结论；用户不需要每次重新输入 License。

### 14.5 设备机器码与激活

- FR-LIC-12：每次启动、激活和刷新都从 macOS 稳定设备标识实时派生机器码，使用带产品域分隔的 SHA-256；Receipt 只保存派生 hash，不保存 IOPlatformUUID 原值。
- FR-LIC-13：首次激活流程为“验证 License → 检查设备额度 → 创建 machine activation → checkout 签名 Receipt”，任一步失败不得留下半激活本地状态。
- FR-LIC-14：机器码算法带版本；组件缺失或硬件/系统变化时进入设备恢复/换机流程，不自动消耗新设备额度。
- FR-LIC-15：用户可从本机停用设备；必须先在服务端成功删除/停用 machine activation，再删除本地 Receipt 和 Keychain 凭证。服务端不可达时只允许“清除本机凭证”，并明确不会释放设备额度。
- FR-LIC-16：不得使用 MAC 地址作为唯一机器码，不依赖藏在客户端的对称密钥作为唯一安全边界。

### 14.6 7 天试用

- FR-LIC-17：每个设备首次成功联系授权服务时开始 7 × 24 小时试用，起止时间由服务端 UTC 决定。
- FR-LIC-18：服务端同时记录 Trial/Machine，删除 App、Receipt、Keychain、偏好或修改本机时间不能创建第二次试用。
- FR-LIC-19：试用期开放核心概要能力：智能扫描、Agent 清单、空间/Skill/活动摘要和结果预览。
- FR-LIC-20：Skill 写操作、补齐、清理执行、深度追踪、历史保存和导出仅对付费激活开放；试用页清楚说明范围。
- FR-LIC-21：试用到期后停止扫描和监控，只保留输入 License、购买/支持、隐私、删除本地数据和退出。
- FR-LIC-22：检测到明显时钟回退且无法用 Receipt 中的可信时间界定时，保留现有数据但要求联网恢复，不自行延长试用。

### 14.7 服务端与商业管理

- 授权服务管理 Product、Policy、License、Machine、Entitlement、Trial、暂停/撤销和审计事件；
- 支付 webhook 必须验签、幂等、可重放恢复；支付供应商故障不能直接破坏仍有效的本地 Receipt；
- 客户支持后台提供按 License 查看设备、释放设备额度、补发/撤销和审计操作，后台动作需要角色权限与审计日志；
- 签名私钥只存在于授权服务/HSM；客户端只含公钥。公钥轮换采用旧钥签名过渡 Receipt，并允许受控的多公钥验证窗口；
- 服务不可用与 License 无效必须是不同提示，不得因服务故障误导用户购买；
- Developer ID、Hardened Runtime、公证、代码签名和基本完整性检查用于提高篡改成本；
- PRD 不使用“无法破解”作为验收标准。验收对象是 Receipt 不可伪造/篡改/跨设备复用、旧响应不能无限重放、服务端变更最终收敛。

## 15. 设置、权限、更新与卸载

### 15.1 设置

- 扫描范围：Definition 默认 Home、环境变量 Home、用户添加 Home、忽略位置；
- Agent：查看识别依据、重命名本机标签、确认/忽略候选 Home；
- Skill：默认创建目标、编辑器偏好、显示项目 Skill；
- 活动：采样间隔、菜单栏指标、历史开关和保留期；
- 隐私：隐藏路径/会话标题、清除实时会话和扫描快照；
- 权限：Full Disk Access、Helper、登录项分别展示状态与恢复动作；
- License：本地 Receipt 状态、离线可用期、剩余试用、最近/下次验证、输入或更换 License、停用设备、设备额度错误与支持入口；
- 更新、语言、登录启动、关于和卸载。

### 15.2 权限分层

| 能力 | 默认权限 | 可选批准 |
| --- | --- | --- |
| Home 内只读发现/空间/Skill | 当前用户 | 受保护目录可能需要 Full Disk Access |
| CPU/磁盘/网络/卷/可见进程 | 无管理员权限 | 受保护进程可部分不可见 |
| 深度文件/卷追踪 | 用户显式发起 | 签名 Helper、登录项批准，受保护路径另需 FDA |
| Skill 写入和清理 | 当前用户权限 | 不为普通写入统一提权 |

管理员批准、Helper 注册、登录项批准和 Full Disk Access 不得合并成一个状态。

### 15.3 更新

- 使用 Sparkle 2 的固定 HTTPS appcast；更新包、发布说明和 enclosure 经过 Ed25519 签名；
- 不静默安装，不上传机器码或扫描数据到更新服务；License 校验与更新检查是两个独立请求；
- 更新安装与深度追踪/清理互斥，确认相关任务停止后再继续；
- App、Helper 为 universal2，使用 Developer ID、Hardened Runtime、公证和 staple。

### 15.4 卸载与删除本地数据

- 设置中提供“删除本地数据并准备卸载”；先列出快照、历史、偏好、SignedEntitlementReceipt、Keychain credential、Helper 和自定义位置记录；
- 停止扫描、监控、清理、写操作和追踪，确认 Helper 子进程退出并注销服务；
- 用户可分别删除或一次性删除上述数据；不得删除已由用户移入废纸篓的第三方文件；
- 展示实际成功、失败和残留路径，最后引导退出并将 AgentNest.app 移入废纸篓；
- 服务端 License 设备解绑是单独联网动作，必须明确确认，不能与本地卸载静默绑定。

## 16. 领域数据模型

### 16.1 核心实体

```text
DeviceSnapshot
  ├─ AgentProduct
  │    └─ AgentInstallation
  │         └─ AgentHome
  │              ├─ Profile
  │              ├─ ArtifactTree
  │              └─ SkillInstallation
  ├─ SkillIndex
  │    └─ LogicalSkill
  │         └─ SkillVariant
  │              └─ Coverage[]
  ├─ StorageLedger
  │    └─ PhysicalResourceIdentity
  ├─ ActivitySnapshot
  └─ Finding[]
```

### 16.2 关键不变量

- 一个物理资源在同一 Snapshot 的物理账本中只计一次；
- Agent 产品名不是 Agent Home 身份；
- Skill 同名不等于同 Variant，路径不同也不必然是不同 Variant；
- Coverage 必须指向具体 Home/Profile 和作用域；
- CleanupTarget 与 Artifact 分离，没有执行器的资源只能查看；
- 所有写计划绑定源 generation 与目标身份，执行时重新验证；
- UI 只消费不可变 Snapshot，不直接拼接文件系统半成品。

## 17. 技术架构

### 17.1 分层

```text
AgentNestApp / Presentation (SwiftUI + AppKit bridge)
        ↓
Application Use Cases (Scan, Skill, Cleanup, Monitor, License)
        ↓
Domain (entities, policies, plans, invariants)
        ↓
Infrastructure
  ├─ Agent Definition Catalog + Discovery + Adapter Registry
  ├─ File Index + Storage Ledger
  ├─ Skill Parsers + Materializers
  ├─ Monitoring + Trace Client
  ├─ Cleanup Executors
  ├─ History SQLite
  └─ License Provider + Receipt Store + Keychain
        ↓
macOS APIs / fixed official CLIs / License Service
```

### 17.2 架构要求

- 业务规则位于 Domain/Application，不在 SwiftUI View、路径字符串或外部 CLI 输出中散落；
- 常规 Agent 识别由统一 Agent Definition 驱动；只有需要高级逻辑的产品才实现能力协议，不用巨大 switch 贯穿项目；
- 路径候选/指纹是数据，关系解析/格式转换/清理是代码，两者不可混成可远程执行脚本；
- 扫描调度、快照发布、Skill 写入、清理和 License 状态使用 Swift concurrency/actor 隔离；
- 主线程只发布节流后的不可变状态，不进行递归扫描、排序大表、数据库读取或 diff；
- SQLite 只用于可选历史和必要本机索引；历史关闭时不创建历史库；
- 所有系统命令使用固定绝对路径或经签名/版本验证的官方 executable，不经过 shell；
- 新架构不承担 FindDiskKiller 旧模型、旧缓存或旧 schema 兼容。

### 17.3 Definition 与 Adapter 能力边界

所有 Agent 先拥有 Agent Definition；它声明安装/Home 候选、required/optional/negative 指纹、支持版本、静态 Artifact/Skill 位置和能力开关。空定义不需要 Swift 类型。

只有 Definition 无法安全表达时才增加 Adapter，能力协议按需提供：

- Profile、会话 family、共享数据库与 Artifact 关系解析；
- Skill 格式校验器、目标 materializer 和跨格式转换；
- 活动进程关联规则；
- Cleanup Unit、保护规则和官方删除能力；
- 可公开给 UI 的结构化诊断与恢复动作。

新增 Agent Definition 必须提供真实匿名 fixture、边界 fixture 和版本不支持 fixture；新增 Adapter 再补充关系、转换和可选官方命令集成测试。

## 18. 隐私与安全

### 18.1 本机数据

- Agent、路径、Skill、会话、进程、磁盘和扫描结果不上传；
- 不集成广告、行为分析或第三方跟踪 SDK；
- 日志只记录结构化错误码、阶段、耗时和匿名计数，不记录完整路径、标题、Skill 正文、License 或设备原始标识；
- 隐私模式同步隐藏 UI、导出、VoiceOver、通知和诊断中的敏感文本；
- Skill 内容按潜在恶意输入解析：限制文件大小、YAML/JSON 深度、总文件数、symlink 和解压行为；
- AgentNest 永不执行扫描到的 Skill 脚本。

### 18.2 文件写入安全

- 写入前以 file descriptor/父目录身份校验抵御 symlink race 和路径替换；
- staging 必须与目标同卷同父级安全目录，最终原子 rename；
- 路径规范化同时保留用户路径与解析路径，禁止 `..`、越界绝对引用和跨 Home 写入；
- 清理/替换尽量进入废纸篓；无法恢复时使用更强复核文案；
- App 退出、取消或崩溃后不得留下半个 Skill；下次启动可识别并安全清理自己的 staging。

### 18.3 Trace Helper

- App 与 Helper 双向验证固定 Bundle ID、Team ID 和审计身份；
- Helper 只执行固定、参数白名单化的系统追踪命令，不接受 shell、任意 executable、环境变量或自由参数；
- 服务端限制时长、PID 数、批量、单行、总缓冲和输出速率；
- owner 断开、超时、stop、App 退出和 SIGTERM 必须回收子进程；
- 未知协议事务替换，不能同时保留两个活跃端点。

## 19. 非功能需求

### 19.1 性能与响应

| 场景 | 要求 |
| --- | --- |
| 点击、选择、导航反馈 | 100 ms 内出现视觉反馈 |
| 扫描启动/停止状态 | 300 ms 内进入明确状态 |
| 已知默认 Agent 快速探测 | P95 2 秒内发布第一批候选，不等待完整空间测量 |
| 空闲基础监控 | 平均 CPU <1%，P95 <2% |
| 正常基础监控 | 平均 CPU <3%，P95 <6% |
| Agent Home 扫描 | 流式枚举、可取消，UI 可交互；不长期占满所有性能核 |
| 活跃追踪 | 额外 CPU P95 <8%，App + Helper 内存 <200 MB |
| UI 快照 | 普通页面不高于 2–4 Hz，列表/图表不高于 1 Hz |
| Helper 停止 | 2 秒内确认退出，否则强制回收 |

扫描耗时受数据规模、磁盘和权限影响，不承诺虚假固定时间。必须用阶段、计数和字节表达真实进展。

### 19.2 并发与可靠性

- 文件 I/O、元数据解析、外部命令和数据库各自使用有界执行器；
- 同一范围单飞，重复请求合并或取消旧 generation；
- 外部命令具有超时、输出上限、取消 handler 和子进程回收；
- CancellationError 结束队列，不被包装为普通失败继续批量执行；
- 采集、Agent 识别、Skill、空间、License 和磁盘健康互相隔离失败；
- 事件风暴先丢弃明细、保留聚合和 dropped count，缓冲始终有界；
- 崩溃恢复不得自动继续上次破坏性操作。

### 19.3 可用性

- License 服务正式环境目标月可用性至少 99.9%，并有跨区域备份与状态页；
- 本地扫描单来源失败不阻止其它来源完成；
- 有旧快照时刷新失败保留旧结果并标注陈旧时间；
- 所有“失败”提供重试、打开权限设置、查看范围或联系支持中的至少一个有效动作。

## 20. 本地化与可访问性

目标语言延续原基线：跟随系统、简体中文、繁体中文、英语、日语、韩语、德语、法语、西班牙语、巴西葡萄牙语、俄语。

- v1.0 简中/英文必须为母语质量；其它语言不得显示裸 key，并在发布前完成布局验收；
- 切换语言无需重启，同步更新主窗口、菜单栏、License、动态错误、图表和 PDF；
- 日期、数字、存储和时长跟随应用语言；CSV schema 不本地化；
- Core/Service 返回本地化 key + arguments，不拼接用户可见句子；
- 支持键盘、VoiceOver、Reduce Motion、Reduce Transparency、Increase Contrast、深浅色和大字体；
- 状态不只依赖颜色；动画、图表和覆盖矩阵均提供文本/表格等价物；
- 最小窗口与最长翻译是发布阻断测试。

## 21. 关键端到端验收场景

### 21.1 首次智能扫描

1. 新设备启动，联网创建服务端试用，页面显示 7 天范围和功能边界。
2. 首页只提供主要扫描动作和范围说明。
3. 点击扫描后依次看到真实阶段、Agent/位置、计数和停止动作。
4. 只递归指纹确认后的 Agent Home；用户 Home 中未声明的深层目录不被访问。
5. 完成后展示 Agent、Skill、空间和活动四组结果。
6. 任一不可读目录只降低对应覆盖，不把整次扫描变成空结果。

### 21.2 多 Home 与相似目录

1. Codex 默认 `~/.codex`、`CODEX_HOME` 指向的自定义 Home 和一个用户明确添加的 Home 同时存在。
2. 三者均包含有效 `version.json`，分别显示来源证据和物理占用。
3. 另一个只有 `.codex` 名称但缺少 `version.json` 的目录只能标为疑似。
4. 两个路径指向同一物理根时只计一次。
5. 用户确认可能目录后只重扫该来源，并保留可撤销的本机识别设置。

### 21.3 Skill 虚拟视图与补齐

1. 三个 Agent 中存在同名 Skill 的两个内容 Variant，第四个 Agent 缺失。
2. 虚拟视图显示逻辑 Skill、两个 Variant、各自覆盖和缺失，不错误合并。
3. 用户选择来源 Variant 和目标 Agent，看到格式转换及文件 diff。
4. 目标存在冲突时默认不覆盖；用户明确选择替换后旧目标进入废纸篓。
5. 写入期间目标变化则中止，不留下半成品。
6. 受影响位置重扫后才显示补齐成功。

### 21.4 按日期和大小清理

1. 用户筛选 90 天未活动且大于 1 GB 的对象。
2. 列表按完整 Cleanup Unit 展示最后活动证据、大小、风险和活动状态。
3. 其中一个会话当前有 writer，即使日期满足也不可选择。
4. 复核页区分废纸篓和官方永久删除，并说明预计占用不等于立即释放。
5. 执行前 inode/引用发生变化的目标被跳过。
6. 完成后单来源重扫，结果逐项显示成功、跳过和失败。

### 21.5 Agent 活动调查

1. 基础监控第二个可比样本后显示真实 CPU/读写/网络速率。
2. 用户从高写入 Agent 进入详情，看到进程、Home、工作区和打开文件证据。
3. 用户显式追踪目录，批准后看到请求字节、最近速率和事件。
4. 页面明确物理设备写入与进程请求写入不是同一指标。
5. 离开页面后 Helper 真实退出，无孤儿进程。

### 21.6 试用、激活与断网

1. 删除偏好和重装 App 后，服务端仍返回同一设备的原试用到期时间。
2. 修改本机时间不延长试用。
3. 试用期间可查看概要，但写操作和清理不可执行。
4. 输入有效 License 后，本机保存绑定设备、功能集和离线窗口的签名 Receipt。
5. 下次启动先完成本地验签并进入已激活状态，网络刷新在后台进行。
6. 本地修改 Receipt、伪造激活布尔值、跨设备复制或重放过期 Receipt 均不能通过校验。
7. 服务故障显示“暂时不可用”，不显示 License 无效；Receipt 仍有效时断网重启可以继续使用。
8. 超过 `offlineUntil` 且无法联网时进入受限激活页；试用总到期后只保留激活、支持、隐私、数据删除和退出。

## 22. 发布阻断门

- Codex Definition 完成 `~/.codex`、环境变量/自定义 Home、`version.json`、未声明深层目录和版本失配 fixture；所有空定义确认不会参与扫描或宣称支持；
- 默认 Home、环境变量 Home、自定义 Home、未声明深层目录不访问、symlink、跨卷、重叠根和不可读路径测试通过；
- 空间物理账本、共享/未归属、硬链接、扫描中变化和逻辑/物理口径守恒；
- Skill CRUD、Variant、覆盖矩阵、格式转换、冲突、原子写入和崩溃恢复测试通过；
- 日期证据、活动目标保护、清理执行前复验和官方删除 fail-closed 通过；
- 监控基线、PID 复用、缺口、追踪 backpressure、XPC 双向信任和无孤儿进程通过；
- 试用重装、机器码版本、Receipt 签名/原子替换、时钟回退、跨设备复制、防重放、后台刷新、离线窗口、撤销、设备上限和服务故障演练通过；
- 默认无遥测、日志脱敏、Keychain 权限、隐私模式和本地数据删除通过；
- 空闲/正常/扫描/追踪/事件风暴与 24 小时稳定性预算通过；
- 简中/英文、VoiceOver、键盘、大字体、对比度和 Reduce Motion 通过；
- universal2、签名、公证、staple、Gatekeeper、更新和 clean Mac 卸载通过。

## 23. 实施阶段

阶段用于控制研发顺序，不削减 v1.0 最终范围：

1. **领域底座**：Snapshot、Adapter、文件索引、空间账本、写计划与安全不变量；
2. **扫描与 Agent**：首页、进度、定向候选发现、多 Home、停止取消、适配器 fixture；
3. **空间与清理**：分类、日期/大小筛选、统一复核和执行后重扫；
4. **Skill**：虚拟索引、Variant/覆盖、CRUD、适配 materializer 和补齐；
5. **活动整合**：Agent 归因、文件证据、追踪、卷/健康、历史与报告；
6. **商业化与发布**：试用、License 服务、更新、权限、隐私、本地化和公证。

每一阶段先完成领域测试与 fixture，再接 UI；不得先用页面路径判断补出临时逻辑。

## 24. 开发前待确认事项

以下问题会改变适配、商业或发布结果，需在对应阶段开始前确认：

1. Codex `version.json` 的稳定字段约束，以及 Codex Skill、Artifact、会话和官方清理 fixture。
2. Claude Code、WorkBuddy 与其它 Agent 的 Definition 暂时保持空白；获得真实目录和 fixture 后再分别立项填充。
3. 7 天试用“概要能力”的当前划分是否符合商业策略，还是改为 7 天全功能试用。
4. License 的设备额度、换机、自助解绑、退款和永久/订阅制规则。
5. Keygen Cloud 的账号区域、SLA、成本、数据处理协议，以及支付 webhook 的服务端部署与法务隐私文本。
6. 是否首发即完成原基线十种语言，还是 v1.0 只发布简中/英文，其它语言后续开放。
7. 是否保留 Intel 正式支持；本文默认延续 universal2。
8. App Store 还是 Developer ID 独立分发；本文默认独立分发，因为 Helper、Sparkle 和目录访问边界更适配该渠道。

## 25. 基线能力映射

| 原 FindDiskKiller 能力 | AgentNest 中的位置 | 调整 |
| --- | --- | --- |
| 现在 / 应用 | 活动 | 以 Agent 归因为主，应用/进程为证据下钻 |
| 文件活动 / 深度追踪 | Agent 活动详情 | 保留安全 Helper 和显式启动边界 |
| 磁盘 / 健康 | 活动 > 卷与设备 | 不再占据普通用户主导航心智 |
| 空间地图 | 首页扫描 + 空间 | Agent 空间成为主模型，共用物理账本 |
| Codex/Claude/OpenCode 分析 | Agent Adapter | 扩展为多产品、多 Home、统一 Artifact 模型 |
| AI 会话清理 | 统一清理 | 仍只走官方接口并 fail closed |
| 历史分析 / 导出 | 历史 | 增加 Agent 空间增长与活动趋势 |
| 设置 / 更新 / 卸载 | 设置 | 加入 Agent Home、Skill、License 和设备解绑 |

## 26. 参考资料

- 原 `prd.md`（FindDiskKiller v1.3.7 重构基线，本文件改写前版本）
- [OpenAI Developers：Codex 与 Skills](https://developers.openai.com/)
- [Keygen：Machine Activation](https://keygen.sh/docs/activating-machines/)
- [Keygen：Signed License Files 与离线校验](https://keygen.sh/docs/api/cryptography/)
- [Keygen：安全与本地缓存建议](https://keygen.sh/docs/api/security/)
- [Cryptlex：Node-locked 与周期同步](https://cryptlex.com/docs/node-locked-licenses/using-lexactivator)
- [LicenseSpring：在线激活后的本地 License 文件](https://docs.licensespring.com/license-entitlements/license-activation-types)
- [Lemon Squeezy：License 激活/验证/停用 API](https://docs.lemonsqueezy.com/api/license-api)
- Apple：SwiftUI、AppKit、IOKit、Disk Arbitration、FSEvents、ServiceManagement、Security/Keychain、公证与 Hardened Runtime 文档

外部 Agent 的目录、schema、CLI 和 Skill 规范会变化。实现时必须以对应版本的官方资料和匿名 fixture 为准；参考链接不替代适配器版本验证。
