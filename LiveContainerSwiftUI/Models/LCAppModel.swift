import Foundation

protocol LCAppModelDelegate {
    func closeNavigationView()
    func changeAppVisibility(app : LCAppModel)
    func jitLaunch(appName: String, classicMode: UInt) async
    func jitLaunch(withScript script: String, appName: String, classicMode: UInt) async
    func jitLaunch(withPID pid: Int, withScript script: String?, appName: String) async
    func showRunWhenMultitaskAlert() async -> Bool?
}

class LCAppModel: ObservableObject, Hashable {
    
    @Published var appInfo : LCAppInfo
    
    @Published private(set) var isOperationBusy = false
    @Published private(set) var isLaunchPreparationBusy = false
    private var processObserver: NSObjectProtocol?
    var isAppRunning: Bool {
        isOperationBusy || isLaunchPreparationBusy || IOSVMProcessRegistry.shared.isBundleBusy(appInfo.relativeBundlePath) ||
            uiContainers.contains { LCSandboxBackupStore.busy($0.containerURL) }
    }
    @Published var isSigningInProgress = false
    @Published var signProgress = 0.0
    private var observer : NSKeyValueObservation?
    
    @Published var uiIsJITNeeded : Bool {
        didSet {
            appInfo.isJITNeeded = uiIsJITNeeded
        }
    }
    @Published var uiClassicMode : Bool {
        didSet {
            appInfo.classicMode = uiClassicMode
        }
    }
    @Published var uiIsHidden : Bool
    @Published var uiIsLocked : Bool
    @Published var uiIsShared : Bool
    @Published var uiDefaultDataFolder : String?
    @Published var uiContainers : [LCContainer]
    @Published var uiSelectedContainer : LCContainer?
    @Published var uiIs32bit : Bool
    @Published var uiIs32bitEmulator : Bool
    @Published var uiTweakFolder : String? {
        didSet {
            appInfo.tweakFolder = uiTweakFolder
        }
    }
    @Published var uiDoSymlinkInbox : Bool {
        didSet {
            appInfo.doSymlinkInbox = uiDoSymlinkInbox
        }
    }
    @Published var uiUseLCBundleId : Bool {
        didSet {
            appInfo.doUseLCBundleId = uiUseLCBundleId
        }
    }
    
    @Published var uiFixFilePickerNew : Bool {
        didSet {
            appInfo.fixFilePickerNew = uiFixFilePickerNew
        }
    }
    @Published var uiFixLocalNotification : Bool {
        didSet {
            appInfo.fixLocalNotification = uiFixLocalNotification
        }
    }
    
    @Published var uiHideLiveContainer : Bool {
        didSet {
            appInfo.hideLiveContainer = uiHideLiveContainer
        }
    }
    @Published var uiTweakLoaderInjectFailed : Bool
    @Published var uiDontInjectTweakLoader : Bool {
        didSet {
            appInfo.dontInjectTweakLoader = uiDontInjectTweakLoader
        }
    }
    @Published var uiDontLoadTweakLoader : Bool {
        didSet {
            appInfo.dontLoadTweakLoader = uiDontLoadTweakLoader
        }
    }
    @Published var uiOrientationLock : LCOrientationLock {
        didSet {
            appInfo.orientationLock = uiOrientationLock
        }
    }
    @Published var uiSelectedLanguage : String {
        didSet {
            appInfo.selectedLanguage = uiSelectedLanguage
        }
    }
    
    @Published var uiDontSign : Bool {
        didSet {
            appInfo.dontSign = uiDontSign
        }
    }
    
    @Published var jitLaunchScriptJs: String? {
        didSet {
            appInfo.jitLaunchScriptJs = jitLaunchScriptJs
        }
    }
    
    @Published var uiSelected32BitEmulator : String {
        didSet {
            appInfo.selected32BitEmulator = uiSelected32BitEmulator
        }
    }
    
    @Published var uiSpoofSDKVersion : Bool {
        didSet {
            appInfo.spoofSDKVersion = uiSpoofSDKVersion
        }
    }
    
    @Published var uiRemark : String {
        didSet {
            appInfo.remark = uiRemark
        }
    }
    
    @Published var uiIsMultitaskModeSpecificed : MultitaskSpecified {
        didSet {
            appInfo.multitaskSpecified = uiIsMultitaskModeSpecificed;
        }
    }
    
    public var bundleIdentifier: String {
        get {
            return appInfo.bundleIdentifier() ?? "?"
        }
    }
    
    public var version: String {
        get {
            return appInfo.version() ?? "?"
        }
    }
    
    public var displayName: String {
        get {
            return appInfo.displayName() ?? "?"
        }
    }
    
    public var shouldLaunchInMultitaskMode : Bool {
        get {
            if #available(iOS 16.0, *) {
                let defaultWindowMode = UserDefaults.standard.object(forKey: "LCLaunchInMultitaskMode") as? Bool
                    ?? (Bundle.main.object(forInfoDictionaryKey: "IOSVMTestWindowsEnabled") as? Bool ?? false)
                return uiIsMultitaskModeSpecificed == .yes ||
                (uiIsMultitaskModeSpecificed == .default && defaultWindowMode)
            } else {
                return false
            }
        }
    }
    
    @Published var supportedLanguages : [String]?
    
    var delegate : LCAppModelDelegate?
    
    init(appInfo : LCAppInfo, delegate: LCAppModelDelegate? = nil) {
        self.appInfo = appInfo
        self.delegate = delegate

        if !appInfo.isLocked && appInfo.isHidden {
            appInfo.isLocked = true
        }
        
        self.uiIsJITNeeded = appInfo.isJITNeeded
        self.uiClassicMode = appInfo.classicMode
        self.uiIsHidden = appInfo.isHidden
        self.uiIsLocked = appInfo.isLocked
        self.uiIsShared = appInfo.isShared
        self.uiSelectedLanguage = appInfo.selectedLanguage ?? ""
        self.uiDefaultDataFolder = appInfo.dataUUID
        self.uiContainers = appInfo.containers
        self.uiTweakFolder = appInfo.tweakFolder
        self.uiDoSymlinkInbox = appInfo.doSymlinkInbox
        self.uiOrientationLock = appInfo.orientationLock
        self.uiIsMultitaskModeSpecificed = appInfo.multitaskSpecified
        self.uiUseLCBundleId = appInfo.doUseLCBundleId
        self.uiFixFilePickerNew = appInfo.fixFilePickerNew
        self.uiFixLocalNotification = appInfo.fixLocalNotification
        self.uiHideLiveContainer = appInfo.hideLiveContainer
        self.uiDontInjectTweakLoader = appInfo.dontInjectTweakLoader
        self.uiTweakLoaderInjectFailed = appInfo.info()["LCTweakLoaderCantInject"] as? Bool ?? false
        self.uiDontLoadTweakLoader = appInfo.dontLoadTweakLoader
        self.uiDontSign = appInfo.dontSign
        self.jitLaunchScriptJs = appInfo.jitLaunchScriptJs
        self.uiSelected32BitEmulator = appInfo.selected32BitEmulator ?? ""
        self.uiSpoofSDKVersion = appInfo.spoofSDKVersion
        self.uiRemark = appInfo.remark ?? ""
        self.uiIs32bit = appInfo.is32bit
        self.uiIs32bitEmulator = appInfo.is32bitEmulator
        processObserver = NotificationCenter.default.addObserver(forName: NSNotification.Name("IOSVMProcessesDidChange"), object: nil, queue: .main) { [weak self] note in
            guard let self, note.userInfo?["bundle"] as? String == self.appInfo.relativeBundlePath else { return }
            self.objectWillChange.send()
        }
        for container in uiContainers {
            if container.folderName == uiDefaultDataFolder {
                self.uiSelectedContainer = container;
                break
            }
        }
    }
    
    deinit {
        if let processObserver { NotificationCenter.default.removeObserver(processObserver) }
    }

    static func == (lhs: LCAppModel, rhs: LCAppModel) -> Bool {
        return lhs === rhs
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
    
    // You should let LCAppModel.runApp to decide whether to run in multitask mode, but you may override the multitask parameter if necessary
    func runApp(multitask: Bool? = nil, containerFolderName : String? = nil, bundleIdOverride : String? = nil, urlStr : String? = nil, forceJIT: Bool? = nil) async throws{
        let canPrepare = await MainActor.run {
            guard !isOperationBusy && !isLaunchPreparationBusy else { return false }
            isLaunchPreparationBusy = true
            return true
        }
        guard canPrepare else { return }
        defer { Task { @MainActor in isLaunchPreparationBusy = false } }

        // Returning to an existing window must not re-sign or mutate its live configuration.
        if let current = containerFolderName ?? uiSelectedContainer?.folderName,
           await bringExistingMultitaskWindowIfNeeded(dataUUID: current, urlScheme: urlStr) { return }
        let launchLease = try await MainActor.run { () throws -> LCSandboxBackupStore.Lease? in
            guard let container = uiContainers.first(where: { $0.folderName == (containerFolderName ?? uiSelectedContainer?.folderName) }) ?? uiSelectedContainer ?? uiContainers.first else { return nil }
            if let context = try? LCSandboxBackupManager.context(self, container), LCSandboxBackupStore.pending(context) {
                throw LCSandboxBackupStore.fail("lc.launch.pendingRestoreExists".loc)
            }
            return try LCSandboxBackupStore.reserve(container.containerURL)
        }
        defer { withExtendedLifetime(launchLease) {} }
        let checks = await MainActor.run { LCLaunchPreflight.check(self, multitask: multitask) }
        if checks.contains(where: \.blocking) { throw LCLaunchPreflight.Failure(issues: checks) }
        if checks.contains(where: { $0.id == "signing" }), IOSVMDeviceSigning.configured {
            isSigningInProgress = true
            do { try await IOSVMDeviceSigning.sign(appInfo); isSigningInProgress = false }
            catch { isSigningInProgress = false; throw error }
        }

        // Importing a certificate also unlocks older queued imports on their next launch.
        if let disk = NSDictionary(contentsOfFile: appInfo.bundlePath() + "/LCAppInfo.plist") as? [String: Any] {
            appInfo.info().setDictionary(disk)
            if disk["IOSVMNeedsExternalSigning"] as? Bool == true && IOSVMDeviceSigning.configured {
                isSigningInProgress = true
                defer { isSigningInProgress = false }
                try await IOSVMDeviceSigning.sign(appInfo)
            }
        }
        // Keep imports unavailable until the companion has finished transferring all signed code.
        let requestURL = LCPath.docPath.appendingPathComponent("iOSVM/SigningRequests/" + appInfo.relativeBundlePath + ".json")
        if let data = try? LCFridaLogBoundary.readData(requestURL, inside: LCPath.docPath, maximumBytes: 262144),
           let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let state = request["state"] as? String, state != "ready" {
            throw "lc.launch.signingIncomplete".loc
        }
        // A Mac companion may have completed signing since this model was created.
        if let disk = NSDictionary(contentsOfFile: appInfo.bundlePath() + "/LCAppInfo.plist") as? [String: Any] {
            if disk["IOSVMNeedsExternalSigning"] as? Bool == true {
                throw "lc.launch.waitingExternalSign".loc
            }
            appInfo.info().setDictionary(disk)
        }
        if uiContainers.isEmpty {
            let newName = NSUUID().uuidString
            let newContainer = LCContainer(folderName: newName, name: newName, isShared: uiIsShared)
            uiContainers.append(newContainer)
            if uiSelectedContainer == nil {
                uiSelectedContainer = newContainer;
            }
            appInfo.containers = uiContainers;
            newContainer.makeLCContainerInfoPlist(appIdentifier: appInfo.bundleIdentifier()!, keychainGroupId: Int.random(in: 0..<SharedModel.keychainAccessGroupCount))
            if let writeError = newContainer.lastPlistWriteError {
                // Roll back the registration so the next launch can retry from
                // a clean state instead of being blocked by a half-created container.
                uiContainers.removeAll { $0.folderName == newName }
                if uiSelectedContainer?.folderName == newName { uiSelectedContainer = nil }
                appInfo.containers = uiContainers
                throw "lc.launch.containerCreateFailed %@".localizeWithFormat(writeError.localizedDescription)
            }
            appInfo.dataUUID = newName
            uiDefaultDataFolder = newName
        }
        if let containerFolderName {
            uiSelectedContainer = uiContainers.first { $0.folderName == containerFolderName } ?? uiSelectedContainer
        }
        let currentDataFolder = containerFolderName ?? uiSelectedContainer?.folderName
        
        let classicMode = appInfo.defaultClassicMode
        let wantsWindow = multitask ?? shouldLaunchInMultitaskMode
        if wantsWindow && classicMode != 0 {
            throw "lc.launch.compatNoWindow".loc
        }
        let multitask = wantsWindow && classicMode == 0
        if multitask && LCUtils.liveProcessBundleIdentifier() == nil {
            throw "lc.launch.missingLiveProcess".loc
        }
        
        if MultitaskManager.isMultitasking() || multitask,
           let currentDataFolder {
            if await bringExistingMultitaskWindowIfNeeded(dataUUID: currentDataFolder, urlScheme: urlStr) {
                return
            }
            
        }
        
        // Refresh only managed startup copies, preserving each script as a separate Gum context.
        if let folder = LCFridaSetup.folder(for: appInfo) {
            // The bundled inspector is versioned with the host. Refresh its library
            // source before snapshotting so an app update cannot keep running an old
            // automatic-auth implementation from a previous selection.
            if try LCFridaScriptStore.selection(folder: folder).scripts.contains(LCFridaKeychainInspector.scriptID) {
                _ = try LCFridaKeychainInspector.installScript()
            }
            try LCFridaScriptStore.refreshBeforeLaunch(folder: folder, owner: appInfo.relativeBundlePath)
        }

        // this is rerouted to bringing app to front, so not needed here?
//        if(MultitaskManager.isUsing(container: uiSelectedContainer!.folderName)) {
//            throw "lc.container.inUse".loc + "\n MultiTask"
//        }
        
        // if the selected container is in use (either other lc or multitask), open the host lc associated with it
        if
            let fn = uiSelectedContainer?.folderName,
            var runningLC = LCSharedUtils.getContainerUsingLCScheme(withFolderName: fn)
        {
            runningLC = (runningLC as NSString).deletingPathExtension
            
            var openURLComp = URLComponents()
            openURLComp.scheme = runningLC
            if let urlStr {
                openURLComp.host = "open-url"
                openURLComp.queryItems = [
                    URLQueryItem(name: "url", value: Data(urlStr.utf8).base64EncodedString())
                ]
            }
            if await UIApplication.shared.canOpenURL(openURLComp.url!) {
                await UIApplication.shared.open(openURLComp.url!)
                return
            }
        }
        
        // find a free lc to run non-multitasking shared app. If none, ask user if they want to terminate all multitasking apps
        if MultitaskManager.isMultitasking() && !multitask {
            if self.uiIsShared {
                var freeScheme: String? = nil
                LCUtils.forEachInstalledLC(isFree: true) { scheme, shouldBreak in
                    freeScheme = scheme
                    shouldBreak = true
                }
                if let freeScheme {
                    LCUtils.appGroupUserDefault.set(freeScheme, forKey: "LCLaunchExtensionScheme")
                    LCUtils.appGroupUserDefault.set(self.appInfo.relativeBundlePath, forKey: "LCLaunchExtensionBundleID")
                    LCUtils.appGroupUserDefault.set(uiSelectedContainer?.folderName, forKey: "LCLaunchExtensionContainerName")
                    if let urlStr {
                        LCUtils.appGroupUserDefault.set(urlStr, forKey: "LCLaunchExtensionLaunchURL")
                    }
                    LCUtils.appGroupUserDefault.set(Date.now, forKey: "LCLaunchExtensionLaunchDate")
                    var launchURLComp = URLComponents()
                    launchURLComp.scheme = freeScheme
                    launchURLComp.host = "livecontainer-launch"
                    var queryItems: [URLQueryItem] = []
                    if let bundlePath = self.appInfo.relativeBundlePath {
                        queryItems.append(URLQueryItem(name: "bundle-name", value: bundlePath))
                    }
                    if let folderName = uiSelectedContainer?.folderName {
                        queryItems.append(URLQueryItem(name: "container-folder-name", value: folderName))
                    }
                    
                    launchURLComp.queryItems = queryItems
                    
                    if let url = launchURLComp.url {
                        await UIApplication.shared.open(url)
                    } else {
                        throw "Unable to build URL from launchURLComp???"
                    }
                    return
                }
            }
            
            guard let ans = await delegate?.showRunWhenMultitaskAlert(), ans else {
                return
            }
        }
        
        await MainActor.run {
            isOperationBusy = true
        }
        defer {
            Task { await MainActor.run {
                isOperationBusy = false
            }}
        }
        try await signApp(force: false)
        
        if let bundleIdOverride {
            UserDefaults.standard.set(bundleIdOverride, forKey: "selected")
        } else {
            UserDefaults.standard.set(self.appInfo.relativeBundlePath, forKey: "selected")
        }
        if let urlStr {
            UserDefaults.standard.setValue(urlStr, forKey: "launchAppUrlScheme")
        }
        UserDefaults.standard.set(uiSelectedContainer?.folderName, forKey: "selectedContainer")
        
        var jitNeeded = appInfo.isJITNeeded || appInfo.is32bit
        if let forceJIT {
            jitNeeded = forceJIT
        }
#if targetEnvironment(simulator)
        jitNeeded = false
#endif
        if jitNeeded {
            if multitask, #available(iOS 17.4, *) {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    LCUtils.launchMultitaskGuestApp(appInfo.displayName()) { pidNumber, error in
                        if let error {
                            continuation.resume(throwing: error)
                            return
                        }
                        guard let pidNumber = pidNumber else {
                            continuation.resume(throwing: "Failed to obtain PID from LiveProcess")
                            return
                        }
                        Task {
                            if let scriptData = self.jitLaunchScriptJs, !scriptData.isEmpty {
                                await self.delegate?.jitLaunch(withPID: pidNumber.intValue, withScript: scriptData, appName: self.appInfo.displayName())
                            } else {
                                await self.delegate?.jitLaunch(withPID: pidNumber.intValue, withScript: nil, appName: self.appInfo.displayName())
                            }
                            continuation.resume()
                        }
                    }
                }
            } else {
                // Non-multitask JIT flow remains unchanged
                if let scriptData = jitLaunchScriptJs, !scriptData.isEmpty {
                    await delegate?.jitLaunch(withScript: scriptData, appName: self.appInfo.displayName(), classicMode: classicMode)
                } else {
                    await delegate?.jitLaunch(appName: self.appInfo.displayName(), classicMode: classicMode)
                }
            }
        } else if multitask, #available(iOS 16.0, *) {
            try await LCUtils.launchMultitaskGuestApp(appInfo.displayName())
        } else {
            if #available(iOS 26.0, *), FileManager.default.fileExists(atPath: "\(appInfo.bundlePath()!)/Frameworks/MetalANGLE.framework/MetalANGLE") {
                let fileContents = "\(appInfo.bundlePath()!)/Frameworks/MetalANGLE.framework/MetalANGLE".data(using: .utf8)
                let fileURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("preloadLibraries.txt")
                try fileContents?.write(to: fileURL)
            }
            LCSharedUtils.launchToGuestApp(withClassicMode: classicMode)
        }
        
        // Record the launch time
        appInfo.lastLaunched = Date()

        await MainActor.run {
            isOperationBusy = false
        }
    }
    
    func forceResign() async throws {
        if isAppRunning {
            return
        }
        isOperationBusy = true
        defer {
            Task{ await MainActor.run {
                self.isOperationBusy = false
            }}

        }
        try await signApp(force: true)
    }
    
    func signApp(force: Bool = false) async throws {
        var signError : String? = nil
        var signSuccess = false
        defer {
            Task{ await MainActor.run {
                self.isSigningInProgress = false
            }}
        }
        
        await withUnsafeContinuation({ c in
            appInfo.patchExecAndSignIfNeed(completionHandler: { success, error in
                signError = error;
                signSuccess = success;
                c.resume()
            }, progressHandler: { signProgress in
                guard let signProgress else {
                    return
                }
                self.isSigningInProgress = true
                self.observer = signProgress.observe(\.fractionCompleted) { p, v in
                    DispatchQueue.main.async {
                        self.signProgress = signProgress.fractionCompleted
                    }
                }
            }, forceSign: force)
        })
        if let signError {
            if !signSuccess {
                throw signError.loc
            }
        }
        
        // sign its tweak
        guard let tweakFolder = appInfo.tweakFolder else {
            return
        }
        
        let tweakFolderUrl : URL
        if(appInfo.isShared) {
            tweakFolderUrl = LCPath.lcGroupTweakPath.appendingPathComponent(tweakFolder)
        } else {
            tweakFolderUrl = LCPath.tweakPath.appendingPathComponent(tweakFolder)
        }
        try await LCUtils.signTweaks(tweakFolderUrl: tweakFolderUrl, force: force) { p in
            Task{ await MainActor.run {
                self.isSigningInProgress = true
            }}
        }
        
        // sign global tweak
        try await LCUtils.signTweaks(tweakFolderUrl: LCPath.tweakPath, force: force) { p in
            Task{ await MainActor.run {
                self.isSigningInProgress = true
            }}
        }
    }

    func setLocked(newLockState: Bool) async {
        // if locked state in appinfo already match with the new state, we just the change
        if appInfo.isLocked == newLockState {
            return
        }
        
        if newLockState {
            appInfo.isLocked = true
        } else {
            // authenticate before cancelling locked state
            do {
                let result = try await LCUtils.authenticateUser()
                if !result {
                    uiIsLocked = true
                    return
                }
            } catch {
                uiIsLocked = true
                return
            }
            
            // auth pass, we need to cancel app's lock and hidden state
            appInfo.isLocked = false
            if appInfo.isHidden {
                await toggleHidden()
            }
        }
    }
    
    func toggleHidden() async {
        delegate?.closeNavigationView()
        if appInfo.isHidden {
            appInfo.isHidden = false
            uiIsHidden = false
        } else {
            appInfo.isHidden = true
            uiIsHidden = true
        }
        delegate?.changeAppVisibility(app: self)
    }
    
    func loadSupportedLanguages() throws {
        let fm = FileManager.default
        if supportedLanguages != nil {
            return
        }
        supportedLanguages = []
        let fileURLs = try fm.contentsOfDirectory(at: URL(fileURLWithPath: appInfo.bundlePath()!) , includingPropertiesForKeys: nil)
        for fileURL in fileURLs {
            let attributes = try fm.attributesOfItem(atPath: fileURL.path)
            let fileType = attributes[.type] as? FileAttributeType
            if(fileType == .typeDirectory && fileURL.lastPathComponent.hasSuffix(".lproj")) {
                supportedLanguages?.append(fileURL.deletingPathExtension().lastPathComponent)
            }
        }
        
    }
    
    private func bringExistingMultitaskWindowIfNeeded(dataUUID: String, urlScheme: String?) async -> Bool {
        guard #available(iOS 16.0, *) else { return false }
        return await MainActor.run {
            guard MultitaskManager.isUsing(container: dataUUID) else { return false }
            if let urlScheme {
                UserDefaults.standard.setValue(urlScheme, forKey: "launchAppUrlScheme")
            }
            var found = false
            if #available(iOS 16.1, *) {
                found = MultitaskWindowManager.openExistingAppWindow(dataUUID: dataUUID)
            }
            if !found {
                found = MultitaskDockManager.shared.bringMultitaskViewToFront(uuid: dataUUID)
            }
            if let urlScheme, !found  {
                UserDefaults.standard.removeObject(forKey: "launchAppUrlScheme")
            }
            return found
        }
    }
}
