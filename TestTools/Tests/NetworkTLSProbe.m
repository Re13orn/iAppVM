#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <objc/message.h>
#import "../../LiveContainer/IOSVMNetwork.h"
#import "../../litehook/src/litehook.h"
void litehook_rebind_symbol(const mach_header_u *h,void *a,void *b,bool (*f)(const mach_header_u *)) {}
static void require(BOOL ok,NSString *message){if(!ok){fprintf(stderr,"FAIL: %s\n",message.UTF8String);exit(1);}}
@interface TLSTestSpace : NSURLProtectionSpace
@property(nonatomic,assign) SecTrustRef testingTrust;
@end
@implementation TLSTestSpace
- (SecTrustRef)serverTrust { return self.testingTrust; }
@end

@interface TLSBase : NSObject <NSURLSessionDataDelegate>
@property NSString *mode;
@property NSData *anchor;
@property NSData *pin;
@property SecIdentityRef identity;
@property NSUInteger serverChallenges;
@property NSUInteger clientChallenges;
@property NSUInteger completions;
- (void)handle:(NSURLAuthenticationChallenge *)challenge completion:(void (^)(NSURLSessionAuthChallengeDisposition,NSURLCredential *))completion;
@end
@implementation TLSBase
- (void)handle:(NSURLAuthenticationChallenge *)challenge completion:(void (^)(NSURLSessionAuthChallengeDisposition,NSURLCredential *))completion {
    if([challenge.protectionSpace.authenticationMethod isEqual:NSURLAuthenticationMethodServerTrust]) {
        self.serverChallenges++;
        if([self.mode isEqual:@"default"]){completion(NSURLSessionAuthChallengePerformDefaultHandling,nil);return;}
        SecTrustRef trust=challenge.protectionSpace.serverTrust;
        SecCertificateRef ca=SecCertificateCreateWithData(NULL,(__bridge CFDataRef)self.anchor);
        require(ca!=NULL,@"fixture CA parsing failed");
        SecTrustSetAnchorCertificates(trust,(__bridge CFArrayRef)@[(__bridge id)ca]);CFRelease(ca);
        SecTrustSetAnchorCertificatesOnly(trust,true);
        BOOL accepted=SecTrustEvaluateWithError(trust,NULL);
        if([self.mode containsString:@"pin"]) {
            NSData *leaf=CFBridgingRelease(SecCertificateCopyData(SecTrustGetCertificateAtIndex(trust,0)));
            accepted=accepted && [leaf isEqual:self.pin] && ![self.mode isEqual:@"pin-mismatch"];
        }
        completion(accepted?NSURLSessionAuthChallengeUseCredential:NSURLSessionAuthChallengeCancelAuthenticationChallenge,accepted?[NSURLCredential credentialForTrust:trust]:nil);
    } else if([challenge.protectionSpace.authenticationMethod isEqual:NSURLAuthenticationMethodClientCertificate]) {
        self.clientChallenges++;
        completion(self.identity?NSURLSessionAuthChallengeUseCredential:NSURLSessionAuthChallengePerformDefaultHandling,self.identity?[NSURLCredential credentialWithIdentity:self.identity certificates:nil persistence:NSURLCredentialPersistenceForSession]:nil);
    } else completion(NSURLSessionAuthChallengePerformDefaultHandling,nil);
}
@end
@interface TLSSession : TLSBase @end
@implementation TLSSession
- (void)URLSession:(NSURLSession *)session didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition,NSURLCredential *))completion {
    [self handle:challenge completion:completion];
}
@end
@interface TLSTask : TLSBase @end
@implementation TLSTask
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition,NSURLCredential *))completion {
    [self handle:challenge completion:completion];
}
@end
int main(int argc,char **argv){@autoreleasepool{
    require(argc==4,@"usage: probe output fixture mode");
    NSString *root=@(argv[1]),*fixture=@(argv[2]),*mode=@(argv[3]);
    [NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *settings=[root stringByAppendingPathComponent:@"settings.json"];
    [[NSJSONSerialization dataWithJSONObject:@{@"version":@1,@"capture":@YES,@"bodies":@NO,@"proxyType":@"off"} options:0 error:nil] writeToFile:settings atomically:YES];
    NSError *startup=nil;require([IOSVMNetwork startWithSettings:settings root:root error:&startup],startup.description);
    TLSBase *delegate=[mode containsString:@"task"]?[TLSTask new]:[TLSSession new];delegate.mode=mode;
    delegate.anchor=[NSData dataWithContentsOfFile:[fixture stringByAppendingPathComponent:@"ca.der"]];
    delegate.pin=[NSData dataWithContentsOfFile:[fixture stringByAppendingPathComponent:@"server.der"]];
    if([mode isEqual:@"mtls"] || [mode isEqual:@"mtls-pin"]){
        NSData *p12=[NSData dataWithContentsOfFile:[fixture stringByAppendingPathComponent:@"client.p12"]];CFArrayRef items=NULL;
        OSStatus status=SecPKCS12Import((__bridge CFDataRef)p12,(__bridge CFDictionaryRef)@{(__bridge id)kSecImportExportPassphrase:@"fixture-only",(__bridge id)kSecImportToMemoryOnly:@YES},&items);
        require(status==errSecSuccess && CFArrayGetCount(items)>0,@"fixture identity import failed");
        delegate.identity=(SecIdentityRef)CFRetain((__bridge CFTypeRef)((__bridge NSArray *)items)[0][(__bridge id)kSecImportItemIdentity]);CFRelease(items);
    }
    id activeDelegate=[@[@"no-delegate",@"per-task-pin"] containsObject:mode]?nil:delegate;
    NSURLSession *session=[NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration delegate:activeDelegate delegateQueue:nil];
    // The wrapper must advertise exactly the authentication methods implemented by the app.
    SEL server=@selector(URLSession:didReceiveChallenge:completionHandler:),task=@selector(URLSession:task:didReceiveChallenge:completionHandler:);
    require([session.delegate respondsToSelector:server]==[activeDelegate respondsToSelector:server],@"session fallback routing changed");
    require([session.delegate respondsToSelector:task]==[activeDelegate respondsToSelector:task],@"task fallback routing changed");
    if([mode isEqual:@"default"]) {
        SecCertificateRef leaf=SecCertificateCreateWithData(NULL,(__bridge CFDataRef)delegate.pin);
        SecPolicyRef policy=SecPolicyCreateSSL(true,CFSTR("localhost"));SecTrustRef untouched=NULL;
        require(SecTrustCreateWithCertificates(leaf,policy,&untouched)==errSecSuccess,@"fresh trust creation failed");
        SecTrustResultType before=kSecTrustResultInvalid,after=kSecTrustResultInvalid;SecTrustGetTrustResult(untouched,&before);
        TLSTestSpace *space=[[TLSTestSpace alloc] initWithHost:@"localhost" port:19443 protocol:@"https" realm:nil authenticationMethod:NSURLAuthenticationMethodServerTrust];space.testingTrust=untouched;
        NSURLAuthenticationChallenge *challenge=[[NSURLAuthenticationChallenge alloc] initWithProtectionSpace:space proposedCredential:nil previousFailureCount:0 failureResponse:nil error:nil sender:nil];
        __block int forwarded=0;
        [session.delegate URLSession:session didReceiveChallenge:challenge completionHandler:^(NSURLSessionAuthChallengeDisposition disposition,NSURLCredential *credential){
            require(disposition==NSURLSessionAuthChallengePerformDefaultHandling && credential==nil,@"synthetic decision altered");forwarded++;
        }];
        SecTrustGetTrustResult(untouched,&after);
        fprintf(stderr,"trust observation before=%u after=%u forwarded=%d\n",(unsigned)before,(unsigned)after,forwarded);
        require(before==after && forwarded==1,@"observer changed trust result");
        CFRelease(untouched);CFRelease(policy);CFRelease(leaf);delegate.serverChallenges=0;
    }
    dispatch_semaphore_t done=dispatch_semaphore_create(0);__block NSError *failure=nil;__block NSInteger http=0;__block int calls=0;
    BOOL mtls=[mode hasPrefix:@"mtls"];
    NSURL *url=[NSURL URLWithString:[NSString stringWithFormat:@"https://localhost:%d/",mtls?19444:19443]];
    NSURLSessionDataTask *request=[session dataTaskWithURL:url completionHandler:^(NSData *data,NSURLResponse *response,NSError *error){calls++;failure=error;http=[(NSHTTPURLResponse *)response statusCode];dispatch_semaphore_signal(done);}];
    if([mode isEqual:@"per-task-pin"])request.delegate=delegate;
    [request resume];
    require(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,12*NSEC_PER_SEC))==0,@"TLS timeout");
    BOOL expectedFailure=[@[@"default",@"no-delegate",@"pin-mismatch",@"mtls-no-identity"] containsObject:mode];
    require(calls==1,@"completion handler delivery changed");
    require(expectedFailure?(failure!=nil):(!failure && http==200),[NSString stringWithFormat:@"unexpected TLS outcome %@ / %ld",failure,(long)http]);
    if(![mode isEqual:@"no-delegate"])require(delegate.serverChallenges>0,@"server challenge not forwarded");
    if(mtls)require(delegate.clientChallenges>0,@"client certificate challenge not forwarded");
    NSString *folder=[root stringByAppendingPathComponent:@"Library/iOSVM/Network"];
    NSString *file=[[[NSFileManager.defaultManager contentsOfDirectoryAtPath:folder error:nil] filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF BEGINSWITH 'traffic-'"]] firstObject];
    NSString *text=[NSString stringWithContentsOfFile:[folder stringByAppendingPathComponent:file] encoding:NSUTF8StringEncoding error:nil];
    NSUInteger challenges=0,decisions=0,identities=0;NSMutableSet *challengeIDs=[NSMutableSet new],*decisionIDs=[NSMutableSet new];
    for(NSString *line in [text componentsSeparatedByString:@"\n"]){
        NSDictionary *e=[NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        if(![e[@"layer"] isEqual:@"tls"])continue;
        if([e[@"state"] isEqual:@"challenge"]){challenges++;[challengeIDs addObject:e[@"challengeID"]];}
        if([e[@"state"] isEqual:@"decision"]){decisions++;[decisionIDs addObject:e[@"challengeID"]];if([e[@"credentialKind"] isEqual:@"clientIdentity"])identities++;}
        require(e[@"host"]!=nil && e[@"scope"]!=nil,@"TLS evidence identity missing");
        if([mode containsString:@"task"])require([e[@"scope"] isEqual:@"task"] && e[@"requestID"]!=nil,@"task/request correlation missing");
    }
    require(([mode isEqual:@"no-delegate"]?challenges==0:challenges>0) && challenges==decisions && [challengeIDs isEqual:decisionIDs],@"challenge/decision correlation failed");
    require(delegate.identity?identities>0:identities==0,@"client identity evidence incorrect");
    [session invalidateAndCancel];if(delegate.identity)CFRelease(delegate.identity);
    printf("PASS TLS %s: original routing/result preserved, challenge/decision pairs, certificate evidence and identity selection\n",mode.UTF8String);
}return 0;}
