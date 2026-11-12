//
//  AppSceneView.m
//  LiveContainer
//
//  Created by s s on 2025/5/17.
//
#import "AppSceneViewController.h"
#import "DecoratedAppSceneViewController.h"
#import "LiveContainerSwiftUI-Swift.h"
#import "../LiveContainerSwiftUI/Utilities/LCUtils.h"
#import "PiPManager.h"
#import "Localization.h"
#import "LCSharedUtils.h"
#import "utils.h"
#import "../LiveContainer/IOSVMGuestSession.h"
#import "UIKitPrivate+MultitaskSupport.h"

@interface AppSceneViewController()
@property int resizeDebounceToken;
@property CFTimeInterval lastResizeRequestTime;
@property CGPoint normalizedOrigin;
@property bool isNativeWindow;
@property NSUUID* identifier;
@end

@interface AppSceneViewController()
@property(nonatomic) UIWindowScene *hostScene;
@property(nonatomic) NSString *sceneID;
@property(nonatomic) NSExtension* extension;
@property(nonatomic) bool isAppTerminationCleanUpCalled;
@property(nonatomic) NSString *processLaunchID;
@property(nonatomic) NSTimer *processTimer;
@property(nonatomic) uint64_t processAuditToken57;
@property(nonatomic) NSDictionary *accessPlan;
@property(nonatomic) NSURL *externalDataURL;
@property(nonatomic) id stopObserver;
@property(nonatomic) BOOL initializationFailureReported;
@property(nonatomic) BOOL stopRequested;
@property(nonatomic) NSString *terminalState;
@property(nonatomic) NSString *terminalReason;
- (void)stopOwnedRequestWithReason:(NSString *)reason;
- (void)killOwnedRequest;

- (void)failLaunch:(NSError *)error;
- (void)checkProcess;

@end

@implementation AppSceneViewController


- (instancetype)initWithBundleId:(NSString*)bundleId dataUUID:(NSString*)dataUUID delegate:(id<AppSceneViewControllerDelegate>)delegate {
    self = [super initWithNibName:nil bundle:nil];
    self.delegate = delegate;
    self.dataUUID = dataUUID;
    self.bundleId = bundleId;
    self.scaleRatio = 1.0;
    self.isAppTerminationCleanUpCalled = false;
    self.isNativeWindow = [NSUserDefaults.lcSharedDefaults integerForKey:@"LCMultitaskMode" ] == 1;
    
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        UIKitFixesInit();
    });
    
    NSError *error = nil;
    self.processLaunchID = [IOSVMProcessRegistry.shared beginBundle:bundleId container:dataUUID error:&error];
    if (!self.processLaunchID) {
        dispatch_async(dispatch_get_main_queue(), ^{ [delegate appSceneVC:self didInitializeWithError:error]; });
        return self;
    }
    __weak typeof(self) stopOwner = self;
    self.stopObserver = [NSNotificationCenter.defaultCenter addObserverForName:@"IOSVMStopGuest" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        AppSceneViewController *owner = stopOwner;
        if ([note.userInfo[@"id"] isEqual:owner.processLaunchID] && !owner.isAppTerminationCleanUpCalled) {
            if ([owner.delegate isKindOfClass:DecoratedAppSceneViewController.class]) [(DecoratedAppSceneViewController *)owner.delegate closeWindow];
            else {
                [owner terminate];
                if (owner.isNativeWindow && owner.view.window.windowScene) [UIApplication.sharedApplication requestSceneSessionDestruction:owner.view.window.windowScene.session options:nil errorHandler:nil];
            }
        }
    }];
    _extension = [NSExtension extensionWithIdentifier:LCUtils.liveProcessBundleIdentifier error:&error];
    if (!_extension || error) {
        [self failLaunch:error ?: [NSError errorWithDomain:@"iOSVMWindow" code:2 userInfo:@{NSLocalizedDescriptionKey:@"LiveProcess 扩展不可用。"}]];
        return self;
    }
    _extension.preferredLanguages = @[];
    
    NSExtensionItem *item = [NSExtensionItem new];
    NSMutableDictionary *userInfo = @{
        @"hostUrlScheme": NSUserDefaults.lcAppUrlScheme,
        @"selected": _bundleId,
        @"selectedContainer": _dataUUID,
        @"lcHomePath": NSHomeDirectory(),
    }.mutableCopy;
    
    NSString* launchAppUrlScheme = [NSUserDefaults.standardUserDefaults stringForKey:@"launchAppUrlScheme"];
    [NSUserDefaults.lcUserDefaults removeObjectForKey:@"launchAppUrlScheme"];
    if(launchAppUrlScheme) {
        [userInfo setValue:launchAppUrlScheme forKey:@"launchAppUrlScheme"];
    }
    
    NSURL *docURL = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].lastObject;
    NSURL *appURL = [[docURL URLByAppendingPathComponent:@"Applications"] URLByAppendingPathComponent:bundleId];
    BOOL shared = ![NSFileManager.defaultManager fileExistsAtPath:appURL.path];
    NSURL *sharedDocuments = [LCSharedUtils.appGroupPath URLByAppendingPathComponent:@"LiveContainer"];
    if (shared) appURL = [[sharedDocuments URLByAppendingPathComponent:@"Applications"] URLByAppendingPathComponent:bundleId];
    NSURL *dataURL = [[(shared ? sharedDocuments : docURL) URLByAppendingPathComponent:@"Data/Application"] URLByAppendingPathComponent:dataUUID];
    NSDictionary *metadata = [NSDictionary dictionaryWithContentsOfURL:[appURL URLByAppendingPathComponent:@"LCAppInfo.plist"]];
    NSArray *registeredContainers = [metadata[@"LCContainers"] isKindOfClass:NSArray.class] ? metadata[@"LCContainers"] : @[];
    for (NSDictionary *container in registeredContainers) {
        if (![container isKindOfClass:NSDictionary.class]) continue;
        if (![container[@"folderName"] isEqual:dataUUID] || ![container[@"bookmarkData"] isKindOfClass:NSData.class]) continue;
        BOOL stale = NO;
        NSURL *external = [NSURL URLByResolvingBookmarkData:container[@"bookmarkData"] options:0 relativeToURL:nil bookmarkDataIsStale:&stale error:&error];
        if (!external || stale || ![external startAccessingSecurityScopedResource]) {
            [self failLaunch:error ?: [NSError errorWithDomain:@"iOSVMWindow" code:4 userInfo:@{NSLocalizedDescriptionKey:@"注册数据容器的书签不可用。"}]];
            return self;
        }
        self.externalDataURL = external;
        dataURL = external;
        break;
    }
    NSDictionary *plan = [IOSVMGuestAccess planForApplication:appURL data:dataURL documents:docURL shared:shared
        shareAll:[NSUserDefaults.standardUserDefaults boolForKey:@"LCSharePrivateDataWithLiveProcess"] error:&error];
    if (!plan) { [self failLaunch:error]; return self; }
    self.accessPlan = plan;
    [IOSVMProcessRegistry.shared updateLaunch:self.processLaunchID state:@"preparing" details:@{
        @"authorizationMode":plan[@"mode"], @"capabilities":[IOSVMGuestAccess publicCapabilities:plan]
    }];
    NSDictionary *issued = [IOSVMGuestAccess issuePlan:plan error:&error];
    if (!issued) { [self failLaunch:error]; return self; }
    userInfo[@"IOSVMAccessPlan"] = issued;
    userInfo[@"IOSVMLaunchID"] = self.processLaunchID;
    item.userInfo = userInfo;
    
    __weak typeof(self) weakSelf = self;
    [_extension setRequestCancellationBlock:^(NSUUID *uuid, NSError *failure) {
        dispatch_async(dispatch_get_main_queue(), ^{
            AppSceneViewController *owner = weakSelf;
            if (!owner || owner.isAppTerminationCleanUpCalled) return;
            if (!owner.stopRequested) {
                owner.terminalState = owner.pid == 0 ? @"failed" : @"interrupted";
                owner.terminalReason = failure.localizedDescription ?: @"扩展请求已取消；退出原因未经确认。";
            }
            if (failure && owner.pid == 0 && !owner.initializationFailureReported) { [owner failLaunch:failure]; return; }
            [owner appTerminationCleanUp];
        });
    }];
    [_extension setRequestInterruptionBlock:^(NSUUID *uuid) {
        dispatch_async(dispatch_get_main_queue(), ^{
            AppSceneViewController *owner = weakSelf;
            if (!owner || owner.isAppTerminationCleanUpCalled) return;
            if (!owner.stopRequested) {
                owner.terminalState = @"interrupted";
                owner.terminalReason = @"扩展请求中断；不据此判定目标发生崩溃。";
            }
            [owner appTerminationCleanUp];
        });
    }];
    self.processTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) { [weakSelf checkProcess]; }];
    [_extension beginExtensionRequestWithInputItems:@[item] completion:^(NSUUID *identifier) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.isAppTerminationCleanUpCalled || self.initializationFailureReported) {
                if (identifier && [self.extension respondsToSelector:@selector(cancelExtensionRequestWithIdentifier:)]) [self.extension cancelExtensionRequestWithIdentifier:identifier];
                return;
            }
            self.identifier = identifier;
            self.pid = identifier ? [self.extension pidForRequestIdentifier:identifier] : 0;
            if (self.stopRequested) {
                [IOSVMProcessRegistry.shared updateLaunch:self.processLaunchID state:@"stopping" details:@{@"pid":@(self.pid)}];
                if (self.pid > 0) [self killOwnedRequest]; else [self appTerminationCleanUp];
                return;
            }
            if (self.pid <= 0 || ![IOSVMProcessRegistry.shared updateLaunch:self.processLaunchID state:@"spawned" details:@{@"pid":@(self.pid)}]) {
                [self failLaunch:[NSError errorWithDomain:@"iOSVMWindow" code:2 userInfo:@{NSLocalizedDescriptionKey:@"测试进程未能启动或启动请求已结束。"}]];
                return;
            }
            [delegate appSceneVC:self didInitializeWithError:nil];
            [self setUpAppPresenter];
        });
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (!self.isAppTerminationCleanUpCalled && [[IOSVMProcessRegistry.shared recordForLaunch:self.processLaunchID][@"state"] isEqual:@"preparing"]) {
            [self failLaunch:[NSError errorWithDomain:@"iOSVMWindow" code:8 userInfo:@{NSLocalizedDescriptionKey:@"等待扩展启动超时。"}]];
        }
    });
    
    return self;
}

- (void)setUpAppPresenter {
    RBSProcessPredicate* predicate = [PrivClass(RBSProcessPredicate) predicateMatchingIdentifier:@(self.pid)];
    FBProcessManager *manager = [PrivClass(FBProcessManager) sharedInstance];
    // At this point, the process is spawned and we're ready to create a scene to render in our app
    RBSProcessHandle* processHandle = [PrivClass(RBSProcessHandle) handleForPredicate:predicate error:nil];
    if (!processHandle) {
        [self failLaunch:[NSError errorWithDomain:@"iOSVMWindow" code:9 userInfo:@{NSLocalizedDescriptionKey:@"无法确认测试进程身份。"}]];
        return;
    }
    audit_token_t token = processHandle.auditToken;
    self.processAuditToken57 = token.val[7] | ((uint64_t)token.val[5] << 32);
    [IOSVMProcessRegistry.shared updateLaunch:self.processLaunchID state:@"spawned" details:@{@"auditToken57":@(self.processAuditToken57)}];
    [manager registerProcessForAuditToken:token];
    UIApplicationSceneSpecification *specification = [UIApplicationSceneSpecification specification];
    
    void (^updateSceneSettings)(id) = ^void(UIMutableApplicationSceneSettings *settings) {
        settings.canShowAlerts = YES;
        settings.cornerRadiusConfiguration = [[PrivClass(BSCornerRadiusConfiguration) alloc] initWithTopLeft:self.view.layer.cornerRadius bottomLeft:self.view.layer.cornerRadius bottomRight:self.view.layer.cornerRadius topRight:self.view.layer.cornerRadius];
        settings.displayConfiguration = UIScreen.mainScreen.displayConfiguration;
        settings.foreground = YES;
        //settings.interruptionPolicy = 2; // reconnect
        settings.level = 1;
        settings.persistenceIdentifier = self.dataUUID;
        settings.statusBarDisabled = !self.isNativeWindow;
        //settings.previewMaximumSize =
        //settings.deviceOrientationEventsEnabled = YES;
        if(!self.usesHostingControllerAPI) {
            settings.safeAreaInsetsPortrait = self.view.safeAreaInsets;
        }
    };
    void (^updateSceneClientSettings)(id) = ^void(UIMutableApplicationSceneClientSettings *clientSettings) {
        clientSettings.interfaceOrientation = UIInterfaceOrientationPortrait;
        clientSettings.statusBarStyle = 0;
    };

    if (@available(iOS 18.0, *)) {
        // Use new API for iOS 18+. While some of these APIs are available since 17.0, we're only interested in fixing event deferring issue
        _UISceneHostingControllerAdvancedConfiguration *config = [[_UISceneHostingControllerAdvancedConfiguration alloc] initWithProcessIdentity:processHandle.identity];
        config.sceneSpecification = specification;
        if (@available(iOS 27.0, *)) {} else {
            // on 27 manually adding this is not need, also setAdditionalExtensions: doesn't exist for some reason
            config.additionalExtensions = [NSOrderedSet orderedSetWithArray:@[
                PrivClass(_UISceneHostingEventDeferringExtension),
            ]];
        }
        self.hostingController = [[_UISceneHostingController alloc] initWithAdvancedConfiguration:config];
        /// !! do NOT use self.hostingController.sceneView here as it breaks keyboard focus on iOS 26 below. I have no idea why this happens even though both return the same object. Maybe sceneView didn't initialize its ViewController properly?
        self.contentView = self.hostingController.sceneViewController.view;
        self.contentView.clipsToBounds = NO;
        // _scenePresenter was a property in 26, but made only ivar in 27
        self.presenter = [self.contentView valueForKey:@"_scenePresenter"];
        self.sceneID = self.presenter.identifier;
        FBScene *scene = self.presenter.scene;
        [scene configureParameters:^(FBSMutableSceneParameters *parameters) {
            [parameters updateSettingsWithBlock:updateSceneSettings];
            [parameters updateClientSettingsWithBlock:updateSceneClientSettings];
        }];
        
        /// Fix keyboard focus by setting up event deferring extension. Previously we worked around it by changing identifier, but that broke other things
        _UISceneEventDeferringHostComponent *deferringComponent = self.hostingController._eventDeferringComponent;
        NSAssert(deferringComponent, @"Unexpectedly nil _UISceneEventDeferringHostComponent");
        if (@available(iOS 27.0, *)) { // _UIKeyboardArbiterUsesDeferringGraph()
            /// UIKitCore`__85-[_UIRemoteViewControllerSceneHostingImpl _viewServiceHostSessionDidConnectToClient:]_block_invoke
            /// iOS 27 requires setting up _UISceneEventDeferringHostComponent for keyboard focus to work
            
            /// Replicate these methods since they are made private
            /// -[_UISceneEventDeferringHostComponent setFirstResponderTrackingSelectionPath:]:
            [deferringComponent setValue:self forKey:@"_firstResponderTrackingSelectionPath"];
            // if (!deferringComponent->_flags.clientIsInChain) return;
            /// -[_UISceneEventDeferringHostComponent becomeFirstResponderIfNecessary]:
            // if (deferringComponent->_flags.maintainHostFirstResponderWhenClientWantsKeyboard)
            
            deferringComponent.grantBehavior = 2;
            deferringComponent.selectionRequestBehavior = 2;
        }
        /// UIKitCore`-[_UISceneHostingController createSceneWithConfiguration:]
        /// Lower iOS uses _UISceneHostingEventDeferringExtension, no further setup needed
        
        // Now it's time to get the initial settings from decorated VC
        [self.delegate appSceneVCWillActivateScene:self];
        [self addChildViewController:self.hostingController.sceneViewController];
        
        // For new API, let FBSSceneObserver send host scene events instead of NSExtensionContext
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center removeObserver:self.extension name:UIApplicationDidBecomeActiveNotification object:UIApp];
        [center removeObserver:self.extension name:UIApplicationWillResignActiveNotification object:UIApp];
        [center removeObserver:self.extension name:UIApplicationDidEnterBackgroundNotification object:UIApp];
        [center removeObserver:self.extension name:UIApplicationWillEnterForegroundNotification object:UIApp];
    } else {
        self.sceneID = [NSString stringWithFormat:@"sceneID:%@-%@", @"LiveProcess", self.dataUUID];
        FBSMutableSceneDefinition *definition = [PrivClass(FBSMutableSceneDefinition) definition];
        definition.identity = [PrivClass(FBSSceneIdentity) identityForIdentifier:self.sceneID];
        definition.clientIdentity = [PrivClass(FBSSceneClientIdentity) identityForProcessIdentity:processHandle.identity];
        definition.specification = specification;
        
        FBSMutableSceneParameters *parameters = [PrivClass(FBSMutableSceneParameters) parametersForSpecification:specification];
        [parameters updateSettingsWithBlock:updateSceneSettings];
        [parameters updateClientSettingsWithBlock:updateSceneClientSettings];
        FBScene *scene = [[PrivClass(FBSceneManager) sharedInstance] createSceneWithDefinition:definition initialParameters:parameters];
        self.presenter = [scene.uiPresentationManager createPresenterWithIdentifier:self.sceneID];
        [self.presenter modifyPresentationContext:^(UIMutableScenePresentationContext *context) {
            context.appearanceStyle = 2;
        }];
        [self.presenter activate];
        
        self.contentView = [[UIView alloc] init];
        [self.contentView addSubview:self.presenter.presentationView];
    }
    [self.view addSubview:_contentView];
    
    // If we have a staging URL scheme, pass it now
    NSString *launchUrl = [NSUserDefaults.standardUserDefaults stringForKey:@"launchAppUrlScheme"];
    if(launchUrl) {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:@"launchAppUrlScheme"];
        [self openURLScheme:launchUrl];
    }
    
    __weak typeof(self) weakSelf = self;
    [self.extension setRequestInterruptionBlock:^(NSUUID *uuid) {
        [weakSelf appTerminationCleanUp];
    }];
    self.contentView.layer.anchorPoint = CGPointMake(0, 0);
    self.contentView.layer.position = CGPointMake(0, 0);
    
    [self.view.window.windowScene _registerSettingsDiffActionArray:@[self] forKey:self.sceneID];
    [IOSVMProcessRegistry.shared updateLaunch:self.processLaunchID state:@"running" details:@{}];
}

- (void)failLaunch:(NSError *)error {
    if (self.isAppTerminationCleanUpCalled || self.initializationFailureReported) return;
    self.initializationFailureReported = YES;
    NSError *failure = error ?: [NSError errorWithDomain:@"iOSVMWindow" code:1 userInfo:@{NSLocalizedDescriptionKey:@"测试启动失败。"}];
    self.terminalState = @"failed";
    self.terminalReason = failure.localizedDescription;
    if (self.pid > 0 && self.isAppRunning) [self stopOwnedRequestWithReason:failure.localizedDescription];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.delegate appSceneVC:self didInitializeWithError:failure];
        [self appTerminationCleanUp];
    });
}

- (void)checkProcess {
    if (self.isAppTerminationCleanUpCalled) return;
    if (self.pid > 0 && !self.isAppRunning) { [self appTerminationCleanUp]; return; }
    NSDictionary *current = [IOSVMProcessRegistry.shared recordForLaunch:self.processLaunchID];
    if ([current[@"authorizationConsumed"] boolValue] || !self.accessPlan) return;
    NSString *receiptPath = [self.accessPlan[@"dataPath"] stringByAppendingPathComponent:
        [NSString stringWithFormat:@"Library/iOSVM/Access/%@.json",self.processLaunchID]];
    NSData *data = [NSData dataWithContentsOfFile:receiptPath];
    NSDictionary *receipt = data && data.length < 16384 ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if ([receipt[@"id"] isEqual:self.processLaunchID] && [receipt[@"pid"] intValue] == self.pid &&
        [receipt[@"bundle"] isEqual:self.bundleId] && [receipt[@"container"] isEqual:self.dataUUID]) {
        [IOSVMProcessRegistry.shared updateLaunch:self.processLaunchID state:current[@"state"] details:@{@"authorizationConsumed":@YES}];
    }
}

- (void)terminate {
    if (!self.terminalState) { self.terminalState = @"exited"; self.terminalReason = @"用户关闭测试窗口。"; }
    [self stopOwnedRequestWithReason:self.terminalReason];
}

- (void)stopOwnedRequestWithReason:(NSString *)reason {
    if (self.isAppTerminationCleanUpCalled || self.stopRequested) return;
    self.stopRequested = YES;
    [IOSVMProcessRegistry.shared updateLaunch:self.processLaunchID state:@"stopping" details:@{@"stopReason":reason ?: @"停止测试进程"}];
    if (self.identifier && self.pid > 0) [self killOwnedRequest];
    // If the request is still starting, keep its reservation until the completion
    // supplies a PID or reports failure. A late completion must never run a guest
    // against a container already handed to a second launch.
}

- (void)killOwnedRequest {
    NSUUID *request = self.identifier;
    [self.extension _kill:SIGTERM];
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        AppSceneViewController *owner = weakSelf;
        NSDictionary *active = [IOSVMProcessRegistry.shared activeRecordForContainer:owner.dataUUID ?: @""];
        if (owner && !owner.isAppTerminationCleanUpCalled && [active[@"id"] isEqual:owner.processLaunchID] &&
            [owner.identifier isEqual:request] && owner.isAppRunning) [owner.extension _kill:SIGKILL];
    });
}

- (void)_performActionsForUIScene:(UIScene *)scene withUpdatedFBSScene:(id)fbsScene settingsDiff:(FBSSceneSettingsDiff *)diff fromSettings:(UIApplicationSceneSettings *)settings transitionContext:(id)context lifecycleActionType:(uint32_t)actionType {
    if (!NSThread.isMainThread) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf _performActionsForUIScene:scene withUpdatedFBSScene:fbsScene
                settingsDiff:diff fromSettings:settings transitionContext:context
                lifecycleActionType:actionType];
        });
        return;
    }

    if(!self.isAppRunning) {
        [self appTerminationCleanUp];
    }
    if(!diff) return;
    
    UIMutableApplicationSceneSettings *baseSettings = [diff settingsByApplyingToMutableCopyOfSettings:settings];
    UIApplicationSceneTransitionContext *newContext = [context copy];
    newContext.actions = nil;
    [self.delegate appSceneVC:self didUpdateFromSettings:baseSettings transitionContext:newContext lifecycleActionType:actionType];
}

- (void)viewWillLayoutSubviews {
    /// For native window we let iPadOS handle it however it wants, which is usually live resize (autoresizingMask set in appSceneVCWillActivateScene)
    if(_contentView.autoresizingMask != (UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight)) {
        [self updateFrameWithSettingsBlock:nil];
    }
}
- (void)updateFrameWithSettingsBlock:(void (^)(UIMutableApplicationSceneSettings *settings))block {
    __block int currentDebounceToken = ++_resizeDebounceToken;
    dispatch_block_t queueBlock = ^{
        if(currentDebounceToken != self.resizeDebounceToken) {
            return;
        }
        [self updateSettingsWithBlock:^(UIMutableApplicationSceneSettings *settings) {
            settings.deviceOrientation = UIDevice.currentDevice.orientation;
            settings.interfaceOrientation = self.view.window.windowScene.interfaceOrientation;
            CGRect frame = self.view.frame;
            if(!self.usesHostingControllerAPI) {
                frame.size.width /= self.scaleRatio;
                frame.size.height /= self.scaleRatio;
            }
            if(UIInterfaceOrientationIsLandscape(settings.interfaceOrientation)) {
                CGSize size = frame.size;
                frame.size.width = size.height;
                frame.size.height = size.width;
            }
            settings.frame = frame;
            if(block) {
                block(settings);
            }
        }];
    };
    if(_shouldSkipDebounceOnce) {
        _shouldSkipDebounceOnce = NO;
        queueBlock();
    } else {
        dispatch_time_t delay = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC));
        dispatch_after(delay, dispatch_get_main_queue(), queueBlock);
    }
}
- (void)updateSettingsWithBlock:(void(^)(UIMutableApplicationSceneSettings *settings))updateSettingsBlock {
    if(_shouldIgnoreSceneUpdates) {
        // Ignore all updates when in PiP mode
        return;
    }
    
    if(!_hostingController && self.contentView) {
        // Legacy path
        [self.presenter.scene updateSettingsWithBlock:updateSettingsBlock];
        return;
    }
    
    /// iOS 18.0 path, most are automatically handled by setting values to _UISceneHostingViewController
    /// This is also reachable on legacy path when contentView is nil during early setup
    UIMutableApplicationSceneSettings *tempSettings = [self.presenter.scene.settings mutableCopy];
    if(!tempSettings) {
        tempSettings = [UIMutableApplicationSceneSettings new];
    }
    updateSettingsBlock(tempSettings);
    CGRect frame = tempSettings.frame;
    if(UIInterfaceOrientationIsLandscape(tempSettings.interfaceOrientation)) {
        frame = CGRectMake(frame.origin.x, frame.origin.y, frame.size.height, frame.size.width);
    }
    
    if (self.contentView) {
        BOOL isiOS26 = NO;
        if(@available(iOS 19.0, *)) { if(@available(iOS 27.0, *)) {} else isiOS26 = YES; }
        // Discard position
        frame.origin = CGPointZero;
        self.contentView.frame = frame;
    } else {
        // This method can be called while contentView is nil to set up initial frame
        self.view.frame = frame;
    }
}

- (BOOL)isAppRunning {
    if (_pid <= 0 || self.isAppTerminationCleanUpCalled) return NO;
    if (self.processAuditToken57) {
        audit_token_t token = {0}; token.val[5] = (uint32_t)(self.processAuditToken57 >> 32); token.val[7] = (uint32_t)self.processAuditToken57;
        errno = 0; csops_audittoken(_pid, 0, NULL, 0, &token);
        return errno != ESRCH;
    }
    errno = 0;
    return getpgid(_pid) > 0 || errno == EPERM;
}

- (void)appTerminationCleanUp {
    if(_isAppTerminationCleanUpCalled) {
        return;
    }
    // Request cancellation is not proof of process death. Keep the container
    // reserved until the identity/liveness check confirms the owned process ended.
    if (self.pid > 0 && self.isAppRunning) {
        [self stopOwnedRequestWithReason:self.terminalReason ?: @"扩展会话结束，正在停止测试进程。"];
        return;
    }
    _isAppTerminationCleanUpCalled = true;
    if (self.stopObserver) { [NSNotificationCenter.defaultCenter removeObserver:self.stopObserver];self.stopObserver = nil; }
    [self.processTimer invalidate];self.processTimer = nil;
    if (self.processLaunchID) {
        [IOSVMProcessRegistry.shared finishLaunch:self.processLaunchID state:self.terminalState ?: @"exited"
            reason:self.terminalReason ?: @"测试进程已结束；退出原因未经确认。"];
    }
    [self.externalDataURL stopAccessingSecurityScopedResource];self.externalDataURL = nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        if(self.sceneID) {
            [[PrivClass(FBSceneManager) sharedInstance] destroyScene:self.sceneID withTransitionContext:nil];
        }
        if(self.usesHostingControllerAPI) {
            if(@available(iOS 17.0, *)) {
                [self.hostingController invalidate];
                [self.hostingController.sceneViewController removeFromParentViewController];
                self.hostingController = nil;
            }
        } else if(self.presenter){
            [self.presenter deactivate];
            [self.presenter invalidate];
        }
        self.presenter = nil;
        
        [self.delegate appSceneVCAppDidExit:self];

    });
}

- (void)setBackgroundNotificationEnabled:(bool)enabled {
    if(self.usesHostingControllerAPI) {
        /// Issue with new API: FBSSceneObserver takes priority over to send UIApplicationWillResignActiveNotification regressed #942,
        /// so here we make it foreground (UIApplicationDidBecomeActiveNotification) again.
        [self.presenter.scene updateSettingsWithBlock:^(UIMutableApplicationSceneSettings *settings) {
            settings.foreground = YES;
            settings.deactivationReasons = 0;
        }];
        return;
    }
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    if(enabled) {
        // Re-add UIApplicationDidEnterBackgroundNotification
        [center addObserver:self.extension selector:@selector(_hostDidEnterBackgroundNote:) name:UIApplicationDidEnterBackgroundNotification object:UIApp];
        [center addObserver:self.extension selector:@selector(_hostWillResignActiveNote:) name:UIApplicationWillResignActiveNotification object:UIApp];
    } else {
        // Remove UIApplicationDidEnterBackgroundNotification so apps like YouTube can continue playing video
        [center removeObserver:self.extension name:UIApplicationDidEnterBackgroundNotification object:UIApp];
        [center removeObserver:self.extension name:UIApplicationWillResignActiveNotification object:UIApp];
    }
}

- (void)viewDidMoveToWindow:(UIWindow *)newWindow shouldAppearOrDisappear:(BOOL)appear {
    [super viewDidMoveToWindow:newWindow shouldAppearOrDisappear:appear];
    if(!newWindow) {
        if(self.sceneID) {
            [self.view.window.windowScene _unregisterSettingsDiffActionArrayForKey:self.sceneID];
        }
        self.delegate = nil;
    }
}

- (void)openURLScheme:(NSString *)urlString {
    [self.presenter.scene updateSettingsWithTransitionBlock:^(id settings) {
        // pull from UserDefaults.standard.setValue(launchURLStr, forKey: "launchAppUrlScheme")
        UIApplicationSceneTransitionContext *context = [UIApplicationSceneTransitionContext new];
        NSURL *url = [NSURL URLWithString:urlString];
        context.payload = @{UIApplicationLaunchOptionsURLKey: urlString};
        context.actions = [NSSet setWithObject:[[UIOpenURLAction alloc] initWithURL:url]];
        return context;
    }];
}

- (void)handleStatusBarTapAction:(UIAction *)action {
    [self.presenter.scene updateSettingsWithTransitionBlock:^(id settings) {
        UIApplicationSceneTransitionContext *context = [UIApplicationSceneTransitionContext new];
        context.actions = [NSSet setWithObject:action];
        return context;
    }];
}

- (BOOL)usesHostingControllerAPI {
    return _hostingController != nil;
}

@end
 
