#import <Foundation/Foundation.h>
#import "../../LiveContainer/IOSVMGuestSession.h"
#include <mach/mach.h>

static void require(BOOL value,NSString *message) {if(!value){fprintf(stderr,"FAIL: %s\n",message.UTF8String);exit(1);}}
static void writePlist(NSDictionary *value,NSURL *url){require([value writeToURL:url atomically:YES],@"cannot write fixture plist");}
int main(void){@autoreleasepool{
    NSFileManager *fm=NSFileManager.defaultManager;
    NSURL *root=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
    NSURL *journal=[root URLByAppendingPathComponent:@"journal"];
    IOSVMProcessRegistry *registry=[[IOSVMProcessRegistry alloc] initWithJournalDirectory:journal];
    __block NSUInteger winners=0;__block NSString *first=nil;
    dispatch_apply(16,dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^(size_t i){
        NSError *e=nil;NSString *launch=[registry beginBundle:@"test.app" container:@"data" error:&e];
        @synchronized(registry){if(launch){winners++;first=launch;}else require(e!=nil,@"duplicate launch has no error");}
    });
    require(winners==1,@"concurrent reservations did not have a single owner");
    require([registry isBundleBusy:@"test.app"] && [registry isContainerBusy:@"data"],@"preparing launch is not busy");
    require(![registry updateLaunch:first state:@"running" details:@{@"pid":@123}],@"invalid state transition accepted");
    require(![registry updateLaunch:first state:@"spawned" details:@{@"pid":@0}],@"zero pid accepted");
    require([registry updateLaunch:first state:@"spawned" details:@{@"pid":@123}],@"spawn transition failed");
    require([registry updateLaunch:first state:@"running" details:@{}],@"running transition failed");
    require([registry updateLaunch:first state:@"stopping" details:@{}],@"stopping transition failed");
    require(![registry updateLaunch:first state:@"running" details:@{}],@"stopped process resurrected");
    require([registry finishLaunch:first state:@"exited" reason:@"closed"],@"finish failed");
    NSString *second=[registry beginBundle:@"test.app" container:@"data" error:nil];require(second!=nil,@"container was not released");
    require(![registry finishLaunch:first state:@"failed" reason:@"late callback"],@"duplicate finish accepted");
    require([[registry activeRecordForContainer:@"data"][@"id"] isEqual:second],@"old callback ended a new launch");
    NSMutableDictionary *copy=[[registry recordForLaunch:second] mutableCopy];copy[@"state"]=@"exited";
    require([registry isContainerBusy:@"data"],@"mutable snapshot escaped registry lock");
    IOSVMProcessRegistry *restarted=[[IOSVMProcessRegistry alloc] initWithJournalDirectory:journal];
    require([[[restarted recordForLaunch:second] objectForKey:@"state"] isEqual:@"unconfirmed"] && ![restarted hasActiveProcesses],@"host restart fabricated a confirmed process state");
    [registry finishLaunch:second state:@"failed" reason:@"test done"];
    audit_token_t token={0};mach_msg_type_number_t count=TASK_AUDIT_TOKEN_COUNT;
    if(task_info(mach_task_self(),TASK_AUDIT_TOKEN,(task_info_t)&token,&count)==KERN_SUCCESS){
        NSString *owned=[registry beginBundle:@"recovery.app" container:@"recovery" error:nil];
        uint64_t identity=token.val[7]|((uint64_t)token.val[5]<<32);
        require([registry updateLaunch:owned state:@"spawned" details:@{@"pid":@(getpid()),@"auditToken57":@(identity)}],@"own process identity not recorded");
        IOSVMProcessRegistry *recovered=[[IOSVMProcessRegistry alloc] initWithJournalDirectory:journal];
        require([recovered isContainerBusy:@"recovery"] && [[[recovered recordForLaunch:owned] objectForKey:@"state"] isEqual:@"orphaned"],@"live recorded identity lost its reservation after host recovery");
        [registry finishLaunch:owned state:@"exited" reason:@"test done"];
        printf("PASS: live audit identity retains its reservation after host recovery\n");
    }
    for(NSUInteger i=0;i<80;i++){NSString *l=[registry beginBundle:@"test.app" container:@"data" error:nil];require(l!=nil,@"history quota blocked released container");[registry finishLaunch:l state:@"exited" reason:@"done"];}
    require([fm contentsOfDirectoryAtURL:journal includingPropertiesForKeys:nil options:0 error:nil].count<=64,@"journal retention exceeded");

    NSURL *docs=[root URLByAppendingPathComponent:@"Documents"],*app=[docs URLByAppendingPathComponent:@"Applications/test.app"],*data=[docs URLByAppendingPathComponent:@"Data/Application/data"];
    NSURL *tweaks=[docs URLByAppendingPathComponent:@"Tweaks"],*selected=[tweaks URLByAppendingPathComponent:@"Selected"],*unselected=[tweaks URLByAppendingPathComponent:@"OtherApp"];
    for(NSURL *dir in @[app,data,selected,unselected,[docs URLByAppendingPathComponent:@"iOSVM/NetworkSettings"]])require([fm createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil],@"fixture directory failed");
    writePlist(@{@"IOSVMDeviceSigned":@YES,@"LCTweakFolder":@"Selected"},[app URLByAppendingPathComponent:@"LCAppInfo.plist"]);
    writePlist(@{@"CFBundleIdentifier":@"test.bundle"},[app URLByAppendingPathComponent:@"Info.plist"]);
    writePlist(@{@"appIdentifier":@"test.bundle"},[data URLByAppendingPathComponent:@"LCContainerInfo.plist"]);
    [@"test" writeToURL:[tweaks URLByAppendingPathComponent:@"Global.dylib"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [@"{}" writeToURL:[docs URLByAppendingPathComponent:@"iOSVM/NetworkSettings/test.app.json"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [fm createSymbolicLinkAtURL:[tweaks URLByAppendingPathComponent:@"TweakLoader.dylib"] withDestinationURL:[root URLByAppendingPathComponent:@"retired-host/TweakLoader.dylib"] error:nil];
    NSError *error=nil;NSDictionary *plan=[IOSVMGuestAccess planForApplication:app data:data documents:docs shared:NO shareAll:NO error:&error];
    require(plan!=nil,error.description);
    require([plan[@"mode"] isEqual:@"scoped"],@"signed guest not scoped");
    NSArray *caps=plan[@"capabilities"];
    require(caps.count==5,@"unexpected resource list");
    require([plan[@"pluginSources"] count]==2,@"plugin source allowlist includes another app");
    for(NSDictionary *cap in caps){
        require(![cap[@"path"] hasSuffix:@"/OtherApp"] && ![cap[@"path"] hasSuffix:@"/Tweaks"],@"grant includes entire plugin root or unrelated app");
        require([cap[@"access"] isEqual:[cap[@"role"] isEqual:@"data"]?@"readWrite":@"readOnly"],@"wrong file access mode");
    }
    NSDictionary *fakeIssued=@{@"capabilities":@[@{@"role":@"application",@"path":@"/fixture",@"access":@"readOnly",@"bookmark":[@"secret" dataUsingEncoding:NSUTF8StringEncoding],@"extensionToken":[@"secret-token" dataUsingEncoding:NSUTF8StringEncoding]}]};
    require([IOSVMGuestAccess publicCapabilities:fakeIssued][0][@"bookmark"]==nil,@"bookmark leaked into diagnostics");
    require([IOSVMGuestAccess publicCapabilities:fakeIssued][0][@"extensionToken"]==nil,@"extension token leaked into diagnostics");
    require(![IOSVMGuestAccess consumePlan:@{@"version":@1,@"capabilities":@[@{@"role":@"application",@"path":@"/fixture",@"access":@"readOnly"}]} error:&error],@"missing bookmark silently accepted");
    writePlist(@{@"appIdentifier":@"other.bundle"},[data URLByAppendingPathComponent:@"LCContainerInfo.plist"]);
    require(![IOSVMGuestAccess planForApplication:app data:data documents:docs shared:NO shareAll:NO error:&error],@"wrong container binding accepted");
    writePlist(@{@"appIdentifier":@"test.bundle"},[data URLByAppendingPathComponent:@"LCContainerInfo.plist"]);
    NSURL *link=[tweaks URLByAppendingPathComponent:@"Escape.dylib"];
    [fm createSymbolicLinkAtURL:link withDestinationURL:[root URLByAppendingPathComponent:@"outside"] error:nil];
    require(![IOSVMGuestAccess planForApplication:app data:data documents:docs shared:NO shareAll:NO error:&error],@"external plugin symlink accepted");
    [fm removeItemAtURL:link error:nil];
    NSDictionary *legacy=[IOSVMGuestAccess planForApplication:app data:data documents:docs shared:NO shareAll:YES error:&error];
    require([legacy[@"mode"] isEqual:@"legacyAllDocuments"],@"explicit broad-sharing compatibility was not recorded");
    require(![IOSVMGuestAccess validComponent:@"../data"] && ![IOSVMGuestAccess validComponent:@".."],@"path traversal component accepted");
    NSURL *ownedNetwork=[IOSVMGuestAccess networkSettingsDirectoryForDocuments:docs];
    [fm createDirectoryAtURL:ownedNetwork withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *ownedFile=[ownedNetwork URLByAppendingPathComponent:@"test.app.json"];
    [@"{\"version\":1}" writeToURL:ownedFile atomically:YES encoding:NSUTF8StringEncoding error:nil];
    require([[IOSVMGuestAccess networkSettingsForBundle:@"test.app" documents:docs].path isEqual:ownedFile.path],@"new network settings did not take precedence");
    NSDictionary *ownedPlan=[IOSVMGuestAccess planForApplication:app data:data documents:docs shared:NO shareAll:NO error:&error];
    NSArray *networkCaps=[ownedPlan[@"capabilities"] filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"role == 'networkSettings'"]];
    require(networkCaps.count==1 && [networkCaps[0][@"path"] isEqual:ownedFile.URLByResolvingSymlinksInPath.path] && [networkCaps[0][@"access"] isEqual:@"readOnly"],@"new settings path was not granted read-only");
    [fm removeItemAtURL:root error:nil];
    printf("PASS: concurrent reservation, state transitions, stale callbacks, immutable snapshots, restart uncertainty, journal quota, per-guest grants, container binding, symlinks, bookmark redaction and explicit legacy mode\n");
}return 0;}
