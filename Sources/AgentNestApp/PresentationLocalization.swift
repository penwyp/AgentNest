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

    func activityEvidenceTitle(_ evidence: ActivityEvidenceKind) -> String {
        switch evidence {
        case .officialMetadata: localized("Agent 官方元数据")
        case .objectMetadata: localized("对象元数据")
        case .contentMaximumModification: localized("内容最后修改")
        case .rootModification: localized("根目录最后修改")
        case .accessTimeOnly: localized("仅访问时间")
        case .unknown: localized("未知")
        }
    }

    func cleanupMethodTitle(_ method: CleanupMethod) -> String {
        switch method {
        case .trash: localized("移到废纸篓")
        case .officialPermanentDelete: localized("官方永久删除")
        }
    }

    func cleanupUnitTitle(_ unit: CleanupUnit) -> String {
        guard unit.category == ArtifactCategory.sessions.rawValue,
              let nativeID = unit.nativeID else { return unit.name }
        return localized("会话 %@", String(nativeID.prefix(8)))
    }

    func cleanupResultStatusTitle(_ status: CleanupResultStatus) -> String {
        switch status {
        case .succeeded: localized("成功")
        case .failed: localized("失败")
        case .skipped: localized("已跳过")
        case .cancelled: localized("已取消")
        }
    }

    func cleanupResultCodeTitle(_ code: String) -> String {
        switch code {
        case "cleanup.trashed": localized("已移入废纸篓")
        case "cleanup.officialDeleted": localized("官方删除已确认")
        case "cleanup.generationChanged": localized("扫描结果已变化")
        case "cleanup.protected": localized("受风险或活动保护")
        case "cleanup.boundaryChanged": localized("Home 边界已变化")
        case "cleanup.targetChanged", "cleanup.familyChanged": localized("目标身份或成员已变化")
        case "cleanup.activityChanged": localized("目标当前正在使用或活动证据不足")
        case "cleanup.officialExecutorUnavailable": localized("未找到官方清理执行器")
        case "cleanup.officialHomeChanged": localized("官方服务返回的 Home 不一致")
        case "cleanup.officialIdentityChanged": localized("官方会话身份或父子关系已变化")
        case "cleanup.officialDeleteFailed": localized("官方删除未确认成功")
        case "cleanup.officialProtocolInvalid": localized("官方清理协议不兼容")
        case "cleanup.ioFailure": localized("文件系统操作失败")
        case "cleanup.cancelled": localized("用户停止了后续清理")
        default: localized("清理未完成：%@", code)
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
