// SPDX-License-Identifier: AGPL-3.0-or-later
// Inspired by Nyxian LiveProcess's explicit argv/environment/cwd and PEFileTable.
// This is a bounded, opt-in launcher for one LiveContainer Guest, not a process VM.
#import "iOSVMRuntime.h"
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>

static NSMutableDictionary *session;
static NSDictionary *debugOptions;
static NSString *sessionPath;
static NSMutableArray *stageHistory;
static dispatch_source_t consoleSource;
static NSError *runtimeError(NSString *message) {
    return [NSError errorWithDomain:@"iOSVMRuntime" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}
static BOOL textValid(id value, NSUInteger limit) {
    return [value isKindOfClass:NSString.class] && [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding] <= limit &&
        [value rangeOfString:[NSString stringWithFormat:@"%C", (unichar)0]].location == NSNotFound;
}

@implementation IOSVMRuntime
+ (void)configureDebug:(NSDictionary *)options { debugOptions = [options copy]; }
+ (NSDictionary *)validateConfiguration:(NSData *)data root:(NSString *)root error:(NSError **)error {
    NSString *problem = nil;
    if (data.length > 32768) problem = @"启动配置不得超过 32 KiB。";
    id config = problem ? nil : [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if (!problem && ![config isKindOfClass:NSDictionary.class]) problem = @"启动配置必须是 JSON 对象。";
    if (!problem) {
        NSSet *keys = [NSSet setWithArray:@[@"version", @"arguments", @"environment", @"workingDirectory", @"captureConsole"]];
        for (NSString *key in config) if (![keys containsObject:key]) { problem = @"启动配置包含未知字段。"; break; }
    }
    if (!problem && (![config[@"version"] isEqual:@1] || CFGetTypeID((__bridge CFTypeRef)config[@"version"]) == CFBooleanGetTypeID())) problem = @"启动配置 version 必须为 1。";
    if (problem) { if (error) *error = runtimeError(problem); return nil; }
    id args = config[@"arguments"] ?: @[];
    if (!problem && (![args isKindOfClass:NSArray.class] || [args count] > 64)) problem = @"arguments 必须是最多 64 项的字符串数组。";
    if (!problem) for (id arg in args) if (!textValid(arg, 4096)) { problem = @"启动参数必须是不含 NUL、最多 4096 字节的字符串。"; break; }
    id env = config[@"environment"] ?: @{};
    if (!problem && (![env isKindOfClass:NSDictionary.class] || [env count] > 64)) problem = @"environment 必须是最多 64 项的对象。";
    if (!problem) {
        NSSet *reserved = [NSSet setWithArray:@[@"HOME", @"CFFIXED_USER_HOME", @"TMPDIR", @"XPC_SERVICE_NAME", @"__CFBundleIdentifier", @"CFProcessPath", @"IAPPVM_PHONE_SCRIPT_LOG_DIR"]];
        NSRegularExpression *pattern = [NSRegularExpression regularExpressionWithPattern:@"^[A-Za-z_][A-Za-z0-9_]{0,127}$" options:0 error:nil];
        for (NSString *key in env) {
            if ([pattern numberOfMatchesInString:key options:0 range:NSMakeRange(0, key.length)] != 1 ||
                [reserved containsObject:key] || [key hasPrefix:@"LC_"] || [key hasPrefix:@"DYLD_"] ||
                !textValid(env[key], 4096)) {
                problem = @"环境变量名或值无效，或试图覆盖容器保留变量（HOME、LC_*、DYLD_* 等）。"; break;
            }
        }
    }
    id capture = config[@"captureConsole"];
    if (!problem && capture && CFGetTypeID((__bridge CFTypeRef)capture) != CFBooleanGetTypeID()) problem = @"captureConsole 必须是布尔值。";
    NSString *cwd = config[@"workingDirectory"] ?: @"Documents";
    NSString *resolved = nil;
    if (!problem) {
        if (!textValid(cwd, 1024) || cwd.isAbsolutePath || [cwd.pathComponents containsObject:@".."]) {
            problem = @"workingDirectory 必须是容器内的相对目录，不能包含 ..。";
        } else {
            NSString *base = root.stringByStandardizingPath.stringByResolvingSymlinksInPath;
            resolved = [base stringByAppendingPathComponent:cwd].stringByStandardizingPath.stringByResolvingSymlinksInPath;
            BOOL directory = NO;
            if ((!([resolved isEqual:base] || [resolved hasPrefix:[base stringByAppendingString:@"/"]])) ||
                ![NSFileManager.defaultManager fileExistsAtPath:resolved isDirectory:&directory] || !directory) {
                problem = @"workingDirectory 不存在，或链接指向容器外部。";
            }
        }
    }
    if (problem) { if (error) *error = runtimeError(problem); return nil; }
    return @{@"arguments": args, @"environment": env, @"workingDirectory": resolved, @"captureConsole": capture ?: @NO};
}

+ (void)stage:(NSString *)stage details:(NSDictionary *)details {
    @synchronized(self) {
        if (!session) return;
        session[@"stage"] = stage;
        session[@"updatedAt"] = @(NSDate.date.timeIntervalSince1970);
        if (details) [session addEntriesFromDictionary:details];
        NSDictionary *event = @{@"stage":stage ?: @"unknown",@"time":@(NSDate.date.timeIntervalSince1970),
                                @"details":details && [NSJSONSerialization isValidJSONObject:details] ? details : @{}};
        [stageHistory addObject:event];
        if (stageHistory.count > 128) [stageHistory removeObjectAtIndex:0];
        session[@"stages"] = stageHistory;
        NSData *data = [NSJSONSerialization dataWithJSONObject:session options:NSJSONWritingPrettyPrinted error:nil];
        [data writeToFile:sessionPath options:NSDataWritingAtomic error:nil];
    }
}

+ (BOOL)captureConsoleAtPath:(NSString *)path error:(NSError **)error {
    int output = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    int channels[2];
    if (output < 0) { if (error) *error = runtimeError(@"无法创建控制台日志。"); return NO; }
    if (pipe(channels) != 0) { close(output); if (error) *error = runtimeError(@"无法创建控制台管道。"); return NO; }
    int oldOut = dup(STDOUT_FILENO), oldErr = dup(STDERR_FILENO);
    fflush(stdout); fflush(stderr);
    if (oldOut < 0 || oldErr < 0 || dup2(channels[1], STDOUT_FILENO) < 0 || dup2(channels[1], STDERR_FILENO) < 0) {
        if (oldOut >= 0) { dup2(oldOut, STDOUT_FILENO); close(oldOut); }
        if (oldErr >= 0) { dup2(oldErr, STDERR_FILENO); close(oldErr); }
        close(channels[0]); close(channels[1]); close(output);
        if (error) *error = runtimeError(@"无法重定向控制台。"); return NO;
    }
    close(oldOut); close(oldErr); close(channels[1]);
    setvbuf(stdout, NULL, _IONBF, 0); setvbuf(stderr, NULL, _IONBF, 0);
    fcntl(channels[0], F_SETFL, fcntl(channels[0], F_GETFL) | O_NONBLOCK);
    fcntl(channels[0], F_SETFD, FD_CLOEXEC); fcntl(output, F_SETFD, FD_CLOEXEC);
    int input = channels[0];
    __block NSUInteger written = 0;
    __block BOOL limited = NO;
    consoleSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, input, 0, dispatch_queue_create("dev.iosvm.console", DISPATCH_QUEUE_SERIAL));
    dispatch_source_set_event_handler(consoleSource, ^{
        char buffer[8192]; ssize_t count;
        while ((count = read(input, buffer, sizeof(buffer))) > 0) {
            NSUInteger keep = MIN((NSUInteger)count, 4 * 1024 * 1024 - written);
            NSUInteger offset = 0;
            while (offset < keep) {
                ssize_t n = write(output, buffer + offset, keep - offset);
                if (n < 0 && errno == EINTR) continue;
                if (n <= 0) break;
                offset += n;
            }
            written += offset;
            if (!limited && written == 4 * 1024 * 1024) {
                limited = YES;
                @synchronized(self) { [self stage:session[@"stage"] details:@{@"consoleTruncated": @YES}]; }
            }
            // Keep draining after the quota; never block the Guest on a full pipe.
        }
        if (count == 0) dispatch_source_cancel(consoleSource);
    });
    dispatch_source_set_cancel_handler(consoleSource, ^{ close(input); close(output); });
    dispatch_resume(consoleSource);
    return YES;
}

+ (BOOL)prepareAtRoot:(NSString *)root executable:(NSString *)executable arguments:(NSArray<NSString *> **)arguments error:(NSError **)error {
    unsetenv("IAPPVM_PHONE_SCRIPT_LOG_DIR");
    NSString *configPath = [root stringByAppendingPathComponent:@"iOSVMLaunch.json"];
    BOOL hasLaunchConfig = [NSFileManager.defaultManager fileExistsAtPath:configPath];
    if (!hasLaunchConfig && !debugOptions) return YES;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *sessions = [root stringByAppendingPathComponent:@"Library/iOSVM/Sessions"];
    if (![fm createDirectoryAtPath:sessions withIntermediateDirectories:YES attributes:nil error:error]) return NO;
    NSArray *previous = [[fm contentsOfDirectoryAtPath:sessions error:nil] sortedArrayUsingSelector:@selector(compare:)];
    if (previous.count >= 10) for (NSUInteger i = 0; i < previous.count - 9; i++) {
        if ([previous[i] hasPrefix:@"session-"]) [fm removeItemAtPath:[sessions stringByAppendingPathComponent:previous[i]] error:nil];
    }
    NSString *directory = [sessions stringByAppendingPathComponent:[NSString stringWithFormat:@"session-%.0f-%@", NSDate.date.timeIntervalSince1970 * 1000, NSUUID.UUID.UUIDString]];
    if (![fm createDirectoryAtPath:directory withIntermediateDirectories:NO attributes:nil error:error]) return NO;
    sessionPath = [directory stringByAppendingPathComponent:@"session.json"];
    stageHistory = [NSMutableArray arrayWithCapacity:128];
    session = [@{@"version": @1, @"pid": @(getpid()), @"executable": executable.lastPathComponent,
                 @"startedAt": @(NSDate.date.timeIntervalSince1970), @"consoleLimitBytes": @(4 * 1024 * 1024),
                 @"stages":stageHistory} mutableCopy];
    if (debugOptions) session[@"frida"] = debugOptions;
    [self stage:@"validating" details:nil];
    NSData *data;
    if (hasLaunchConfig) {
        NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:configPath];
        data = [handle readDataUpToLength:32769 error:error]; [handle closeFile];
    } else {
        data = [NSJSONSerialization dataWithJSONObject:@{@"version":@1} options:0 error:error];
    }
    NSDictionary *config = data ? [self validateConfiguration:data root:root error:error] : nil;
    if (!config) { if (error && !*error) *error = runtimeError(@"无法读取启动配置。"); return NO; }
    NSString *debugRoot = [root stringByAppendingPathComponent:@"Library/iOSVM/Debug"];
    if (debugOptions && ![fm createDirectoryAtPath:debugRoot withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:error]) return NO;
    if (([config[@"captureConsole"] boolValue] || [debugOptions[@"captureConsole"] boolValue]) && ![self captureConsoleAtPath:[directory stringByAppendingPathComponent:@"console.log"] error:error]) return NO;
    if ([debugOptions[@"automatic"] boolValue] && [debugOptions[@"captureConsole"] boolValue]) {
        NSString *phoneDirectory = [directory stringByAppendingPathComponent:@"phone-scripts"];
        if (![fm createDirectoryAtPath:phoneDirectory withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions:@0700} error:error]) return NO;
        NSMutableArray *scripts = [NSMutableArray array];
        NSArray *ids = [debugOptions[@"scriptIDs"] isKindOfClass:NSArray.class] ? debugOptions[@"scriptIDs"] : @[];
        NSDictionary *names = [debugOptions[@"scriptNames"] isKindOfClass:NSDictionary.class] ? debugOptions[@"scriptNames"] : @{};
        for (id identifier in ids) {
            if (scripts.count >= 32 || ![identifier isKindOfClass:NSString.class] || ![[NSUUID alloc] initWithUUIDString:identifier]) continue;
            NSString *file = [identifier stringByAppendingString:@".jsonl"];
            NSString *stateFile = [identifier stringByAppendingString:@".state.json"];
            for (NSString *name in @[file,stateFile]) {
                int fd = open([[phoneDirectory stringByAppendingPathComponent:name] fileSystemRepresentation], O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
                if (fd < 0) { if (error) *error = runtimeError(@"无法创建手机脚本独立日志。 "); return NO; }
                close(fd);
            }
            NSString *name = textValid(names[identifier],160) ? names[identifier] : identifier;
            [scripts addObject:@{@"id":identifier,@"name":name,@"file":file,@"stateFile":stateFile}];
        }
        session[@"phoneScriptLogs"] = @{@"version":@2,@"commandProtocol":@"file-v1",@"scripts":scripts,@"limitBytes":@(4*1024*1024)};
        if (setenv("IAPPVM_PHONE_SCRIPT_LOG_DIR",phoneDirectory.fileSystemRepresentation,1) != 0) {
            if (error) *error = runtimeError(@"无法设置手机脚本日志通道。"); return NO;
        }
        [self stage:@"phoneScriptCaptureReady" details:nil];
    }
    if (hasLaunchConfig && chdir([config[@"workingDirectory"] fileSystemRepresentation]) != 0) { if (error) *error = runtimeError(@"无法切换工作目录。"); return NO; }
    for (NSString *key in config[@"environment"]) {
        if (setenv(key.UTF8String, [config[@"environment"][key] UTF8String], 1) != 0) {
            if (error) *error = runtimeError(@"无法设置环境变量。"); return NO;
        }
    }
    if (hasLaunchConfig) *arguments = [@[executable] arrayByAddingObjectsFromArray:config[@"arguments"]];
    [self stage:@"environmentReady" details:@{@"argumentCount": @([config[@"arguments"] count]), @"environmentKeys": [[config[@"environment"] allKeys] sortedArrayUsingSelector:@selector(compare:)]}];
    return YES;
}
@end
