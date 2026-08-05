import AgentNestCore
import Foundation

extension AppModel {
    func scanPhaseTitle(_ phase: ScanPhase) -> String {
        switch phase {
        case .discoveringAgents: localized("发现 Agent")
        case .validatingHomes: localized("验证 Home / Profile")
        case .indexingSkills: localized("索引 Skill")
        case .measuringSpace: localized("测量空间")
        case .generatingFindings: localized("生成安全与活动结论")
        case .reconciling: localized("对账并完成")
        }
    }

    func discoverySourceTitle(_ source: DiscoverySource) -> String {
        switch source {
        case .defaultPath: localized("默认路径")
        case .environment: localized("环境变量")
        case .custom: localized("用户添加")
        case .userConfirmed: localized("用户确认")
        }
    }

    func artifactCategoryTitle(_ category: ArtifactCategory) -> String {
        switch category {
        case .sessions: localized("会话")
        case .cache: localized("缓存")
        case .logs: localized("日志")
        case .runtime: localized("运行时")
        case .browser: localized("浏览器")
        case .database: localized("数据库")
        case .skill: localized("Skill")
        case .configuration: localized("配置")
        case .unattributed: localized("未归属")
        }
    }

    func artifactRiskTitle(_ risk: ArtifactRisk) -> String {
        switch risk {
        case .rebuildable: localized("可重建")
        case .expensiveOrShared: localized("昂贵或共享")
        case .userContent: localized("用户内容")
        case .protected: localized("受保护")
        }
    }

    func activityProtectionTitle(_ activity: ActivityProtection) -> String {
        switch activity {
        case .inactive: localized("不活跃")
        case .recentlyOpened: localized("最近打开")
        case .writerPresent: localized("正在写入")
        case .unknown: localized("未知")
        }
    }

    func cleanupMethodTitle(_ method: CleanupMethod) -> String {
        switch method {
        case .trash: localized("移到废纸篓")
        case .officialPermanentDelete: localized("官方永久删除")
        }
    }

    func deviceHealthTitle(_ health: DeviceHealthState) -> String {
        switch health {
        case .verified: localized("已验证")
        case .failing: localized("可能故障")
        case .unsupported: localized("不支持")
        case .unavailable: localized("不可用")
        case .disconnected: localized("已断开")
        case .stale: localized("数据已过期")
        }
    }

    func formatBytes(_ value: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = .useAll
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: Int64(value))
    }

    func formatPercent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(1)).locale(appLocale))
    }
}
