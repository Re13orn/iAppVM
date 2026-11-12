#import "IOSVMNetwork.h"
#import "IOSVMSocketProxy.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <Network/Network.h>
#import <Network/NSURLSession+Network.h>
#import <WebKit/WebKit.h>
#import <Security/Security.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <dlfcn.h>
#import <CommonCrypto/CommonDigest.h>
#import "../litehook/src/litehook.h"

static BOOL capturing, bodies;
static int journal = -1;
static NSUInteger journalBytes, journalEvents;
static NSObject *journalLock;
static NSArray *proxies;
static NSMutableDictionary<NSString *, NSValue *> *originals;
static char taskRecordKey;
static const NSUInteger bodyLimit = 64 * 1024, journalLimit = 8 * 1024 * 1024;
static void hookTask(NSURLSessionTask *task);
static NSString *networkStatusPath;
static NSMutableDictionary *networkStatus;
static dispatch_queue_t statusQueue;
static BOOL statusScheduled;
static void publishNetworkStatus(NSDictionary *update) {
    if (!statusQueue) return;
    dispatch_async(statusQueue, ^{
        if (update) [networkStatus addEntriesFromDictionary:update];
        if (statusScheduled) return;
        statusScheduled = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC), statusQueue, ^{
            statusScheduled = NO;
            networkStatus[@"socketProxy"] = IOSVMSocketProxyStatus();
            networkStatus[@"updatedAt"] = @(NSDate.date.timeIntervalSince1970);
            NSData *data = [NSJSONSerialization dataWithJSONObject:networkStatus options:0 error:nil];
            [data writeToFile:networkStatusPath options:NSDataWritingAtomic error:nil];
            [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions:@0600} ofItemAtPath:networkStatusPath error:nil];
        });
    });
}

static NSString *safeURL(NSURL *url) {
    // Record URLs verbatim: this is a self-owned testing tool and the
    // operator explicitly wants full request details in the capture journal.
    NSURLComponents *c = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    c.fragment = nil;
    return c.string ?: @"";
}
static NSDictionary *safeHeaders(NSDictionary *headers) {
    // Headers are recorded verbatim (see safeURL).
    NSMutableDictionary *result = [NSMutableDictionary new];
    for (id key in headers) {
        result[[key description]] = [headers[key] description];
    }
    return result;
}
static void emit(NSDictionary *value) {
    if (!capturing || journal < 0) return;
    @synchronized(journalLock) {
        if (journalEvents >= 2000 || journalBytes >= journalLimit) return;
        NSMutableDictionary *event = value.mutableCopy;
        event[@"time"] = @(NSDate.date.timeIntervalSince1970);
        NSData *data = [NSJSONSerialization dataWithJSONObject:event options:0 error:nil];
        if (!data || data.length + 1 > journalLimit - journalBytes) return;
        NSMutableData *line = data.mutableCopy; [line appendBytes:"\n" length:1];
        const char *p = line.bytes; NSUInteger left = line.length;
        while (left) { ssize_t n = write(journal, p, left); if (n < 0 && errno == EINTR) continue; if (n <= 0) break; p += n; left -= n; }
        journalBytes += line.length - left; journalEvents++;
    }
}
static NSMutableDictionary *record(NSURLSessionTask *task) {
    if (!task) return nil;
    hookTask(task);
    if (!capturing) return nil;
    @synchronized(task) {
        NSMutableDictionary *r = objc_getAssociatedObject(task, &taskRecordKey);
        if (!r) {
            NSURLRequest *q = task.originalRequest ?: task.currentRequest;
            r = [@{@"id": NSUUID.UUID.UUIDString, @"layer": @"urlsession", @"state": @"created", @"startedAt": @(NSDate.date.timeIntervalSince1970), @"url": safeURL(q.URL), @"method": q.HTTPMethod ?: @"GET", @"requestHeaders": safeHeaders(q.allHTTPHeaderFields ?: @{}), @"bodyBytes": @0} mutableCopy];
            if (bodies && q.HTTPBody) {
                r[@"requestBodyBase64"] = [[q.HTTPBody subdataWithRange:NSMakeRange(0, MIN(bodyLimit, q.HTTPBody.length))] base64EncodedStringWithOptions:0];
                r[@"requestBodyTruncated"] = @(q.HTTPBody.length > bodyLimit);
            }
            if (q.HTTPBodyStream) r[@"requestBodyUnavailable"] = @"stream is not consumed by capture";
            objc_setAssociatedObject(task, &taskRecordKey, r, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            emit(r);
        }
        return r;
    }
}
static void response(NSURLSessionTask *task, NSURLResponse *resp) {
    NSMutableDictionary *r = record(task); if (!r || !resp) return;
    @synchronized(task) {
        r[@"responseURL"] = safeURL(resp.URL);
        r[@"mimeType"] = resp.MIMEType ?: @"";
        if ([resp isKindOfClass:NSHTTPURLResponse.class]) {
            r[@"status"] = @([(NSHTTPURLResponse *)resp statusCode]);
            r[@"responseHeaders"] = safeHeaders([(NSHTTPURLResponse *)resp allHeaderFields]);
        }
    }
}
static void received(NSURLSessionTask *task, NSData *data) {
    NSMutableDictionary *r = record(task); if (!r || !data) return;
    @synchronized(task) {
        r[@"bodyBytes"] = @([r[@"bodyBytes"] unsignedLongLongValue] + data.length);
        if (bodies) {
            NSMutableData *buffer = r[@"buffer"];
            if (!buffer) { buffer = [NSMutableData new]; r[@"buffer"] = buffer; }
            NSUInteger keep = MIN(data.length, bodyLimit - buffer.length);
            [buffer appendBytes:data.bytes length:keep];
        }
    }
}
static void finish(NSURLSessionTask *task, NSError *error) {
    NSMutableDictionary *r = record(task); if (!r) return;
    response(task, task.response);
    @synchronized(task) {
        if ([r[@"state"] isEqual:@"complete"]) return;
        NSMutableData *buffer = r[@"buffer"];
        if (buffer) { r[@"responseBodyBase64"] = [buffer base64EncodedStringWithOptions:0]; [r removeObjectForKey:@"buffer"]; r[@"responseBodyTruncated"] = @([r[@"bodyBytes"] unsignedLongLongValue] > bodyLimit); }
        r[@"state"] = @"complete";
        r[@"duration"] = @(NSDate.date.timeIntervalSince1970 - [r[@"startedAt"] doubleValue]);
        r[@"sentBytes"] = @(task.countOfBytesSent);
        r[@"receivedBytes"] = @(task.countOfBytesReceived);
        if (error) { r[@"errorDomain"] = error.domain; r[@"errorCode"] = @(error.code); r[@"error"] = error.localizedDescription; }
        emit(r);
    }
}

// Observation only: never evaluate trust, import a key or change a disposition.
static NSString *tlsDigest(NSData *data) {
    unsigned char hash[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(data.bytes, (CC_LONG)data.length, hash);
    NSMutableString *text=[NSMutableString new]; for(NSUInteger i=0;i<sizeof(hash);i++)[text appendFormat:@"%02x",hash[i]];
    return text;
}
static NSDictionary *tlsCertificate(SecCertificateRef certificate) {
    if (!certificate) return @{};
    NSData *der=CFBridgingRelease(SecCertificateCopyData(certificate));
    NSMutableDictionary *result=[NSMutableDictionary new];
    result[@"subject"]=CFBridgingRelease(SecCertificateCopySubjectSummary(certificate)) ?: @"";
    if (der) {
        result[@"sha256"]=tlsDigest(der);
        if (der.length<=16384) result[@"derBase64"]=[der base64EncodedStringWithOptions:0];
        else result[@"derOmitted"]=@YES;
    }
    return result;
}
static NSDictionary *tlsChallenge(NSURLSession *session, NSURLSessionTask *task, NSURLAuthenticationChallenge *challenge, NSString *scope) {
    NSString *method=challenge.protectionSpace.authenticationMethod;
    if (!capturing || (! [method isEqual:NSURLAuthenticationMethodServerTrust] && ![method isEqual:NSURLAuthenticationMethodClientCertificate])) return nil;
    NSString *challengeID=NSUUID.UUID.UUIDString;
    NSURLComponents *endpoint=[NSURLComponents new];endpoint.scheme=challenge.protectionSpace.protocol ?: @"https";
    endpoint.host=challenge.protectionSpace.host;endpoint.port=@(challenge.protectionSpace.port);
    NSMutableDictionary *event=[@{@"id":challengeID,@"challengeID":challengeID,@"layer":@"tls",@"state":@"challenge",
        @"scope":scope,@"method":method,@"host":challenge.protectionSpace.host ?: @"",@"port":@(challenge.protectionSpace.port),
        @"url":safeURL(task.originalRequest.URL ?: endpoint.URL),@"previousFailureCount":@(challenge.previousFailureCount),
        @"sessionObject":[NSString stringWithFormat:@"%p",session]} mutableCopy];
    if(task) event[@"requestID"]=record(task)[@"id"] ?: @"";
    SecTrustRef trust=challenge.protectionSpace.serverTrust;
    if(trust) {
        // Index zero is documented as available without evaluating trust.
        // GetCertificateCount can trigger evaluation and must not be used here.
        SecCertificateRef leaf=SecTrustGetCertificateAtIndex(trust,0);
        event[@"serverCertificates"]=leaf?@[tlsCertificate(leaf)]:@[];
        event[@"certificateScope"]=@"leaf-only-no-trust-evaluation";
    }
    emit(event);
    return event;
}
#include "IOSVMTLS.inc"

static void tlsDecision(NSDictionary *challenge, NSURLSessionAuthChallengeDisposition disposition, NSURLCredential *credential) {
    if(!challenge)return;
    NSMutableDictionary *event=challenge.mutableCopy;
    event[@"id"]=NSUUID.UUID.UUIDString;event[@"state"]=@"decision";
    [event removeObjectForKey:@"serverCertificates"];
    NSDictionary *names=@{@(NSURLSessionAuthChallengeUseCredential):@"useCredential",@(NSURLSessionAuthChallengePerformDefaultHandling):@"performDefaultHandling",
        @(NSURLSessionAuthChallengeCancelAuthenticationChallenge):@"cancelAuthenticationChallenge",@(NSURLSessionAuthChallengeRejectProtectionSpace):@"rejectProtectionSpace"};
    event[@"disposition"]=names[@(disposition)] ?: @"unknown";
    event[@"credentialKind"]=credential ? @"other" : @"none";
    if(credential.identity) {
        tlsExportCredential(credential,challenge[@"host"]);
        event[@"credentialKind"]=@"clientIdentity";
        SecCertificateRef certificate=NULL;
        if(SecIdentityCopyCertificate(credential.identity,&certificate)==errSecSuccess && certificate) {
            event[@"clientCertificate"]=tlsCertificate(certificate);CFRelease(certificate);
        }
    }
    NSArray *stack=NSThread.callStackSymbols;
    event[@"callStack"]=[stack subarrayWithRange:NSMakeRange(0,MIN((NSUInteger)16,stack.count))];
    emit(event);
}

// A forwarding delegate preserves the application's certificate checks, redirects,
// authentication and optional delegate methods. No replacement transport is created.
@interface IOSVMNetworkDelegate : NSObject <NSURLSessionDataDelegate, NSURLSessionDownloadDelegate>
@property(nonatomic, strong) id downstream;
@end
@implementation IOSVMNetworkDelegate
- (BOOL)respondsToSelector:(SEL)sel {
    // Preserve URLSession's session/task fallback routing exactly. Advertising an
    // authentication callback that the app never implemented changes that routing.
    if(sel==@selector(URLSession:didReceiveChallenge:completionHandler:) || sel==@selector(URLSession:task:didReceiveChallenge:completionHandler:))
        return (tlsBypass && sel==@selector(URLSession:task:didReceiveChallenge:completionHandler:)) || [self.downstream respondsToSelector:sel];
    return [super respondsToSelector:sel] || [self.downstream respondsToSelector:sel];
}
- (void)URLSession:(NSURLSession *)session didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition,NSURLCredential *))completion {
    NSDictionary *event=tlsChallenge(session,nil,challenge,@"session");
    if(event && tlsWillOverride(challenge)){NSMutableDictionary *testing=event.mutableCopy;testing[@"testingOverride"]=@YES;event=testing;}
    void (^observed)(NSURLSessionAuthChallengeDisposition,NSURLCredential *)=^(NSURLSessionAuthChallengeDisposition disposition,NSURLCredential *credential){
        if(!event)tlsExportCredential(credential,challenge.protectionSpace.host);
        tlsDecision(event,disposition,credential);completion(disposition,credential);
    };
    if(tlsOverride(challenge,observed))return;
    if([self.downstream respondsToSelector:_cmd]) [self.downstream URLSession:session didReceiveChallenge:challenge completionHandler:observed];
    else observed(NSURLSessionAuthChallengePerformDefaultHandling,nil);
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition,NSURLCredential *))completion {
    NSDictionary *event=tlsChallenge(session,task,challenge,@"task");
    if(event && tlsWillOverride(challenge)){NSMutableDictionary *testing=event.mutableCopy;testing[@"testingOverride"]=@YES;event=testing;}
    void (^observed)(NSURLSessionAuthChallengeDisposition,NSURLCredential *)=^(NSURLSessionAuthChallengeDisposition disposition,NSURLCredential *credential){
        if(!event)tlsExportCredential(credential,challenge.protectionSpace.host);
        tlsDecision(event,disposition,credential);completion(disposition,credential);
    };
    if(tlsOverride(challenge,observed))return;
    if([self.downstream respondsToSelector:_cmd]) [self.downstream URLSession:session task:task didReceiveChallenge:challenge completionHandler:observed];
    else observed(NSURLSessionAuthChallengePerformDefaultHandling,nil);
}
- (id)forwardingTargetForSelector:(SEL)sel { return [self.downstream respondsToSelector:sel] ? self.downstream : [super forwardingTargetForSelector:sel]; }
- (void)URLSession:(NSURLSession *)s dataTask:(NSURLSessionDataTask *)t didReceiveResponse:(NSURLResponse *)r completionHandler:(void (^)(NSURLSessionResponseDisposition))completion {
    response(t, r);
    if ([self.downstream respondsToSelector:_cmd]) [self.downstream URLSession:s dataTask:t didReceiveResponse:r completionHandler:completion]; else completion(NSURLSessionResponseAllow);
}
- (void)URLSession:(NSURLSession *)s dataTask:(NSURLSessionDataTask *)t didReceiveData:(NSData *)data {
    received(t, data);
    if ([self.downstream respondsToSelector:_cmd]) [self.downstream URLSession:s dataTask:t didReceiveData:data];
}
- (void)URLSession:(NSURLSession *)s task:(NSURLSessionTask *)t didCompleteWithError:(NSError *)e {
    finish(t, e);
    if ([self.downstream respondsToSelector:_cmd]) [self.downstream URLSession:s task:t didCompleteWithError:e];
}
- (void)URLSession:(NSURLSession *)s downloadTask:(NSURLSessionDownloadTask *)t didFinishDownloadingToURL:(NSURL *)url {
    // Do not read or move the application's downloaded file.
    response(t, t.response);
    if ([self.downstream respondsToSelector:_cmd]) [self.downstream URLSession:s downloadTask:t didFinishDownloadingToURL:url];
}
@end

// Every installed trampoline carries its own original IMP. Dynamic-class lookup
// alone cannot distinguish a child call from that child's call to super.
typedef struct IOSVMHookFrame {
    __unsafe_unretained id object;
    SEL selector;
    IMP implementation;
    struct IOSVMHookFrame *previous;
} IOSVMHookFrame;
static _Thread_local IOSVMHookFrame *activeHookFrame;
static IMP original(id object, SEL sel) {
    for (IOSVMHookFrame *frame=activeHookFrame;frame;frame=frame->previous)
        if (frame->object==object && frame->selector==sel) return frame->implementation;
    return NULL;
}
#define IOSVM_WITH_ORIGINAL(...) do { \
    IOSVMHookFrame frame={object,sel,old,activeHookFrame}; \
    activeHookFrame=&frame; \
    @try { __VA_ARGS__; } @finally { activeHookFrame=frame.previous; } \
} while (0)
static void hook(Class cls, SEL sel, IMP replacement) {
    if (!cls || !replacement) return;
    @synchronized(originals) {
        Method method=class_getInstanceMethod(cls,sel);if(!method)return;
        NSString *key=[NSString stringWithFormat:@"%p/%s",cls,sel_getName(sel)];
        if(originals[key])return;
        IMP old=method_getImplementation(method);
        // An inherited trampoline already supplies the correct original. A real
        // override is installed independently, including one that calls super.
        BOOL owns=NO;unsigned count=0;Method *methods=class_copyMethodList(cls,&count);
        for(unsigned i=0;i<count;i++)if(method_getName(methods[i])==sel){owns=YES;break;}
        free(methods);
        if(!owns)for(Class parent=class_getSuperclass(cls);parent;parent=class_getSuperclass(parent)) {
            NSValue *installed=originals[[NSString stringWithFormat:@"%p/%s",parent,sel_getName(sel)]];
            if(installed && installed.pointerValue==old)return;
        }
        NSMethodSignature *signature=[NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
        const char *result=signature.methodReturnType;NSUInteger arguments=signature.numberOfArguments;
        id block=nil;
        if(result[0]=='v' && arguments==3)
            block=^(id object,id value){IOSVM_WITH_ORIGINAL(((void(*)(id,SEL,id))replacement)(object,sel,value));};
        else if(result[0]=='v' && arguments==2)
            block=^(id object){IOSVM_WITH_ORIGINAL(((void(*)(id,SEL))replacement)(object,sel));};
        else if(result[0]=='@' && arguments==2)
            block=^id(id object){IOSVM_WITH_ORIGINAL(return ((id(*)(id,SEL))replacement)(object,sel));};
        else if(result[0]=='@' && arguments==3)
            block=^id(id object,id value){IOSVM_WITH_ORIGINAL(return ((id(*)(id,SEL,id))replacement)(object,sel,value));};
        else if(result[0]=='@' && arguments==4 && !strcmp([signature getArgumentTypeAtIndex:2],@encode(CGRect)))
            block=^id(id object,CGRect rect,id value){IOSVM_WITH_ORIGINAL(return ((id(*)(id,SEL,CGRect,id))replacement)(object,sel,rect,value));};
        else if(result[0]=='@' && arguments==4)
            block=^id(id object,id first,id second){IOSVM_WITH_ORIGINAL(return ((id(*)(id,SEL,id,id))replacement)(object,sel,first,second));};
        else if(result[0]=='@' && arguments==5)
            block=^id(id object,id first,id second,id third){IOSVM_WITH_ORIGINAL(return ((id(*)(id,SEL,id,id,id))replacement)(object,sel,first,second,third));};
        else if(!strcmp(result,@encode(BOOL)) && arguments==4)
            block=^BOOL(id object,void *trust,id host){IOSVM_WITH_ORIGINAL(return ((BOOL(*)(id,SEL,void *,id))replacement)(object,sel,trust,host));};
        else if(!strcmp(result,@encode(NSInteger)) && arguments==4)
            block=^NSInteger(id object,void *trust,id host){IOSVM_WITH_ORIGINAL(return ((NSInteger(*)(id,SEL,void *,id))replacement)(object,sel,trust,host));};
        if(!block)return; // Refuse an unsupported ABI instead of guessing it.
        IMP trampoline=imp_implementationWithBlock(block);
        if(!trampoline)return;
        originals[key]=[NSValue valueWithPointer:trampoline];
        if(!class_addMethod(cls,sel,trampoline,method_getTypeEncoding(method)))method_setImplementation(method,trampoline);
    }
}
#undef IOSVM_WITH_ORIGINAL
static void taskDelegate(id self, SEL sel, id delegate) {
    if (delegate && ![delegate isKindOfClass:IOSVMNetworkDelegate.class]) {
        IOSVMNetworkDelegate *wrapper=[IOSVMNetworkDelegate new];wrapper.downstream=delegate;delegate=wrapper;
    }
    ((void (*)(id,SEL,id))original(self,sel))(self,sel,delegate);
}
static void hookTask(NSURLSessionTask *task) {
    hook(object_getClass(task),@selector(setDelegate:),(IMP)taskDelegate);
}
static id plainTask(id self, SEL sel, id input) {
    id task=((id (*)(id,SEL,id))original(self,sel))(self,sel,input);if(tlsBypass || tlsIdentities)hookTask(task);record(task);return task;
}
static id plainUpload(id self, SEL sel, id request, id source) {
    id task=((id (*)(id,SEL,id,id))original(self,sel))(self,sel,request,source);if(tlsBypass || tlsIdentities)hookTask(task);record(task);return task;
}
static id dataRequest(id self, SEL sel, NSURLRequest *request, void (^completion)(NSData *, NSURLResponse *, NSError *)) {
    __block __weak NSURLSessionTask *weakTask;
    id task = ((id (*)(id,SEL,id,id))original(self,sel))(self, sel, request, completion ? ^(NSData *d, NSURLResponse *r, NSError *e) {
        NSURLSessionTask *t = weakTask; response(t,r); received(t,d); finish(t,e); completion(d,r,e);
    } : nil);
    weakTask = task; record(task); return task;
}
static id dataURL(id self, SEL sel, NSURL *url, void (^completion)(NSData *, NSURLResponse *, NSError *)) {
    __block __weak NSURLSessionTask *weakTask;
    id task = ((id (*)(id,SEL,id,id))original(self,sel))(self, sel, url, completion ? ^(NSData *d, NSURLResponse *r, NSError *e) {
        NSURLSessionTask *t = weakTask; response(t,r); received(t,d); finish(t,e); completion(d,r,e);
    } : nil);
    weakTask = task; record(task); return task;
}
static id uploadData(id self, SEL sel, NSURLRequest *request, NSData *data, void (^completion)(NSData *, NSURLResponse *, NSError *)) {
    __block __weak NSURLSessionTask *weakTask;
    id task = ((id (*)(id,SEL,id,id,id))original(self,sel))(self,sel,request,data,completion ? ^(NSData *d,NSURLResponse *r,NSError *e){ NSURLSessionTask *t=weakTask; response(t,r); received(t,d); finish(t,e); completion(d,r,e); } : nil);
    weakTask=task; NSMutableDictionary *entry=record(task);
    if (bodies && [data isKindOfClass:NSData.class] && entry) @synchronized(task) { entry[@"requestBodyBase64"]=[[data subdataWithRange:NSMakeRange(0,MIN(data.length,bodyLimit))] base64EncodedStringWithOptions:0]; entry[@"requestBodyTruncated"]=@(data.length>bodyLimit); }
    return task;
}
static id download(id self, SEL sel, id input, void (^completion)(NSURL *, NSURLResponse *, NSError *)) {
    __block __weak NSURLSessionTask *weakTask;
    id task=((id (*)(id,SEL,id,id))original(self,sel))(self,sel,input,completion ? ^(NSURL *u,NSURLResponse *r,NSError *e){NSURLSessionTask *t=weakTask;response(t,r);finish(t,e);completion(u,r,e);} : nil);
    weakTask=task;if(tlsBypass || tlsIdentities)hookTask(task);record(task);return task;
}
static void hookSession(Class cls) {
    if (!capturing && !tlsBypass && !tlsIdentities) return;
    hook(cls,@selector(dataTaskWithRequest:completionHandler:),(IMP)dataRequest);
    hook(cls,@selector(dataTaskWithURL:completionHandler:),(IMP)dataURL);
    hook(cls,@selector(uploadTaskWithRequest:fromData:completionHandler:),(IMP)uploadData);
    hook(cls,@selector(uploadTaskWithRequest:fromFile:completionHandler:),(IMP)uploadData);
    hook(cls,@selector(downloadTaskWithRequest:completionHandler:),(IMP)download);
    hook(cls,@selector(downloadTaskWithURL:completionHandler:),(IMP)download);
    for (NSString *name in @[@"dataTaskWithRequest:",@"dataTaskWithURL:",@"downloadTaskWithRequest:",@"downloadTaskWithURL:",@"uploadTaskWithStreamedRequest:",@"webSocketTaskWithURL:",@"webSocketTaskWithRequest:"])
        hook(cls,NSSelectorFromString(name),(IMP)plainTask);
    hook(cls,@selector(uploadTaskWithRequest:fromData:),(IMP)plainUpload);
    hook(cls,@selector(uploadTaskWithRequest:fromFile:),(IMP)plainUpload);
}
static id makeSession(id self, SEL sel, NSURLSessionConfiguration *config, id delegate, NSOperationQueue *queue) {
    tlsLibraryHooks();
    NSURLSessionConfiguration *copy = config.copy;
    if (proxies.count) { if (@available(iOS 17.0, macOS 14.0, *)) copy.proxyConfigurations = proxies; }
    if ((capturing || tlsBypass || tlsIdentities) && ![delegate isKindOfClass:IOSVMNetworkDelegate.class]) { IOSVMNetworkDelegate *d=[IOSVMNetworkDelegate new];d.downstream=delegate;delegate=d; }
    NSURLSession *s=((id (*)(id,SEL,id,id,id))original(self,sel))(self,sel,copy,delegate,queue);
    hookSession(object_getClass(s));return s;
}
static id sharedSession(id self, SEL sel) {
    static NSURLSession *session; static dispatch_once_t once;
    dispatch_once(&once, ^{session=[NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.defaultSessionConfiguration delegate:nil delegateQueue:nil];});
    return session;
}
static id simpleSession(id self, SEL sel, NSURLSessionConfiguration *config) {
    return [NSURLSession sessionWithConfiguration:config delegate:nil delegateQueue:nil];
}
static id webStore(id self, SEL sel) {
    id store=((id (*)(id,SEL))original(self,sel))(self,sel);
    if (@available(iOS 17.0, macOS 14.0, *)) [store setProxyConfigurations:proxies];
    return store;
}
static id webViewInit(id self, SEL sel, CGRect frame, WKWebViewConfiguration *configuration) {
    if (@available(iOS 17.0, macOS 14.0, *)) configuration.websiteDataStore.proxyConfigurations=proxies;
    return ((id (*)(id,SEL,CGRect,id))original(self,sel))(self,sel,frame,configuration);
}

// Socket import observation adds endpoint metadata, not decrypted TLS payloads.
// System shared-cache images are excluded; observation never rewrites destinations.
static int (*realConnect)(int,const struct sockaddr *,socklen_t);
static ssize_t (*realSendmsg)(int,const struct msghdr *,int);
static int (*realConnectNoCancel)(int,const struct sockaddr *,socklen_t);
static ssize_t (*realSendto)(int,const void *,size_t,int,const struct sockaddr *,socklen_t);
static void socketEvent(int fd,const struct sockaddr *address,socklen_t length,int result,int savedErrno,NSString *kind,NSUInteger bytes) {
    if (!address) return;
    char host[INET6_ADDRSTRLEN]; unsigned port;
    if (address->sa_family==AF_INET && length>=sizeof(struct sockaddr_in)) { const struct sockaddr_in *a=(void *)address; if(!inet_ntop(AF_INET,&a->sin_addr,host,sizeof(host)))return;port=ntohs(a->sin_port); }
    else if(address->sa_family==AF_INET6 && length>=sizeof(struct sockaddr_in6)) {const struct sockaddr_in6 *a=(void *)address;if(!inet_ntop(AF_INET6,&a->sin6_addr,host,sizeof(host)))return;port=ntohs(a->sin6_port);}
    else return;
    emit(@{@"id":NSUUID.UUID.UUIDString,@"layer":@"socket",@"state":kind,@"url":[NSString stringWithFormat:@"%@:%u",@(host),port],@"method":kind,@"fd":@(fd),@"result":@(result),@"errno":@(result<0?savedErrno:0),@"bytes":@(bytes)});
}
static int connectObserved(int fd,const struct sockaddr *a,socklen_t n) {int r=IOSVMSocketProxyConnect(fd,a,n,realConnect),e=errno;socketEvent(fd,a,n,r,e,@"connect",0);errno=e;return r;}
static int connectNoCancelObserved(int fd,const struct sockaddr *a,socklen_t n) {int r=IOSVMSocketProxyConnect(fd,a,n,realConnectNoCancel),e=errno;socketEvent(fd,a,n,r,e,@"connect",0);errno=e;return r;}
static ssize_t sendtoObserved(int fd,const void *b,size_t count,int flags,const struct sockaddr *a,socklen_t n) {
    ssize_t r;
    if (IOSVMSocketProxyRejectDatagram(fd,a,n)) {errno=EPROTONOSUPPORT;r=-1;}
    else r=realSendto(fd,b,count,flags,a,n);
    int e=errno;socketEvent(fd,a,n,(int)r,e,@"sendto",r>0?(NSUInteger)r:0);errno=e;return r;
}
static ssize_t sendmsgObserved(int fd,const struct msghdr *message,int flags) {
    ssize_t r;
    const struct sockaddr *a=message?message->msg_name:NULL;
    socklen_t n=message?message->msg_namelen:0;
    if (IOSVMSocketProxyRejectDatagram(fd,a,n)) {errno=EPROTONOSUPPORT;r=-1;}
    else r=realSendmsg(fd,message,flags);
    // Mirror sendtoObserved: a rejected datagram still shows up in the log.
    int e=errno;socketEvent(fd,a,n,(int)r,e,@"sendmsg",r>0?(NSUInteger)r:0);errno=e;return r;
}
static BOOL guestImage(const mach_header_u *h) {
    Dl_info info={0}, own={0};
    dladdr((void *)guestImage,&own);
    // Do not rebind relay imports, otherwise its upstream connect would recurse into itself.
    return dladdr(h,&info)&&info.dli_fname&&info.dli_fbase!=own.dli_fbase&&strncmp(info.dli_fname,"/System/",8)&&strncmp(info.dli_fname,"/usr/lib/",9);
}

@implementation IOSVMNetwork
+ (NSDictionary *)socketProxyStatus { return IOSVMSocketProxyStatus(); }
+ (BOOL)startWithSettings:(NSString *)settings root:(NSString *)root error:(NSError **)error {
    if (![NSFileManager.defaultManager fileExistsAtPath:settings]) return YES;
    NSData *data=[NSData dataWithContentsOfFile:settings];
    id value=data && data.length<=16384?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
    NSString *problem=nil;
    if (![value isKindOfClass:NSDictionary.class] || ![value[@"version"] isEqual:@1] || CFGetTypeID((__bridge CFTypeRef)value[@"version"])==CFBooleanGetTypeID()) problem=@"网络配置无效，请在 App 的网络工具页重新保存。";
    NSDictionary *config=problem?@{}:value;
    for (NSString *key in @[@"capture",@"bodies"]) if (config[key] && CFGetTypeID((__bridge CFTypeRef)config[key])!=CFBooleanGetTypeID()) problem=@"网络捕获开关必须是布尔值。";
    NSString *type=config[@"proxyType"] ?: @"off", *host=config[@"host"];
    if (![@[@"off",@"http",@"socks5"] containsObject:type]) problem=@"代理类型无效。";
    if (![type isEqual:@"off"] && (![host isKindOfClass:NSString.class] || !host.length || host.length>253 || [host containsString:@"/"] || [host rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location!=NSNotFound || ![config[@"port"] isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)config[@"port"])==CFBooleanGetTypeID() || [config[@"port"] doubleValue]!=[config[@"port"] integerValue] || [config[@"port"] integerValue]<1 || [config[@"port"] integerValue]>65535)) problem=@"代理地址或端口无效。";
    if (problem) {if(error)*error=[NSError errorWithDomain:@"IOSVMNetwork" code:1 userInfo:@{NSLocalizedDescriptionKey:problem}];return NO;}
    for(NSString *key in @[@"tlsBypass",@"tlsIdentities"]){if(config[key] && CFGetTypeID((__bridge CFTypeRef)config[key])!=CFBooleanGetTypeID()){if(error)*error=[NSError errorWithDomain:@"IOSVMNetwork" code:1 userInfo:@{NSLocalizedDescriptionKey:@"TLS 配置必须为布尔值。"}];return NO;}}
    capturing=[config[@"capture"] boolValue];bodies=[config[@"bodies"] boolValue];
    originals=[NSMutableDictionary new];journalLock=[NSObject new];
    NSString *statusDirectory=[root stringByAppendingPathComponent:@"Library/iOSVM/Network"];
    if (![NSFileManager.defaultManager createDirectoryAtPath:statusDirectory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:error]) return NO;
    unsigned char hash[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(data.bytes,(CC_LONG)data.length,hash);
    NSMutableString *digest=[NSMutableString new]; for (NSUInteger i=0;i<sizeof(hash);i++) [digest appendFormat:@"%02x",hash[i]];
    networkStatusPath=[statusDirectory stringByAppendingPathComponent:@"status.json"];
    networkStatus=[@{@"pid":@(getpid()),@"startedAt":@(NSDate.date.timeIntervalSince1970),@"settingsDigest":digest,
                     @"proxyType":type,@"configurationLoaded":@NO} mutableCopy];
    statusQueue=dispatch_queue_create("dev.iosvm.network-status",DISPATCH_QUEUE_SERIAL);
    if (capturing) {
        NSString *directory=[root stringByAppendingPathComponent:@"Library/iOSVM/Network"];
        if (![NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:error])return NO;
        NSArray *files=[[[NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:nil] filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF BEGINSWITH 'traffic-' AND SELF ENDSWITH '.jsonl'"]] sortedArrayUsingSelector:@selector(compare:)];
        for(NSUInteger i=0;i+9<files.count;i++)[NSFileManager.defaultManager removeItemAtPath:[directory stringByAppendingPathComponent:files[i]] error:nil];
        NSString *path=[directory stringByAppendingPathComponent:[NSString stringWithFormat:@"traffic-%.0f-%@.jsonl",NSDate.date.timeIntervalSince1970*1000,NSUUID.UUID.UUIDString]];
        journal=open(path.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
        if(journal<0){if(error)*error=[NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];return NO;}
        emit(@{@"id":@"session",@"layer":@"session",@"state":@"started",@"url":@"",@"proxyType":type,@"bodies":@(bodies),@"eventLimit":@2000,@"byteLimit":@(journalLimit),@"coverage":@"URLSession request/response; guest socket endpoints and TCP proxy tunnels. Socket TLS bytes and WebKit payloads are not decrypted. Intercepted external UDP is rejected while proxying."});
    }
    if (![type isEqual:@"off"]) {
        if (@available(iOS 17.0, macOS 14.0, *)) {
            nw_endpoint_t endpoint=nw_endpoint_create_host(host.UTF8String,[[config[@"port"] stringValue] UTF8String]);
            nw_proxy_config_t proxy=endpoint?([type isEqual:@"http"]?nw_proxy_config_create_http_connect(endpoint,NULL):nw_proxy_config_create_socksv5(endpoint)):nil;
            if (!proxy) {if(error)*error=[NSError errorWithDomain:@"IOSVMNetwork" code:3 userInfo:@{NSLocalizedDescriptionKey:@"系统无法创建此代理配置，请检查服务器地址。"}];return NO;}
            nw_proxy_config_set_failover_allowed(proxy,false);
            proxies=@[proxy];
            nw_privacy_context_add_proxy(NW_DEFAULT_PRIVACY_CONTEXT,proxy);
            hook(object_getClass(WKWebsiteDataStore.class),@selector(defaultDataStore),(IMP)webStore);
            hook(object_getClass(WKWebsiteDataStore.class),@selector(nonPersistentDataStore),(IMP)webStore);
            hook(WKWebView.class,@selector(initWithFrame:configuration:),(IMP)webViewInit);
        } else {if(error)*error=[NSError errorWithDomain:@"IOSVMNetwork" code:2 userInfo:@{NSLocalizedDescriptionKey:@"按 App 代理需要 iOS 17 或更高版本。"}];return NO;}
    }
    if (proxies.count) {
        if (!IOSVMSocketProxyConfigure(type,host,[config[@"port"] unsignedShortValue],^(NSString *state,NSString *target,int code) {
            emit(@{@"id":NSUUID.UUID.UUIDString,@"layer":@"proxy",@"state":state,@"url":target,@"proxyType":type,@"errno":@(code)});
            publishNetworkStatus(@{@"lastProxyState":state,@"lastProxyError":@(code)});
        },error)) return NO;
        litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL,getpeername,IOSVMSocketProxyGetPeerName,guestImage);
        realSendmsg=sendmsg;
        litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL,realSendmsg,sendmsgObserved,guestImage);
    }
    if (!tlsStart(config,statusDirectory,error))return NO;
    if (capturing || proxies.count || tlsBypass || tlsIdentities) {
        realConnect=connect;realSendto=sendto;
        realConnectNoCancel=dlsym(RTLD_DEFAULT,"connect$NOCANCEL");
        litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL,realConnect,connectObserved,guestImage);
        if (realConnectNoCancel && realConnectNoCancel!=realConnect)
            litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL,realConnectNoCancel,connectNoCancelObserved,guestImage);
        litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL,realSendto,sendtoObserved,guestImage);
        hook(object_getClass(NSURLSession.class),@selector(sessionWithConfiguration:delegate:delegateQueue:),(IMP)makeSession);
        hook(object_getClass(NSURLSession.class),@selector(sessionWithConfiguration:),(IMP)simpleSession);
        hook(object_getClass(NSURLSession.class),@selector(sharedSession),(IMP)sharedSession);
    }
    publishNetworkStatus(@{@"configurationLoaded":@YES});
    return YES;
}
@end
