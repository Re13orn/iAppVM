import Foundation

@MainActor enum LCSandboxBackupManager {
    static var storage: URL { LCPath.docPath.resolvingSymlinksInPath().appendingPathComponent("iOSVM/SandboxBackups") }
    static func context(_ model: LCAppModel, _ container: LCContainer) throws -> LCSandboxBackupStore.Context {
        guard !model.appInfo.isShared, !container.isShared, container.storageBookMark == nil,
              model.uiContainers.contains(where: { $0.folderName == container.folderName }),
              container.containerURL.standardizedFileURL == LCPath.dataPath.appendingPathComponent(container.folderName).standardizedFileURL else {
            throw LCSandboxBackupStore.fail("目前仅支持此 App 的本地普通数据容器；共享或外部容器请使用所属存储的备份功能。")
        }
        return try .init(owner: model.appInfo.relativeBundlePath, container: container.folderName, root: container.containerURL, storage: storage)
    }
    static func requireStopped(_ model: LCAppModel, _ container: LCContainer) throws {
        guard !model.isOperationBusy, !model.isLaunchPreparationBusy, !model.isSigningInProgress,
              !IOSVMProcessRegistry.shared.isBundleBusy(model.appInfo.relativeBundlePath),
              !IOSVMProcessRegistry.shared.isContainerBusy(container.folderName) else {
            throw LCSandboxBackupStore.fail("请先关闭目标 App 的所有窗口，待进程退出后再操作沙盒备份。")
        }
    }
    /// Reserve on the main actor before moving I/O off the UI thread. Launches use
    /// the same lease, including their signing/preparation phase.
    static func perform<T: Sendable>(_ model: LCAppModel, _ container: LCContainer,
                                    work: @escaping @Sendable (LCSandboxBackupStore.Context) throws -> T) async throws -> T {
        try requireStopped(model, container)
        let context = try context(model, container)
        let lease = try LCSandboxBackupStore.reserve(context.root)
        return try await Task.detached(priority: .userInitiated) {
            defer { withExtendedLifetime(lease) {} }
            return try work(context)
        }.value
    }
}
