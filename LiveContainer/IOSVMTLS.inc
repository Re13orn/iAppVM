#include <sys/stat.h>
// Process-local TLS testing. Strategies are explicit per-guest settings.
// Layering informed by ssl-kill-switch3 (MIT); see TestTools/SSL-Kill-Switch3-Review.md.
static BOOL tlsBypass, tlsIdentities;
static NSString *tlsIdentityRoot;
static NSObject *tlsIdentityLock;
static NSMutableSet *tlsSavedIdentities; // Successfully committed identities only.
static NSMutableDictionary<NSString *, NSDictionary *> *tlsIdentityRecords;
static NSUInteger tlsIdentityBytes;
static int tlsIdentityDirectoryFD=-1;
static bool guestImage(const mach_header_u *header);
static IMP original(id object, SEL sel);
static void hook(Class cls, SEL sel, IMP replacement);
static void tlsHit(NSString *strategy) {
    publishNetworkStatus(@{@"tlsLastHit":strategy,@"tlsLastHitAt":@(NSDate.date.timeIntervalSince1970)});
}
static void tlsStorageError(NSString *message) {
    publishNetworkStatus(@{@"tlsIdentityError":message ?: @"身份文件保存失败。"});
}
static void tlsRemoveFile(NSString *name) {
    struct stat info;
    if(fstatat(tlsIdentityDirectoryFD,name.fileSystemRepresentation,&info,AT_SYMLINK_NOFOLLOW)==0 && S_ISREG(info.st_mode) &&
       unlinkat(tlsIdentityDirectoryFD,name.fileSystemRepresentation,0)==0)
        tlsIdentityBytes-=MIN(tlsIdentityBytes,(NSUInteger)info.st_size);
}
static BOOL tlsWrite(NSString *name, NSData *data) {
    if (!data || data.length>8*1024*1024 || data.length>32*1024*1024-MIN(tlsIdentityBytes,(NSUInteger)32*1024*1024)) return NO;
    int fd=tlsIdentityDirectoryFD<0?-1:openat(tlsIdentityDirectoryFD,name.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
    if(fd<0)return NO;
    const uint8_t *bytes=data.bytes;NSUInteger written=0;
    while(written<data.length){ssize_t n=write(fd,bytes+written,data.length-written);if(n<0&&errno==EINTR)continue;if(n<=0)break;written+=n;}
    BOOL complete=written==data.length;int closed=close(fd);
    if(!complete || closed!=0){unlinkat(tlsIdentityDirectoryFD,name.fileSystemRepresentation,0);return NO;}
    tlsIdentityBytes+=written;return YES;
}
static void tlsSaveIdentity(NSData *p12, NSString *password, NSString *source, NSString *host, NSString *fingerprint, NSString *problem) {
    if(!tlsIdentities)return;
    // Compute the material identity before dropping invalid display metadata.
    NSString *key=[source isEqual:@"selected-identity"] ? [NSString stringWithFormat:@"selected:%@:%@",fingerprint ?: @"",host ?: @""] : tlsDigest(p12 ?: [source dataUsingEncoding:NSUTF8StringEncoding]);
    if([password lengthOfBytesUsingEncoding:NSUTF8StringEncoding]>8192){p12=nil;password=nil;problem=@"导入密码超过 8 KiB，无法保存为可展示的身份记录。";}
    @synchronized(tlsIdentityLock) {
        if(!tlsIdentityRecords)tlsIdentityRecords=[NSMutableDictionary new];
        if([tlsSavedIdentities containsObject:key])return;
        NSDictionary *previous=tlsIdentityRecords[key];
        if(!previous && tlsIdentityRecords.count>=20){tlsStorageError(@"身份记录已达到 20 项上限，请先在文件浏览器管理已有记录。");return;}
        NSString *identifier=previous[@"id"] ?: NSUUID.UUID.UUIDString;
        NSString *p12Name=[identifier stringByAppendingString:@".p12"],*metaName=[identifier stringByAppendingString:@".json"];
        NSString *temporary=[NSUUID.UUID.UUIDString stringByAppendingString:@".pending"];
        NSMutableDictionary *meta=[@{@"version":@1,@"id":identifier,@"materialID":key,@"source":source,@"host":host ?: @"",@"certificateSHA256":fingerprint ?: @"",@"time":@(NSDate.date.timeIntervalSince1970)} mutableCopy];
        if(p12){meta[@"file"]=p12Name;meta[@"password"]=password ?: @"";meta[@"state"]=@"exported";}
        else{meta[@"state"]=@"unavailable";meta[@"error"]=problem ?: @"私钥不可导出。";}
        NSData *json=[NSJSONSerialization dataWithJSONObject:meta options:NSJSONWritingPrettyPrinted error:nil];
        if(!json || json.length>IOSVMTLSIdentityMetadataLimit){tlsStorageError(@"身份元数据超过可读取的大小上限，未保存身份文件。");return;}
        NSUInteger available=32*1024*1024-MIN(tlsIdentityBytes,(NSUInteger)32*1024*1024);
        if(p12.length>available || json.length>available-p12.length){tlsStorageError(@"身份及元数据超过 32 MiB 存储上限，未保存，请先清理已有记录。");return;}
        // Stage bounded metadata first. It is the commit marker; failed writes
        // must not leave a PKCS#12 whose password/record cannot be found by UI.
        if(!tlsWrite(temporary,json)){tlsStorageError(@"无法写入身份元数据；可在下一次认证时重试。");return;}
        if(p12 && !tlsWrite(p12Name,p12)){tlsRemoveFile(temporary);tlsStorageError(@"无法写入 PKCS#12；可在下一次认证时重试。");return;}
        struct stat oldInfo;NSUInteger oldBytes=fstatat(tlsIdentityDirectoryFD,metaName.fileSystemRepresentation,&oldInfo,AT_SYMLINK_NOFOLLOW)==0 && S_ISREG(oldInfo.st_mode)?(NSUInteger)oldInfo.st_size:0;
        if(renameat(tlsIdentityDirectoryFD,temporary.fileSystemRepresentation,tlsIdentityDirectoryFD,metaName.fileSystemRepresentation)!=0){
            if(p12)tlsRemoveFile(p12Name);tlsRemoveFile(temporary);tlsStorageError(@"无法提交身份记录；已撤销本次文件写入。");return;
        }
        tlsIdentityBytes-=MIN(tlsIdentityBytes,oldBytes);
        tlsIdentityRecords[key]=meta;
        if(p12)[tlsSavedIdentities addObject:key];
        publishNetworkStatus(@{@"tlsIdentityCount":@(tlsIdentityRecords.count),@"tlsIdentityError":@""});
    }
}
// Build a PKCS#12 using the OpenSSL already shipped with the host. No plaintext
// private-key file is written; all intermediates stay inside this process.
static NSData *tlsDER(uint8_t tag, NSData *body) {
    NSMutableData *out=[NSMutableData dataWithBytes:&tag length:1];NSUInteger n=body.length;
    if(n<128){uint8_t b=(uint8_t)n;[out appendBytes:&b length:1];}
    else{uint8_t b[5],count=0;while(n){b[4-count++]=(uint8_t)n;n>>=8;}uint8_t lead=0x80|count;[out appendBytes:&lead length:1];[out appendBytes:b+5-count length:count];}
    [out appendData:body];return out;
}
static NSData *tlsECPrivateDER(NSData *raw) {
    if(!raw.length)return nil;NSUInteger n=(raw.length-1)/3;if(raw.length!=1+3*n || ((const uint8_t *)raw.bytes)[0]!=4)return nil;
    const uint8_t p256[]={0x06,0x08,0x2a,0x86,0x48,0xce,0x3d,0x03,0x01,0x07};
    const uint8_t p384[]={0x06,0x05,0x2b,0x81,0x04,0x00,0x22},p521[]={0x06,0x05,0x2b,0x81,0x04,0x00,0x23};
    NSData *oid=n==32?[NSData dataWithBytes:p256 length:sizeof(p256)]:n==48?[NSData dataWithBytes:p384 length:sizeof(p384)]:n==66?[NSData dataWithBytes:p521 length:sizeof(p521)]:nil;if(!oid)return nil;
    uint8_t version[]={2,1,1};NSMutableData *body=[NSMutableData dataWithBytes:version length:3];
    [body appendData:tlsDER(4,[raw subdataWithRange:NSMakeRange(1+2*n,n)])];[body appendData:tlsDER(0xa0,oid)];
    uint8_t zero=0;NSMutableData *public=[NSMutableData dataWithBytes:&zero length:1];[public appendData:[raw subdataWithRange:NSMakeRange(0,1+2*n)]];
    [body appendData:tlsDER(0xa1,tlsDER(3,public))];return tlsDER(0x30,body);
}
static NSData *tlsPKCS12(NSData *keyDER, NSData *certDER, NSArray<NSData *> *chain, NSString *password) {
    static void *crypto;static dispatch_once_t once;
    dispatch_once(&once,^{
        NSString *folder=[NSBundle bundleForClass:IOSVMNetwork.class].bundlePath.stringByDeletingLastPathComponent;
        crypto=dlopen([[folder stringByAppendingPathComponent:@"OpenSSL.framework/OpenSSL"] fileSystemRepresentation],RTLD_NOW|RTLD_LOCAL);
#if IOSVM_TLS_TESTING
        if(!crypto)crypto=dlopen("/opt/homebrew/opt/openssl@3/lib/libcrypto.dylib",RTLD_NOW|RTLD_LOCAL);
#endif
    });if(!crypto)return nil;
#define TLS_FN(ret,name,args) ret (*name)args=dlsym(crypto,#name);if(!name)return nil
    TLS_FN(void *,d2i_AutoPrivateKey,(void **,const unsigned char **,long));TLS_FN(void *,d2i_X509,(void **,const unsigned char **,long));
    TLS_FN(void *,PKCS12_create,(const char *,const char *,void *,void *,void *,int,int,int,int,int));TLS_FN(int,i2d_PKCS12,(void *,unsigned char **));
    TLS_FN(void,EVP_PKEY_free,(void *));TLS_FN(void,X509_free,(void *));TLS_FN(void,PKCS12_free,(void *));
    TLS_FN(void *,OPENSSL_sk_new_null,(void));TLS_FN(int,OPENSSL_sk_push,(void *,const void *));TLS_FN(void,OPENSSL_sk_free,(void *));
#undef TLS_FN
    const unsigned char *kp=keyDER.bytes,*cp=certDER.bytes;void *key=d2i_AutoPrivateKey(NULL,&kp,keyDER.length),*cert=d2i_X509(NULL,&cp,certDER.length);
    void *stack=OPENSSL_sk_new_null();NSMutableArray *owned=[NSMutableArray new];
    for(NSData *data in (stack ? chain : @[])){if([data isEqual:certDER])continue;const unsigned char *ptr=data.bytes;void *c=d2i_X509(NULL,&ptr,data.length);if(c){[owned addObject:[NSValue valueWithPointer:c]];OPENSSL_sk_push(stack,c);}}
    void *p12=(key && cert && stack)?PKCS12_create(password.UTF8String,"iAppVM client identity",key,cert,stack,0,0,0,0,0):NULL;
    int size=p12?i2d_PKCS12(p12,NULL):0;NSMutableData *result=(size>0 && size<=8*1024*1024)?[NSMutableData dataWithLength:size]:nil;
    if(result){unsigned char *ptr=result.mutableBytes;if(i2d_PKCS12(p12,&ptr)!=size)result=nil;}
    if(p12)PKCS12_free(p12);if(key)EVP_PKEY_free(key);if(cert)X509_free(cert);for(NSValue *v in owned)X509_free(v.pointerValue);if(stack)OPENSSL_sk_free(stack);return result;
}
static void tlsExportCredential(NSURLCredential *credential, NSString *host) {
    if(!tlsIdentities || !credential.identity)return;
    SecIdentityRef identity=credential.identity;SecCertificateRef cert=NULL;SecKeyRef key=NULL;
    if(SecIdentityCopyCertificate(identity,&cert)!=errSecSuccess || !cert)return;
    NSData *der=CFBridgingRelease(SecCertificateCopyData(cert));CFRelease(cert);NSString *fingerprint=tlsDigest(der);
    CFErrorRef error=NULL;NSData *raw=nil;NSDictionary *attrs=nil;
    if(SecIdentityCopyPrivateKey(identity,&key)==errSecSuccess && key){raw=CFBridgingRelease(SecKeyCopyExternalRepresentation(key,&error));attrs=CFBridgingRelease(SecKeyCopyAttributes(key));CFRelease(key);}
    NSString *problem=error?((NSError *)CFBridgingRelease(error)).localizedDescription:@"私钥不可导出，或当前进程无访问权限。";
    if(!raw){tlsSaveIdentity(nil,nil,@"selected-identity",host,fingerprint,problem);return;}
    NSData *keyDER=[attrs[(__bridge id)kSecAttrKeyType] isEqual:(__bridge id)kSecAttrKeyTypeECSECPrimeRandom]?tlsECPrivateDER(raw):raw;
    NSMutableArray *chain=[NSMutableArray new];for(id certificate in [(credential.certificates ?: @[]) subarrayWithRange:NSMakeRange(0,MIN((NSUInteger)32,credential.certificates.count))])if(CFGetTypeID((__bridge CFTypeRef)certificate)==SecCertificateGetTypeID())[chain addObject:CFBridgingRelease(SecCertificateCopyData((__bridge SecCertificateRef)certificate))];
    NSString *password=NSUUID.UUID.UUIDString;NSData *p12=keyDER?tlsPKCS12(keyDER,der,chain,password):nil;
    tlsSaveIdentity(p12,password,@"selected-identity",host,fingerprint,@"私钥已读取，但 PKCS#12 打包失败；请查看 OpenSSL 加载及密钥格式。");
}
static OSStatus (*tlsOriginalImport)(CFDataRef,CFDictionaryRef,CFArrayRef *);
static OSStatus tlsImport(CFDataRef data,CFDictionaryRef options,CFArrayRef *items) {
    OSStatus result=tlsOriginalImport(data,options,items);
    if(result==errSecSuccess && tlsIdentities && data && CFDataGetLength(data)<=8*1024*1024) {
        NSString *password=((__bridge NSDictionary *)options)[(__bridge id)kSecImportExportPassphrase];
        if(!password || [password isKindOfClass:NSString.class])tlsSaveIdentity((__bridge NSData *)data,password,@"pkcs12-import",nil,nil,nil);
    }return result;
}
static bool (*tlsOriginalEvaluateError)(SecTrustRef,CFErrorRef *);
static OSStatus (*tlsOriginalEvaluate)(SecTrustRef,SecTrustResultType *);
static bool tlsEvaluateError(SecTrustRef trust,CFErrorRef *error){if(!trust)return false;CFErrorRef local=NULL;tlsOriginalEvaluateError(trust,&local);if(local)CFRelease(local);if(error)*error=NULL;tlsHit(@"SecTrustEvaluateWithError");return true;}
static OSStatus tlsEvaluate(SecTrustRef trust,SecTrustResultType *result){if(!trust)return errSecParam;tlsOriginalEvaluate(trust,result);if(result)*result=kSecTrustResultProceed;tlsHit(@"SecTrustEvaluate");return errSecSuccess;}
static OSStatus (*tlsOriginalAsync)(SecTrustRef,dispatch_queue_t,SecTrustCallback);
static OSStatus (*tlsOriginalAsyncError)(SecTrustRef,dispatch_queue_t,SecTrustWithErrorCallback);
static OSStatus tlsAsync(SecTrustRef trust,dispatch_queue_t queue,SecTrustCallback callback){if(!trust || !queue || !callback)return errSecParam;CFRetain(trust);dispatch_async(queue,^{tlsHit(@"SecTrustEvaluateAsync");callback(trust,kSecTrustResultProceed);CFRelease(trust);});return errSecSuccess;}
static OSStatus tlsAsyncError(SecTrustRef trust,dispatch_queue_t queue,SecTrustWithErrorCallback callback){if(!trust || !queue || !callback)return errSecParam;CFRetain(trust);dispatch_async(queue,^{tlsHit(@"SecTrustEvaluateAsyncWithError");callback(trust,true,NULL);CFRelease(trust);});return errSecSuccess;}
static void (*tlsOriginalVerify)(void *,int,int (*)(void *,uint8_t *));
static void (*tlsOriginalContextVerify)(void *,int,int (*)(void *,uint8_t *));
static int tlsAcceptVerify(void *ssl,uint8_t *alert){tlsHit(@"BoringSSL custom verify");return 0;}
static void tlsSetVerify(void *ssl,int mode,int (*callback)(void *,uint8_t *)){tlsOriginalVerify(ssl,0,tlsAcceptVerify);}
static void tlsSetContextVerify(void *context,int mode,int (*callback)(void *,uint8_t *)){tlsOriginalContextVerify(context,0,tlsAcceptVerify);}
static BOOL tlsAFEvaluate(id self,SEL sel,SecTrustRef trust,NSString *host){tlsHit(@"AFSecurityPolicy");return YES;}
static NSInteger tlsTSKEvaluate(id self,SEL sel,SecTrustRef trust,NSString *host){tlsHit(@"TSKPinningValidator");return 0;}
static void tlsLibraryHooks(void) {
    if(!tlsBypass)return;
    hook(NSClassFromString(@"AFSecurityPolicy"),NSSelectorFromString(@"evaluateServerTrust:forDomain:"),(IMP)tlsAFEvaluate);
    hook(NSClassFromString(@"TSKPinningValidator"),NSSelectorFromString(@"evaluateTrust:forHostname:"),(IMP)tlsTSKEvaluate);
}
static BOOL tlsWillOverride(NSURLAuthenticationChallenge *challenge) {
    return tlsBypass && [challenge.protectionSpace.authenticationMethod isEqual:NSURLAuthenticationMethodServerTrust] && challenge.protectionSpace.serverTrust;
}
static BOOL tlsOverride(NSURLAuthenticationChallenge *challenge, void (^completion)(NSURLSessionAuthChallengeDisposition,NSURLCredential *)) {
    if(!tlsWillOverride(challenge))return NO;
    tlsHit(@"URLSession ServerTrust");completion(NSURLSessionAuthChallengeUseCredential,[NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust]);return YES;
}
static BOOL tlsStart(NSDictionary *config,NSString *directory,NSError **error) {
    tlsBypass=[config[@"tlsBypass"] boolValue];tlsIdentities=[config[@"tlsIdentities"] boolValue];tlsIdentityLock=[NSObject new];tlsSavedIdentities=[NSMutableSet new];tlsIdentityRecords=[NSMutableDictionary new];
    tlsIdentityRoot=[directory stringByAppendingPathComponent:@"TLSIdentities"];
    if(tlsIdentities){
        if(![NSFileManager.defaultManager createDirectoryAtPath:tlsIdentityRoot withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:error])return NO;
        NSDictionary *attr=[NSFileManager.defaultManager attributesOfItemAtPath:tlsIdentityRoot error:error];if(![attr[NSFileType] isEqual:NSFileTypeDirectory])return NO;
        tlsIdentityDirectoryFD=open(tlsIdentityRoot.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(tlsIdentityDirectoryFD<0)return NO;
        NSArray *files=[NSFileManager.defaultManager contentsOfDirectoryAtPath:tlsIdentityRoot error:error];NSUInteger total=0;
        for(NSString *name in files){NSDictionary *a=[NSFileManager.defaultManager attributesOfItemAtPath:[tlsIdentityRoot stringByAppendingPathComponent:name] error:nil];total+=[a[NSFileSize] unsignedIntegerValue];}
        tlsIdentityBytes=total;
        // Only successful records are terminal; failures remain retryable across restarts.
        NSMutableSet *referenced=[NSMutableSet new];
        for(NSString *name in files)if([name.pathExtension isEqual:@"json"]){
            int fd=openat(tlsIdentityDirectoryFD,name.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK);
            if(fd>=0){struct stat st;BOOL regular=fstat(fd,&st)==0 && S_ISREG(st.st_mode);
                NSMutableData *data=[NSMutableData dataWithLength:IOSVMTLSIdentityMetadataLimit+1];ssize_t length=regular?read(fd,data.mutableBytes,data.length):-1;close(fd);
                id decoded=(length>0 && length<=IOSVMTLSIdentityMetadataLimit)?[NSJSONSerialization JSONObjectWithData:[data subdataWithRange:NSMakeRange(0,length)] options:0 error:nil]:nil;
                NSDictionary *meta=[decoded isKindOfClass:NSDictionary.class]?decoded:nil;NSString *identifier=meta[@"id"],*key=meta[@"materialID"];
                if(![identifier isKindOfClass:NSString.class] || ![[NSUUID alloc] initWithUUIDString:identifier] || ![name isEqual:[identifier stringByAppendingString:@".json"]] || ![key isKindOfClass:NSString.class])continue;
                tlsIdentityRecords[key]=meta;
                NSString *file=meta[@"file"];
                if([meta[@"state"] isEqual:@"exported"] && [file isKindOfClass:NSString.class] && [file isEqual:[identifier stringByAppendingString:@".p12"]]){
                    struct stat item;if(fstatat(tlsIdentityDirectoryFD,file.fileSystemRepresentation,&item,AT_SYMLINK_NOFOLLOW)==0 && S_ISREG(item.st_mode) && item.st_size>0 && item.st_size<=8*1024*1024){[tlsSavedIdentities addObject:key];[referenced addObject:file];}
                }
            }
        }
        // Recover our own interrupted transactions. Preserve files belonging to
        // unreadable metadata instead of guessing that user material is disposable.
        for(NSString *name in files){NSString *identifier=name.stringByDeletingPathExtension;if(![[NSUUID alloc] initWithUUIDString:identifier])continue;
            if([name.pathExtension isEqual:@"pending"])tlsRemoveFile(name);
            else if([name.pathExtension isEqual:@"p12"] && ![referenced containsObject:name]){
                struct stat metadata;BOOL exists=fstatat(tlsIdentityDirectoryFD,[identifier stringByAppendingString:@".json"].fileSystemRepresentation,&metadata,AT_SYMLINK_NOFOLLOW)==0;
                BOOL knownFailure=NO;for(NSDictionary *meta in tlsIdentityRecords.allValues)if([meta[@"id"] isEqual:identifier] && [meta[@"state"] isEqual:@"unavailable"])knownFailure=YES;
                if(!exists || knownFailure)tlsRemoveFile(name);
            }
        }
        tlsOriginalImport=SecPKCS12Import;litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL,tlsOriginalImport,tlsImport,guestImage);
    }
    if(tlsBypass){
        tlsOriginalEvaluateError=SecTrustEvaluateWithError;tlsOriginalEvaluate=SecTrustEvaluate;tlsOriginalAsync=SecTrustEvaluateAsync;tlsOriginalAsyncError=SecTrustEvaluateAsyncWithError;
        litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL,tlsOriginalEvaluateError,tlsEvaluateError,guestImage);
        litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL,tlsOriginalEvaluate,tlsEvaluate,guestImage);
        litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL,tlsOriginalAsync,tlsAsync,guestImage);
        litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL,tlsOriginalAsyncError,tlsAsyncError,guestImage);
        void *boring=dlopen("/usr/lib/libboringssl.dylib",RTLD_NOW|RTLD_LOCAL);
        tlsOriginalVerify=dlsym(boring ?: RTLD_DEFAULT,"SSL_set_custom_verify");if(tlsOriginalVerify)litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL,tlsOriginalVerify,tlsSetVerify,guestImage);
        tlsOriginalContextVerify=dlsym(boring ?: RTLD_DEFAULT,"SSL_CTX_set_custom_verify");if(tlsOriginalContextVerify)litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL,tlsOriginalContextVerify,tlsSetContextVerify,guestImage);
        publishNetworkStatus(@{@"tlsBoringSSLAvailable":@(tlsOriginalVerify!=NULL || tlsOriginalContextVerify!=NULL)});
    }
    publishNetworkStatus(@{@"tlsBypass":@(tlsBypass),@"tlsIdentities":@(tlsIdentities),@"tlsIdentityCount":@(tlsIdentityRecords.count)});return YES;
}
