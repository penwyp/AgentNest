# AgentNest 设计系统（Design Language）

> 版本：1.0 · 真源：本文件 + `Sources/AgentNestApp/DesignSystem.swift`（实现符号在文末对照）
>
> AgentNest 是一台**本机 Agent 环境仪器**：它处理的是文件系统账本、物理空间、进程证据与授权状态，因此视觉气质应当是"精密的仪器面板"，而不是消费级玻璃卡片。
>
> **最重要的约束：以「原生性能」为第一优先级。** 所有材质、阴影、动效都必须在普通 macOS 硬件上以近乎零渲染成本运行。任何需要多层 `ultraThinMaterial`、多重阴影或持续动画的配方在本系统中**被明令禁止**，见 [性能策略](#2-性能策略)。

---

## 1. 视觉意图

AgentNest 的界面应当像一块安静的 macOS 原生仪器面板：

- **克制的色度**：中性色覆盖 85–92% 的渲染表面；彩色只用于语义（状态、强调、方向），一个视觉组内最多一个主强调色 + 一个次强调色。
- **稳定的光学边缘**：层级用「细描边 + 顶部高光 + 极浅投影」表达，边缘清晰、稳定、不闪烁。
- **浅物理深度**：卡片是"抬起的纸"，不是"悬浮的玻璃"。
- **清晰的数字**：所有会变化的数字使用等宽数字（`monospacedDigit`），物理字节、百分比、速率是这台仪器的读数。
- **安静地落定**：动效只在交互（hover / press / state）时发生，且以毫秒计；没有循环动画，没有装饰性弹跳。

---

## 2. 性能策略

> 这是本设计系统**最根本的约束**：透明窗口、多层系统材质与双层阴影虽然在部分 macOS 应用中可行，但在需要持续滚动、扫描与监控共存的 AgentNest 中会导致可感知的掉帧与功耗上升，因此被明确拒绝。

| 约束 | 规则 |
| --- | --- |
| 材质 | **不透明表面**。禁止 `ultraThinMaterial`/`thickMaterial`/`regularMaterial` 叠加，禁止 `NSVisualEffectView` |
| 阴影 | 最多 **1 层**浅投影（卡片），blur ≤ 4 pt，y 偏移 ≤ 2 pt；禁止双层/多色阴影 |
| 渐变 | 仅允许顶部高光描边（0.6 pt）与图表面积填充；禁止大面积装饰渐变 |
| 动效 | 只在 hover / press / state 切换时发生，时长 ≤ 0.40 s；**禁止循环、脉冲、持续动画** |
| 滚动 | 列表 / 表单使用原生 `List` / `Form` / `ScrollView`，不自定义滚动容器 |
| 图表 | 使用单一 `Path` 或少量 `Shape` 绘制；禁止每帧重建大量视图层级 |
| 目标 | 空闲 CPU 平均 < 1%；滚动与导航 60 fps；扫描/监控运行中 UI 保持可交互 |

**性能回退即默认**："不透明、无模糊"直接作为**默认实现**，因此不存在"降级模式"，任何外观下质感一致。

---

## 3. Token 架构

三层 token：

1. **Reference tokens**：原始值，如 `color.blue.500`、`space.250`。
2. **Semantic tokens**：视觉用途，如 `color.accent.primary`。
3. **Component tokens**：可复用的组合配方，如 `surface.card.border.width`。

命名规则：小写点分 `category.role.variant.state`；维度为逻辑点（pt），颜色为 sRGB，透明度 0–1，时长为秒。

**治理规则**：原始值只出现在一个命名空间（`DS.Chroma` / `DS.Neutral` / `DS.Space` …）；消费方（View）只使用语义或组件 token；新值必须先入参考表，禁止在 View 里写裸色值或裸圆角。

---

## 4. Reference Tokens

### 4.1 中性色 `color.neutral.*`（随系统外观动态切换）

| Token | 浅色 | 深色 | 用途 |
| --- | --- | --- | --- |
| `color.neutral.canvas` | `#ECF0F2` | `#090B0D` | 窗口基底画布（侧栏 + 内容区共用） |
| `color.neutral.canvas.raised` | `#F6F8F9` | `#0F1315` | 抬升表面（卡片） |
| `color.neutral.canvas.recessed` | 黑 `0.035` | 白 `0.025` | 沉入表面（输入/进度/证据区） |
| `color.neutral.white` | `#FFFFFF` | `#FFFFFF` | 顶部高光、填充按钮文字 |
| `color.neutral.black` | `#000000` | `#000000` | 投影与深度着色 |

系统动态语义色（直接消费 `NSColor` / SwiftUI 语义）：

| Token | macOS 来源 |
| --- | --- |
| `color.text.primary` | `Color.primary` |
| `color.text.secondary` | `Color.secondary` |
| `color.text.tertiary` | `Color.tertiary` |
| `color.separator` | `NSColor.separatorColor` |
| `color.control.background` | `NSColor.controlBackgroundColor` |
| `color.focus` | `NSColor.keyboardFocusIndicatorColor` |

### 4.2 彩色 `color.chroma.*`（浅/深外观恒定）

| Token | sRGB | 用途 |
| --- | --- | --- |
| `color.blue.500` | `#4D759E` `(0.30, 0.46, 0.62)` | **主强调**：导航选中、主按钮、主数值 |
| `color.cyan.500` | `#4799A6` `(0.28, 0.60, 0.65)` | 方向 A（下载/读取类语义） |
| `color.amber.500` | `#BF782E` `(0.75, 0.47, 0.18)` | 方向 B / 警示（疑似、陈旧） |
| `color.graphite.500` | `#85919E` `(0.52, 0.57, 0.62)` | 中性对比（其它进程、缺失） |
| `color.green.500` | `#4F9E78` `(0.31, 0.62, 0.47)` | 建设性动作 |
| `color.green.600` | `#4F9C59` `(0.31, 0.61, 0.35)` | **正向状态**（已确认、已归因） |
| `color.violet.500` | `#8761A3` `(0.53, 0.38, 0.64)` | 次强调（Skill 系列） |
| `color.indigo.500` | `#7361A5` `(0.45, 0.38, 0.65)` | 次方向 |
| `color.red.600` | `#BF3D38` `(0.75, 0.24, 0.22)` | **临界状态**（删除、失败） |
| `color.teal.500` | `#479687` `(0.28, 0.59, 0.53)` | 建设性次动作 |

### 4.3 语义别名 `color.semantic.*`

| Token | Reference |
| --- | --- |
| `color.surface.canvas` | `color.neutral.canvas` |
| `color.surface.raised` | `color.neutral.canvas.raised` |
| `color.surface.recessed` | `color.neutral.canvas.recessed` |
| `color.accent.primary` | `color.blue.500` |
| `color.accent.secondary` | `color.violet.500` |
| `color.direction.a` | `color.cyan.500` |
| `color.direction.b` | `color.amber.500` |
| `color.status.positive` | `color.green.600` |
| `color.status.caution` | `color.amber.500` |
| `color.status.critical` | `color.red.600` |

> **全局强调色**：应用 `tint` 必须固定为 `color.accent.primary`，原生控件（Picker、Toggle、ProgressView、输入框焦点）的选中色才与固定色板一致；不依赖用户系统的任意强调色。

### 4.4 间距 `space.*`

| Token | 值 | 用途 |
| --- | ---: | --- |
| `space.050` | `2 pt` | 紧凑文字间距 |
| `space.100` | `4 pt` | 紧凑行内间距 |
| `space.150` | `6 pt` | 控件内容间隙 |
| `space.200` | `8 pt` | 标准行内间隙 |
| `space.250` | `10 pt` | 图标-文字间隙 |
| `space.300` | `12 pt` | 紧凑表面内边距 |
| `space.400` | `16 pt` | 标准表面内边距 |
| `space.450` | `18 pt` | 宽裕表面内边距 |

### 4.5 圆角 `radius.*` 与描边 `stroke.*`

| Token | 值 | 用途 |
| --- | ---: | --- |
| `radius.small` | `5 pt` | 徽标、小提示 |
| `radius.control.compact` | `6 pt` | 紧凑按钮、图标控件、导航行 |
| `radius.control.regular` | `7 pt` | 常规/大按钮 |
| `radius.icon` | `7 pt` | 独立图标基底 |
| `radius.panel` | `8 pt` | 卡片表面 |
| `stroke.hairline` | `0.6 pt` | 光学边、分隔线 |
| `stroke.surface` | `0.75 pt` | 标准轮廓 |
| `stroke.focus` | `2 pt` | 键盘焦点环 |

所有圆角使用连续圆角（`.continuous`）；选择命名半径，不随组件缩放。

### 4.6 字体 `type.*`

| Token | 家族 | 字号 | 字重 | 用途 |
| --- | --- | ---: | --- | --- |
| `type.displayLarge` | SF Pro Display | `34` | Semibold | 激活门户主标题 |
| `type.display` | SF Pro Display | `26` | Semibold | 首页主标题 |
| `type.title` | SF Pro Display | `20` | Semibold | 页面/卡片主数值 |
| `type.section` | SF Pro Display | `17` | Medium | 行标题、小节标题 |
| `type.body` | SF Pro Text | `13` | Regular | 正文 |
| `type.lead` | SF Pro Text | `15` | Regular | 激活门户副标题 |
| `type.label` | SF Pro Text | `12` | Medium | 标签、紧凑注释 |
| `type.caption` | SF Pro Text | `11` | Regular | 辅助说明 |
| `type.micro` | SF Pro Text | `10` | Regular | 密集辅助文字 |
| `type.value.large` | SF Pro Display | `48` | Light | 单体数字强调 |
| `type.value.medium` | SF Pro Display | `36` | Regular | 紧凑数字强调 |
| `type.data` | SF Mono | `12` | Regular | 路径、时间、标识、表格数值 |

**规则**：数值 + 单位共享首行基线；所有会变化的数字使用 `monospacedDigit()`；SF Pro Display 只用于强调，密集表面用 SF Pro Text / SF Mono。

### 4.7 不透明度 `opacity.*`

| Token | 值 | 用途 |
| --- | ---: | --- |
| `opacity.fill.subtle` | `0.10` | 图标底色、安静强调填充 |
| `opacity.fill.standard` | `0.12` | 选中填充 |
| `opacity.border.standard` | `0.13` | 表面轮廓 |
| `opacity.disabled.control` | `0.46` | 禁用文本控件 |
| `opacity.disabled.icon` | `0.42` | 禁用图标控件 |
| `opacity.unavailable` | `0.30` | 不可用内容 |

### 4.8 动效 `motion.*`

| Token | 时长 | 曲线 | 用途 |
| --- | ---: | --- | --- |
| `motion.press` | `0.10 s` | easeOut | 按压缩放 |
| `motion.hover` | `0.12 s` | easeOut | 悬停反馈 |
| `motion.state` | `0.20 s` | easeInOut | 选中/焦点变化 |
| `motion.enter` | `0.28 s` | easeOut | 内容进入 |
| `motion.sample` | `0.36 s` | easeInOut | 连续数值过渡 |
| `motion.settle` | `0.40 s` | easeInOut | 小型几何变换 |
| `motion.chart.histogram` | `0.50 s` | easeInOut | 柱高过渡 |
| `motion.chart.meter` | `0.48 s` | easeInOut | 分段仪表过渡 |
| `motion.chart.donut` | `0.55 s` | easeInOut | 环形弧过渡 |
| `motion.entranceStagger` | `0.06 s` | — | 门户入场编排段间错峰 |

Reduce Motion 将全部时长解析为 `0 s`，保留最终视觉状态。

---

## 5. 表面配方

### 5.1 Canvas（画布）

| Token | 浅色 | 深色 |
| --- | --- | --- |
| `canvas.background` | `color.surface.canvas` | `color.surface.canvas` |
| 附加效果 | 无（性能策略：不透明） | 无 |

画布是**唯一**的窗口底色，覆盖侧栏与内容区；任何卡片之下都是画布，不允许透明内容层级。

### 5.2 Card（抬升表面，玻璃的轻量替代）

| Token | 值 |
| --- | --- |
| `surface.card.radius` | `radius.panel` |
| `surface.card.inset` | `space.400` |
| `surface.card.fill` | `color.surface.raised`（不透明） |
| `surface.card.border.width` | `stroke.surface` |
| `surface.card.border.color` | `color.text.primary` at `opacity.border.standard` |
| `surface.card.edge.highlight` | 白色 0.30 → 透明 → 黑色 0.03，`stroke.hairline`，inset 1.25 pt |
| `surface.card.elevation` | 黑色 `0.06`，blur `4 pt`，y `1 pt`（唯一允许的阴影） |

图层顺序（后→前）：raised 填充 → 标准轮廓 → 顶部高光描边（内缩 1.25 pt）。**无材质、无内部渐变填充、单层阴影。**

### 5.3 Recessed（沉入表面）

| Token | 值 |
| --- | --- |
| `surface.recessed.fill` | `color.surface.recessed`（浅黑 0.035 / 深白 0.025） |
| `surface.recessed.border` | `color.text.primary` at `0.08`，`stroke.hairline` |
| `surface.recessed.radius` | `radius.control.regular` |

用于扫描进度容器、输入区、证据区；无投影。

### 5.4 Selection（选中表面）

| Token | 值 |
| --- | --- |
| `surface.selection.fill` | `color.accent.primary` at `opacity.fill.standard` |
| `surface.selection.border` | `color.accent.primary` at `0.28`，`stroke.surface` |
| `surface.selection.radius` | `radius.control.compact` |

用于导航选中行、卡片式选中；不用于系统原生控件内部绘制。

### 5.5 Divider（分隔线）

| Token | 值 |
| --- | --- |
| `surface.divider` | `color.text.primary` at `0.06`，`stroke.hairline` 高 |
| 内边距 | 水平 `space.200`，垂直 `space.150` |

### 5.6 Page Header（页面首部）

页面首部用于建立“当前对象 + 当前状态 + 主操作”的稳定层级，不承担装饰性 Hero 展示：

| Token | 值 |
| --- | --- |
| `layout.page.max-width` | `920 pt` |
| `layout.page.inset.horizontal` | `32 pt` |
| `layout.page.inset.vertical` | `24 pt` |
| `page.header.icon.frame` | `40 pt` 方形，符号 `20 pt Medium` |
| `page.header.icon.surface` | 当前语义色 `10%` 填充 + `18%` 描边 |
| `page.header.title` | `type.display` |
| `page.header.subtitle` | `type.body` / `text.secondary` |
| `page.header.action.minimum-width` | `168 pt` |

首页扫描状态在页面首部下方使用 `Recessed` 配方就地更新；不得用循环脉冲、旋转图标或放大的装饰图形表达后台工作。

### 5.7 激活门户（Onboarding 门户）

激活门户是未授权状态下用户进入后的首页，也是产品唯一的品牌页面。它遵循优秀桌面产品的 onboarding 惯例（Linear / Raycast / Arc / CleanShot 的「深色 + 大标题 + 产品预览 + 强 CTA + 信任徽章」范式），在性能策略内实现：

| Token | 值 |
| --- | --- |
| `layout.activation.max-width` | `960 pt` |
| `layout.activation.feature.icon` | `32 pt` 能力行图标基底 |
| `type.displayLarge` | `34 pt` 门户主标题（负字距 −0.4） |
| `type.lead` | `15 pt` 门户副标题 |

- **外观**：门户及其弹窗固定深色外观（`preferredColorScheme(.dark)`），与系统外观解耦；进入主界面后恢复跟随系统。这是「品牌页」与「仪器页」的刻意区分。
- **布局**：顶部品牌行（鸟标 + 应用名 + 关于/隐私/退出）→ 分屏 Hero（左：overline + 主标题 + 副标题 + 双 CTA + 信任徽章；右：产品预览窗口 `DSProductPreview`）→ 2×2 能力卡（`DSFeatureRow`）→ 页脚（版本 · 删除本地数据）。
- **产品预览**（`DSProductPreview`）：用真实 DS 原语绘制 Home 页缩影（页面首部、Recessed 进度、面积折线、微柱图、环形容量、徽章），带窗口 chrome（红黄绿三色点 + 标题栏 + 细描边 + 单层投影）。它是产品本身，不是虚构装饰；入场一次性 fade/位移，柱图与环形做一次性绘制入场，面积折线静态，无循环。
- **氛围渐变例外**：仅激活门户 Hero 允许 `DSHeroWash`——单层静态 `RadialGradient`（accent 0.12 → 0.04 → 透明），无模糊、无辉光、无循环、位于内容之下。这是 §2「禁止大面积装饰渐变」的唯一登记例外。
- **文案原则**：主标题传达「全流程、一站式」定位（「你的 Agent，一站式打理。」）；副标题点名生命周期环节（安装、空间、配置、Skill）；主 CTA 动词 + 具体利益（「免费试用 7 天」，`control.action.hero`、320 pt 宽铺满按钮面）；次路径为句子式内联链接「已有授权密钥？输入密钥激活 ›」，与主按钮左边缘对齐，chevron 随展开右→下旋转；信任徽章只陈述真实事实（本机分析 / 数据不出 Mac / 设备绑定 · Ed25519 验签）。
- **动效**：一次性入场编排（fade + ≤ 8 pt 位移，段间 `motion.entranceStagger` 错峰）；之后回到纯交互动效；Reduce Motion 直接落定。
- 页脚与顶部链接使用 `DSFooterButtonStyle`，视觉降级为 caption 链接。

### 5.8 首页（Home，借鉴 find-disk-killer Storage Map 语言）

首页是「扫描中 = 发现模式 / 扫描后 = 管理模式」的两态页面，借鉴 find-disk-killer `StorageMapDiscoveryView` 的逐个确认体验，但两态互斥：**扫描进行时只呈现发现界面，扫描完成后的摘要与影响卡（`SnapshotSummary` + `ImpactCards`）在扫描结束前不出现**（重扫同理）。每一处动效都折算进 AgentNest 的性能约束（无循环动画、无多层阴影、无材质）：

- **页面首部（扫描中）**：标题「正在发现本机 Agent 环境」；副标题为实时状态行「N 个 Agent Home 已发现 · 当前阶段」（`DSPageHeader.animatesSubtitle`：等宽数字 + `contentTransition(.numericText())` + `motion.sample`），无结果时为「正在检查已知位置」。计数与阶段**只在状态行出现一次**，发现区不再重复放标题块。
- **发现界面**（`HomeDiscoveryView`，直接铺在画布上、无卡片容器）：
  - **刚刚发现**：仅发现/验证阶段且有结果时显示——最近一个 Home 的产品图标（纯图标，无容器）+ 绿色「刚刚发现」+ 名称 + 来源；每次确认以 `.id(home.id)` + fade/8 pt 位移过渡换新（find-disk 用 `blurReplace`，macOS 14 以 opacity+offset 等效替代）。
  - **已发现的 Agent**：自适应网格芯片（产品图标 + 名称 + 来源 + 绿色勾 /「疑似」徽章），随确认逐个以 fade/位移插入，整区 `.animation(value: homes.map(\.id))`（`motion.enter`）驱动；无结果时以小 `ProgressView` + 当前阶段文案就地提示。
  - **正在确认的范围**：默认路径 / 环境变量 / 用户添加 / 用户确认四个来源区，实时显示「N 个已发现 / 正在检查」；右翼「只读取位置，不读取文件内容」盾牌标注。
  - **进度行**：进入索引阶段后显示 `Recessed` 就地进度（当前位置 + 已处理项数，numericText）；阶段文案不重复（状态行已承载），验证阶段不显示。
  - **信任底栏**：分隔线下的「本机分析 · 只读元数据 · 不执行清理」，只陈述真实行为。
  - **渐进数据**：`ScanProgress.confirmedHomes` 由 `ScanUseCase` 每验证一个 Home 立即发布；`AppModel` 对发现计数变化即时放行（位置刻度仍按 0.25 s 节流）。首次进入首页且无快照时自动开始首次扫描（仅一次，用户停止后不自动重启）。
  - 数值滚动与插入过渡一律尊重 Reduce Motion。


---

## 6. 导航配方（侧边栏）

AgentNest 的侧边栏是一等公民，遵循"克制的仪器导航"：

| Token | 值 |
| --- | --- |
| `nav.width` | 最小 208 pt，理想 224 pt |
| `nav.background` | `color.surface.canvas` |
| `nav.brand.icon` | `bird.fill`，16 pt Medium，`color.accent.primary` |
| `nav.brand.title` | `type.section` |
| `nav.row.height` | 图标 13 pt Medium + 文字 `type.body`，垂直 padding 8 pt |
| `nav.row.radius` | `radius.control.compact` |
| `nav.row.hover` | `color.text.primary` at `0.05` |
| `nav.row.selected` | `surface.selection` 配方；图标与文字转为 `color.accent.primary` |
| `nav.row.gap` | 2 pt |
| `nav.divider` | `surface.divider` 配方 |

分组顺序固定：**首页** | Agent / Skill / 空间 / 活动 / 历史 | 设置。底部状态区显示授权状态圆点（`status.positive` / `status.caution`）与版本号（`type.micro` / `tertiary`）。

导航不使用系统 sidebar 材质；hover 在指针离开或窗口失活时立即清除。

---

## 7. 控件状态配方

### 7.1 Action Button（`DSActionButtonStyle`）

| 尺寸 | 最小高度 | 水平内边距 | 字体 | 圆角 |
| --- | ---: | ---: | --- | --- |
| `control.action.compact` | `30 pt` | `10 pt` | 11 Semibold | `radius.control.compact` |
| `control.action.regular` | `34 pt` | `13 pt` | 12 Semibold | `radius.control.regular` |
| `control.action.large` | `38 pt` | `16 pt` | 13 Semibold | `radius.control.regular` |
| `control.action.hero` | `44 pt` | `22 pt` | 15 Semibold | `radius.control.regular` |

顶部白色高光：中性 0.07 / 强调与破坏 0.16，0.5 pt。

| 变体 | 填充（rest） | 前景 | 边框 | 顶部高光 |
| --- | --- | --- | --- | --- |
| `neutral` | `control.background` at `0.92` | `text.primary` | separator `0.90`，`stroke.surface` | 白 `0.07` |
| `accent` | `accent.primary` at `0.86` | 白 | 白 `0.18`，0.5 pt | 白 `0.16` |
| `destructive` | `status.critical` at `1` | 白 | 白 `0.20`，0.5 pt | 白 `0.16` |

| 状态 | 填充 | 边框 | 缩放 | 动效 |
| --- | --- | --- | --- | --- |
| rest | 变体填充 | 变体边框 | 1 | 无 |
| hover | 中性 `text.primary` 0.09；accent 0.92；destructive 0.90 | 不变 | 1 | `motion.hover` |
| pressed | accent 0.78；destructive 0.78；中性 0.13 | 不变 | 0.985 | `motion.press` |
| disabled | 变体填充 × `0.46` 整体 | 不变 | 1 | 无 |
| focus | 状态填充 | 加 `focus` 色 `stroke.focus` 外环 | 1 | `motion.state` |

hover 在指针离开或窗口失活时清除；pressed 不叠加 hover；focus 不改变布局尺寸。

### 7.2 Icon Button（`DSIconButtonStyle`）

| Token | 值 |
| --- | --- |
| `icon.size` | 13 pt Medium（SF Symbols） |
| `icon.frame` | 30 pt 方形 |
| `icon.radius` | `radius.control.compact` |
| `icon.fill.rest` | `control.background` at `0.78` |
| `icon.fill.hover` | `text.primary` at `0.10` |
| `icon.fill.pressed` | `text.primary` at `0.14` |
| `icon.border` | separator `0.72`，0.5 pt |
| `icon.highlight` | 顶部白边 `0.08`，0.5 pt |
| `icon.disabled` | 整体 `opacity.disabled.icon` |
| `icon.pressed.scale` | 0.96 |

### 7.3 Badge（`DSBadge`）

`type.micro` Medium，`radius.small`（Capsule）；未填充态用 `color.opacity.fill.subtle` 底色 + 同色 0.24 描边；填充态（`filled`）用实色底 + 白字。用于状态短词：已确认（positive）、疑似（caution）、Agent（positive filled）、macOS 与其它进程（secondary）。

---

## 8. 图表语言

图表是精密仪表读数，渲染在同一 canvas 环境内；数据标记本身保持光学平整——**禁止发光、辉光、斜角、数据点投影**。图表深度来自所在卡片表面、安静的绘图底色与工具提示层。

### 8.1 颜色分配 `chart.color.*`

| Token | Reference | 用途 |
| --- | --- | --- |
| `chart.color.series.01` | `blue.500` | 单系列 / 首系列（Agent、CPU） |
| `chart.color.series.02` | `cyan.500` | 第二系列（磁盘、卷容量） |
| `chart.color.series.03` | `amber.500` | 第三系列（空间、方向 B） |
| `chart.color.series.04` | `graphite.500` | 中性对比（其它进程） |
| `chart.color.series.05` | `green.500` | 第五系列 |
| `chart.color.series.06` | `violet.500` | 第六系列（Skill） |
| `chart.color.series.07` | `indigo.500` | 第七系列 |
| `chart.color.series.08` | `teal.500` | 第八系列 |
| `chart.color.threshold` | `status.critical` | 仅用于临界规则与超限区域 |

`status.positive` / `status.critical` 不进入常规系列顺序。颜色从不作为唯一区分：辅以线型、位置或直接标注。

### 8.2 绘图与标记 `chart.plot.*`

| Token | 值 | 用途 |
| --- | --- | --- |
| `chart.plot.fill` | `text.secondary` at `0.035` | 绘图区底色 |
| `chart.line.width` | `1.7 pt` | 标准线系列 |
| `chart.area.opacity` | `0.12` | 面积填充（单一主系列） |
| `chart.bar.radius` | `1.5 pt` | 微柱状图柱端 |
| `chart.bar.gap` | `3 pt` | 微柱状图柱间隙 |
| `chart.bar.width.minimum` | `2 pt` | 最小柱宽 |
| `chart.bar.height.minimum` | `3 pt` | 非零可见柱高 |
| `chart.bar.opacity.active` | `0.70` | 活跃柱 |
| `chart.bar.opacity.missing` | `0.14` | 缺失样本占位（`text.secondary`） |
| `chart.meter.segment.count` | `10` | 校准仪表段数 |
| `chart.meter.segment.gap` | `1.25 pt` | 段间隙 |
| `chart.meter.segment.opacity.active` | `0.74` | 活跃段 |
| `chart.meter.segment.opacity.inactive` | `0.15` | 非活跃段 |
| `chart.meter.border` | `text.primary` at `0.05`，0.5 pt | 仪表光学边界 |
| `chart.donut.track` | `text.secondary` at `0.18` | 环形轨道 |
| `chart.donut.stroke.width` | `8 pt` | 轨道与数值弧 |
| `chart.donut.value.opacity` | `0.78` | 数值弧 |
| `chart.donut.cap` | Butt | 弧端点 |
| `chart.donut.start.angle` | `-90 deg` | 十二点方向起点 |

### 8.3 图表类型

- **面积折线（`DSLineChart`）**：历史趋势 / 连续速率。单一 `Path`，线性插值；面积仅当累积量有意义时使用；缺失区间断线，不跨缺口插值。动效 `motion.sample`（0.36 s）。
- **微柱状图（`DSMicroHistogram`）**：离散样本。恒定基线、单系列色；缺失样本用中性缺失 token 与已知零值区分；柱高过渡 `motion.chart.histogram`（0.50 s），不从任意位置飞入。
- **分段仪表（`DSSegmentedMeter`）**：量化进度（CPU、进程占用）。10 段、稳定原点激活；越过真实语义阈值（≥ 第 9 段）才允许 caution 色；过渡 `motion.chart.meter`（0.48 s）。
- **环形进度（`DSDonut`）**：单一部分-整体归一值（卷容量）。8 pt 描边、轨道常显、中心值等宽数字；弧过渡 `motion.chart.donut`（0.55 s）。禁止多环装饰。

### 8.4 图表外观与无障碍

图表几何、系列身份与颜色分配在浅/深外观下完全一致；外观只改变文字、中性底色与工具提示。每个图表需要非颜色表示的系列说明 + 文本摘要；缺失、不可用与零是三种不同状态，口头与视觉表示必须区分。Reduce Motion 保留最终几何、移除插值。

---

## 9. 外观矩阵

后续列覆盖基础配方；几何在任意外观下不变。

| 元素 | 浅色 | 深色 | Increased Contrast | Reduced Transparency | 非活跃窗口 |
| --- | --- | --- | --- | --- | --- |
| Canvas | 浅画布 | 深画布 | 不变 | 不变（默认即不透明） | 底色不变 |
| Card | 浅 raised | 深 raised | 轮廓 1 pt，`0.30` | 不变 | 阴影不透明度 × 0.70 |
| Recessed | 浅沉入 | 深沉入 | 内顶边 × 1.5 | 不变 | 不变 |
| 导航选中 | accent 12% + 28% | 同左 | 边框 1 pt | 不变 | accent × 0.72 |
| Control | 原生语义色 | 原生语义色 | 边框 1 pt，焦点环 3 pt | 原生不透明控件背景 | 清除 hover/pressed |
| Accent | 固定色值 | 固定色值 | 不变，不增饱和度 | 不变 | × 0.72 |
| 图表 | 固定系列色 | 同左 | 网格/轴 × 1.5 | 不变 | 彩色标记 × 0.72，清除 hover |

每个外观必须作为完整原生渲染环境评估；深色画布上放一个深色矩形不构成"深色模式"证据。

---

## 10. 像素与栅格化

- 点值由目标显示比例的原生渲染器求值；`@2x` 下 `0.5 pt` = 1 设备像素，`0.6 / 0.75 pt` 有意跨分数像素抗锯齿。
- 使用 `strokeBorder` 绘制内缩光学边，保持形状外几何稳定。
- **源码中禁止把 token 圆整为整像素**。
- 用原生 SF Pro 与 SF Symbols 渲染；字体回退与手绘符号替代会使类型/图标比较失效。
- 评审截图：原生 `@2x` PNG 以其像素尺寸的 50% 查看（100% 显示）；嵌入 sRGB IEC61966-2.1 配置。

---

## 11. 动效行为

- 本地反馈位移限制在 4–12 pt；不靠大行程制造重要性。
- 材质/表面进入时同时动画不透明度与位置；不对静止表面做缩放弹跳。
- 状态变化保持持久对象身份。
- 数值插值 `v(t) = v0 + (v1 - v0) × E(t)`，等宽数字保证插值不变宽。
- 先归一化比例再投影到像素；钳制渲染几何而非源值。
- 禁止无状态过渡的持续脉冲、发光或运动。

---

## 12. 无障碍

- 每种颜色区分配以文字、形状、位置或符号。
- 纯图标控件必须有可访问名称与 hover 提示。
- 键盘焦点指示可见且几何稳定。
- Reduced Transparency 与 Reduce Motion 保留最终视觉层级。
- 长文本不得与相邻内容重叠（渲染要求，非页面布局规定）。
- 仪表、图表在 VoiceOver 下朗读语义值（如"CPU 12.5%"），缺失/不可用/零读音可区分。

---

## 13. Token 治理

- 一个 token 只在视觉语言变化时改变；局部例外不得改动全局 token。
- 参考值保持单一命名空间（`DS.Chroma` / `DS.Neutral`），向组件暴露语义别名。
- 共享配方用组件 token（`DSCard`、`DSActionButtonStyle`…），不重复 modifier 链。
- 裸色值、裸圆角、裸阴影不得出现在消费 View 中。
- 新增参考 token 仅当现有值无法表达所需视觉关系；新增语义 token 当需要稳定视觉用途；新增组件 token 当两个以上属性需光学耦合。
- 每个外观替换都记录在其基础 token 旁。

---

## 14. 实现对照（token ↔ DesignSystem.swift）

> 文档与实现必须一致；不一致时以 token 源（本文件）为准修正代码。

| 组件 token | Swift 实现 | 使用处 |
| --- | --- | --- |
| 色彩参考 | `DS.Chroma.*`、`DS.Neutral.*` | 全部 |
| 语义色 | `DS.Semantic.*` | 全局 tint、状态、徽标 |
| 间距 / 圆角 / 描边 | `DS.Space.*`、`DS.Radius.*`、`DS.Stroke.*` | 全部 |
| 字体 | `DS.Typeface.*` | 全部 |
| 不透明度 | `DS.Opacity.*` | 表面、禁用态 |
| 动效 | `DS.Motion.*` | 控件、图表 |
| Canvas | `DSCanvasBackground` | ContentView / ActivationView |
| Card | `DSCard` | SnapshotSummary、Activation 卡片 |
| Card 按钮 | `DSCardButtonStyle` | ImpactCards |
| Recessed | `DSRecessed` | 进度容器（HomeView） |
| Action Button | `DSActionButtonStyle`（`.dsAction(_:size:)`） | 扫描、激活、清理、设置 |
| Icon Button | `DSIconButtonStyle`（`.dsIcon`） | 预留（工具按钮） |
| Badge | `DSBadge` | Agent 列表、进程行 |
| 页面布局 / 图标尺寸 | `DS.Layout.*`、`DS.IconSize.*` | 首页、导航、状态行、激活门户 |
| 门户页脚链接 | `DSFooterButtonStyle` | 激活门户 |
| 门户氛围渐变 | `DSHeroWash`（ActivationView.swift） | 激活门户 |
| 门户信任徽章 | `DSTrustBadge`（ActivationView.swift） | 激活门户 |
| 门户能力行 | `DSFeatureRow`（ActivationView.swift） | 激活门户 |
| 门户产品预览 | `DSProductPreview`（ActivationView.swift） | 激活门户 |
| 页面首部 | `DSPageHeader` | HomeView |
| 原生列表画布 | `.dsInstrumentList()` | Agent / Skill / 空间 / 活动 / 设置 / 历史 |
| 导航行 | `SidebarRow`（ContentView） | 侧边栏 |
| 面积折线 | `DSLineChart` | HistoryView CPU 趋势 |
| 微柱状图 | `DSMicroHistogram` | 预留（速率分布） |
| 分段仪表 | `DSSegmentedMeter` | ActivityView CPU / 进程 |
| 环形进度 | `DSDonut` | ActivityView 卷容量 |
| 发现界面 | `HomeDiscoveryView`（HomeView.swift） | HomeView 扫描中（逐个确认 Agent） |
| 发现芯片 | `HomeDiscoveryChip`（HomeView.swift） | HomeView 发现界面 |
| 产品视觉映射 | `HomeProductStyle`（HomeView.swift） | 发现芯片产品图标与色相 |

---

## 15. 验收清单（新增 / 修改界面时的自检）

1. [ ] 不引入任何 `material` / `NSVisualEffectView` / 多层阴影 / 循环动画。
2. [ ] 所有数字使用 `monospacedDigit()`；数值与单位共享首行基线。
3. [ ] 颜色只来自 `DS.Chroma` / `DS.Neutral` / 语义色；无 View 内裸色值。
4. [ ] 间距 / 圆角 / 描边 / 字体来自 `DS` token；无裸字面量。
5. [ ] 选中态使用 `surface.selection` 配方（accent 12% + 28% 描边）。
6. [ ] 动效时长来自 `DS.Motion`，且尊重 Reduce Motion。
7. [ ] 状态不只靠颜色表达：配文字、徽标或位置。
8. [ ] 浅色 / 深色 / 非活跃窗口三个环境都检查过。
9. [ ] 新组件有语义 token 或组件 token 支撑，并登记到第 14 节对照表。
