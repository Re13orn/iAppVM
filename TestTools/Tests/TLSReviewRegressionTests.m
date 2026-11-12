#define IOSVM_TLS_TESTING 1
#import "../../LiveContainer/IOSVMNetwork.m"
#include <stdatomic.h>
void litehook_rebind_symbol(const mach_header_u *h,void *a,void *b,bool (*f)(const mach_header_u *)) {}
static void require(BOOL condition,NSString *message){if(!condition){fprintf(stderr,"FAIL %s\n",message.UTF8String);exit(1);}}
static _Atomic unsigned baseCalls,childCalls;
@interface ReviewParent:NSObject
- (void)run;
- (void)raise;
@end
@implementation ReviewParent
- (void)run {atomic_fetch_add(&baseCalls,1);}
- (void)raise {@throw [NSException exceptionWithName:@"ReviewExpected" reason:nil userInfo:nil];}
@end
@interface ReviewChild:ReviewParent @end
@implementation ReviewChild
- (void)run {require(atomic_fetch_add(&childCalls,1)<1000,@"recursive super dispatch");[super run];}
@end
static void replacement(id object,SEL sel){IMP next=original(object,sel);require(next!=NULL,@"missing bound original");((void(*)(id,SEL))next)(object,sel);}
@interface ReviewDelegate:NSObject<NSURLSessionTaskDelegate> @end
@implementation ReviewDelegate
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition,NSURLCredential *))done {
    done(NSURLSessionAuthChallengeCancelAuthenticationChallenge,nil);
}
@end
static NSArray *files(void){return [NSFileManager.defaultManager contentsOfDirectoryAtPath:tlsIdentityRoot error:nil];}
static NSDictionary *metadata(void){for(NSString *file in files())if([file.pathExtension isEqual:@"json"])return [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[tlsIdentityRoot stringByAppendingPathComponent:file]] options:0 error:nil];return nil;}
int main(int argc,char **argv){@autoreleasepool{
    require(argc==3,@"usage root mode");NSString *root=@(argv[1]),*mode=@(argv[2]);
    [NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
    originals=[NSMutableDictionary new];
    if([mode hasPrefix:@"inheritance"]){
        BOOL childFirst=[mode hasSuffix:@"child-first"];
        hook(childFirst?ReviewChild.class:ReviewParent.class,@selector(run),(IMP)replacement);
        hook(childFirst?ReviewParent.class:ReviewChild.class,@selector(run),(IMP)replacement);
        dispatch_apply(64,dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^(size_t index){
            hook(ReviewChild.class,@selector(run),(IMP)replacement);[[ReviewChild new] run];
        });
        require(baseCalls==64 && childCalls==64,@"super must reach each original exactly once");
        hook(ReviewParent.class,@selector(raise),(IMP)replacement);
        @try{[[ReviewParent new] raise];require(NO,@"expected exception");}@catch(NSException *error){require([error.name isEqual:@"ReviewExpected"],@"unexpected exception");}
        require(activeHookFrame==NULL,@"exception leaked dispatch frame");
    }else if([mode hasPrefix:@"task-"]){
        BOOL capture=[mode isEqual:@"task-capture-on"];
        NSString *settings=[root stringByAppendingPathComponent:@"settings.json"];
        [[NSJSONSerialization dataWithJSONObject:@{@"version":@1,@"capture":@(capture),@"proxyType":@"off",@"tlsBypass":@YES,@"tlsIdentities":@YES} options:0 error:nil] writeToFile:settings atomically:YES];
        NSError *error=nil;require([IOSVMNetwork startWithSettings:settings root:root error:&error],error.description);
        NSURLSession *session=[NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration delegate:nil delegateQueue:nil];
        NSURLSessionTask *task=[session dataTaskWithURL:[NSURL URLWithString:@"https://fixture.invalid/"] completionHandler:^(NSData *data,NSURLResponse *response,NSError *error){}];
        ReviewDelegate *delegate=[ReviewDelegate new];task.delegate=delegate;
        require([task.delegate isKindOfClass:IOSVMNetworkDelegate.class],@"per-task delegate missing wrapper");
        // Non-server authentication must reach the application unchanged, even
        // when bypass is enabled. No external request is sent by this test.
        for(NSString *method in @[NSURLAuthenticationMethodClientCertificate,NSURLAuthenticationMethodHTTPBasic,NSURLAuthenticationMethodHTTPDigest]){
            NSURLProtectionSpace *space=[[NSURLProtectionSpace alloc] initWithHost:@"fixture.invalid" port:443 protocol:@"https" realm:nil authenticationMethod:method];
            NSURLAuthenticationChallenge *challenge=[[NSURLAuthenticationChallenge alloc] initWithProtectionSpace:space proposedCredential:nil previousFailureCount:0 failureResponse:nil error:nil sender:nil];
            __block NSUInteger calls=0;
            [task.delegate URLSession:session task:task didReceiveChallenge:challenge completionHandler:^(NSURLSessionAuthChallengeDisposition disposition,NSURLCredential *credential){calls++;require(disposition==NSURLSessionAuthChallengeCancelAuthenticationChallenge && credential==nil,@"non-server authentication changed");}];
            require(calls==1,@"non-server authentication completion count");
        }
        [session invalidateAndCancel];
    }else{
        tlsIdentities=YES;tlsIdentityLock=[NSObject new];tlsSavedIdentities=[NSMutableSet new];tlsIdentityRecords=[NSMutableDictionary new];tlsIdentityBytes=0;
        tlsIdentityRoot=[root stringByAppendingPathComponent:@"TLSIdentities"];
        [NSFileManager.defaultManager createDirectoryAtPath:tlsIdentityRoot withIntermediateDirectories:YES attributes:nil error:nil];
        tlsIdentityDirectoryFD=open(tlsIdentityRoot.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW);
        require(tlsIdentityDirectoryFD>=0,@"store open");
        NSData *data=[@"synthetic storage material; crypto verified separately" dataUsingEncoding:NSUTF8StringEncoding];
        if([mode isEqual:@"retry"]){
            tlsSaveIdentity(nil,nil,@"selected-identity",@"fixture.invalid",@"fingerprint",@"temporary failure");
            require([metadata()[@"state"] isEqual:@"unavailable"],@"failure not recorded");
            NSString *identifier=metadata()[@"id"];
            close(tlsIdentityDirectoryFD);tlsIdentityDirectoryFD=-1;
            NSError *error=nil;require(tlsStart(@{@"tlsIdentities":@YES,@"tlsBypass":@NO},root,&error),error.description);
            require(tlsSavedIdentities.count==0 && tlsIdentityRecords.count==1,@"failure became terminal after restart");
            tlsSaveIdentity(data,@"fixture-password",@"selected-identity",@"fixture.invalid",@"fingerprint",nil);
            require([metadata()[@"state"] isEqual:@"exported"] && [metadata()[@"id"] isEqual:identifier] && files().count==2,@"failed identity did not recover in place");
            tlsSaveIdentity(data,@"fixture-password",@"selected-identity",@"fixture.invalid",@"fingerprint",nil);
            require(files().count==2 && tlsSavedIdentities.count==1,@"successful identity deduplication");
            close(tlsIdentityDirectoryFD);tlsIdentityDirectoryFD=-1;
            require(tlsStart(@{@"tlsIdentities":@YES,@"tlsBypass":@NO},root,&error),error.description);
            require(tlsSavedIdentities.count==1 && tlsIdentityRecords.count==1,@"success not recovered across restart");
        }else if([mode isEqual:@"quota"]){
            tlsIdentityBytes=32*1024*1024-data.length;
            tlsSaveIdentity(data,@"fixture-password",@"selected-identity",@"fixture.invalid",@"fingerprint",nil);
            require(files().count==0 && tlsSavedIdentities.count==0,@"quota left partial identity files");
        }else if([mode isEqual:@"commit-failure"]){
            NSString *identifier=NSUUID.UUID.UUIDString,*key=@"selected:fingerprint:fixture.invalid";
            tlsIdentityRecords[key]=@{@"id":identifier,@"state":@"unavailable"};
            [NSFileManager.defaultManager createDirectoryAtPath:[tlsIdentityRoot stringByAppendingPathComponent:[identifier stringByAppendingString:@".json"]] withIntermediateDirectories:NO attributes:nil error:nil];
            tlsSaveIdentity(data,@"fixture-password",@"selected-identity",@"fixture.invalid",@"fingerprint",nil);
            require(files().count==1 && tlsIdentityBytes==0 && tlsSavedIdentities.count==0,@"failed metadata commit did not roll back");
        }else if([mode isEqual:@"metadata"]){
            NSString *password=[@"" stringByPaddingToLength:8192 withString:@"\x01" startingAtIndex:0];
            tlsSaveIdentity(data,password,@"pkcs12-import",nil,nil,nil);
            NSDictionary *meta=metadata();require([meta[@"password"] isEqual:password],@"password changed");
            NSData *json=[NSData dataWithContentsOfFile:[tlsIdentityRoot stringByAppendingPathComponent:[meta[@"id"] stringByAppendingString:@".json"]]];
            require(json.length>16384 && json.length<=IOSVMTLSIdentityMetadataLimit,@"metadata exceeds shared reader limit");
        }else require(NO,@"unknown mode");
        close(tlsIdentityDirectoryFD);
    }
    printf("PASS TLS review regression %s\n",mode.UTF8String);
}return 0;}
