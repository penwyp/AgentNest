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

    func cleanupMethodTitle(_ method: CleanupMethod) -> String {
        switch method {
        case .trash: localized("移到废纸篓")
        case .officialPermanentDelete: localized("官方永久删除")
        }
    }

    func cleanupUnitTitle(_ unit: CleanupUnit) -> String {
        guard unit.category == ArtifactCategory.sessions.rawValue,
              let nativeID = unit.nativeID else { return unit.name }
        return localized("会话 %@", nativeID)
    }

    func cleanupUnitOwnerTitle(_ unit: CleanupUnit) -> String {
        cleanupOwnerTitle(productID: unit.productID, homeIdentity: unit.homeIdentity, homePath: unit.homePath)
    }

    func cleanupResultOwnerTitle(_ result: CleanupResultRow) -> String? {
        guard !result.productID.isEmpty, !result.homePath.isEmpty else { return nil }
        return cleanupOwnerTitle(productID: result.productID, homeIdentity: result.homeIdentity, homePath: result.homePath)
    }

    private func cleanupOwnerTitle(
        productID: String,
        homeIdentity: PhysicalResourceIdentity?,
        homePath: String
    ) -> String {
        let productName = snapshot?.products.first { $0.id == productID }?.displayName ?? productID
        let homeName = homeDisplayTitle(
            productID: productID,
            homeIdentity: homeIdentity,
            homePath: homePath
        )
        return localized("Agent：%@ · Home：%@", productName, homeName)
    }

    func homeDisplayTitle(
        productID: String,
        homeIdentity: PhysicalResourceIdentity?,
        homePath: String
    ) -> String {
        if hideSensitivePaths,
           let product = snapshot?.products.first(where: { $0.id == productID }),
           let homeIdentity,
           let index = product.homes.sorted(by: { $0.path.localizedStandardCompare($1.path) == .orderedAscending })
               .firstIndex(where: { $0.id == homeIdentity }) {
            return localized("Home %d（路径已隐藏）", index + 1)
        } else {
            return displayPath(homePath)
        }
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
