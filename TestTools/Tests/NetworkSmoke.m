#import <Foundation/Foundation.h>
#import "../../LiveContainer/IOSVMNetwork.h"
#import "../../litehook/src/litehook.h"

// The macOS transport test does not rebind imports. Device tests exercise that layer.
void litehook_rebind_symbol(const mach_header_u *h, void *a, void *b, bool (*filter)(const mach_header_u *)) {}
static void check(BOOL ok, NSString *message) { if (!ok) { fprintf(stderr,"FAIL: %s\n",message.UTF8String); exit(1); } }
@interface ProbeDelegate : NSObject <NSURLSessionDataDelegate>
@property dispatch_semaphore_t done;
@property NSMutableData *bytes;
@property NSUInteger redirects;
@property NSError *error;
@property NSUInteger challenges;
@end
@implementation ProbeDelegate
- (void)URLSession:(NSURLSession *)s dataTask:(NSURLSessionDataTask *)t didReceiveData:(NSData *)data { [self.bytes appendData:data]; }
- (void)URLSession:(NSURLSession *)s task:(NSURLSessionTask *)t didCompleteWithError:(NSError *)e { self.error=e;dispatch_semaphore_signal(self.done); }
- (void)URLSession:(NSURLSession *)s task:(NSURLSessionTask *)t willPerformHTTPRedirection:(NSHTTPURLResponse *)r newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completion {self.redirects++;completion(request);}
- (void)URLSession:(NSURLSession *)s didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition,NSURLCredential *))completion {self.challenges++;completion(NSURLSessionAuthChallengePerformDefaultHandling,nil);}
@end
int main(int argc,char **argv) { @autoreleasepool {
    check(argc==3,@"usage: NetworkSmoke root off|http|socks5");
    NSString *root=@(argv[1]),*mode=@(argv[2]);
    NSFileManager *fm=NSFileManager.defaultManager;[fm createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *path=[root stringByAppendingPathComponent:@"settings.json"];
    if([mode isEqual:@"invalid"]){
        NSArray *cases=@[@[],@{@"version":@YES},@{@"version":@1,@"capture":@"yes"},@{@"version":@1,@"proxyType":@"unknown"},@{@"version":@1,@"proxyType":@"http",@"host":@"http://bad",@"port":@8080},@{@"version":@1,@"proxyType":@"socks5",@"host":@"localhost",@"port":@YES},@{@"version":@1,@"proxyType":@"http",@"host":@"localhost",@"port":@1.5}];
        for(id item in cases){[[NSJSONSerialization dataWithJSONObject:item options:NSJSONWritingFragmentsAllowed error:nil] writeToFile:path atomically:YES];NSError *e=nil;check(![IOSVMNetwork startWithSettings:path root:root error:&e] && e!=nil,@"invalid configuration accepted");}
        printf("PASS invalid: malformed objects, booleans, host, protocol and port validation\n");return 0;
    }
    BOOL blocked=[mode isEqual:@"blocked"];
    NSDictionary *config=@{@"version":@1,@"capture":@YES,@"bodies":@YES,@"proxyType":blocked?@"http":mode,@"host":@"127.0.0.1",@"port":blocked?@18994:([mode isEqual:@"http"]?@18991:@18992)};
    [[NSJSONSerialization dataWithJSONObject:config options:0 error:nil] writeToFile:path atomically:YES];
    NSError *error=nil;check([IOSVMNetwork startWithSettings:path root:root error:&error],error.description);
    NSString *base=[mode isEqual:@"off"]?@"http://127.0.0.1:18990":@"http://iosvm-fixture.test:18990";
    dispatch_semaphore_t done=dispatch_semaphore_create(0);
    __block NSUInteger length=0;__block NSError *failure=nil;
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:[base stringByAppendingString:@"/echo?token=must-redact-token&signature=must-redact-signature&code=must-redact-code"]]];
    [request setValue:@"Bearer must-redact" forHTTPHeaderField:@"Authorization"];
    [request setValue:@"must-redact-jwt" forHTTPHeaderField:@"Cf-Access-Jwt-Assertion"];
    if(blocked){request.URL=[NSURL URLWithString:@"https://example.com/"];request.timeoutInterval=3;[request setValue:nil forHTTPHeaderField:@"Authorization"];}
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *d,NSURLResponse *r,NSError *e){length=d.length;failure=e;dispatch_semaphore_signal(done);}] resume];
    check(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,15*NSEC_PER_SEC))==0,@"request timed out");
    if(blocked){check(failure!=nil && length==0,@"unavailable proxy fell back to a direct connection");printf("PASS blocked: unavailable HTTP proxy did not fall back to direct HTTPS\n");return 0;}
    check(!failure && length>0,failure.description?:@"empty response");
    ProbeDelegate *delegate=[ProbeDelegate new];delegate.done=dispatch_semaphore_create(0);delegate.bytes=[NSMutableData new];
    NSURLSession *session=[NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration delegate:delegate delegateQueue:nil];
    [[session dataTaskWithURL:[NSURL URLWithString:[base stringByAppendingString:@"/redirect"]]] resume];
    check(dispatch_semaphore_wait(delegate.done,dispatch_time(DISPATCH_TIME_NOW,15*NSEC_PER_SEC))==0,@"delegate request timed out");
    check(!delegate.error && delegate.bytes.length>0 && delegate.redirects==1,@"delegate response or redirect was not forwarded");
    NSMutableURLRequest *post=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:[base stringByAppendingString:@"/upload"]]];post.HTTPMethod=@"POST";
    [[[NSURLSession sharedSession] uploadTaskWithRequest:post fromData:[@"synthetic-upload" dataUsingEncoding:NSUTF8StringEncoding] completionHandler:^(NSData *d,NSURLResponse *r,NSError *e){failure=e;dispatch_semaphore_signal(done);}] resume];
    check(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,15*NSEC_PER_SEC))==0&&!failure,@"upload failed");
    ProbeDelegate *perTask=[ProbeDelegate new];perTask.done=dispatch_semaphore_create(0);perTask.bytes=[NSMutableData new];
    NSURLSession *plain=[NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
    NSURLSessionDataTask *task=[plain dataTaskWithURL:[NSURL URLWithString:[base stringByAppendingString:@"/echo"]]];
    task.delegate=perTask;[task resume];
    check(dispatch_semaphore_wait(perTask.done,dispatch_time(DISPATCH_TIME_NOW,15*NSEC_PER_SEC))==0 && perTask.bytes.length>0 && !perTask.error,@"per-task delegate was not forwarded");
    [[[NSURLSession sharedSession] dataTaskWithURL:[NSURL URLWithString:[base stringByAppendingString:@"/large"]] completionHandler:^(NSData *d,NSURLResponse *r,NSError *e){length=d.length;failure=e;dispatch_semaphore_signal(done);}] resume];
    check(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,15*NSEC_PER_SEC))==0 && !failure && length==100*1024,@"capture truncated the actual application response");
    ProbeDelegate *tls=[ProbeDelegate new];tls.done=dispatch_semaphore_create(0);tls.bytes=[NSMutableData new];
    NSURLSession *secure=[NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration delegate:tls delegateQueue:nil];
    NSString *secureURL=[mode isEqual:@"off"]?@"https://localhost:18993/echo":@"https://iosvm-fixture.test:18993/echo";
    [[secure dataTaskWithURL:[NSURL URLWithString:secureURL]] resume];
    check(dispatch_semaphore_wait(tls.done,dispatch_time(DISPATCH_TIME_NOW,15*NSEC_PER_SEC))==0 && tls.error!=nil && tls.challenges>0,@"TLS challenge was lost or an untrusted certificate was accepted");
    NSString *folder=[root stringByAppendingPathComponent:@"Library/iOSVM/Network"];
    NSArray *traffic=[[fm contentsOfDirectoryAtPath:folder error:nil] filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF BEGINSWITH 'traffic-' AND SELF ENDSWITH '.jsonl'"]];
    NSString *log=[folder stringByAppendingPathComponent:traffic.lastObject];
    NSString *text=[NSString stringWithContentsOfFile:log encoding:NSUTF8StringEncoding error:nil];
    check([text containsString:@"must-redact"],@"full-fidelity capture was expected but credential was not recorded");
    NSUInteger complete=0,large=0,failedTLS=0;
    for(NSString *line in [text componentsSeparatedByString:@"\n"]){
        if(!line.length)continue;
        NSDictionary *entry=[NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        check(entry!=nil,@"invalid event JSON");
        if(![entry[@"state"] isEqual:@"complete"])continue;
        complete++;
        if([entry[@"errorCode"] integerValue]!=0){failedTLS++;continue;}
        NSData *body=[[NSData alloc] initWithBase64EncodedString:entry[@"responseBodyBase64"] options:0];
        check(body.length>0 && body.length==MIN(64*1024,[entry[@"bodyBytes"] unsignedIntegerValue]),@"missing, duplicated or incorrectly capped response capture");
        if([entry[@"bodyBytes"] unsignedIntegerValue]>64*1024){large++;check([entry[@"responseBodyTruncated"] boolValue],@"body limit was not reported");}
        check([entry[@"status"] integerValue]==200,@"status missing");
    }
    check(complete==6 && large==1 && failedTLS==1,[NSString stringWithFormat:@"expected 6 requests / 1 capped body / 1 rejected TLS, got %lu / %lu / %lu",(unsigned long)complete,(unsigned long)large,(unsigned long)failedTLS]);
    [session invalidateAndCancel];[plain invalidateAndCancel];[secure invalidateAndCancel];
    printf("PASS %s: completion, session/task delegates, redirect, upload, body cap, verbatim capture, TLS rejection\n",mode.UTF8String);
}return 0;}
