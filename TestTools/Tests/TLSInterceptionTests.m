#define IOSVM_TLS_TESTING 1
#import "../../LiveContainer/IOSVMNetwork.m"
void litehook_rebind_symbol(const mach_header_u *h,void *a,void *b,bool (*f)(const mach_header_u *)) {}
static void check(BOOL value,NSString *message){if(!value){fprintf(stderr,"FAIL %s\n",message.UTF8String);exit(1);}}
@interface AFSecurityPolicy : NSObject
- (BOOL)evaluateServerTrust:(SecTrustRef)trust forDomain:(NSString *)domain;
@end
@implementation AFSecurityPolicy
- (BOOL)evaluateServerTrust:(SecTrustRef)trust forDomain:(NSString *)domain {return NO;}
@end
@interface TLSInterceptDelegate : NSObject <NSURLSessionTaskDelegate>
@property SecIdentityRef identity;
@property NSUInteger servers,clients;
@property NSData *pin;
@end
@implementation TLSInterceptDelegate
- (void)URLSession:(NSURLSession *)s task:(NSURLSessionTask *)t didReceiveChallenge:(NSURLAuthenticationChallenge *)c completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition,NSURLCredential *))done {
    if([c.protectionSpace.authenticationMethod isEqual:NSURLAuthenticationMethodClientCertificate]){self.clients++;done(self.identity?NSURLSessionAuthChallengeUseCredential:NSURLSessionAuthChallengePerformDefaultHandling,self.identity?[NSURLCredential credentialWithIdentity:self.identity certificates:nil persistence:NSURLCredentialPersistenceForSession]:nil);}
    else {self.servers++;
        NSData *leaf=c.protectionSpace.serverTrust?CFBridgingRelease(SecCertificateCopyData(SecTrustGetCertificateAtIndex(c.protectionSpace.serverTrust,0))):nil;
        BOOL matches=self.pin && [self.pin isEqual:leaf];
        done(matches?NSURLSessionAuthChallengeUseCredential:NSURLSessionAuthChallengeCancelAuthenticationChallenge,matches?[NSURLCredential credentialForTrust:c.protectionSpace.serverTrust]:nil);
    }
}
@end
int main(int argc,char **argv){@autoreleasepool{
    check(argc==5 || argc==6,@"usage output fixture bypass|off direct|proxy [per-task-no-capture]");NSString *root=@(argv[1]),*fixture=@(argv[2]);BOOL bypass=[@(argv[3]) isEqual:@"bypass"],proxy=[@(argv[4]) isEqual:@"proxy"],perTask=argc==6;
    [NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *settings=[root stringByAppendingPathComponent:@"settings.json"];
    NSDictionary *config=@{@"version":@1,@"capture":perTask?@NO:@YES,@"bodies":@YES,@"proxyType":proxy?@"http":@"off",@"host":@"127.0.0.1",@"port":@19446,@"tlsBypass":@(bypass),@"tlsIdentities":@YES};
    [[NSJSONSerialization dataWithJSONObject:config options:0 error:nil] writeToFile:settings atomically:YES];NSError *error=nil;check([IOSVMNetwork startWithSettings:settings root:root error:&error],error.description);
    NSData *data=[NSData dataWithContentsOfFile:[fixture stringByAppendingPathComponent:@"client.p12"]];CFArrayRef items=NULL;
    check(tlsImport((__bridge CFDataRef)data,(__bridge CFDictionaryRef)@{(__bridge id)kSecImportExportPassphrase:@"fixture-only",(__bridge id)kSecImportToMemoryOnly:@YES},&items)==errSecSuccess,@"p12 import");
    SecIdentityRef identity=(SecIdentityRef)CFRetain((__bridge CFTypeRef)((__bridge NSArray *)items)[0][(__bridge id)kSecImportItemIdentity]);CFRelease(items);
    NSURLCredential *credential=[NSURLCredential credentialWithIdentity:identity certificates:nil persistence:NSURLCredentialPersistenceForSession];
    tlsExportCredential(credential,@"localhost");
    SecIdentityRef exportedIdentity=NULL;
    NSUInteger exports=0;for(NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:tlsIdentityRoot error:nil])if([name.pathExtension isEqual:@"json"]){NSDictionary *meta=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[tlsIdentityRoot stringByAppendingPathComponent:name]] options:0 error:nil];
        check([meta[@"state"] isEqual:@"exported"],meta.description);NSData *out=[NSData dataWithContentsOfFile:[tlsIdentityRoot stringByAppendingPathComponent:meta[@"file"]]];
        CFArrayRef test=NULL;check(SecPKCS12Import((__bridge CFDataRef)out,(__bridge CFDictionaryRef)@{(__bridge id)kSecImportExportPassphrase:meta[@"password"],(__bridge id)kSecImportToMemoryOnly:@YES},&test)==errSecSuccess,@"exported p12 reimport");if([meta[@"source"] isEqual:@"selected-identity"] && test && CFArrayGetCount(test)>0)exportedIdentity=(SecIdentityRef)CFRetain((__bridge CFTypeRef)((__bridge NSArray *)test)[0][(__bridge id)kSecImportItemIdentity]);if(test)CFRelease(test);exports++;}
    tlsExportCredential(credential,@"localhost");
    check(tlsSavedIdentities.count==2,@"identity exports deduplicated");
    check(exports==2,@"both raw import and selected software identity exported");
    for(NSString *curve in @[@"prime256v1",@"secp384r1",@"secp521r1"]) {
        NSString *name=[fixture stringByAppendingPathComponent:[curve stringByAppendingString:@".p12"]];
        if(![NSFileManager.defaultManager fileExistsAtPath:name])continue;
        CFArrayRef ecItems=NULL;check(SecPKCS12Import((__bridge CFDataRef)[NSData dataWithContentsOfFile:name],(__bridge CFDictionaryRef)@{(__bridge id)kSecImportExportPassphrase:@"fixture-only",(__bridge id)kSecImportToMemoryOnly:@YES},&ecItems)==errSecSuccess,@"EC fixture import");
        SecIdentityRef ec=(__bridge SecIdentityRef)((__bridge NSArray *)ecItems)[0][(__bridge id)kSecImportItemIdentity];
        tlsExportCredential([NSURLCredential credentialWithIdentity:ec certificates:nil persistence:NSURLCredentialPersistenceForSession],curve);CFRelease(ecItems);
        BOOL found=NO;for(NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:tlsIdentityRoot error:nil])if([name.pathExtension isEqual:@"json"]){NSDictionary *meta=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[tlsIdentityRoot stringByAppendingPathComponent:name]] options:0 error:nil];if(![meta[@"host"] isEqual:curve])continue;found=YES;check([meta[@"state"] isEqual:@"exported"],meta.description);CFArrayRef test=NULL;check(SecPKCS12Import((__bridge CFDataRef)[NSData dataWithContentsOfFile:[tlsIdentityRoot stringByAppendingPathComponent:meta[@"file"]]],(__bridge CFDictionaryRef)@{(__bridge id)kSecImportExportPassphrase:meta[@"password"],(__bridge id)kSecImportToMemoryOnly:@YES},&test)==errSecSuccess,@"EC exported identity roundtrip");if(test)CFRelease(test);}
        check(found,@"EC record");
    }
    TLSInterceptDelegate *delegate=[TLSInterceptDelegate new];delegate.identity=exportedIdentity;if(proxy)delegate.pin=[NSData dataWithContentsOfFile:[fixture stringByAppendingPathComponent:@"server.der"]];check(exportedIdentity!=NULL,@"exported p12 contains matching identity");
    NSURLSession *session=[NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration delegate:perTask?nil:delegate delegateQueue:nil];
    check([[AFSecurityPolicy new] evaluateServerTrust:NULL forDomain:@"localhost"]==bypass,@"AFNetworking bypass switch");
    for(NSString *mode in @[@"pin",@"mtls"]) {
        NSInteger port=[mode isEqual:@"mtls"]?19444:19443;
        NSDictionary *endpoint=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[fixture stringByAppendingPathComponent:@"endpoint.json"]] ?: [@"{}" dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        NSURL *url=[NSURL URLWithString:[NSString stringWithFormat:@"https://%@:%ld/iosvm-tls-test/%@",endpoint[@"host"] ?: @"localhost",(long)port,mode]];
        dispatch_semaphore_t sem=dispatch_semaphore_create(0);__block NSError *failure=nil;__block NSInteger status=0;__block NSString *body=nil;__block int calls=0;
        NSURLSessionTask *task=[session dataTaskWithURL:url completionHandler:^(NSData *bodyData,NSURLResponse *response,NSError *e){calls++;failure=e;status=[(NSHTTPURLResponse *)response statusCode];body=[[NSString alloc] initWithData:bodyData encoding:NSUTF8StringEncoding];dispatch_semaphore_signal(sem);}];
        if(perTask)task.delegate=delegate;[task resume];
        check(dispatch_semaphore_wait(sem,dispatch_time(DISPATCH_TIME_NOW,15*NSEC_PER_SEC))==0,@"request timeout");check(calls==1,@"completion once");
        check(bypass?(!failure && status==200):(failure!=nil),[NSString stringWithFormat:@"%@ unexpected %@ %ld",mode,failure,(long)status]);
        if(proxy && bypass)check([body containsString:@"burp-modified"],@"Burp response edit reached app");
    }
    check(bypass?(delegate.servers==0 && (proxy?delegate.clients==0:delegate.clients>0)):(delegate.servers>0),@"server pinning bypassed; task client identity delegate preserved");
    [session invalidateAndCancel];CFRelease(identity);CFRelease(exportedIdentity);printf("PASS TLS interception %s %s; p12 capture + software export; client authentication route verified%s\n",argv[3],argv[4],perTask?"; per-task delegate with capture OFF":"");
}return 0;}
