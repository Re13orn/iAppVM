//
//  ContentView.swift
//  LiveContainerSwiftUI
//
//  Created by s s on 2024/8/21.
//

import Combine
import SwiftUI
import UniformTypeIdentifiers

class SearchContext: ObservableObject {
    @Published var query: String = ""
    @Published var debouncedQuery: String = ""
    @Published var isTyping: Bool = false

    private var cancellables = Set<AnyCancellable>()

    init() {
        $query
            .debounce(for: .seconds(0.2), scheduler: DispatchQueue.main)
            .sink { [weak self] value in
                self?.isTyping = true
                self?.debouncedQuery = value
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    self?.isTyping = false
                }
            }
            .store(in: &cancellables)
    }
}

struct AppReplaceOption : Hashable {
    var isReplace: Bool
    var nameOfFolderToInstall: String
    var appToReplace: LCAppModel?
}

struct LCAppListView : View, LCAppBannerDelegate, LCAppModelDelegate {
    @State var didAppear = false
    // ipa choosing stuff
    @State var choosingIPA = false
    @AppStorage("IOSVMAutoFrida", store: LCUtils.appGroupUserDefault) private var autoFrida = true
    @State var errorShow = false
    @State var errorInfo = ""
    
    // ipa installing stuff
    @State var installprogressVisible = false
    @State var installProgressPercentage : Float = 0.0
    @State var installObserver : NSKeyValueObservation?
    
    @State var installOptions: [AppReplaceOption]
    @StateObject var installReplaceAlert = AlertHelper<AppReplaceOption>()
    
    @State var webViewOpened = false
    @State var webViewURL : URL = URL(string: "about:blank")!
    @StateObject private var webViewUrlInput = InputHelper()
    
    @EnvironmentObject var downloadHelper: DownloadHelper
    @StateObject private var installUrlInput = InputHelper()
    
    @State private var jitLog = ""
    @StateObject private var jitAlert = YesNoHelper()
    
    @StateObject private var runWhenMultitaskAlert = YesNoHelper()
    
    @StateObject private var generatedIconStyleSelector = AlertHelper<GeneratedIconStyle>()
    
    @State var safariViewOpened = false
    @State var safariViewURL = URL(string: "https://google.com")!
    
    @State private var navigateTo : AnyView?
    @State private var isNavigationActive = false
    
    @State private var helpPresent = false
    
    @State private var customSortViewPresent = false
    
    @EnvironmentObject private var sharedModel : SharedModel
    @EnvironmentObject private var sharedAppSortManager : LCAppSortManager
    
    @AppStorage("LCMultitaskMode", store: LCUtils.appGroupUserDefault) var multitaskMode: MultitaskMode = .virtualWindow
    @AppStorage("darkModeIcon", store: LCUtils.appGroupUserDefault) private var darkModeIcon = false
    
    @State private var isViewAppeared = false
    
    @ObservedObject var searchContext: SearchContext = SearchContext()
    var sortedApps: [LCAppModel] {
        return sharedAppSortManager.sortedApps
    }
    
    var sortedHiddenApps: [LCAppModel] {
        return sharedAppSortManager.sortedHiddenApps
    }
    
    var filteredApps: [LCAppModel] {
        let apps = sortedApps
        if searchContext.debouncedQuery.isEmpty {
            return apps
        } else {
            return apps.filter { app in
                app.appInfo.displayName().localizedCaseInsensitiveContains(searchContext.debouncedQuery) ||
                app.appInfo.bundleIdentifier()!.localizedCaseInsensitiveContains(searchContext.debouncedQuery)
            }
        }
    }
    
    var filteredHiddenApps: [LCAppModel] {
        let apps = sortedHiddenApps
        if searchContext.debouncedQuery.isEmpty || !sharedModel.isHiddenAppUnlocked {
            return apps
        } else {
            return apps.filter { app in
                app.appInfo.displayName().localizedCaseInsensitiveContains(searchContext.debouncedQuery) ||
                app.appInfo.bundleIdentifier()!.localizedCaseInsensitiveContains(searchContext.debouncedQuery)
            }
        }
    }
    
    init() {
        _installOptions = State(initialValue: [])
    }
    
    var body: some View {
        NavigationView {
            ScrollView {
                NavigationLink(
                    destination: navigateTo,
                    isActive: $isNavigationActive,
                    label: {
                        EmptyView()
                })
                .hidden()
                
                LazyVStack(spacing: 12) {
                    ForEach(filteredApps, id: \.self) { app in
                        LCAppBanner(appModel: app, delegate: self)
                    }
                    .transition(.scale)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 16)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
                .animation(searchContext.isTyping ? nil : .easeInOut, value: filteredApps)

                VStack {
                    if LCUtils.appGroupUserDefault.bool(forKey: "LCStrictHiding") {
                        if sharedModel.isHiddenAppUnlocked {
                            LazyVStack {
                                HStack {
                                    Text("lc.appList.hiddenApps".loc)
                                        .font(.system(.title2).bold())
                                    Spacer()
                                }
                                
                                ForEach(filteredHiddenApps, id: \.self) { app in
                                    LCAppBanner(appModel: app, delegate: self)
                                }
                                .transition(.scale)
                                
                            }
                            .padding()
                            .transition(.opacity)
                            .animation(searchContext.isTyping ? nil : .easeInOut, value: filteredHiddenApps)
                            
                            if sharedModel.hiddenApps.count == 0 {
                                Text("lc.appList.hideAppTip".loc)
                                    .foregroundStyle(.gray)
                            }
                        }
                    } else if sharedModel.hiddenApps.count > 0 {
                        LazyVStack {
                            HStack {
                                Text("lc.appList.hiddenApps".loc)
                                    .font(.system(.title2).bold())
                                Spacer()
                            }
                            ForEach(filteredHiddenApps, id: \.self) { app in
                                if sharedModel.isHiddenAppUnlocked {
                                    LCAppBanner(appModel: app, delegate: self)
                                } else {
                                    LCAppSkeletonBanner()
                                }
                            }
                            .animation(.easeInOut, value: sharedModel.isHiddenAppUnlocked)
                            .onTapGesture {
                                Task { await authenticateUser() }
                            }
                        }
                        .padding()
                        .animation(searchContext.isTyping ? nil : .easeInOut, value: filteredHiddenApps)
                    }

                    let appCount = sharedModel.isHiddenAppUnlocked ? filteredApps.count + filteredHiddenApps.count : filteredApps.count
                    if appCount == 0 {
                        LCToolEmptyState(title: searchContext.debouncedQuery.isEmpty ? "lc.appList.empty.addTestApp".loc : "lc.appList.empty.noMatch".loc, message: searchContext.debouncedQuery.isEmpty ? "lc.appList.empty.message".loc : "lc.appList.empty.searchHint".loc, symbol: searchContext.debouncedQuery.isEmpty ? "square.and.arrow.down" : "magnifyingglass")
                    }
                    Text("lc.appList.appCounter %lld".localizeWithFormat(appCount))
                        .font(.footnote)
                        .padding(.horizontal)
                        .foregroundStyle(.secondary)
                        .animation(searchContext.isTyping ? nil : .easeInOut, value: appCount)
                        .onTapGesture(count: 3) {
                            Task { await authenticateUser() }
                        }
                }.animation(searchContext.isTyping ? nil : .easeInOut, value: LCUtils.appGroupUserDefault.bool(forKey: "LCStrictHiding"))

                if sharedModel.multiLCStatus == 2 {
                    Text("lc.appList.manageInPrimaryTip".loc).foregroundStyle(.gray).padding()
                }

            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationBarProgressBar(show:$installprogressVisible, progress: $installProgressPercentage)
            .coordinateSpace(name: "scroll")
            .onAppear {
                if !didAppear {
                    onAppear()
                }
            }
            
            .navigationTitle("lc.appList.myApps".loc)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if sharedModel.multiLCStatus != 2 {
                        if !installprogressVisible {
                            Menu {
                                
                                Toggle("lc.appList.autoFrida".loc, isOn: $autoFrida)
                                Divider()
                                Button("lc.appList.installFromIpa".loc, systemImage: "doc.badge.plus", action: {
                                    choosingIPA = true
                                })
                                Button("lc.appList.installFromUrl".loc, systemImage: "link.badge.plus", action: {
                                    Task{ await startInstallFromUrl() }
                                })
                            } label: {
                                Label("lc.appList.add".loc, systemImage: "plus")
                            }
                            
                        } else {
                            ProgressView().progressViewStyle(.circular).padding(.horizontal, 8)
                        }
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    if(UserDefaults.sideStoreExist()) {
                        Button {
                            LCUtils.openSideStore(delegate: self)
                        } label: {
                            IconImageView(icon: BuiltInSideStoreAppInfo.shared.iconIsDarkIcon(darkModeIcon))
                                .frame(width: UIFont.preferredFont(forTextStyle: .body).lineHeight, height: UIFont.preferredFont(forTextStyle: .body).lineHeight)

                        }
                    } else {
                        Button("lc.appList.help".loc, systemImage: "questionmark") {
                            helpPresent = true
                        }
                    }
                    

                }
                
                ToolbarItem(placement: .topBarTrailing) {
                    Button("lc.appList.openLink".loc, systemImage: "link", action: {
                        Task { await onOpenWebViewTapped() }
                    })
                }
                
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("lc.appList.sortBy".loc, selection: $sharedAppSortManager.appSortType) {
                            ForEach(AppSortType.allCases, id: \.self) { sortType in
                                Label(sortType.displayName, systemImage: sortType.systemImage)
                                    .tag(sortType)
                            }
                        }
                        .onChange(of: sharedAppSortManager.appSortType) { newValue in
                            if sharedAppSortManager.appSortType == .custom {
                                customSortViewPresent = true
                            }
                        }
                        if sharedAppSortManager.appSortType == .custom {
                            Divider()
                            
                            Button {
                                customSortViewPresent = true
                            } label: {
                                Label("lc.appList.sort.customManage".loc, systemImage: "slider.horizontal.3")
                            }
                        }
                    } label: {
                        Label("lc.appList.sortBy".loc, systemImage: "line.3.horizontal.decrease.circle")
                    }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .alert("lc.common.error".loc, isPresented: $errorShow){
            Button("lc.common.ok".loc, action: {
            })
            Button("lc.common.copy".loc, action: {
                copyError()
            })
        } message: {
            Text(errorInfo)
        }
        .betterFileImporter(isPresented: $choosingIPA, types: [.ipa, .tipa], multiple: false, callback: { fileUrls in
            Task { await startInstallApp(fileUrls[0]) }
        }, onDismiss: {
            choosingIPA = false
        })
        .alert("lc.appList.installation".loc, isPresented: $installReplaceAlert.show) {
            ForEach(installOptions, id: \.self) { installOption in
                Button(role: installOption.isReplace ? .destructive : nil, action: {
                    installReplaceAlert.close(result: installOption)
                }, label: {
                    Text(installOption.isReplace ? installOption.nameOfFolderToInstall : "lc.appList.installAsNew".loc)
                })
            
            }
            Button(role: .cancel, action: {
                installReplaceAlert.close(result: nil)
            }, label: {
                Text("lc.appList.abortInstallation".loc)
            })
        } message: {
            Text("lc.appList.installReplaceTip".loc)
        }
        .alert("lc.webView.runApp".loc, isPresented: $runWhenMultitaskAlert.show) {
            Button(role: .destructive) {
                runWhenMultitaskAlert.close(result: true)
            } label: {
                Text("lc.common.continue".loc)
            }
            Button("lc.common.cancel".loc, role: .cancel) {
                runWhenMultitaskAlert.close(result: false)
            }
        } message: {
            Text("lc.appBanner.confirmRunWhenMultitasking".loc)
        }
        .alert("lc.appList.generatedIconStyleSelector.title".loc, isPresented:$generatedIconStyleSelector.show) {
            Button {
                generatedIconStyleSelector.close(result: .Light)
            } label: {
                Text("lc.appList.generatedIconStyleSelector.light".loc)
            }
            Button {
                generatedIconStyleSelector.close(result: .Dark)
            } label: {
                Text("lc.appList.generatedIconStyleSelector.dark".loc)
            }
            Button {
                generatedIconStyleSelector.close(result: .Original)
            } label: {
                Text("lc.appList.generatedIconStyleSelector.original".loc)
            }
            Button("lc.common.cancel".loc, role: .cancel) {
                generatedIconStyleSelector.close(result: nil)
            }
        }
        .textFieldAlert(
            isPresented: $webViewUrlInput.show,
            title:  "lc.appList.enterUrlTip".loc,
            text: $webViewUrlInput.initVal,
            placeholder: "scheme://",
            action: { newText in
                webViewUrlInput.close(result: newText)
            },
            actionCancel: {_ in
                webViewUrlInput.close(result: nil)
            }
        )
        .textFieldAlert(
            isPresented: $installUrlInput.show,
            title:  "lc.appList.installUrlInputTip".loc,
            text: $installUrlInput.initVal,
            placeholder: "https://",
            action: { newText in
                installUrlInput.close(result: newText)
            },
            actionCancel: {_ in
                installUrlInput.close(result: nil)
            }
        )
        .sheet(isPresented: $jitAlert.show, onDismiss: {
            jitAlert.close(result: false)
        }) {
            JITEnablingModal
        }
        .onChange(of: jitAlert.show) { newValue in
            sharedModel.isJITModalOpen = newValue
        }
        .fullScreenCover(isPresented: $webViewOpened) {
            LCWebView(url: $webViewURL, isPresent: $webViewOpened, itmsServicesHandler: { urlStr in
                await installFromPlist(urlStr: urlStr)
            })
        }
        .fullScreenCover(isPresented: $safariViewOpened) {
            SafariView(url: $safariViewURL)
        }
        .sheet(isPresented: $helpPresent) {
            LCHelpView(isPresent: $helpPresent)
        }
        .sheet(isPresented: $customSortViewPresent) {
            LCCustomSortView()
        }
        .onAppear() {
            if !isViewAppeared {
                if let webpageUrlStr = UserDefaults.standard.string(forKey: "webPageToOpen") {
                    Task { await openWebView(urlString: webpageUrlStr) }
                    UserDefaults.standard.set(nil, forKey: "webPageToOpen")
                }
                
                guard sharedModel.selectedTab == .apps, let link = sharedModel.deepLink else { return }
                sharedModel.deepLink = nil
                handleURL(url: link)
                isViewAppeared = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("IOSVMWindowFailed"))) { notification in
            errorInfo = notification.userInfo?["error"] as? String ?? "lc.appList.windowLaunchFailed".loc
            errorShow = true
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("IOSVMOpenAppTool"))) { notification in
            guard let relative = notification.userInfo?["bundle"] as? String,
                  let tool = notification.userInfo?["tool"] as? String,
                  let app = (sharedModel.apps + sharedModel.hiddenApps).first(where: { $0.appInfo.relativeBundlePath == relative }) else { return }
            if let folder = notification.userInfo?["container"] as? String,
               let container = app.uiContainers.first(where: { $0.folderName == folder }) {
                app.uiSelectedContainer = container
            }
            sharedModel.selectedTab = .apps
            if tool == "sandbox" { openNavigationView(view: AnyView(LCAppSandboxView(model: app))) }
            else if tool == "frida" { openNavigationView(view: AnyView(LCFridaView(model: app))) }
            else if tool == "process" { openNavigationView(view: AnyView(LCGuestSessionView(model: app))) }
        }
        .onChange(of: sharedModel.deepLink) { link in
            guard sharedModel.selectedTab == .apps, let link else { return }
            sharedModel.deepLink = nil
            handleURL(url: link)
        }
        .onDrop(of: [.url], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, error in
                guard let url else { return }
                Task {
                    guard let urlToOpen = await webViewUrlInput.open(initVal: url.absoluteString), urlToOpen != "" else {
                        return
                    }
                    await openWebView(urlString: urlToOpen)
                }
            }
            return true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.InstallAppNotification)) { obj in
            if let obj2 = obj.object as? [String: Any], let installUrl = obj2["url"] as? URL {
                Task { await installFromUrl(urlStr: installUrl.absoluteString) }
            }
        }
        .searchable(text: $searchContext.query)

    }
    
    var JITEnablingModal : some View {
        NavigationView {
            ScrollViewReader { proxy in
                ScrollView {
                    Text("lc.appBanner.waitForJitMsg".loc)
                        .padding(.vertical)
                        .id(0)
                    
                    HStack {
                        Text(jitLog)
                            .font(.system(size: 12).monospaced())
                            .fixedSize(horizontal: false, vertical: false)
                            .textSelection(.enabled)
                        Spacer()
                    }
                    
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal)
                .onAppear {
                    proxy.scrollTo(0)
                }
            }
            .navigationTitle("lc.appBanner.waitForJitTitle".loc)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("lc.common.cancel".loc, role: .cancel) {
                        jitAlert.close(result: false)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        jitAlert.close(result: true)
                    } label: {
                        Text("lc.appBanner.jitLaunchNow".loc)
                    }
                }
            }
        }
    }
    
    func onOpenWebViewTapped() async {
        guard let urlToOpen = await webViewUrlInput.open(), urlToOpen != "" else {
            return
        }
        await openWebView(urlString: urlToOpen)
        
    }
    func onAppear() {
        for app in sharedModel.apps {
            app.delegate = self
        }
        for app in sharedModel.hiddenApps {
            app.delegate = self
        }
        didAppear = true
        runRequestedTestWindow()
        #if IOSVM_TESTING
        runIOSVMTestingRoute()
        #endif
    }
    
    
    func runRequestedTestWindow() {
        guard let relative = UserDefaults.standard.string(forKey: "iosvmWindowApp") else { return }
        let container = UserDefaults.standard.string(forKey: "iosvmWindowContainer") ?? ""
        Task { @MainActor in
            do {
                var app: LCAppModel?
                for _ in 0..<50 where app == nil {
                    app = (sharedModel.apps + sharedModel.hiddenApps)
                        .first(where: { $0.appInfo.relativeBundlePath == relative })
                    if app == nil { try? await Task.sleep(nanoseconds: 100_000_000) }
                }
                guard let app else {
                    throw "lc.appList.windowAppNotFound".loc
                }
                if !container.isEmpty && !app.uiContainers.contains(where: { $0.folderName == container }) {
                    throw "lc.appList.windowContainerMismatch".loc
                }
                if app.appInfo.isLocked && !sharedModel.isHiddenAppUnlocked {
                    guard try await LCUtils.authenticateUser() else { throw "lc.appList.authFailed".loc }
                }
                try await app.runApp(multitask: true, containerFolderName: container.isEmpty ? nil : container)
            } catch let error as LCLaunchPreflight.Failure {
                IOSVMWindowLaunchReporter.record(pid:nil,error:error as NSError,bundle:relative,container:container)
                if let app=sharedModel.apps.first(where:{$0.appInfo.relativeBundlePath==relative}) { openNavigationView(view:AnyView(LCLaunchPreflightView(model:app))) }
            } catch {
                IOSVMWindowLaunchReporter.record(pid: nil, error: error as NSError, bundle: relative, container: container)
                errorInfo = error.localizedDescription
                errorShow = true
            }
        }
    }

    func openWebView(urlString: String) async {
        guard var urlToOpen = URLComponents(string: urlString), urlToOpen.url != nil else {
            errorInfo = "lc.appList.urlInvalidError".loc
            errorShow = true
            return
        }
        if urlToOpen.scheme == nil || urlToOpen.scheme! == "" {
            urlToOpen.scheme = "https"
        }
        
        if urlToOpen.scheme?.lowercased() == "itms-services" {
            await installFromPlist(urlStr: urlString)
            return
        }
        
        if urlToOpen.scheme != "https" && urlToOpen.scheme != "http" {
            var appToLaunch : LCAppModel? = nil
            var appListsToConsider = [sharedModel.apps]
            if sharedModel.isHiddenAppUnlocked || !LCUtils.appGroupUserDefault.bool(forKey: "LCStrictHiding") {
                appListsToConsider.append(sharedModel.hiddenApps)
            }
            appLoop:
            for appList in appListsToConsider {
                for app in appList {
                    if let schemes = app.appInfo.urlSchemes() {
                        for scheme in schemes {
                            if let scheme = scheme as? String, scheme == urlToOpen.scheme {
                                appToLaunch = app
                                break appLoop
                            }
                        }
                    }
                }
            }


            guard let appToLaunch = appToLaunch else {
                errorInfo = "lc.appList.schemeCannotOpenError %@".localizeWithFormat(urlToOpen.scheme!)
                errorShow = true
                return
            }
            
            if appToLaunch.appInfo.isLocked && !sharedModel.isHiddenAppUnlocked {
                do {
                    if !(try await LCUtils.authenticateUser()) {
                        return
                    }
                } catch {
                    errorInfo = error.localizedDescription
                    errorShow = true
                    return
                }
            }
            
            do {
                try await appToLaunch.runApp(urlStr: urlToOpen.url!.absoluteString)
            } catch is LCLaunchPreflight.Failure {
                openNavigationView(view:AnyView(LCLaunchPreflightView(model:appToLaunch)))
            } catch {
                errorInfo = error.localizedDescription
                errorShow = true
            }
            
            return
        }
        webViewURL = urlToOpen.url!
        if webViewOpened {
            webViewOpened = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: {
                webViewOpened = true
            })
        } else {
            webViewOpened = true
        }
    }


    
    func startInstallApp(_ fileUrl:URL) async {
        do {
            self.installprogressVisible = true
            try await installIpaFile(fileUrl)
            // A desktop-imported source can be read-only; cleanup must not turn a successful install into an error.
            LCManagedDirectory.cleanup(fileUrl)
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
            self.installprogressVisible = false
        }
    }
    
    nonisolated func decompress(_ path: String, _ destination: String ,_ progress: Progress) async -> Int32 {
        extract(path, destination, progress)
    }
    
    func installIpaFile(_ url:URL) async throws {
        let fm = FileManager()
        let enableFrida = autoFrida
        
        let installProgress = Progress.discreteProgress(totalUnitCount: 100)
        self.installProgressPercentage = 0.0
        self.installObserver = installProgress.observe(\.fractionCompleted) { p, v in
            DispatchQueue.main.async {
                self.installProgressPercentage = Float(p.fractionCompleted)
            }
        }
        let decompressProgress = Progress.discreteProgress(totalUnitCount: 100)
        installProgress.addChild(decompressProgress, withPendingUnitCount: 80)
        let workspace = try LCManagedDirectory.temporaryWorkspace()
        defer { LCManagedDirectory.cleanup(workspace) }
        let payloadPath = workspace.appendingPathComponent("Payload")

        // Decompress into this import's workspace, independent of previous attempts.
        let decompressResult = await decompress(url.path, workspace.path, decompressProgress)
        if decompressResult != 0 {
            NSLog("[iOSVM] install decompress failed rc=%d for %@", decompressResult, url.path)
            throw "lc.appList.urlFileIsNotIpaError".loc
        }

        let payloadContents = try fm.contentsOfDirectory(atPath: payloadPath.path)
        var appBundleName : String? = nil
        for fileName in payloadContents {
            if fileName.hasSuffix(".app") {
                appBundleName = fileName
                break
            }
        }
        guard let appBundleName = appBundleName else {
            NSLog("[iOSVM] install payload has no .app (contents: %@)", payloadContents.joined(separator: ", "))
            throw "lc.appList.bundleNotFondError".loc
        }

        let appFolderPath = payloadPath.appendingPathComponent(appBundleName)
        
        guard let newAppInfo = LCAppInfo(bundlePath: appFolderPath.path) else {
            NSLog("[iOSVM] install LCAppInfo init failed at %@", appFolderPath.path)
            throw "lc.appList.infoPlistCannotReadError".loc
        }

        var appRelativePath = "\(newAppInfo.bundleIdentifier()!.sanitizeNonACSII()).app"
        var outputFolder = LCPath.bundlePath.appendingPathComponent(appRelativePath)
        var appToReplace : LCAppModel? = nil
        // Folder exist! show alert for user to choose which bundle to replace
        var sameBundleIdApp = sharedModel.apps.filter { app in
            return app.appInfo.bundleIdentifier()! == newAppInfo.bundleIdentifier()
        }
        if sameBundleIdApp.count == 0 {
            sameBundleIdApp = sharedModel.hiddenApps.filter { app in
                return app.appInfo.bundleIdentifier()! == newAppInfo.bundleIdentifier()
            }
            
            // we found a hidden app, we need to authenticate before proceeding
            if sameBundleIdApp.count > 0 && !sharedModel.isHiddenAppUnlocked {
                do {
                    if !(try await LCUtils.authenticateUser()) {
                        self.installprogressVisible = false
                        return
                    }
                } catch {
                    errorInfo = error.localizedDescription
                    errorShow = true
                    self.installprogressVisible = false
                    return
                }
            }
            
        }
        
        if fm.fileExists(atPath: outputFolder.path) || sameBundleIdApp.count > 0 {
            appRelativePath = "\(newAppInfo.bundleIdentifier()!)_\(Int(CFAbsoluteTimeGetCurrent())).app"
            
            self.installOptions = [AppReplaceOption(isReplace: false, nameOfFolderToInstall: appRelativePath)]
            
            for app in sameBundleIdApp {
                self.installOptions.append(AppReplaceOption(isReplace: true, nameOfFolderToInstall: app.appInfo.relativeBundlePath, appToReplace: app))
            }

            guard let installOptionChosen = await installReplaceAlert.open() else {
                // user cancelled
                self.installprogressVisible = false
                return
            }
            
            if let appToReplace = installOptionChosen.appToReplace, appToReplace.uiIsShared {
                outputFolder = LCPath.lcGroupBundlePath.appendingPathComponent(installOptionChosen.nameOfFolderToInstall)
            } else {
                outputFolder = LCPath.bundlePath.appendingPathComponent(installOptionChosen.nameOfFolderToInstall)
            }
            appRelativePath = installOptionChosen.nameOfFolderToInstall
            appToReplace = installOptionChosen.appToReplace
            if installOptionChosen.isReplace {
                // Removing the bundle of a running guest would break its loaded
                // code and leave the registry thinking it is still alive.
                if let appToReplace, appToReplace.isAppRunning {
                    errorInfo = "lc.appList.appIsRunningErr".loc
                    errorShow = true
                    self.installprogressVisible = false
                    return
                }
                try fm.removeItem(at: outputFolder)
            }
        }
        // Move it!
        do {
            try fm.moveItem(at: appFolderPath, to: outputFolder)
        } catch {
            NSLog("[iOSVM] install moveItem failed %@ -> %@: %@", appFolderPath.path, outputFolder.path, error.localizedDescription)
            throw error
        }
        // If anything below fails before the app enters the list, remove the
        // moved bundle so half-finished imports don't silently occupy disk.
        func abandonMovedBundle() {
            try? fm.removeItem(at: outputFolder)
        }
        let finalNewApp = LCAppInfo(bundlePath: outputFolder.path)
        finalNewApp?.relativeBundlePath = appRelativePath
        
        guard let finalNewApp else {
            abandonMovedBundle()
            errorInfo = "lc.appList.appInfoInitError".loc
            errorShow = true
            self.installprogressVisible = false
            return
        }
        
        // Frida imports require the loader injected into the newly patched executable.
        if enableFrida { finalNewApp.dontInjectTweakLoader = false }
        // patch and sign it
        var signError : String? = nil
        var signSuccess = false
        await withUnsafeContinuation({ c in
            if appToReplace?.uiDontSign ?? false || LCUtils.appGroupUserDefault.bool(forKey: "LCDontSignApp") {
                finalNewApp.dontSign = true
            }
            finalNewApp.patchExecAndSignIfNeed(completionHandler: { success, error in
                signError = error
                signSuccess = success
                c.resume()
            }, progressHandler: { signProgress in
                installProgress.addChild(signProgress!, withPendingUnitCount: 20)
            }, forceSign: false)
        })
        
        // we leave it unsigned even if signing failed
        if let signError {
            NSLog("[iOSVM] install sign result success=%d error=%@", signSuccess, signError)
            if signSuccess {
                errorInfo = "\("lc.appList.signSuccessWithError".loc)\n\n\(signError)"
            } else {
                errorInfo = signError.loc
            }
            errorShow = true
        }
        
        if let appToReplace {
            // copy previous configration to new app
            finalNewApp.autoSaveDisabled = true
            finalNewApp.isLocked = appToReplace.appInfo.isLocked
            finalNewApp.isHidden = appToReplace.appInfo.isHidden
            finalNewApp.isJITNeeded = appToReplace.appInfo.isJITNeeded
            finalNewApp.isShared = appToReplace.appInfo.isShared
            finalNewApp.spoofSDKVersion = appToReplace.appInfo.spoofSDKVersion
            finalNewApp.doSymlinkInbox = appToReplace.appInfo.doSymlinkInbox
            finalNewApp.containerInfo = appToReplace.appInfo.containerInfo
            finalNewApp.tweakFolder = appToReplace.appInfo.tweakFolder
            finalNewApp.selectedLanguage = appToReplace.appInfo.selectedLanguage
            finalNewApp.dataUUID = appToReplace.appInfo.dataUUID
            finalNewApp.orientationLock = appToReplace.appInfo.orientationLock
            finalNewApp.dontInjectTweakLoader = enableFrida ? false : appToReplace.appInfo.dontInjectTweakLoader
            finalNewApp.hideLiveContainer = appToReplace.appInfo.hideLiveContainer
            finalNewApp.dontLoadTweakLoader = appToReplace.appInfo.dontLoadTweakLoader
            finalNewApp.doUseLCBundleId = appToReplace.appInfo.doUseLCBundleId
            finalNewApp.fixFilePickerNew = appToReplace.appInfo.fixFilePickerNew
            finalNewApp.fixLocalNotification = appToReplace.appInfo.fixLocalNotification
            finalNewApp.lastLaunched = appToReplace.appInfo.lastLaunched
            finalNewApp.jitLaunchScriptJs = appToReplace.appInfo.jitLaunchScriptJs
            finalNewApp.multitaskSpecified = appToReplace.appInfo.multitaskSpecified
            finalNewApp.classicMode = appToReplace.appInfo.classicMode
            finalNewApp.autoSaveDisabled = false
            finalNewApp.save()
        } else {
            // enable SDK version spoof by defalut
            finalNewApp.spoofSDKVersion = true
        }
        // Provision Gadget after preserving replacement settings, before exposing the App in the list.
        if enableFrida {
            do {
                try await LCFridaSetup.prepare(finalNewApp)
                if let name = finalNewApp.tweakFolder, !sharedModel.tweakFolderNames.contains(name) {
                    sharedModel.tweakFolderNames.append(name)
                }
            } catch {
                errorInfo = "lc.appList.importedFridaFailed %@".localizeWithFormat(error.localizedDescription)
                errorShow = true
            }
        }
        if !finalNewApp.is32bit {
            if IOSVMDeviceSigning.configured && !finalNewApp.isShared {
                do { try await IOSVMDeviceSigning.sign(finalNewApp) }
                catch {
                    errorInfo = "lc.appList.importedSignFailed %@".localizeWithFormat(error.localizedDescription)
                    errorShow = true
                }
            } else if !IOSVMDeviceSigning.configured {
                try LCFridaSetup.requestSigning(finalNewApp)
            }
        }
        finalNewApp.installationDate = Date.now
        
        await MainActor.run {
            if let appToReplace {
                let newAppModel = LCAppModel(appInfo: finalNewApp, delegate: self)
                
                if appToReplace.uiIsHidden {
                    sharedModel.hiddenApps.removeAll { $0 == appToReplace }
                    sharedModel.hiddenApps.append(newAppModel)
                } else {
                    sharedModel.apps.removeAll { $0 == appToReplace }
                    sharedModel.apps.append(newAppModel)
                }

            } else {
                let newAppModel = LCAppModel(appInfo: finalNewApp, delegate: self)
                sharedModel.apps.append(newAppModel)
                
                // add url schemes
                if let urlSchemes = finalNewApp.urlSchemes(), urlSchemes.count > 0 {
                    UserDefaults.lcShared().mutableArrayValue(forKey: "LCGuestURLSchemes")
                        .addObjects(from: urlSchemes as! [Any])
                }
            }

            self.installprogressVisible = false
        }
    }
    
    func startInstallFromUrl() async {
        guard let installUrlStr = await installUrlInput.open(), installUrlStr.count > 0 else {
            return
        }
        if let url = URL(string:installUrlStr), url.scheme?.lowercased() == "itms-services" {
            await installFromPlist(urlStr: installUrlStr)
            return
        }
        await installFromUrl(urlStr: installUrlStr)
    }
    
    func installFromPlist(urlStr: String) async {
        if self.installprogressVisible {
            return
        }
        
        if sharedModel.multiLCStatus == 2 {
            errorInfo = "lc.appList.manageInPrimaryTip".loc
            errorShow = true
            return
        }
        
        var plistUrlStr = urlStr.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if plistUrlStr.lowercased().hasPrefix("itms-services://") {
            if let urlComponents = URLComponents(string: plistUrlStr),
               let queryItems = urlComponents.queryItems,
               let urlParam = queryItems.first(where: { $0.name == "url" })?.value {
                plistUrlStr = urlParam
            } else {
                errorInfo = "lc.appList.plistInvalidError".loc
                errorShow = true
                return
            }
        }
        
        guard let plistUrl = URL(string: plistUrlStr) else {
            errorInfo = "lc.appList.urlInvalidError".loc
            errorShow = true
            return
        }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: plistUrl)
            
            guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                  let items = plist["items"] as? [[String: Any]],
                  let firstItem = items.first,
                  let assets = firstItem["assets"] as? [[String: Any]] else {
                errorInfo = "lc.appList.plistParseError".loc
                errorShow = true
                return
            }
            
            var ipaUrlStr: String?
            for asset in assets {
                if let kind = asset["kind"] as? String, kind == "software-package",
                   let url = asset["url"] as? String {
                    ipaUrlStr = url
                    break
                }
            }
            
            guard let ipaUrlStr else {
                errorInfo = "lc.appList.plistNoIpaError".loc
                errorShow = true
                return
            }
            
            await installFromUrl(urlStr: ipaUrlStr)
            
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
    }
    
    func installFromUrl(urlStr: String) async {
        // ignore any install request if we are installing another app
        if self.installprogressVisible {
            NSLog("[iOSVM] install ignored: another installation in progress")
            return
        }
        
        if sharedModel.multiLCStatus == 2 {
            errorInfo = "lc.appList.manageInPrimaryTip".loc
            errorShow = true
            return
        }
        
        guard var installUrl = URL(string: urlStr) else {
            NSLog("[iOSVM] install URL invalid: %@", urlStr)
            errorInfo = "lc.appList.urlInvalidError".loc
            errorShow = true
            return
        }
        
        self.installprogressVisible = true
        defer {
            self.installprogressVisible = false
        }
        
        if installUrl.isFileURL {
            // install from local, we directly call local install method
            let fileExtension = installUrl.pathExtension.lowercased()
            if fileExtension != "ipa" && fileExtension != "tipa" {
                NSLog("[iOSVM] install rejected: not an ipa: %@", urlStr)
                errorInfo = "lc.appList.urlFileIsNotIpaError".loc
                errorShow = true
                return
            }
            
            let fm = FileManager.default
            var didStartAccessing = false
            if !fm.isReadableFile(atPath: installUrl.path),
               let bookmarkData = LCUtils.appGroupUserDefault.data(forKey: "LCLaunchExtensionFileBookmark") {
                do {
                    var isStale = false
                    let resolvedURL = try URL(
                        resolvingBookmarkData: bookmarkData,
                        options: URL.BookmarkResolutionOptions(rawValue: 1 << 10),
                        relativeTo: nil,
                        bookmarkDataIsStale: &isStale
                    )
                    installUrl = resolvedURL
                    didStartAccessing = resolvedURL.startAccessingSecurityScopedResource()
                } catch {
                    errorInfo =  "Failed to resolve shared IPA bookmark: \(error.localizedDescription)"
                    errorShow = true
                    return
                }
            }

            if !fm.isReadableFile(atPath: installUrl.path) && !didStartAccessing {
                didStartAccessing = installUrl.startAccessingSecurityScopedResource()
            }

            if !fm.isReadableFile(atPath: installUrl.path) && !didStartAccessing {
                NSLog("[iOSVM] install ipa unreadable: %@", installUrl.path)
                errorInfo = "lc.appList.ipaAccessError".loc
                errorShow = true
                return
            }
            
            defer {
                if didStartAccessing {
                    installUrl.stopAccessingSecurityScopedResource()
                }
            }
            
            do {
                NSLog("[iOSVM] installing ipa from path: %@", installUrl.path)
                try await installIpaFile(installUrl)
                let inbox = LCPath.docPath.appendingPathComponent("Inbox")
                if installUrl.deletingLastPathComponent().standardizedFileURL == inbox.standardizedFileURL {
                    LCManagedDirectory.cleanup(installUrl)
                }
                NSLog("[iOSVM] install completed for %@", installUrl.path)
            } catch {
                NSLog("[iOSVM] install threw: %@", error.localizedDescription)
                errorInfo = error.localizedDescription
                errorShow = true
            }

            return
        }
        
        do {
            let workspace = try LCManagedDirectory.temporaryWorkspace()
            defer { LCManagedDirectory.cleanup(workspace) }
            let destinationURL = workspace.appendingPathComponent("Download.ipa")
            
            try await downloadHelper.download(url: installUrl, to: destinationURL)
            if downloadHelper.cancelled {
                return
            }
            try await installIpaFile(destinationURL)
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
        
    }
    
    func removeApp(app: LCAppModel) {
        DispatchQueue.main.async {
            sharedModel.apps.removeAll { now in
                return app == now
            }
            sharedModel.hiddenApps.removeAll { now in
                return app == now
            }
            
        }
    }
    
    func changeAppVisibility(app: LCAppModel) {
        DispatchQueue.main.async {
            if app.appInfo.isHidden {
                sharedModel.apps.removeAll { now in
                    return app == now
                }
                if !sharedModel.hiddenApps.contains(app) {
                    sharedModel.hiddenApps.append(app)
                }
                UserDefaults.lcShared().mutableArrayValue(forKey: "LCGuestURLSchemes")
                    .removeObjects(in: app.appInfo.urlSchemes() as! [Any])
            } else {
                sharedModel.hiddenApps.removeAll { now in
                    return app == now
                }
                if !sharedModel.apps.contains(app) {
                    sharedModel.apps.append(app)
                }
                UserDefaults.lcShared().mutableArrayValue(forKey: "LCGuestURLSchemes")
                    .addObjects(from: app.appInfo.urlSchemes() as! [Any])
            }
            
        }
    }
    
    func launchAppWithBundleId(bundleId : String, container : String?, urlStr: String? = nil, forceJIT: Bool? = nil) async {
        if bundleId == "" {
            return
        }
        var appFound : LCAppModel? = nil
        var isFoundAppLocked = false
        for app in sharedModel.apps {
            if app.appInfo.relativeBundlePath == bundleId {
                appFound = app
                if app.appInfo.isLocked {
                    isFoundAppLocked = true
                }
                break
            }
        }
        if appFound == nil && !LCUtils.appGroupUserDefault.bool(forKey: "LCStrictHiding") {
            for app in sharedModel.hiddenApps {
                if app.appInfo.relativeBundlePath == bundleId {
                    appFound = app
                    isFoundAppLocked = true
                    break
                }
            }
        }
        
        if appFound == nil && bundleId == "builtinSideStore" {
            appFound = LCAppModel(appInfo: BuiltInSideStoreAppInfo.shared)
        }
        
        if isFoundAppLocked && !sharedModel.isHiddenAppUnlocked {
            do {
                let result = try await LCUtils.authenticateUser()
                if !result {
                    return
                }
            } catch {
                errorInfo = error.localizedDescription
                errorShow = true
                return
            }
        }
        
        guard let appFound else {
            errorInfo = "lc.appList.appNotFoundError".loc
            errorShow = true
            return
        }

        do {
            try await appFound.runApp(multitask: nil, containerFolderName: container, urlStr: urlStr, forceJIT: forceJIT)
        } catch is LCLaunchPreflight.Failure {
            openNavigationView(view:AnyView(LCLaunchPreflightView(model:appFound)))
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
        
    }
    
    func authenticateUser() async {
        do {
            if !(try await LCUtils.authenticateUser()) {
                return
            }
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
            return
        }
    }
    
    func jitLaunch(appName: String, classicMode: UInt) async {
        await jitLaunch(withScript: "", appName: appName, classicMode: classicMode)
    }

    func jitLaunch(withScript script: String, appName: String, classicMode: UInt) async {
        await MainActor.run {
            jitLog = ""
        }
        let enableJITTask = Task {
            
            let _ = await LCUtils.askForJIT(withScript: script, appName: appName, classicMode: classicMode) { newMsg in
                Task { await MainActor.run {
                    self.jitLog += "\(newMsg)\n"
                }}
            }
            guard let _ = JITEnablerType(rawValue: LCUtils.appGroupUserDefault.integer(forKey: "LCJITEnablerType")) else {
                return
            }
        }
        guard let result = await jitAlert.open(), result else {
            UserDefaults.standard.removeObject(forKey: "selected")
            enableJITTask.cancel()
            return
        }
        LCSharedUtils.launchToGuestApp(withClassicMode: classicMode)

    }
    
    func jitLaunch(withPID pid: Int, withScript script: String? = nil, appName: String) async {
        await MainActor.run {
            let encodedData = script?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
                
            
            if let jitEnabler = JITEnablerType(rawValue: LCUtils.appGroupUserDefault.integer(forKey: "LCJITEnablerType")) {
                if jitEnabler == .StosDebug || jitEnabler == .StosDebugLC {
                    let encoded = encodedData.map { "&script=\($0)" } ?? ""
                    if jitEnabler == .StosDebugLC {
                        if let app = sharedModel.apps.first(where: { app in
                            return app.appInfo.urlSchemes().contains("stosdebug") &&
                            (sharedModel.multiLCStatus != 2 || app.appInfo.isShared)
                        }) {
                            if var url = URL(string: "stosdebug://enableJIT?bundleId=\(Bundle.main.bundleIdentifier!)&appName=\(appName)&pid=\(pid)&relaunchApp=false& forcePID=true\(encoded)") {
                                Task { await openWebView(urlString: url.absoluteString) }
                            }
                        } else {
                            errorInfo = "StosDebug is not found. Please install it first and switch it to shared app."
                            errorShow = true
                            return
                        }
                    } else {
                        if var url = URL(string: "stosdebug://enableJIT?bundleId=\(Bundle.main.bundleIdentifier!)&appName=\(appName)&pid=\(pid)&forcePID=true\(encoded)") {
                            UIApplication.shared.open(url)
                        }
                    }
                    return
                }
                
                let encoded = encodedData.map { "&script-data=\($0)" } ?? ""
                if let url = URL(string: "stikjit://enable-jit?bundle-id=\(Bundle.main.bundleIdentifier!)&pid=\(pid)\(encoded)") {
                    if jitEnabler == .StikJITLC {
                        if let app = sharedModel.apps.first(where: { app in
                            return app.appInfo.urlSchemes().contains("stikjit") &&
                            (sharedModel.multiLCStatus != 2 || app.appInfo.isShared)
                        }) {
                            Task { await openWebView(urlString: url.absoluteString) }
                        } else {
                            errorInfo = "StikDebug is not found. Please install it first and switch it to shared app."
                            errorShow = true
                            return
                        }
                    } else {
                        UIApplication.shared.open(url)
                    }
                }
            }
        }
    }

    func showRunWhenMultitaskAlert() async -> Bool? {
        return await runWhenMultitaskAlert.open()
    }
    
    func installMdm(data: Data) {
        safariViewURL = URL(string:"data:application/x-apple-aspen-config;base64,\(data.base64EncodedString())")!
        safariViewOpened = true
    }
    
    func openNavigationView(view: AnyView) {
        navigateTo = view
        isNavigationActive = true
    }
    
    func promptForGeneratedIconStyle() async -> GeneratedIconStyle? {
        if #available(iOS 18.0, *) {
            return await generatedIconStyleSelector.open()
        } else {
            return .Light
        }
        
    }
    
    func closeNavigationView() {
        isNavigationActive = false
        navigateTo = nil
    }
    
    func copyError() {
        UIPasteboard.general.string = errorInfo
    }
    
    func handleURL(url : URL) {
        if url.isFileURL {
            Task { await installFromUrl(urlStr: url.absoluteString) }
            return
        }
        
        if url.scheme == "sidestore" && UserDefaults.sideStoreExist() {
            UserDefaults.standard.setValue(url.absoluteString, forKey: "launchAppUrlScheme")
            LCUtils.openSideStore(delegate: self)
            return
        }
        
        if url.host == "open-web-page" || url.host == "open-url" {
            if let urlComponent = URLComponents(url: url, resolvingAgainstBaseURL: false), let queryItem = urlComponent.queryItems?.first {
                if queryItem.value?.isEmpty ?? true {
                    return
                }
                
                if let decodedData = Data(base64Encoded: queryItem.value ?? ""),
                   let decodedUrl = String(data: decodedData, encoding: .utf8) {
                    Task { await openWebView(urlString: decodedUrl) }
                }
            }
        } else if url.host == "livecontainer-launch" {
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                var bundleId : String? = nil
                var containerName : String? = nil
                var forceJIT: Bool? = nil
                var urlStr: String? = nil
                for queryItem in components.queryItems ?? [] {
                    if queryItem.name == "bundle-name", let bundleId1 = queryItem.value {
                        bundleId = bundleId1
                    } else if queryItem.name == "container-folder-name", let containerName1 = queryItem.value {
                        containerName = containerName1
                    } else if queryItem.name == "jit", let forceJIT1 = queryItem.value {
                        if forceJIT1 == "true" {
                            forceJIT = true
                        } else if forceJIT1 == "false" {
                            forceJIT = false
                        }
                    } else if queryItem.name == "open-url" {
                        if let decodedData = Data(base64Encoded: queryItem.value ?? ""),
                           let decodedUrl = String(data: decodedData, encoding: .utf8) {
                            urlStr = decodedUrl
                        }
                    }
                }
                if let bundleId, bundleId != "ui"{
                    Task { await launchAppWithBundleId(bundleId: bundleId, container: containerName, urlStr: urlStr, forceJIT: forceJIT) }
                }
            }
        } else if url.host == "install" {
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                var installUrl : String? = nil
                for queryItem in components.queryItems ?? [] {
                    if queryItem.name == "url", let installUrl1 = queryItem.value {
                        installUrl = installUrl1
                    }
                }
                NSLog("[iOSVM] install deep link received: %@", installUrl ?? "<nil>")
                if let installUrl {
                    Task { await installFromUrl(urlStr: installUrl) }
                }
            }
        }
    }
    
}

extension View {
    func apply<V: View>(@ViewBuilder _ block: (Self) -> V) -> V { block(self) }
}

#if IOSVM_TESTING
// Internal device acceptance route; excluded from normal builds.
extension LCAppListView {
    @MainActor func runIOSVMTestingRoute() {
        let defaults = UserDefaults.standard
        Task { @MainActor in
            // Let the initial NavigationView finish mounting before driving acceptance navigation.
            try? await Task.sleep(nanoseconds: 750_000_000)
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("--iosvm-keychain-diagnose") {
                let report = LCGuestKeychainAcceptance.diagnose(sharedModel.apps + sharedModel.hiddenApps)
                if let app = sharedModel.apps.first(where: { $0.bundleIdentifier == "com.sixdays.trust" }) ?? sharedModel.apps.first,
                   let container = app.uiContainers.first,
                   report["apps"] != nil {
                    app.uiSelectedContainer = container
                    openNavigationView(view: AnyView(LCGuestKeychainView(model: app)))
                }
                return
            }
            if defaults.bool(forKey: "iosvmTestDownloadGadget") {
                await LCFridaDownloadAcceptance.run()
                openNavigationView(view: AnyView(LCFridaDownloadView()))
            }
            if defaults.bool(forKey: "iosvmTestRepairStorage") {
                let app = sharedModel.apps.first { $0.appInfo.relativeBundlePath == "com.etz.exchangeApp.app" }
                await LCStorageAcceptance.run(app: app, repairFrida: defaults.bool(forKey: "iosvmTestRepairFrida"))
            }
            if defaults.bool(forKey: "iosvmTestStorageDiagnostics") {
                let fm = FileManager.default
                let paths = ["", "iOSVM", "iOSVM/NetworkSettings", "iOSVM/NetworkSettingsV2", "iOSVM/NetworkSettings/com.etz.exchangeApp.app.json", "Tweaks", "Tweaks/iOSVM-Frida-com.etz.exchangeApp.app"]
                var items: [[String: Any]] = []
                for path in paths {
                    let url = LCPath.docPath.appendingPathComponent(path)
                    var item: [String: Any] = ["path": url.path, "writable": fm.isWritableFile(atPath: url.path)]
                    do {
                        let attrs = try fm.attributesOfItem(atPath: url.path)
                        for key in [FileAttributeKey.posixPermissions, .ownerAccountID, .groupOwnerAccountID, .immutable, .appendOnly, .type] {
                            if let value = attrs[key] { item[key.rawValue] = String(describing: value) }
                        }
                    } catch { item["error"] = String(describing: error) }
                    items.append(item)
                }
                let probe = IOSVMGuestAccess.networkSettingsDirectory(documents: LCPath.docPath).appendingPathComponent(".iosvm-write-probe-" + UUID().uuidString)
                var report: [String: Any] = ["uid": getuid(), "euid": geteuid(), "items": items]
                do { try Data("probe".utf8).write(to: probe, options: .atomic); try fm.removeItem(at: probe); report["writeProbe"] = "passed" }
                catch { report["writeProbe"] = String(describing: error); report["writeProbeDetails"] = String(describing: (error as NSError).userInfo) }
                if let app = sharedModel.apps.first(where: { $0.appInfo.relativeBundlePath == "com.etz.exchangeApp.app" }) {
                    report["selectedTweakFolder"] = app.uiTweakFolder ?? ""
                }
                let output = LCPath.docPath.appendingPathComponent("iOSVMUITests")
                try? fm.createDirectory(at: output, withIntermediateDirectories: true)
                try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("storage-diagnostics.json"), options: .atomic)
            }
            if defaults.bool(forKey: "iosvmTestCleanup") {
                // Fixed, self-owned acceptance fixtures only. No caller-supplied deletion paths.
                let paths = [
                    "Applications/dev.iosvm.uipreview.app",
                    "Data/Application/67B32081-F51B-41B8-A1AB-0919CEB5643E",
                    "Tweaks/iOSVM-UI-Preview",
                    "iOSVM/NetworkSettings/dev.iosvm.uipreview.app.json",
                    "iOSVM/Processes/CE907C3C-538A-49AB-9880-BA2A32F9ED88.json",
                    "Tweaks/iOSVM-Authorization-Probe-F112",
                    "iOSVM/NetworkSettings/dev.iosvm.sessioncheck.app.json",
                    "Inbox/SessionCheck.ipa"
                ]
                var retained: [String] = []
                for path in paths {
                    let url = LCPath.docPath.appendingPathComponent(path)
                    if FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.removeItem(at: url) }
                    if FileManager.default.fileExists(atPath: url.path) { retained.append(path) }
                }
                let output = LCPath.docPath.appendingPathComponent("iOSVMUITests")
                try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try? JSONSerialization.data(withJSONObject: ["retained": retained]).write(to: output.appendingPathComponent("ui-cleanup.json"), options: .atomic)
            }
            if let ipa = defaults.string(forKey: "iosvmTestImport"),
               URL(fileURLWithPath: ipa).lastPathComponent == ipa {
                // A cancelled duplicate-install dialog must not replay on every host launch.
                defaults.removeObject(forKey: "iosvmTestImport")
                let directory = defaults.bool(forKey: "iosvmTestSandboxBackupsImport") && ipa == "BackupCheck.ipa" ? "iOSVMUITests" : "Inbox"
                await startInstallApp(LCPath.docPath.appendingPathComponent(directory).appendingPathComponent(ipa))
            }
            if let relative = defaults.string(forKey: "iosvmTestApp"),
               let app = sharedModel.apps.first(where: { $0.appInfo.relativeBundlePath == relative }) {
                if defaults.bool(forKey: "iosvmTestLaunch") {
                    do { try await app.runApp(multitask: true) }
                    catch { print("[iOSVM Testing] launch failed: \(error.localizedDescription)") }
                }
                if let action = defaults.string(forKey: "iosvmTestGuestKeychain") {
                    let report = await LCGuestKeychainAcceptance.run(app, action: action)
                    if report["state"] as? String == "passed" {
                        openNavigationView(view: AnyView(LCGuestKeychainView(model: app)))
                    }
                }
                if let action = defaults.string(forKey: "iosvmTestPresets") { await LCTestPresetAcceptance.run(app,action:action) }
                if defaults.bool(forKey: "iosvmTestSandboxBackups") { await LCSandboxBackupAcceptance.run(app) }
                if defaults.bool(forKey:"iosvmTestPreflightPage") { openNavigationView(view:AnyView(LCLaunchPreflightView(model:app))) }
                else if defaults.bool(forKey:"iosvmTestPresetsPage") { openNavigationView(view:AnyView(LCTestPresetsView(model:app))) }
                if let action = defaults.string(forKey: "iosvmTestDebugWorkbench") {
                    await LCFridaWorkbenchAcceptance.run(app, action: action)
                }
                if defaults.bool(forKey:"iosvmTestFridaComputer") {
                    openNavigationView(view:AnyView(LCFridaStartupScriptsView(model:app,computer:true)))
                } else if defaults.bool(forKey: "iosvmTestCompatibility") {
                    openNavigationView(view: AnyView(LCCompatibilityDiagnosticsView(model: app)))
                } else if defaults.bool(forKey: "iosvmTestMatrix") {
                    openNavigationView(view: AnyView(LCCompatibilityMatrixView()))

                } else if defaults.bool(forKey: "iosvmTestUnifiedLogs") {
                    openNavigationView(view: AnyView(LCAppLogsView(model: app)))
                } else if defaults.bool(forKey: "iosvmTestKeychain") {
                    openNavigationView(view: AnyView(LCGuestKeychainView(model: app)))
                } else if defaults.bool(forKey: "iosvmTestScriptCompatibility"), app.appInfo.relativeBundlePath == "dev.iosvm.debugcheck.app",
                   let script = try? LCFridaScriptStore.list().first(where:{$0.name == "Acceptance ObjC"}) {
                    openNavigationView(view: AnyView(LCFridaScriptEditor(script:script)))
                } else if defaults.bool(forKey: "iosvmTestFridaScripts") {
                    openNavigationView(view: AnyView(LCFridaStartupScriptsView(model: app)))
                } else if defaults.bool(forKey: "iosvmTestFridaLogs") {
                    openNavigationView(view: AnyView(LCAppLogsView(model: app, initialSource: .process)))
                } else if defaults.bool(forKey: "iosvmTestFridaVersions") {
                    openNavigationView(view: AnyView(LCFridaVersionsView(model: app)))
                } else if defaults.bool(forKey: "iosvmTestWorkbench") {
                    openNavigationView(view: AnyView(LCAppWorkbenchView(model: app)))
                } else if defaults.bool(forKey: "iosvmTestSettings") {
                    openNavigationView(view: AnyView(LCAppSettingsView(model: app)))
                } else if defaults.bool(forKey: "iosvmTestProcess") {
                    openNavigationView(view: AnyView(LCGuestSessionView(model: app)))
                } else if defaults.bool(forKey: "iosvmTestNetwork") {
                    openNavigationView(view: AnyView(LCNetworkView(model: app)))
                } else if defaults.bool(forKey: "iosvmTestSandbox") {
                    openNavigationView(view: AnyView(LCAppSandboxView(model: app)))
                } else if defaults.bool(forKey: "iosvmTestBackupDiff") {
                    openNavigationView(view: AnyView(LCSandboxBackupAcceptanceDetail(model: app)))
                } else if defaults.bool(forKey: "iosvmTestBackupsPage") || defaults.bool(forKey: "iosvmTestSandboxBackups") {
                    openNavigationView(view: AnyView(LCSandboxBackupsView(model: app)))
                } else if !defaults.bool(forKey:"iosvmTestPreflightPage")
                            && !defaults.bool(forKey:"iosvmTestPresetsPage")
                            && !defaults.bool(forKey:"iosvmTestCompatibility")
                            && !defaults.bool(forKey:"iosvmTestMatrix")
                            && !defaults.bool(forKey:"iosvmTestScenarios")
                            && !defaults.bool(forKey:"iosvmTestUnifiedLogs")
                            && !defaults.bool(forKey:"iosvmTestKeychain")
                            && defaults.string(forKey:"iosvmTestGuestKeychain") == nil {
                    openNavigationView(view: AnyView(LCFridaView(model: app)))
                }
                let record: [String: Any] = ["guest": relative, "gadget": LCFridaSetup.enabled(app.appInfo),
                                            "containers": app.uiContainers.map { $0.folderName },
                                            "isAppRunning": app.isAppRunning,
                                            "processes": IOSVMProcessRegistry.shared.records(forBundle: relative)]
                let output = LCPath.docPath.appendingPathComponent("iOSVMUITests")
                try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
                    .write(to: output.appendingPathComponent("route.json"), options: .atomic)
            }
            if let name = defaults.string(forKey: "iosvmTestCapture"),
               name.range(of: "^[a-zA-Z0-9_-]+$", options: .regularExpression) != nil {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                    .flatMap { $0.windows }.first { $0.isKeyWindow }
                if let window {
                    let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
                    let image = renderer.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
                    let output = LCPath.docPath.appendingPathComponent("iOSVMUITests")
                    try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                    try? image.pngData()?.write(to: output.appendingPathComponent(name + ".png"), options: .atomic)
                }
            }
        }
    }
}
#endif
