// SPDX-License-Identifier: AGPL-3.0-or-later
// Adapted in design from Nyxian's PEProcessManager and sandbox permission registry.
// This is a host launch registry and OS bookmark policy, not a virtual kernel.
#import "IOSVMGuestSession.h"
#include <unistd.h>
#include <errno.h>
#include <mach/mach.h>
#include <dlfcn.h>
#import <objc/runtime.h>
extern int csops_audittoken(pid_t,unsigned int,void *,size_t,audit_token_t *);

NSNotificationName const IOSVMProcessesDidChange = @"IOSVMProcessesDidChange";
static NSError *guestError(NSString *message) {
    return [NSError errorWithDomain:@"IOSVMGuestSession" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
}
static BOOL activeState(NSString *state) {
    return [@[@"preparing",@"spawned",@"running",@"stopping",@"orphaned"] containsObject:state];
}
static BOOL recordedIdentityAlive(NSDictionary *record) {
    if(![record[@"auditToken57"] isKindOfClass:NSNumber.class] || ![record[@"pid"] isKindOfClass:NSNumber.class])return NO;
    uint64_t identity=[record[@"auditToken57"] unsignedLongLongValue];
    if (!identity || [record[@"pid"] unsignedIntValue]!=(uint32_t)(identity>>32)) return NO;
    audit_token_t token={0};token.val[5]=(uint32_t)(identity>>32);token.val[7]=(uint32_t)identity;
    errno=0;
    if (csops_audittoken(token.val[5],0,NULL,0,&token)==0) {
        // On success the token describes whichever process currently owns this
        // PID. A mismatching unique PID (val[7]) means the recorded process
        // exited and the PID was reused, so the session is dead even though
        // the PID itself is alive.
        return token.val[7]==(uint32_t)identity;
    }
    return errno!=ESRCH;
}

@implementation IOSVMProcessRegistry {
    NSURL *_directory;
    NSMutableDictionary<NSString *, NSMutableDictionary *> *_records;
    NSTimer *_recoveryTimer;
}
+ (instancetype)shared {
    static IOSVMProcessRegistry *registry; static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURL *documents=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].lastObject;
        registry=[[self alloc] initWithJournalDirectory:[documents URLByAppendingPathComponent:@"iOSVM/Processes"]];
    });return registry;
}
- (instancetype)initWithJournalDirectory:(NSURL *)directory {
    if (!(self=[super init])) return nil;
    _directory=directory;_records=[NSMutableDictionary new];
    [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil];
    // Load the most recently modified records first so that, when the 64-record
    // cap is hit, the freshest sessions are the ones kept (UUID name order is
    // unrelated to age).
    NSArray *files=[[NSFileManager.defaultManager contentsOfDirectoryAtURL:directory includingPropertiesForKeys:@[NSURLContentModificationDateKey] options:0 error:nil] sortedArrayUsingComparator:^NSComparisonResult(NSURL *a,NSURL *b){
        NSDate *ma=nil,*mb=nil;
        [a getResourceValue:&ma forKey:NSURLContentModificationDateKey error:nil];
        [b getResourceValue:&mb forKey:NSURLContentModificationDateKey error:nil];
        if(ma&&mb) return [mb compare:ma];
        return [b.lastPathComponent compare:a.lastPathComponent];
    }];
    // Historical active states are unconfirmed after a host restart, never proof of a crash.
    for (NSURL *file in files) {
        if (![file.pathExtension isEqual:@"json"] || _records.count>=64) continue;
        NSData *data=[NSData dataWithContentsOfURL:file];
        NSDictionary *value=data && data.length<=262144?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
        if (![value isKindOfClass:NSDictionary.class] || ![value[@"id"] isKindOfClass:NSString.class] ||
            ![[NSUUID alloc] initWithUUIDString:value[@"id"]] || ![IOSVMGuestAccess validComponent:value[@"bundle"]] ||
            ![IOSVMGuestAccess validComponent:value[@"container"]]) continue;
        NSMutableDictionary *record=value.mutableCopy;
        _records[record[@"id"]]=record;
        if (activeState(record[@"state"])) {
            BOOL held=recordedIdentityAlive(record);
            record[@"state"]=held?@"orphaned":@"unconfirmed";
            record[@"reason"]=held?@"旧进程身份仍有效；保留容器占用。请关闭旧窗口，必要时从系统结束宿主后重新打开。":@"管理进程重新启动；旧会话的运行结果未经确认。";
            [self persist:record];
        }
    }
    __weak typeof(self) weakSelf=self;
    void (^installRecovery)(void)=^{
      IOSVMProcessRegistry *registry=weakSelf;if(!registry)return;
      registry->_recoveryTimer=[NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer){
        IOSVMProcessRegistry *owner=weakSelf;
        if(!owner){[timer invalidate];return;}
        @synchronized(owner){
            for(NSMutableDictionary *r in owner->_records.allValues) if([r[@"state"] isEqual:@"orphaned"] && !recordedIdentityAlive(r))
                [owner finishLaunch:r[@"id"] state:@"exited" reason:@"恢复后观察到旧进程身份失效；已释放容器。"];
        }
      }];
    };
    if(NSThread.isMainThread)installRecovery();else dispatch_async(dispatch_get_main_queue(),installRecovery);
    return self;
}
- (void)persist:(NSMutableDictionary *)record {
    record[@"updatedAt"]=@(NSDate.date.timeIntervalSince1970);
    NSData *data=[NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingSortedKeys error:nil];
    NSError *error=nil;
    NSURL *file=[_directory URLByAppendingPathComponent:[record[@"id"] stringByAppendingString:@".json"]];
    if (![data writeToURL:file options:NSDataWritingAtomic error:&error]) record[@"journalError"]=error.localizedDescription ?: @"无法保存运行记录。";
    else [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions:@0600} ofItemAtPath:file.path error:nil];
    NSDictionary *snapshot=[self snapshot:record];
    dispatch_async(dispatch_get_main_queue(), ^{[NSNotificationCenter.defaultCenter postNotificationName:IOSVMProcessesDidChange object:self userInfo:snapshot];});
}
- (NSDictionary *)snapshot:(NSDictionary *)record {
    // No mutable nested containers escape the registry lock.
    NSData *data=[NSJSONSerialization dataWithJSONObject:record options:0 error:nil];
    return data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:@{};
}
- (NSString *)beginBundle:(NSString *)bundle container:(NSString *)container error:(NSError **)error {
    @synchronized(self) {
        if (![IOSVMGuestAccess validComponent:bundle] || ![IOSVMGuestAccess validComponent:container]) {if(error)*error=guestError(@"App 或数据容器名称无效。");return nil;}
        for (NSDictionary *r in _records.allValues) if (activeState(r[@"state"]) && [r[@"container"] isEqual:container]) {if(error)*error=guestError(@"此数据容器已有启动或运行中的测试进程。");return nil;}
        if (_records.count>=64) {
            NSArray *old=[_records.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){return [a[@"startedAt"] compare:b[@"startedAt"]];}];
            for (NSDictionary *r in old) {
                if (activeState(r[@"state"])) continue;
                [_records removeObjectForKey:r[@"id"]];
                [NSFileManager.defaultManager removeItemAtURL:[_directory URLByAppendingPathComponent:[r[@"id"] stringByAppendingString:@".json"]] error:nil];
                if (_records.count<64) break;
            }
        }
        if (_records.count>=64) {if(error)*error=guestError(@"同时运行的测试进程过多。");return nil;}
        NSString *launch=NSUUID.UUID.UUIDString;
        NSMutableDictionary *r=[@{@"id":launch,@"bundle":bundle,@"container":container,@"state":@"preparing",@"startedAt":@(NSDate.date.timeIntervalSince1970),@"pid":@0,@"capabilities":@[]} mutableCopy];
        _records[launch]=r;[self persist:r];return launch;
    }
}
- (BOOL)updateLaunch:(NSString *)launch state:(NSString *)state details:(NSDictionary *)details {
    if (!launch.length) return NO;
    @synchronized(self) {
        NSMutableDictionary *r=_records[launch];if (!r || !activeState(r[@"state"])) return NO;
        NSString *old=r[@"state"];
        BOOL valid=[old isEqual:state] || ([old isEqual:@"preparing"] && [state isEqual:@"spawned"]) || ([old isEqual:@"spawned"] && [state isEqual:@"running"]) || ([state isEqual:@"stopping"] && activeState(old));
        if (!valid || ![NSJSONSerialization isValidJSONObject:details]) return NO;
        if ([state isEqual:@"spawned"] || [state isEqual:@"running"]) {
            id pid=details[@"pid"] ?: r[@"pid"];
            if (![pid isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)pid)==CFBooleanGetTypeID() || [pid longLongValue]<=0 || [pid longLongValue]>INT_MAX || [pid doubleValue]!=[pid longLongValue]) return NO;
        }
        r[@"state"]=state;
        for (NSString *key in @[@"pid",@"auditToken57",@"authorizationMode",@"capabilities",@"authorizationConsumed",@"stopReason"]) if (details[key]) r[key]=details[key];
        [self persist:r];return YES;
    }
}
- (BOOL)finishLaunch:(NSString *)launch state:(NSString *)state reason:(NSString *)reason {
    if (!launch.length) return NO;
    @synchronized(self) {
        NSMutableDictionary *r=_records[launch];
        if (!r || !activeState(r[@"state"]) || ![@[@"exited",@"failed",@"interrupted"] containsObject:state]) return NO;
        r[@"state"]=state;r[@"reason"]=reason;r[@"endedAt"]=@(NSDate.date.timeIntervalSince1970);[self persist:r];return YES;
    }
}
- (NSDictionary *)recordForLaunch:(NSString *)launch { if(!launch.length)return nil;@synchronized(self) {return _records[launch]?[self snapshot:_records[launch]]:nil;} }
- (NSDictionary *)activeRecordForContainer:(NSString *)container { @synchronized(self) {for(NSDictionary *r in _records.allValues)if(activeState(r[@"state"])&&[r[@"container"] isEqual:container])return [self snapshot:r];return nil;} }
- (NSArray *)recordsForBundle:(NSString *)bundle { @synchronized(self) {
    NSMutableArray *result=[NSMutableArray new];for(NSDictionary *r in _records.allValues)if([r[@"bundle"] isEqual:bundle])[result addObject:[self snapshot:r]];
    return [result sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){return [b[@"startedAt"] compare:a[@"startedAt"]];}];
} }
- (BOOL)isBundleBusy:(NSString *)bundle { @synchronized(self) {for(NSDictionary *r in _records.allValues)if(activeState(r[@"state"])&&[r[@"bundle"] isEqual:bundle])return YES;return NO;} }
- (BOOL)isContainerBusy:(NSString *)container {return [self activeRecordForContainer:container]!=nil;}
- (BOOL)hasActiveProcesses { @synchronized(self) {for(NSDictionary *r in _records.allValues)if(activeState(r[@"state"]))return YES;return NO;} }
@end

static NSString *canonical(NSURL *url) {return url.URLByStandardizingPath.URLByResolvingSymlinksInPath.path;}
static BOOL containsPath(NSString *root,NSString *path) {return [path isEqual:root] || [path hasPrefix:[root stringByAppendingString:@"/"]];}
static BOOL existsDirectory(NSURL *url) {BOOL directory=NO;return [NSFileManager.defaultManager fileExistsAtPath:url.path isDirectory:&directory]&&directory;}
static char accessLeaseKey;
typedef int64_t (*ConsumeExtension)(const char *);
typedef int (*ReleaseExtension)(int64_t);
static void *sandboxSymbol(const char *name) {
    void *symbol=dlsym(RTLD_DEFAULT,name);
    if(!symbol){void *library=dlopen("/usr/lib/system/libsystem_sandbox.dylib",RTLD_LAZY);if(library)symbol=dlsym(library,name);}
    return symbol;
}
@interface IOSVMAccessLease : NSObject
@property NSMutableArray<NSNumber *> *handles;
@property NSMutableArray<NSURL *> *urls;
- (void)invalidate;
@end
@implementation IOSVMAccessLease
- (instancetype)init {if((self=[super init])){_handles=[NSMutableArray new];_urls=[NSMutableArray new];}return self;}
- (void)invalidate {
    ReleaseExtension release=sandboxSymbol("sandbox_extension_release");
    for(NSNumber *handle in self.handles)if(release)release(handle.longLongValue);
    [self.handles removeAllObjects];
    for(NSURL *url in self.urls)[url stopAccessingSecurityScopedResource];
    [self.urls removeAllObjects];
}
- (void)dealloc {[self invalidate];}
@end

@implementation IOSVMGuestAccess
+ (NSURL *)networkSettingsDirectoryForDocuments:(NSURL *)documents {
    return [documents URLByAppendingPathComponent:@"iOSVM/NetworkSettingsV2" isDirectory:YES];
}
+ (NSURL *)networkSettingsForBundle:(NSString *)bundle documents:(NSURL *)documents {
    NSString *name=[bundle stringByAppendingString:@".json"];
    NSURL *owned=[[self networkSettingsDirectoryForDocuments:documents] URLByAppendingPathComponent:name];
    if([NSFileManager.defaultManager fileExistsAtPath:owned.path])return owned;
    return [[documents URLByAppendingPathComponent:@"iOSVM/NetworkSettings"] URLByAppendingPathComponent:name];
}
+ (BOOL)validComponent:(NSString *)value {
    return [value isKindOfClass:NSString.class] && value.length>0 && [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding]<=255 && [value.lastPathComponent isEqual:value] && ![@[@".",@".."] containsObject:value] && [value rangeOfString:[NSString stringWithFormat:@"%C",(unichar)0]].location==NSNotFound;
}
+ (NSDictionary *)planForApplication:(NSURL *)application data:(NSURL *)data documents:(NSURL *)documents shared:(BOOL)shared shareAll:(BOOL)shareAll error:(NSError **)error {
    NSFileManager *fm=NSFileManager.defaultManager;
    NSDictionary *metadata=[NSDictionary dictionaryWithContentsOfURL:[application URLByAppendingPathComponent:@"LCAppInfo.plist"]] ?: @{};
    NSDictionary *info=[NSDictionary dictionaryWithContentsOfURL:[application URLByAppendingPathComponent:@"Info.plist"]] ?: @{};
    BOOL cached=[metadata[@"IOSVMDeviceSigned"] boolValue] || [metadata[@"IOSVMExternallySigned"] boolValue];
    BOOL scoped=cached && !shared && !shareAll;
    NSString *problem=nil;
    if (![self validComponent:application.lastPathComponent] || ![self validComponent:data.lastPathComponent] || !existsDirectory(application) || !existsDirectory(data)) problem=@"App 或注册数据容器不存在。";
    NSString *owner=metadata[@"LCOrignalBundleIdentifier"] ?: info[@"LCBundleIdentifier"] ?: info[@"CFBundleIdentifier"];
    NSDictionary *binding=[NSDictionary dictionaryWithContentsOfURL:[data URLByAppendingPathComponent:@"LCContainerInfo.plist"]];
    if (scoped && (![owner isKindOfClass:NSString.class] || !owner.length || ![binding[@"appIdentifier"] isEqual:owner])) problem=@"数据容器与目标 App 的登记信息不匹配。";
    if (!shared && ![canonical(application) isEqual:[canonical([documents URLByAppendingPathComponent:@"Applications"]) stringByAppendingPathComponent:application.lastPathComponent]]) problem=@"App 路径包含未经允许的链接。";
    if (containsPath([documents URLByAppendingPathComponent:@"Data/Application"].URLByStandardizingPath.path,data.URLByStandardizingPath.path) && ![canonical(data) isEqual:[canonical([documents URLByAppendingPathComponent:@"Data/Application"]) stringByAppendingPathComponent:data.lastPathComponent]]) problem=@"数据容器链接指向未登记的位置。";
    if(problem){if(error)*error=guestError(problem);return nil;}
    NSMutableArray *capabilities=[NSMutableArray new],*sources=[NSMutableArray new];
    void (^grant)(NSURL *,NSString *,NSString *)=^(NSURL *url,NSString *role,NSString *access){[capabilities addObject:@{@"path":canonical(url),@"role":role,@"access":access}];};
    if(shareAll) grant(documents,@"legacyDocuments",@"readWrite");
    else if(!shared){grant(application,@"application",scoped?@"readOnly":@"readWrite");grant(data,@"data",@"readWrite");}
    if(shared) {grant(application,@"sharedApplication",@"systemSharedContainer");grant(data,@"sharedData",@"systemSharedContainer");}
    NSURL *tweaks=[documents URLByAppendingPathComponent:@"Tweaks"];
    NSString *folder=metadata[@"LCTweakFolder"];
    if(folder && ![self validComponent:folder]){if(error)*error=guestError(@"选中的插件目录名无效。");return nil;}
    if(existsDirectory(tweaks)) {
        if (!scoped && !shareAll) grant(tweaks,@"legacyTweaks",@"readWrite");
        NSArray *items=[fm contentsOfDirectoryAtURL:tweaks includingPropertiesForKeys:@[NSURLIsSymbolicLinkKey] options:0 error:error];
        if (!items) return nil;
        for (NSURL *item in items) {
            NSString *name=item.lastPathComponent;
            BOOL selected=folder.length && [folder isEqual:name];
            BOOL global=[@[@"dylib",@"framework",@"config"] containsObject:item.pathExtension] || [name isEqual:@"iOSVMPlugins.json"];
            if (!selected && !global) continue;
            NSNumber *link=nil;[item getResourceValue:&link forKey:NSURLIsSymbolicLinkKey error:nil];
            // Bootstrap manages this link in its own code cache; it must not grant a host framework path.
            if ([name isEqual:@"TweakLoader.dylib"] && link.boolValue) continue;
            if(link.boolValue || !containsPath(canonical(tweaks),canonical(item))){if(error)*error=guestError(@"插件目录包含外部链接，请移除后重试。");return nil;}
            if(scoped) grant(item,selected?@"selectedPlugins":@"globalPlugin",@"readOnly");
            [sources addObject:@{@"path":canonical(item),@"name":name}];
        }
    }
    NSURL *network=[self networkSettingsForBundle:application.lastPathComponent documents:documents];
    if([fm fileExistsAtPath:network.path]) {
        NSString *relative=[network.URLByStandardizingPath.path substringFromIndex:documents.URLByStandardizingPath.path.length+1];
        if(![canonical(network) isEqual:[canonical(documents) stringByAppendingPathComponent:relative]]){if(error)*error=guestError(@"网络配置链接指向未登记的位置。");return nil;}
        grant(network,@"networkSettings",@"readOnly");
    }
    return @{@"version":@1,@"mode":scoped?@"scoped":(shareAll?@"legacyAllDocuments":@"legacyCompatibility"),@"capabilities":capabilities,@"pluginSources":sources,@"dataPath":canonical(data)};
}
+ (NSArray *)publicCapabilities:(NSDictionary *)plan {
    NSMutableArray *result=[NSMutableArray new];
    for(NSDictionary *entry in plan[@"capabilities"]) [result addObject:@{@"path":entry[@"path"],@"role":entry[@"role"],@"access":entry[@"access"]}];
    return result;
}
+ (NSDictionary *)issuePlan:(NSDictionary *)plan error:(NSError **)error {
    NSMutableDictionary *issued=plan.mutableCopy;NSMutableArray *grants=[NSMutableArray new];
    char *(*issue)(const char *,const char *,uint32_t)=sandboxSymbol("sandbox_extension_issue_file");
    for(NSDictionary *entry in plan[@"capabilities"]) {
        NSMutableDictionary *grant=entry.mutableCopy;
        if(![entry[@"access"] isEqual:@"systemSharedContainer"]) {
            if(issue){
                const char *kind=[entry[@"access"] isEqual:@"readOnly"]?"com.apple.app-sandbox.read":"com.apple.app-sandbox.read-write";
                char *token=issue(kind,[entry[@"path"] fileSystemRepresentation],0);
                if(!token){if(error)*error=guestError([NSString stringWithFormat:@"无法签发 %@ 的系统文件授权。",entry[@"role"]]);return nil;}
                grant[@"extensionToken"]=[NSData dataWithBytes:token length:strlen(token)+1];free(token);
                [grants addObject:grant];continue;
            }
            if([plan[@"mode"] isEqual:@"scoped"]){if(error)*error=guestError(@"此系统无法签发明确的只读文件授权；未退回到读写书签。");return nil;}
            NSURLBookmarkCreationOptions options=(1UL<<11);
            if([entry[@"access"] isEqual:@"readOnly"])options|=(1UL<<12);
            NSData *bookmark=[[NSURL fileURLWithPath:entry[@"path"]] bookmarkDataWithOptions:options includingResourceValuesForKeys:nil relativeToURL:nil error:error];
            if(!bookmark)return nil;grant[@"bookmark"]=bookmark;
        }
        [grants addObject:grant];
    }
    issued[@"capabilities"]=grants;return issued;
}
+ (NSArray<NSURL *> *)consumePlan:(NSDictionary *)plan error:(NSError **)error {
    if(![plan isKindOfClass:NSDictionary.class] || ![plan[@"version"] isEqual:@1] || ![plan[@"capabilities"] isKindOfClass:NSArray.class] || [plan[@"capabilities"] count]>512){if(error)*error=guestError(@"启动授权清单无效。");return nil;}
    NSMutableArray<NSURL *> *opened=[NSMutableArray new];
    IOSVMAccessLease *lease=[IOSVMAccessLease new];
    for(NSDictionary *entry in plan[@"capabilities"]) {
        NSString *path=[entry isKindOfClass:NSDictionary.class]?entry[@"path"]:nil;
        NSError *failure=nil;NSURL *url=nil;BOOL stale=NO;
        if(![path isKindOfClass:NSString.class] || !path.isAbsolutePath)failure=guestError(@"授权路径无效。");
        else if([entry[@"access"] isEqual:@"systemSharedContainer"]) {
            if(![NSFileManager.defaultManager isReadableFileAtPath:path])failure=guestError(@"系统共享容器不可访问。");
            else continue;
        } else if([entry[@"extensionToken"] isKindOfClass:NSData.class]) {
            NSData *token=entry[@"extensionToken"];
            ConsumeExtension consume=sandboxSymbol("sandbox_extension_consume");
            if(!consume || token.length<2 || token.length>65536 || ((const char *)token.bytes)[token.length-1]!=0 || strnlen(token.bytes,token.length)!=token.length-1)failure=guestError(@"系统文件授权令牌无效。");
            else {
                int64_t handle=consume(token.bytes);
                if(handle<0)failure=guestError([NSString stringWithFormat:@"无法取得 %@ 的系统文件授权。",entry[@"role"] ?: @"目标"]);
                else {
                    [lease.handles addObject:@(handle)];
                    if(![canonical([NSURL fileURLWithPath:path]) isEqual:path])failure=guestError(@"授权路径在启动期间发生变化。");
                    else continue;
                }
            }
        } else if(![entry[@"bookmark"] isKindOfClass:NSData.class])failure=guestError(@"启动授权缺少安全书签。");
        else {
            url=[NSURL URLByResolvingBookmarkData:entry[@"bookmark"] options:0 relativeToURL:nil bookmarkDataIsStale:&stale error:&failure];
            if(!url || stale || ![canonical(url) isEqual:path])failure=guestError(@"授权书签已失效或路径不匹配，请重新启动目标。");
            else if(![url startAccessingSecurityScopedResource])failure=guestError([NSString stringWithFormat:@"无法取得 %@ 的文件访问权限。",entry[@"role"] ?: @"目标"]);
        }
        if(failure){[lease invalidate];if(error)*error=failure;return nil;}
        [opened addObject:url];
        [lease.urls addObject:url];
    }
    objc_setAssociatedObject(opened,&accessLeaseKey,lease,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return opened;
}
+ (void)releaseAccess:(NSArray<NSURL *> *)access {
    if(!access)return;
    IOSVMAccessLease *lease=objc_getAssociatedObject(access,&accessLeaseKey);[lease invalidate];
    objc_setAssociatedObject(access,&accessLeaseKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
@end
