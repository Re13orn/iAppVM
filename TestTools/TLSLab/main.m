#import <UIKit/UIKit.h>
#import <Security/Security.h>

@interface TLSLabDelegate : NSObject <NSURLSessionDelegate>
@property NSString *mode;
@property NSData *root;
@property NSData *pin;
@property NSArray *identityItems;
@property NSUInteger serverChallenges;
@property NSUInteger clientChallenges;
@end
@implementation TLSLabDelegate
- (void)URLSession:(NSURLSession *)session didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition,NSURLCredential *))completion {
    if([challenge.protectionSpace.authenticationMethod isEqual:NSURLAuthenticationMethodServerTrust]) {
        self.serverChallenges++;
        if([self.mode isEqual:@"default"]){completion(NSURLSessionAuthChallengePerformDefaultHandling,nil);return;}
        SecTrustRef trust=challenge.protectionSpace.serverTrust;
        SecCertificateRef anchor=SecCertificateCreateWithData(NULL,(__bridge CFDataRef)self.root);
        if(!anchor){completion(NSURLSessionAuthChallengeCancelAuthenticationChallenge,nil);return;}
        SecTrustSetAnchorCertificates(trust,(__bridge CFArrayRef)@[(__bridge id)anchor]);CFRelease(anchor);
        SecTrustSetAnchorCertificatesOnly(trust,true);
        BOOL ok=SecTrustEvaluateWithError(trust,NULL);
        if([self.mode containsString:@"pin"]) {
            NSData *der=CFBridgingRelease(SecCertificateCopyData(SecTrustGetCertificateAtIndex(trust,0)));
            ok=ok && [der isEqual:self.pin] && ![self.mode isEqual:@"pin-mismatch"];
        }
        completion(ok?NSURLSessionAuthChallengeUseCredential:NSURLSessionAuthChallengeCancelAuthenticationChallenge,ok?[NSURLCredential credentialForTrust:trust]:nil);
    } else if([challenge.protectionSpace.authenticationMethod isEqual:NSURLAuthenticationMethodClientCertificate]) {
        self.clientChallenges++;
        SecIdentityRef identity=self.identityItems.count?(__bridge SecIdentityRef)self.identityItems[0][(__bridge id)kSecImportItemIdentity]:NULL;
        completion(identity?NSURLSessionAuthChallengeUseCredential:NSURLSessionAuthChallengePerformDefaultHandling,identity?[NSURLCredential credentialWithIdentity:identity certificates:nil persistence:NSURLCredentialPersistenceForSession]:nil);
    } else completion(NSURLSessionAuthChallengePerformDefaultHandling,nil);
}
@end

// Exercise task-level authentication independently of session delegates.
@interface TLSLabTaskDelegate : TLSLabDelegate <NSURLSessionTaskDelegate> @end
@implementation TLSLabTaskDelegate
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition,NSURLCredential *))completion {
    [super URLSession:session didReceiveChallenge:challenge completionHandler:completion];
}
@end

@interface TLSLabController : UIViewController
@property UILabel *status;
@property UIButton *run;
@property NSMutableArray *results;
@end
@implementation TLSLabController
- (void)viewDidLoad {
    [super viewDidLoad];self.title=@"iAppVM TLS Lab";self.view.backgroundColor=UIColor.systemBackgroundColor;
    UIStackView *stack=[UIStackView new];stack.axis=UILayoutConstraintAxisVertical;stack.spacing=24;stack.translatesAutoresizingMaskIntoConstraints=NO;
    UILabel *info=[UILabel new];info.text=@"仅连接自有局域网 TLS 夹具。验证普通校验、内置 CA、Pinning 与双向 TLS。所有身份均为合成材料；计数仅表示符合未绕过直连基线，代理验收请核对状态与改包证据。";info.numberOfLines=0;
    [stack addArrangedSubview:info];self.run=[UIButton buttonWithType:UIButtonTypeSystem];[self.run setTitle:@"执行 7 组 TLS 验证" forState:UIControlStateNormal];[self.run addTarget:self action:@selector(runChecks) forControlEvents:UIControlEventTouchUpInside];[stack addArrangedSubview:self.run];
    self.status=[UILabel new];self.status.text=@"先在网络分析中开启捕获，再启动并执行。";self.status.numberOfLines=0;[stack addArrangedSubview:self.status];[self.view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[[stack.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:24],[stack.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-24],[stack.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor]]];
}
- (void)runChecks {
    self.run.enabled=NO;self.results=[NSMutableArray new];self.status.text=@"执行中…";
    NSString *folder=[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"TLSFixture"];
    NSDictionary *config=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[folder stringByAppendingPathComponent:@"endpoint.json"]] options:0 error:nil];
    BOOL perTask=[config[@"perTask"] boolValue];
    for(NSString *mode in @[@"default",@"custom-ca",@"pin",@"pin-mismatch",@"mtls",@"mtls-no-identity",@"mtls-pin"]) {
        TLSLabDelegate *delegate=perTask?[TLSLabTaskDelegate new]:[TLSLabDelegate new];delegate.mode=mode;delegate.root=[NSData dataWithContentsOfFile:[folder stringByAppendingPathComponent:@"ca.der"]];delegate.pin=[NSData dataWithContentsOfFile:[folder stringByAppendingPathComponent:@"server.der"]];
        if([mode isEqual:@"mtls"] || [mode isEqual:@"mtls-pin"]) {
            CFArrayRef items=NULL;
            OSStatus code=SecPKCS12Import((__bridge CFDataRef)[NSData dataWithContentsOfFile:[folder stringByAppendingPathComponent:@"client.p12"]],(__bridge CFDictionaryRef)@{(__bridge id)kSecImportExportPassphrase:@"fixture-only"},&items);
            if(code==errSecSuccess)delegate.identityItems=CFBridgingRelease(items);
        }
        NSURLSession *session=[NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration delegate:perTask?nil:delegate delegateQueue:nil];
        NSURL *url=[NSURL URLWithString:[NSString stringWithFormat:@"https://%@:%d/%@",config[@"host"],[mode hasPrefix:@"mtls"]?19444:19443,mode]];
        NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:url];request.timeoutInterval=12;
        NSURLSessionDataTask *task=[session dataTaskWithRequest:request completionHandler:^(NSData *data,NSURLResponse *response,NSError *error){
            BOOL expectedFailure=[@[@"default",@"pin-mismatch",@"mtls-no-identity"] containsObject:mode];
            NSInteger status=[(NSHTTPURLResponse *)response statusCode];BOOL pass=expectedFailure?(error!=nil && delegate.serverChallenges>0):(!error && status==200);
            NSDictionary *result=@{@"mode":mode,@"perTask":@(perTask),@"pass":@(pass),@"status":@(status),@"errorCode":@(error.code),@"error":error.description?:@"",@"serverChallenges":@(delegate.serverChallenges),@"clientChallenges":@(delegate.clientChallenges)};
            dispatch_async(dispatch_get_main_queue(),^{
                [self.results addObject:result];NSUInteger passed=0;for(NSDictionary *r in self.results)if([r[@"pass"] boolValue])passed++;
                self.status.text=[NSString stringWithFormat:@"已完成 %lu/7 · 符合直连基线 %lu",(unsigned long)self.results.count,(unsigned long)passed];
                NSData *json=[NSJSONSerialization dataWithJSONObject:self.results options:NSJSONWritingPrettyPrinted error:nil];[json writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/TLSLabResults.json"] atomically:YES];
                if(self.results.count==7)self.run.enabled=YES;
            });[session finishTasksAndInvalidate];
        }];
        if(perTask)task.delegate=(id<NSURLSessionTaskDelegate>)delegate;[task resume];
    }
}
@end
@interface TLSLabApp : UIResponder <UIApplicationDelegate>
@property UIWindow *window;
@end
@implementation TLSLabApp
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];self.window.rootViewController=[[UINavigationController alloc] initWithRootViewController:[TLSLabController new]];[self.window makeKeyAndVisible];return YES;
}
@end
int main(int argc,char **argv){@autoreleasepool{return UIApplicationMain(argc,argv,nil,NSStringFromClass(TLSLabApp.class));}}
