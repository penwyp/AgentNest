import AgentNestCore
import SwiftUI

struct ActivityView: View {
    @Bindable var model: AppModel
    @State private var section: ActivitySection = .overview
    @State private var range: ActivityTimeRange = .minute
    @State private var trendMetric: ActivityTrendMetric = .disk
    @State private var frozenWorkspace: ActivityWorkspaceSnapshot?

    private var workspace: ActivityWorkspaceSnapshot? {
        frozenWorkspace ?? model.activityWorkspace
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            Group {
                if let workspace {
                    switch section {
                    case .overview:
                        ActivityOverviewPage(
                            model: model,
                            workspace: workspace,
                            range: range,
                            trendMetric: $trendMetric
                        )
                    case .processes:
                        ActivityProcessesPage(model: model, workspace: workspace)
                    case .disks:
                        ActivityDisksPage(model: model, workspace: workspace, range: range)
                    }
                } else {
                    ActivityWorkspaceSkeleton(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DS.Space.x300) {
                sectionPicker
                Spacer(minLength: DS.Space.x400)
                rangePicker
                liveButton
            }
            HStack(spacing: DS.Space.x200) {
                sectionPicker
                Spacer(minLength: DS.Space.x200)
                liveButton
            }
        }
        .padding(.horizontal, DS.Layout.pageHorizontalInset)
        .padding(.vertical, DS.Space.x300)
        .background(Color(nsColor: DS.Neutral.canvas))
    }

    private var sectionPicker: some View {
        Picker(model.localized("活动视图"), selection: $section) {
            ForEach(ActivitySection.allCases) { item in
                Text(model.localized(item.title)).tag(item)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(width: DS.Layout.activitySectionPickerWidth)
    }

    private var rangePicker: some View {
        HStack(spacing: DS.Space.x200) {
            Text(model.localized("时间范围"))
                .font(DS.Typeface.label)
                .foregroundStyle(.secondary)
            Picker(model.localized("时间范围"), selection: $range) {
                ForEach(ActivityTimeRange.allCases) { item in
                    Text(model.localized(item.title)).tag(item)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: DS.Layout.activityRangePickerWidth)
        }
        .disabled(section == .processes)
        .opacity(section == .processes ? DS.Opacity.disabledControl : 1)
        .help(model.localized(section == .processes ? "进程表显示最近一次采样" : "选择趋势图时间范围"))
    }

    private var liveButton: some View {
        Button {
            if frozenWorkspace == nil {
                frozenWorkspace = model.activityWorkspace
            } else {
                frozenWorkspace = nil
            }
        } label: {
            Image(systemName: frozenWorkspace == nil ? "pause.fill" : "play.fill")
        }
        .buttonStyle(.dsAction(size: .compact))
        .help(model.localized(frozenWorkspace == nil ? "暂停实时跟随" : "返回实时"))
        .accessibilityLabel(model.localized(frozenWorkspace == nil ? "暂停实时跟随" : "返回实时"))
        .disabled(model.activityWorkspace == nil)
    }
}

private enum ActivitySection: String, CaseIterable, Identifiable {
    case overview
    case processes
    case disks

    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: "概览"
        case .processes: "进程"
        case .disks: "磁盘"
        }
    }
}

private enum ActivityTimeRange: String, CaseIterable, Identifiable {
    case minute
    case fifteenMinutes
    case hour

    var id: String { rawValue }
    var seconds: TimeInterval {
        switch self {
        case .minute: 60
        case .fifteenMinutes: 900
        case .hour: 3_600
        }
    }
    var title: String {
        switch self {
        case .minute: "1 分钟"
        case .fifteenMinutes: "15 分钟"
        case .hour: "1 小时"
        }
    }

    func points(in workspace: ActivityWorkspaceSnapshot) -> [ActivityTrendPoint] {
        let cutoff = workspace.current.capturedAt.addingTimeInterval(-seconds)
        return workspace.trend.filter { $0.capturedAt >= cutoff }
    }

    func coverage(of points: [ActivityTrendPoint]) -> Double {
        min(1, points.reduce(0) { $0 + min($1.coveredSeconds, seconds) } / seconds)
    }
}

private enum ActivityTrendMetric: String, CaseIterable, Identifiable {
    case disk
    case cpu
    case network

    var id: String { rawValue }
    var title: String {
        switch self {
        case .disk: "磁盘 I/O"
        case .cpu: "CPU"
        case .network: "网络"
        }
    }
}

private struct ActivityOverviewPage: View {
    @Bindable var model: AppModel
    let workspace: ActivityWorkspaceSnapshot
    let range: ActivityTimeRange
    @Binding var trendMetric: ActivityTrendMetric

    var body: some View {
        let current = workspace.current
        let points = range.points(in: workspace)
        let coverage = range.coverage(of: points)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DS.Space.x450) {
                statusHeader(current, coverage: coverage)
                metricStrip(current)
                liveDiskSection(current)
                trendSection(points)
                processSection(current)
                measurementNote(current)
            }
            .padding(.horizontal, DS.Layout.pageHorizontalInset)
            .padding(.vertical, DS.Layout.pageVerticalInset)
            .frame(maxWidth: DS.Layout.activityPageMaxWidth)
            .frame(maxWidth: .infinity)
        }
    }

    /// 页面身份区：标题「活动」+ 状态信息行；符号随状态着色（positive / caution）。
    private func statusHeader(_ snapshot: ActivitySnapshot, coverage: Double) -> some View {
        DSPageIdentity(
            title: model.localized("活动"),
            glyph: snapshot.didResetBaseline ? "clock.arrow.circlepath" : "waveform.path.ecg",
            glyphColor: snapshot.droppedEvidenceCount > 0 ? DS.Semantic.statusCaution : DS.Semantic.statusPositive,
            detail: model.localized(statusTitle(snapshot)) + " · " + statusSubtitle(snapshot) + " · " + model.localized("已观测 %@", model.formatPercent(coverage))
        ) { EmptyView() }
    }

    private func statusTitle(_ snapshot: ActivitySnapshot) -> String {
        if snapshot.didResetBaseline { return "正在建立活动基线" }
        if snapshot.droppedEvidenceCount > 0 { return "活动证据部分可用" }
        if [
            snapshot.cpuFraction,
            snapshot.diskReadBytesPerSecond,
            snapshot.diskWriteBytesPerSecond,
            snapshot.networkReceiveBytesPerSecond,
            snapshot.networkSendBytesPerSecond,
        ].contains(where: { $0.value == nil }) { return "活动指标部分可用" }
        return "活动采集正常"
    }

    private func statusSubtitle(_ snapshot: ActivitySnapshot) -> String {
        guard let process = snapshot.processes.first,
              let fraction = process.cpuFraction.value else {
            return model.localized("正在等待可比较的进程活动样本。")
        }
        guard fraction >= 0.001 else {
            return model.localized("正在观测 %d 个可见进程。", snapshot.processes.count)
        }
        return model.localized("%@ 当前 CPU 最高 · %@", process.name, model.formatPercent(fraction))
    }

    private func metricStrip(_ snapshot: ActivitySnapshot) -> some View {
        DSCard {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DS.Space.x300) {
                    metricItems(snapshot)
                }
                Grid(horizontalSpacing: DS.Space.x300, verticalSpacing: DS.Space.x300) {
                    GridRow {
                        ActivityHeadlineMetric(
                            title: model.localized("CPU · 最近一次采样"),
                            value: metricText(snapshot.cpuFraction, format: .percent),
                            symbol: "cpu",
                            color: DS.Chart.series01
                        )
                        ActivityHeadlineMetric(
                            title: model.localized("磁盘写入 · 最近一次采样"),
                            value: metricText(snapshot.diskWriteBytesPerSecond, format: .rate),
                            symbol: "pencil.line",
                            color: DS.Chart.series03
                        )
                    }
                    GridRow {
                        ActivityHeadlineMetric(
                            title: model.localized("网络 · 最近一次采样"),
                            value: networkText(snapshot),
                            symbol: "network",
                            color: DS.Chart.series05
                        )
                        ActivityHeadlineMetric(
                            title: model.localized("可见进程"),
                            value: snapshot.processes.count.formatted(.number.locale(model.appLocale)),
                            symbol: "square.stack.3d.up",
                            color: DS.Chart.series06
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func metricItems(_ snapshot: ActivitySnapshot) -> some View {
        ActivityHeadlineMetric(
            title: model.localized("CPU · 最近一次采样"),
            value: metricText(snapshot.cpuFraction, format: .percent),
            symbol: "cpu",
            color: DS.Chart.series01
        )
        Divider().frame(height: DS.Layout.activityMetricDividerHeight)
        ActivityHeadlineMetric(
            title: model.localized("磁盘写入 · 最近一次采样"),
            value: metricText(snapshot.diskWriteBytesPerSecond, format: .rate),
            symbol: "pencil.line",
            color: DS.Chart.series03
        )
        Divider().frame(height: DS.Layout.activityMetricDividerHeight)
        ActivityHeadlineMetric(
            title: model.localized("网络 · 最近一次采样"),
            value: networkText(snapshot),
            symbol: "network",
            color: DS.Chart.series05
        )
        Divider().frame(height: DS.Layout.activityMetricDividerHeight)
        ActivityHeadlineMetric(
            title: model.localized("可见进程"),
            value: snapshot.processes.count.formatted(.number.locale(model.appLocale)),
            symbol: "square.stack.3d.up",
            color: DS.Chart.series06
        )
    }

    private func liveDiskSection(_ snapshot: ActivitySnapshot) -> some View {
        DSCard {
            VStack(alignment: .leading, spacing: DS.Space.x300) {
                ActivitySectionHeading(
                    title: model.localized("实时磁盘活动"),
                    subtitle: model.localized("物理设备最近一次采样的读取与写入吞吐")
                )
                if snapshot.physicalDevices.isEmpty {
                    Text(model.localized("物理设备指标不可用"))
                        .font(DS.Typeface.body)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(snapshot.physicalDevices.prefix(4)) { device in
                        HStack(spacing: DS.Space.x300) {
                            Image(systemName: "internaldrive")
                                .foregroundStyle(.secondary)
                                .frame(width: DS.IconSize.card)
                            VStack(alignment: .leading, spacing: DS.Space.x050) {
                                Text(device.name).font(DS.Typeface.body)
                                Text(device.bsdName ?? model.localized("物理设备"))
                                    .font(DS.Typeface.micro)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            directionMetric("读", device.readBytesPerSecond, color: DS.Semantic.directionA)
                            directionMetric("写", device.writeBytesPerSecond, color: DS.Semantic.directionB)
                        }
                        if device.id != snapshot.physicalDevices.prefix(4).last?.id { Divider() }
                    }
                }
            }
        }
    }

    private func trendSection(_ points: [ActivityTrendPoint]) -> some View {
        DSCard {
            VStack(alignment: .leading, spacing: DS.Space.x300) {
                ActivitySectionHeading(
                    title: model.localized("资源趋势"),
                    subtitle: model.localized("缺失样本会断开曲线，不会显示为零")
                ) {
                    Picker(model.localized("资源"), selection: $trendMetric) {
                        ForEach(ActivityTrendMetric.allCases) { metric in
                            Text(model.localized(metric.title)).tag(metric)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: DS.Layout.activityTrendPickerWidth)
                }
                ActivityTrendChart(model: model, points: points, metric: trendMetric)
                    .frame(height: DS.Layout.activityChartHeight)
            }
        }
    }

    private func processSection(_ snapshot: ActivitySnapshot) -> some View {
        DSCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                ActivitySectionHeading(
                    title: model.localized("活跃进程"),
                    subtitle: model.localized("CPU 与请求 I/O 汇总在同一处")
                ) {
                    Text(model.localized("点击表头排序 · 显示前 12 个"))
                        .font(DS.Typeface.micro)
                        .foregroundStyle(.secondary)
                }
                .padding(DS.Space.x400)
                ActivityProcessTable(
                    model: model,
                    capturedAt: snapshot.capturedAt,
                    processes: snapshot.processes,
                    query: "",
                    limit: 12,
                    showsDetails: false
                )
            }
        }
    }

    private func measurementNote(_ snapshot: ActivitySnapshot) -> some View {
        DSRecessed {
            VStack(alignment: .leading, spacing: DS.Space.x100) {
                Label(model.localized("采集口径"), systemImage: "info.circle")
                    .font(DS.Typeface.label)
                Text(model.localized("进程请求 I/O 与物理设备吞吐不是同一指标；macOS 不提供可靠的逐进程网络计数，因此不会推测或显示伪造数据。"))
                    .font(DS.Typeface.caption)
                    .foregroundStyle(.secondary)
                if snapshot.droppedEvidenceCount > 0 {
                    Text(model.localized("本轮有 %d 个进程证据因权限、退出或预算未采集。", snapshot.droppedEvidenceCount))
                        .font(DS.Typeface.caption)
                        .foregroundStyle(DS.Semantic.statusCaution)
                }
            }
        }
    }

    private func directionMetric(_ title: String, _ metric: MetricValue, color: Color) -> some View {
        VStack(alignment: .trailing, spacing: DS.Space.x050) {
            Text(metricText(metric, format: .rate))
                .font(DS.Typeface.data)
                .foregroundStyle(metric.value == nil ? Color.secondary : color)
                .monospacedDigit()
            Text(model.localized(title)).font(DS.Typeface.micro).foregroundStyle(.secondary)
        }
        .frame(minWidth: DS.Layout.activityDirectionMetricWidth, alignment: .trailing)
    }

    private func networkText(_ snapshot: ActivitySnapshot) -> String {
        guard let receive = snapshot.networkReceiveBytesPerSecond.value,
              let send = snapshot.networkSendBytesPerSecond.value else { return model.localized("不可用") }
        return model.activityRateText(receive + send)
    }

    private func metricText(_ metric: MetricValue, format: ActivityMetricFormat) -> String {
        guard let value = metric.value else {
            return model.localized(metric.availability == .partial ? "部分可用" : "不可用")
        }
        switch format {
        case .percent: return model.formatPercent(value)
        case .rate: return model.activityRateText(value)
        }
    }
}

private struct ActivityProcessesPage: View {
    @Bindable var model: AppModel
    let workspace: ActivityWorkspaceSnapshot
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.x300) {
                HStack(spacing: DS.Space.x200) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField(model.localized("搜索进程或路径"), text: $query)
                        .textFieldStyle(.plain)
                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(model.localized("清除搜索"))
                    }
                }
                .padding(.horizontal, DS.Space.x300)
                .frame(width: DS.Layout.activitySearchWidth, height: DS.Layout.activitySearchHeight)
                .background(Color(nsColor: DS.Neutral.recessed), in: RoundedRectangle(cornerRadius: DS.Radius.controlRegular))
                .overlay {
                    RoundedRectangle(cornerRadius: DS.Radius.controlRegular)
                        .strokeBorder(Color.primary.opacity(DS.Opacity.borderQuiet), lineWidth: DS.Stroke.hairline)
                }
                Spacer()
                Label(model.localized("I/O · CPU · 当前用户可见"), systemImage: "person.crop.circle.badge.checkmark")
                    .font(DS.Typeface.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, DS.Layout.pageHorizontalInset)
            .padding(.vertical, DS.Space.x300)
            Divider()
            ScrollView {
                DSCard(padding: 0) {
                    ActivityProcessTable(
                        model: model,
                        capturedAt: workspace.current.capturedAt,
                        processes: workspace.current.processes,
                        query: query,
                        limit: 200,
                        showsDetails: true
                    )
                }
                .padding(.horizontal, DS.Layout.pageHorizontalInset)
                .padding(.vertical, DS.Layout.pageVerticalInset)
                .frame(maxWidth: DS.Layout.activityPageMaxWidth)
                .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct ActivityDisksPage: View {
    @Bindable var model: AppModel
    let workspace: ActivityWorkspaceSnapshot
    let range: ActivityTimeRange
    @State private var showsHardware = true

    var body: some View {
        let snapshot = workspace.current
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DS.Space.x450) {
                diskMetrics(snapshot)
                DSCard {
                    VStack(alignment: .leading, spacing: DS.Space.x300) {
                        ActivitySectionHeading(
                            title: model.localized("物理设备总吞吐"),
                            subtitle: model.localized("虚拟磁盘不计入总量")
                        )
                        ActivityTrendChart(model: model, points: range.points(in: workspace), metric: .disk)
                            .frame(height: DS.Layout.activityChartHeight)
                    }
                }
                volumeSection(snapshot)
                hardwareSection(snapshot)
            }
            .padding(.horizontal, DS.Layout.pageHorizontalInset)
            .padding(.vertical, DS.Layout.pageVerticalInset)
            .frame(maxWidth: DS.Layout.activityPageMaxWidth)
            .frame(maxWidth: .infinity)
        }
    }

    private func diskMetrics(_ snapshot: ActivitySnapshot) -> some View {
        DSCard {
            HStack(spacing: DS.Space.x300) {
                diskMetric("读取 · 最近一次采样", snapshot.diskReadBytesPerSecond, "eye", DS.Semantic.directionA)
                Divider().frame(height: DS.Layout.activityMetricDividerHeight)
                diskMetric("写入 · 最近一次采样", snapshot.diskWriteBytesPerSecond, "pencil.line", DS.Semantic.directionB)
                Divider().frame(height: DS.Layout.activityMetricDividerHeight)
                ActivityHeadlineMetric(
                    title: model.localized("已挂载卷"),
                    value: snapshot.volumes.count.formatted(.number.locale(model.appLocale)),
                    symbol: "externaldrive.connected.to.line.below",
                    color: DS.Semantic.accentPrimary
                )
            }
        }
    }

    private func diskMetric(_ title: String, _ metric: MetricValue, _ symbol: String, _ color: Color) -> some View {
        ActivityHeadlineMetric(
            title: model.localized(title),
            value: metric.value.map { model.activityRateText($0) } ?? model.localized(metric.availability == .partial ? "部分可用" : "不可用"),
            symbol: symbol,
            color: color
        )
    }

    private func volumeSection(_ snapshot: ActivitySnapshot) -> some View {
        DSCard {
            VStack(alignment: .leading, spacing: 0) {
                ActivitySectionHeading(
                    title: model.localized("挂载卷"),
                    subtitle: model.localized("卷名直接对应底层设备的实时吞吐")
                )
                .padding(.bottom, DS.Space.x200)
                if snapshot.volumes.isEmpty {
                    Text(model.localized("没有可见的挂载卷"))
                        .font(DS.Typeface.body)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(snapshot.volumes) { volume in
                        ActivityVolumeRow(model: model, volume: volume, devices: devices(for: volume, in: snapshot))
                        if volume.id != snapshot.volumes.last?.id { Divider() }
                    }
                }
            }
        }
    }

    private func hardwareSection(_ snapshot: ActivitySnapshot) -> some View {
        DSCard {
            DisclosureGroup(isExpanded: $showsHardware) {
                VStack(spacing: 0) {
                    ForEach(snapshot.physicalDevices) { device in
                        HStack(spacing: DS.Space.x300) {
                            Image(systemName: "internaldrive").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: DS.Space.x050) {
                                Text(device.name).font(DS.Typeface.body)
                                Text(device.bsdName ?? model.localized("设备标识不可用"))
                                    .font(DS.Typeface.micro).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(model.localized("读 %@", metricText(device.readBytesPerSecond)))
                                .font(DS.Typeface.data).foregroundStyle(DS.Semantic.directionA)
                            Text(model.localized("写 %@", metricText(device.writeBytesPerSecond)))
                                .font(DS.Typeface.data).foregroundStyle(DS.Semantic.directionB)
                        }
                        .padding(.vertical, DS.Space.x200)
                        if device.id != snapshot.physicalDevices.last?.id { Divider() }
                    }
                }
                .padding(.top, DS.Space.x200)
            } label: {
                Text(model.localized("硬件诊断")).font(DS.Typeface.section)
            }
        }
    }

    private func devices(for volume: MountedVolume, in snapshot: ActivitySnapshot) -> [PhysicalDeviceActivity] {
        let identifiers = Set(volume.physicalDeviceIDs)
        return snapshot.physicalDevices.filter { identifiers.contains($0.id) }
    }

    private func metricText(_ metric: MetricValue) -> String {
        metric.value.map { model.activityRateText($0) } ?? model.localized(metric.availability == .partial ? "部分可用" : "不可用")
    }
}

private struct ActivityHeadlineMetric: View {
    let title: String
    let value: String
    let symbol: String
    let color: Color

    var body: some View {
        HStack(spacing: DS.Space.x250) {
            Image(systemName: symbol)
                .font(.system(size: DS.IconSize.navigation, weight: .medium))
                .foregroundStyle(color)
                .frame(width: DS.Layout.activityMetricIconFrame, height: DS.Layout.activityMetricIconFrame)
                .background(color.opacity(DS.Opacity.fillSubtle), in: RoundedRectangle(cornerRadius: DS.Radius.icon))
            VStack(alignment: .leading, spacing: DS.Space.x050) {
                Text(title).font(DS.Typeface.micro).foregroundStyle(.secondary).lineLimit(1)
                Text(value).font(DS.Typeface.data).monospacedDigit().lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ActivitySectionHeading<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let trailing: Trailing

    init(title: String, subtitle: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: DS.Space.x300) {
            VStack(alignment: .leading, spacing: DS.Space.x050) {
                Text(title).font(DS.Typeface.section)
                Text(subtitle).font(DS.Typeface.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: DS.Space.x300)
            trailing
        }
    }
}

private extension ActivitySectionHeading where Trailing == EmptyView {
    init(title: String, subtitle: String) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

private enum ActivityMetricFormat { case percent, rate }

private struct ActivityTrendChart: View {
    @Bindable var model: AppModel
    let points: [ActivityTrendPoint]
    let metric: ActivityTrendMetric

    var body: some View {
        let resolvedSeries = series
        let dataMaximum = resolvedSeries.flatMap(\.values).compactMap { $0 }.max()
        let scaleMaximum = maximum(for: dataMaximum)
        VStack(alignment: .leading, spacing: DS.Space.x100) {
            HStack(spacing: DS.Space.x300) {
                ForEach(resolvedSeries, id: \.name) { item in
                    HStack(spacing: DS.Space.x150) {
                        Capsule().fill(item.color).frame(width: DS.Layout.activityLegendWidth, height: DS.Stroke.surface)
                        Text(model.localized(item.name)).font(DS.Typeface.micro).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(maximumLabel(dataMaximum))
                    .font(DS.Typeface.micro)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            GeometryReader { proxy in
                Canvas { context, size in
                    let plotHeight = max(1, size.height - DS.Layout.activityChartAxisHeight)
                    var grid = Path()
                    for index in 0...3 {
                        let y = plotHeight * CGFloat(index) / 3
                        grid.move(to: CGPoint(x: 0, y: y))
                        grid.addLine(to: CGPoint(x: size.width, y: y))
                    }
                    context.stroke(grid, with: .color(DS.Chart.grid), lineWidth: DS.Stroke.hairline)
                    for item in resolvedSeries {
                        let path = linePath(values: item.values, width: size.width, height: plotHeight, maximum: scaleMaximum)
                        let style = StrokeStyle(
                            lineWidth: DS.Chart.lineWidth,
                            lineCap: .round,
                            lineJoin: .round,
                            dash: item.dashed ? DS.Chart.secondaryDash : []
                        )
                        context.stroke(path, with: .color(item.color), style: style)
                    }
                }
                .background(DS.Chart.plotFill)
                .overlay(alignment: .bottom) {
                    HStack {
                        Text(points.first?.capturedAt.formatted(date: .omitted, time: .standard) ?? "—")
                        Spacer()
                        Text(points.last?.capturedAt.formatted(date: .omitted, time: .standard) ?? "—")
                    }
                    .font(DS.Typeface.micro)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .padding(.horizontal, DS.Space.x100)
                    .frame(height: DS.Layout.activityChartAxisHeight)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(model.localized("%@趋势图，共 %d 个样本", model.localized(metric.title), points.count))
    }

    private var series: [ActivityChartSeries] {
        switch metric {
        case .disk:
            return [
                ActivityChartSeries(name: "读取", color: DS.Semantic.directionA, dashed: false, values: points.map(\.diskReadBytesPerSecond)),
                ActivityChartSeries(name: "写入", color: DS.Semantic.directionB, dashed: true, values: points.map(\.diskWriteBytesPerSecond)),
            ]
        case .cpu:
            return [ActivityChartSeries(name: "CPU", color: DS.Chart.series01, dashed: false, values: points.map(\.cpuFraction))]
        case .network:
            return [
                ActivityChartSeries(name: "下载", color: DS.Chart.series05, dashed: false, values: points.map(\.networkReceiveBytesPerSecond)),
                ActivityChartSeries(name: "上传", color: DS.Chart.series07, dashed: true, values: points.map(\.networkSendBytesPerSecond)),
            ]
        }
    }

    private func maximum(for dataMaximum: Double?) -> Double {
        if metric == .cpu { return 1 }
        return max(dataMaximum ?? 0, 1)
    }

    private func maximumLabel(_ maximum: Double?) -> String {
        if metric == .cpu { return model.localized("上限 %@", model.formatPercent(1)) }
        guard let maximum else { return model.localized("峰值不可用") }
        return model.localized("峰值 %@", model.activityRateText(maximum))
    }

    private func linePath(values: [Double?], width: CGFloat, height: CGFloat, maximum: Double) -> Path {
        var path = Path()
        var hasCurrentSegment = false
        for (index, value) in values.enumerated() {
            guard let value else {
                hasCurrentSegment = false
                continue
            }
            let x = values.count <= 1 ? 0 : width * CGFloat(index) / CGFloat(values.count - 1)
            let y = height * (1 - CGFloat(min(max(value / maximum, 0), 1)))
            let point = CGPoint(x: x, y: y)
            if hasCurrentSegment {
                path.addLine(to: point)
            } else {
                path.move(to: point)
                hasCurrentSegment = true
            }
        }
        return path
    }
}

private struct ActivityChartSeries {
    let name: String
    let color: Color
    let dashed: Bool
    let values: [Double?]
}

private enum ActivityProcessSortKey: String, Hashable {
    case name
    case cpu
    case read
    case write
}

private struct ActivityProcessDerivationKey: Hashable {
    let capturedAt: Date
    let query: String
    let sort: ActivityProcessSortKey
    let ascending: Bool
    let limit: Int
}

private struct ActivityProcessTable: View {
    @Bindable var model: AppModel
    let capturedAt: Date
    let processes: [VisibleProcessActivity]
    let query: String
    let limit: Int
    let showsDetails: Bool
    @State private var sort: ActivityProcessSortKey = .write
    @State private var ascending = false
    @State private var rows: [VisibleProcessActivity] = []
    @State private var selectedID: ProcessStartIdentity?
    @State private var hasDerivedRows = false

    var body: some View {
        VStack(spacing: 0) {
            tableHeader
            Divider()
            if rows.isEmpty {
                if processes.isEmpty || hasDerivedRows {
                    ContentUnavailableView(
                        model.localized(processes.isEmpty ? "没有可见进程" : "未找到匹配进程"),
                        systemImage: processes.isEmpty ? "waveform.path.ecg" : "magnifyingglass",
                        description: Text(model.localized(processes.isEmpty ? "正在等待可比较的进程活动样本。" : "请尝试其它搜索词。"))
                    )
                    .frame(minHeight: DS.Layout.activityEmptyTableHeight)
                } else {
                    loadingRows
                }
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { process in
                        processRow(process)
                        if process.id != rows.last?.id { Divider().padding(.leading, DS.Space.x400) }
                    }
                }
            }
            if processes.count > limit {
                Text(model.localized("为保持页面响应，仅显示排序后的前 %d 个进程。", limit))
                    .font(DS.Typeface.micro)
                    .foregroundStyle(.secondary)
                    .padding(DS.Space.x300)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(DS.Opacity.fillFaint))
            }
        }
        .task(id: derivationKey) {
            let source = processes
            let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let currentSort = sort
            let currentAscending = ascending
            let currentLimit = limit
            let derived = await Task.detached(priority: .utility) {
                let filtered = normalizedQuery.isEmpty ? source : source.filter {
                    $0.name.localizedCaseInsensitiveContains(normalizedQuery)
                        || ($0.executablePath?.localizedCaseInsensitiveContains(normalizedQuery) ?? false)
                        || ($0.workingDirectoryPath?.localizedCaseInsensitiveContains(normalizedQuery) ?? false)
                }
                return Array(filtered.sorted {
                    Self.precedes($0, $1, sort: currentSort, ascending: currentAscending)
                }.prefix(currentLimit))
            }.value
            guard !Task.isCancelled else { return }
            rows = derived
            hasDerivedRows = true
            if let selectedID, !derived.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
        }
    }

    private var derivationKey: ActivityProcessDerivationKey {
        ActivityProcessDerivationKey(capturedAt: capturedAt, query: query, sort: sort, ascending: ascending, limit: limit)
    }

    private var tableHeader: some View {
        HStack(spacing: 0) {
            sortButton("进程", key: .name, width: nil, alignment: .leading)
            sortButton("CPU", key: .cpu, width: DS.Layout.activityCPUColumnWidth, alignment: .trailing)
            sortButton("当前读取", key: .read, width: DS.Layout.activityRateColumnWidth, alignment: .trailing)
            sortButton("当前写入", key: .write, width: DS.Layout.activityRateColumnWidth, alignment: .trailing)
            Text(model.localized("归因"))
                .font(DS.Typeface.label)
                .foregroundStyle(.secondary)
                .frame(width: DS.Layout.activityAttributionColumnWidth, alignment: .trailing)
        }
        .padding(.horizontal, DS.Space.x400)
        .frame(height: DS.Layout.activityTableHeaderHeight)
        .background(Color.primary.opacity(DS.Opacity.fillFaint))
    }

    private func sortButton(_ title: String, key: ActivityProcessSortKey, width: CGFloat?, alignment: Alignment) -> some View {
        Button {
            if sort == key {
                ascending.toggle()
            } else {
                sort = key
                ascending = key == .name
            }
        } label: {
            HStack(spacing: DS.Space.x100) {
                if alignment == .trailing { Spacer(minLength: 0) }
                Text(model.localized(title)).lineLimit(1)
                if sort == key {
                    Image(systemName: ascending ? "chevron.up" : "chevron.down")
                        .font(.system(size: DS.IconSize.sortIndicator, weight: .bold))
                }
                if alignment == .leading { Spacer(minLength: 0) }
            }
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: alignment)
            .frame(width: width)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(DS.Typeface.label)
        .foregroundStyle(sort == key ? Color.primary : Color.secondary)
        .accessibilityLabel(model.localized("按%@排序", model.localized(title)))
    }

    private func processRow(_ process: VisibleProcessActivity) -> some View {
        VStack(spacing: 0) {
            Button {
                guard showsDetails else { return }
                selectedID = selectedID == process.id ? nil : process.id
            } label: {
                HStack(spacing: 0) {
                    HStack(spacing: DS.Space.x250) {
                        Image(systemName: process.attribution == .agent ? "cpu" : "terminal")
                            .foregroundStyle(process.attribution == .agent ? DS.Semantic.accentPrimary : Color.secondary)
                            .frame(width: DS.Layout.activityProcessIconFrame, height: DS.Layout.activityProcessIconFrame)
                            .background(Color.primary.opacity(DS.Opacity.fillQuiet), in: RoundedRectangle(cornerRadius: DS.Radius.icon))
                        VStack(alignment: .leading, spacing: DS.Space.x050) {
                            Text(process.name).font(DS.Typeface.body).lineLimit(1)
                            Text(process.executablePath.map(model.displayPath) ?? model.localized("可执行路径不可用"))
                                .font(DS.Typeface.micro)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .privacySensitive()
                        }
                        Spacer(minLength: DS.Space.x200)
                    }
                    metricCell(process.cpuFraction, format: .percent, width: DS.Layout.activityCPUColumnWidth)
                    metricCell(process.requestedReadBytesPerSecond, format: .rate, width: DS.Layout.activityRateColumnWidth)
                    metricCell(process.requestedWriteBytesPerSecond, format: .rate, width: DS.Layout.activityRateColumnWidth)
                    Group {
                        if process.attribution == .agent {
                            DSBadge(text: "Agent", color: DS.Semantic.statusPositive, filled: true)
                        } else {
                            Text(model.localized("系统 / 其它")).foregroundStyle(.secondary)
                        }
                    }
                    .font(DS.Typeface.micro)
                    .frame(width: DS.Layout.activityAttributionColumnWidth, alignment: .trailing)
                }
                .padding(.horizontal, DS.Space.x400)
                .frame(minHeight: DS.Layout.activityProcessRowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .allowsHitTesting(showsDetails)
            if selectedID == process.id, showsDetails {
                ActivityProcessEvidence(model: model, process: process)
                    .padding(.horizontal, DS.Space.x400)
                    .padding(.bottom, DS.Space.x300)
            }
        }
    }

    private func metricCell(_ metric: MetricValue, format: ActivityMetricFormat, width: CGFloat) -> some View {
        let text: String
        if let value = metric.value {
            text = format == .percent
                ? model.formatPercent(value)
                : model.activityRateText(value)
        } else {
            text = model.localized(metric.availability == .partial ? "部分可用" : "不可用")
        }
        return Text(text)
            .font(DS.Typeface.data)
            .foregroundStyle(metric.value == nil ? Color.secondary : Color.primary)
            .monospacedDigit()
            .lineLimit(1)
            .frame(width: width, alignment: .trailing)
    }

    private var loadingRows: some View {
        VStack(spacing: 0) {
            ForEach(0..<6, id: \.self) { _ in
                HStack(spacing: DS.Space.x300) {
                    RoundedRectangle(cornerRadius: DS.Radius.icon).fill(Color.primary.opacity(DS.Opacity.fillSkeleton))
                        .frame(width: DS.Layout.activityProcessIconFrame, height: DS.Layout.activityProcessIconFrame)
                    RoundedRectangle(cornerRadius: DS.Radius.small).fill(Color.primary.opacity(DS.Opacity.fillSkeleton))
                        .frame(height: DS.Layout.activitySkeletonLineHeight)
                }
                .padding(.horizontal, DS.Space.x400)
                .frame(height: DS.Layout.activityProcessRowHeight)
            }
        }
        .redacted(reason: .placeholder)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    nonisolated private static func precedes(
        _ lhs: VisibleProcessActivity,
        _ rhs: VisibleProcessActivity,
        sort: ActivityProcessSortKey,
        ascending: Bool
    ) -> Bool {
        if sort == .name {
            let result = lhs.name.localizedStandardCompare(rhs.name)
            if result != .orderedSame { return ascending ? result == .orderedAscending : result == .orderedDescending }
            return lhs.id.pid < rhs.id.pid
        }
        let left: Double?
        let right: Double?
        switch sort {
        case .cpu:
            left = lhs.cpuFraction.value
            right = rhs.cpuFraction.value
        case .read:
            left = lhs.requestedReadBytesPerSecond.value
            right = rhs.requestedReadBytesPerSecond.value
        case .write:
            left = lhs.requestedWriteBytesPerSecond.value
            right = rhs.requestedWriteBytesPerSecond.value
        case .name:
            return false
        }
        switch (left, right) {
        case (let left?, let right?) where left != right: return ascending ? left < right : left > right
        case (_?, nil): return true
        case (nil, _?): return false
        default:
            let result = lhs.name.localizedStandardCompare(rhs.name)
            if result != .orderedSame { return result == .orderedAscending }
            return lhs.id.pid < rhs.id.pid
        }
    }
}

private struct ActivityProcessEvidence: View {
    @Bindable var model: AppModel
    let process: VisibleProcessActivity

    var body: some View {
        DSRecessed {
            VStack(alignment: .leading, spacing: DS.Space.x200) {
                if let workingDirectory = process.workingDirectoryPath {
                    LabeledContent(model.localized("工作目录")) {
                        Text(model.displayPath(workingDirectory)).privacySensitive()
                    }
                }
                if !process.evidence.isEmpty {
                    LabeledContent(model.localized("Agent 归因证据")) {
                        Text(process.evidence.joined(separator: " · ")).privacySensitive()
                    }
                }
                if process.attribution == .agent {
                    Text(model.localized("当前打开文件")).font(DS.Typeface.label)
                    if process.currentlyOpenFiles.isEmpty {
                        Text(model.localized("无权限、进程已退出或当前没有可见 vnode 文件。"))
                            .font(DS.Typeface.micro).foregroundStyle(.secondary)
                    } else {
                        ForEach(process.currentlyOpenFiles.prefix(10), id: \.path) { evidence in
                            Text(model.displayPath(evidence.path))
                                .font(DS.Typeface.micro)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .privacySensitive()
                        }
                    }
                    Text(model.localized("最近变化")).font(DS.Typeface.label)
                    Text(model.localized("未启动 Trace Helper；打开文件不会被冒充为变化事件。"))
                        .font(DS.Typeface.micro).foregroundStyle(.secondary)
                } else {
                    Text(model.localized("文件证据仅为已归因的 Agent 进程采集。"))
                        .font(DS.Typeface.micro).foregroundStyle(.secondary)
                }
            }
            .font(DS.Typeface.caption)
        }
    }
}

private struct ActivityVolumeRow: View {
    @Bindable var model: AppModel
    let volume: MountedVolume
    let devices: [PhysicalDeviceActivity]

    var body: some View {
        HStack(spacing: DS.Space.x300) {
            Image(systemName: volume.isLocal == false ? "network" : "externaldrive")
                .foregroundStyle(.secondary)
                .frame(width: DS.Layout.activityProcessIconFrame)
            VStack(alignment: .leading, spacing: DS.Space.x050) {
                Text(volume.name).font(DS.Typeface.body)
                Text(model.displayPath(volume.mountPath))
                    .font(DS.Typeface.micro).foregroundStyle(.secondary).privacySensitive()
            }
            Spacer()
            if devices.isEmpty {
                Text(volume.isLocal == false ? model.localized("网络卷") : model.localized("设备映射不可用"))
                    .font(DS.Typeface.caption).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .trailing, spacing: DS.Space.x050) {
                    Text(model.localized("读 %@", combinedRate(\.readBytesPerSecond)))
                        .foregroundStyle(DS.Semantic.directionA)
                    Text(model.localized("写 %@", combinedRate(\.writeBytesPerSecond)))
                        .foregroundStyle(DS.Semantic.directionB)
                }
                .font(DS.Typeface.data)
            }
            capacity
                .frame(width: DS.Layout.activityCapacityWidth)
        }
        .padding(.vertical, DS.Space.x300)
    }

    @ViewBuilder
    private var capacity: some View {
        if let available = volume.availableBytes, let total = volume.totalBytes, total > 0 {
            let used = total > available ? total - available : 0
            let fraction = Double(used) / Double(total)
            VStack(alignment: .trailing, spacing: DS.Space.x100) {
                Text(model.localized("%@ / %@", model.formatBytes(used), model.formatBytes(total)))
                    .font(DS.Typeface.micro).monospacedDigit()
                ProgressView(value: fraction)
                    .tint(fraction >= 0.9 ? DS.Semantic.statusCritical : DS.Semantic.accentPrimary)
            }
        } else {
            Text(model.localized("容量不可用")).font(DS.Typeface.caption).foregroundStyle(.secondary)
        }
    }

    private func combinedRate(_ keyPath: KeyPath<PhysicalDeviceActivity, MetricValue>) -> String {
        let values = devices.compactMap { $0[keyPath: keyPath].value }
        guard !values.isEmpty else { return model.localized("不可用") }
        let rate = model.activityRateText(values.reduce(0, +))
        return values.count == devices.count ? rate : model.localized("部分 %@", rate)
    }
}

private extension AppModel {
    func activityRateText(_ value: Double) -> String {
        let rounded = UInt64(max(0, value).rounded())
        guard rounded > 0 else { return localized("0 B/s") }
        return localized("%@/s", formatBytes(rounded))
    }
}

private struct ActivityWorkspaceSkeleton: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DS.Space.x450) {
                VStack(alignment: .leading, spacing: DS.Space.x200) {
                    HStack(spacing: DS.Space.x200) {
                        Circle()
                            .fill(DS.Semantic.statusPositive)
                            .frame(width: 20, height: 20)
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.primary.opacity(0.12))
                            .frame(width: 96, height: 26)
                    }
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.primary.opacity(0.12))
                        .frame(width: 280, height: 11)
                }
                DSCard {
                    HStack {
                        ForEach(0..<4, id: \.self) { _ in
                            ActivitySkeletonBlock(height: DS.Layout.activityMetricDividerHeight)
                        }
                    }
                }
                DSCard { ActivitySkeletonBlock(height: DS.Layout.activityChartHeight) }
                DSCard {
                    VStack {
                        ForEach(0..<6, id: \.self) { _ in
                            ActivitySkeletonBlock(height: DS.Layout.activityProcessRowHeight)
                        }
                    }
                }
            }
            .padding(.horizontal, DS.Layout.pageHorizontalInset)
            .padding(.vertical, DS.Layout.pageVerticalInset)
            .frame(maxWidth: DS.Layout.activityPageMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .redacted(reason: .placeholder)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct ActivitySkeletonBlock: View {
    let height: CGFloat
    var body: some View {
        RoundedRectangle(cornerRadius: DS.Radius.small)
            .fill(Color.primary.opacity(DS.Opacity.fillSkeleton))
            .frame(maxWidth: .infinity)
            .frame(height: height)
    }
}
