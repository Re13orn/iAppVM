//
//  main.m
//  LiveProcess
//
//  Created by Duy Tran on 3/5/25.
//

#import <dlfcn.h>
#import <UIKit/UIKit.h>
#import <mach-o/dyld.h>
#import "../LiveContainer/utils.h"
#import "../LiveContainer/Tweaks/Tweaks.h"
#import "../LiveContainer/UIKitPrivate.h"
#import "../SideStoreSupport/XPCServer.h"
#import "../LiveContainer/IOSVMGuestSession.h"

@interface LiveProcessHandler : NSObject<NSExtensionRequestHandling>
@end
@implementation LiveProcessHandler
static NSExtensionContext *extensionContext;
static NSDictionary *retrievedAppInfo;
+ (NSExtensionContext *)extensionContext {
    return extensionContext;
}

+ (NSDictionary *)retrievedAppInfo {
    return retrievedAppInfo;
}

- (void)beginRequestWithExtensionContext:(NSExtensionContext *)context {
    extensionContext = context;
    retrievedAppInfo = [context.inputItems.firstObject userInfo];
    // Return control to LiveContainerMain
    CFRunLoopStop(CFRunLoopGetMain());
}
@end

// Security-scoped bookmarks permit reading the parent's files, but do not grant
// executable mappings there. Keep signed code in this extension's own container.
// Each launch publishes its own uniquely named cache directory: publishing is a
// single atomic rename and never deletes a directory another window still uses.
// Entries older than a day are evicted opportunistically; iOS does not keep
// extension processes (and thus lazily-loaded frameworks) alive that long.
static void evictAgedCodeCacheEntries(NSFileManager *fm, NSURL *base, NSURL *keep) {
    NSArray<NSURL *> *items = [fm contentsOfDirectoryAtURL:base
                                includingPropertiesForKeys:@[NSURLContentModificationDateKey]
                                options:0 error:nil];
    if (!items) return;
    NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-86400];
    for (NSURL *item in items) {
        if ([item.path isEqualToString:keep.path]) continue;
        NSDate *modified = nil;
        [item getResourceValue:&modified forKey:NSURLContentModificationDateKey error:nil];
        if (modified && [modified compare:cutoff] == NSOrderedAscending) {
            [fm removeItemAtURL:item error:nil];
        }
    }
}

static NSError *prepareExternalCodeCache(NSDictionary *request) {
    NSString *selected = request[@"selected"];
    NSString *container = request[@"selectedContainer"];
    if (!selected.length || !container.length || ![selected.lastPathComponent isEqual:selected] || ![container.lastPathComponent isEqual:container] ||
        [@[@".", @".."] containsObject:selected] || [@[@".", @".."] containsObject:container]) {
        return [NSError errorWithDomain:@"iOSVMWindow" code:5 userInfo:@{NSLocalizedDescriptionKey:@"测试窗口的 App 或容器路径无效。"}];
    }
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *home = request[@"lcHomePath"];
    if (!home.isAbsolutePath) return [NSError errorWithDomain:@"iOSVMWindow" code:5 userInfo:@{NSLocalizedDescriptionKey:@"测试窗口的管理目录无效。"}];
    NSURL *documents = [NSURL fileURLWithPath:[home stringByAppendingPathComponent:@"Documents"] isDirectory:YES];
    NSURL *source = [[documents URLByAppendingPathComponent:@"Applications"] URLByAppendingPathComponent:selected];
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfURL:[source URLByAppendingPathComponent:@"LCAppInfo.plist"]];
    if (![info[@"IOSVMExternallySigned"] boolValue] && ![info[@"IOSVMDeviceSigned"] boolValue]) return nil;
    NSURL *base = [NSURL fileURLWithPath:[NSString stringWithFormat:@"%s/Documents/iOSVMCodeCache", getenv("LP_HOME_PATH")] isDirectory:YES];
    // Unique final name per launch: the publish below is one atomic rename and
    // can never remove or replace a directory another process is still using.
    NSURL *final = [base URLByAppendingPathComponent:[NSString stringWithFormat:@"%@-%@-%@", container, selected, NSUUID.UUID.UUIDString]];
    NSURL *stage = [base URLByAppendingPathComponent:[@".staging-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSError *error = nil;
    NSURL *apps = [stage URLByAppendingPathComponent:@"Applications"];
    NSURL *tweaks = [stage URLByAppendingPathComponent:@"Tweaks"];
    BOOL success = [fm createDirectoryAtURL:apps withIntermediateDirectories:YES attributes:nil error:&error] &&
        [fm createDirectoryAtURL:tweaks withIntermediateDirectories:YES attributes:nil error:&error] &&
        [fm copyItemAtURL:source toURL:[apps URLByAppendingPathComponent:selected] error:&error];
    NSURL *sourceTweaks = [documents URLByAppendingPathComponent:@"Tweaks"];
    NSString *folder = info[@"LCTweakFolder"];
    if (success && folder.length && (![folder.lastPathComponent isEqual:folder] || [@[@".", @".."] containsObject:folder])) {
        success = NO;
        error = [NSError errorWithDomain:@"iOSVMWindow" code:6 userInfo:@{NSLocalizedDescriptionKey:@"测试插件目录名无效。"}];
    }
    NSArray *plannedSources = request[@"IOSVMAccessPlan"][@"pluginSources"];
    if (success && [plannedSources isKindOfClass:NSArray.class]) {
        for (NSDictionary *entry in plannedSources) {
            NSString *name = entry[@"name"], *path = entry[@"path"];
            if (![IOSVMGuestAccess validComponent:name] || ![path isKindOfClass:NSString.class] ||
                ![name isEqual:path.lastPathComponent]) {
                success = NO;
                error = [NSError errorWithDomain:@"iOSVMWindow" code:6 userInfo:@{NSLocalizedDescriptionKey:@"插件授权清单无效。"}];
                break;
            }
            if (![fm copyItemAtPath:path toPath:[[tweaks URLByAppendingPathComponent:name] path] error:&error]) { success = NO; break; }
        }
    } else if (success && [fm fileExistsAtPath:sourceTweaks.path]) {
        NSArray<NSURL *> *items = [fm contentsOfDirectoryAtURL:sourceTweaks includingPropertiesForKeys:nil options:0 error:&error];
        if (!items) success = NO;
        for (NSURL *item in items) {
            NSString *name = item.lastPathComponent;
            BOOL selectedFolder = folder.length && [name isEqual:folder];
            BOOL globalPlugin = [name hasSuffix:@".dylib"] || [name hasSuffix:@".framework"] ||
                [name hasSuffix:@".config"] || [name isEqual:@"iOSVMPlugins.json"];
            if (selectedFolder || globalPlugin) {
                if (![fm copyItemAtURL:item toURL:[tweaks URLByAppendingPathComponent:name] error:&error]) { success = NO; break; }
            }
        }
    }
    if (success) success = [fm moveItemAtURL:stage toURL:final error:&error];
    if (success) evictAgedCodeCacheEntries(fm, base, final);
    if (!success) {
        [fm removeItemAtURL:stage error:nil];
        return error ?: [NSError errorWithDomain:@"iOSVMWindow" code:7 userInfo:@{NSLocalizedDescriptionKey:@"无法准备测试窗口的代码缓存。"}];
    }
    setenv("LC_CODE_CACHE_ROOT", final.path.fileSystemRepresentation, 1);
    return nil;
}

extern int LiveContainerMain(int argc, char *argv[]);
static char **_envp, **_apple = NULL;
int LiveProcessMain(int argc, char *argv[]) {
    // Let NSExtensionContext initialize, once it's done it will call CFRunLoopStop
    CFRunLoopRun();
    // Ensure app info is delivered
    NSDictionary *appInfo = LiveProcessHandler.retrievedAppInfo;
    NSCAssert(appInfo, @"Failed to retrieve app info");

    // Check if we received a request to execute a custom payload
    NSString *customPayloadDylib = appInfo[@"customPayloadDylib"];
    if(customPayloadDylib) {
        void *handle = dlopen(customPayloadDylib.fileSystemRepresentation, RTLD_LAZY);
        if (!handle) {
            const char *dlErr = dlerror();
            [[LiveProcessHandler extensionContext] cancelRequestWithError:[NSError errorWithDomain:@"iOSVMWindow" code:9 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"无法加载自定义 payload：%s", dlErr ? dlErr : "未知错误"]}]];
            return 1;
        }

        NSString *customPayloadEntry = appInfo[@"customPayloadEntry"];
        int (*payloadEntry)(int, char **, char **, char **) = customPayloadEntry ? dlsym(handle, customPayloadEntry.UTF8String) : NULL;
        if (!payloadEntry) {
            [[LiveProcessHandler extensionContext] cancelRequestWithError:[NSError errorWithDomain:@"iOSVMWindow" code:9 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"自定义 payload 中找不到入口点 %@", customPayloadEntry ?: @"(nil)"]}]];
            return 1;
        }
        return payloadEntry(argc, argv, _envp, _apple);
    }
    
    NSLog(@"[iOSVM] LiveProcess received a Guest launch request");
    // Set LiveContainer's home path
    setenv("LP_HOME_PATH", getenv("HOME"), 1);
    const char *overrideHomePath = [appInfo[@"lcHomePath"] fileSystemRepresentation];
    if(overrideHomePath) setenv("LC_HOME_PATH", overrideHomePath, 1);
    // Pass selected app info to user defaults
    NSUserDefaults *lcUserDefaults = NSUserDefaults.standardUserDefaults;
    [lcUserDefaults setObject:appInfo[@"hostUrlScheme"] forKey:@"hostUrlScheme"];
    [lcUserDefaults setObject:appInfo[@"launchAppUrlScheme"] forKey:@"launchAppUrlScheme"];
    [lcUserDefaults setObject:appInfo[@"selected"] forKey:@"selected"];
    [lcUserDefaults setObject:appInfo[@"selectedContainer"] forKey:@"selectedContainer"];
    
    bool access = false;
    NSDictionary *accessPlan = appInfo[@"IOSVMAccessPlan"];
    NSArray<NSURL *> *authorizedURLs = nil;
    if (accessPlan) {
        NSError *accessError = nil;
        authorizedURLs = [IOSVMGuestAccess consumePlan:accessPlan error:&accessError];
        if (!authorizedURLs) { [[LiveProcessHandler extensionContext] cancelRequestWithError:accessError]; return 1; }
        access = YES;
        NSString *launch = appInfo[@"IOSVMLaunchID"];
        if (![[NSUUID alloc] initWithUUIDString:launch ?: @""]) {
            [IOSVMGuestAccess releaseAccess:authorizedURLs];
            [[LiveProcessHandler extensionContext] cancelRequestWithError:[NSError errorWithDomain:@"iOSVMWindow" code:4 userInfo:@{NSLocalizedDescriptionKey:@"启动标识无效。"}]];
            return 1;
        }
        NSString *folder = [accessPlan[@"dataPath"] stringByAppendingPathComponent:@"Library/iOSVM/Access"];
        [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil];
        NSDictionary *receipt = @{@"id":launch,@"pid":@(getpid()),@"bundle":appInfo[@"selected"],@"container":appInfo[@"selectedContainer"]};
        NSData *receiptData = [NSJSONSerialization dataWithJSONObject:receipt options:0 error:nil];
        NSString *receiptPath = [folder stringByAppendingPathComponent:[launch stringByAppendingString:@".json"]];
        [receiptData writeToFile:receiptPath options:NSDataWritingAtomic error:nil];
        [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions:@0600} ofItemAtPath:receiptPath error:nil];
        NSArray *old = [[NSFileManager.defaultManager contentsOfDirectoryAtPath:folder error:nil] sortedArrayUsingSelector:@selector(compare:)];
        for (NSUInteger i=0; i+20<old.count; i++) if (![old[i] isEqual:[launch stringByAppendingString:@".json"]] && [[old[i] pathExtension] isEqual:@"json"]) [NSFileManager.defaultManager removeItemAtPath:[folder stringByAppendingPathComponent:old[i]] error:nil];
    }
    NSArray* bookmarks = [appInfo[@"bookmarks"] isKindOfClass:NSArray.class] ? appInfo[@"bookmarks"] : @[];
    NSMutableArray<NSURL *>* bookmarkedUrls = [NSMutableArray array];
    for(int i = 0; !accessPlan && i < bookmarks.count; i++) {
        bool isStale = false;
        NSError* error = nil;
        if (![bookmarks[i] isKindOfClass:NSData.class]) continue;
        NSURL *url = [NSURL URLByResolvingBookmarkData:bookmarks[i] options:0 relativeToURL:nil bookmarkDataIsStale:&isStale error:&error];
        if (!url || isStale) continue;
        [bookmarkedUrls addObject:url];
        // Accumulate instead of overwrite: earlier bookmarks must keep their
        // access grant for the lifetime of this process.
        if ([url startAccessingSecurityScopedResource]) access = true;
    }
    
    if (![appInfo[@"selected"] isEqualToString:@"builtinSideStore"]) {
        NSError *cacheError = prepareExternalCodeCache(appInfo);
        if (cacheError) {
            [[LiveProcessHandler extensionContext] cancelRequestWithError:cacheError];
            return 1;
        }
    }
    if ([appInfo[@"selected"] isEqualToString:@"builtinSideStore"]) {
        if(access && bookmarkedUrls.count > 0) {
            [lcUserDefaults setObject:bookmarkedUrls.firstObject.path forKey:@"specifiedSideStoreContainerPath"];
        }
        NSXPCListenerEndpoint* endpoint = appInfo[@"endpoint"];

        NSXPCConnection* connection = [[NSXPCConnection alloc] initWithListenerEndpoint:endpoint];
        connection.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol:@protocol(RefreshServer)];
        connection.interruptionHandler = ^{
            NSLog(@"interrupted!!!");
        };
        
        [connection activate];
        
        NSObject<RefreshServer>* proxy = [connection remoteObjectProxy];
        LiveProcessSideStoreHandler.shared.server = proxy;
        LiveProcessSideStoreHandler.shared.connection = connection;
        
    }

    
    int result = LiveContainerMain(argc, argv);
    [IOSVMGuestAccess releaseAccess:authorizedURLs];
    return result;
}

// this is our fake UIApplicationMain called from _xpc_objc_uimain (xpc_main)
__attribute__((visibility("default")))
int UIApplicationMain(int argc, char * argv[], NSString * principalClassName, NSString * delegateClassName) {
    return LiveProcessMain(argc, argv);
}

// NSExtensionMain will load UIKit and call UIApplicationMain, so we need to redirect it to our fake one
static void* (*orig_dlopen)(void* dyldApiInstancePtr, const char* path, int mode);
static void* hook_dlopen(void* dyldApiInstancePtr, const char* path, int mode) {
    const char *UIKitFrameworkPath = "/System/Library/Frameworks/UIKit.framework/UIKit";
    if(path && !strncmp(path, UIKitFrameworkPath, strlen(UIKitFrameworkPath))) {
        // switch back to original dlopen
        performHookDyldApi("dlopen", 2, (void**)&orig_dlopen, orig_dlopen);
        // FIXME: may be incompatible with jailbreak tweaks?
        return RTLD_MAIN_ONLY;
    } else {
        __attribute__((musttail)) return orig_dlopen(dyldApiInstancePtr, path, mode);
    }
}

// Extension entry point
int NSExtensionMain(int argc, char *argv[], char *envp[], char *apple[]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wundeclared-selector"
    method_setImplementation(class_getInstanceMethod(NSClassFromString(@"NSXPCDecoder"), @selector(_validateAllowedClass:forKey:allowingInvocations:)), (IMP)hook_do_nothing);
#pragma clang diagnostic pop
    // hook dlopen UIKit
    performHookDyldApi("dlopen", 2, (void**)&orig_dlopen, hook_dlopen);
    // call the real one
    _envp = envp;
    _apple = apple;
    int (*orig_NSExtensionMain)(int argc, char * argv[]) = dlsym(RTLD_NEXT, "NSExtensionMain");
    return orig_NSExtensionMain(argc, argv);
}
