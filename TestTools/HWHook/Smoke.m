// SPDX-License-Identifier: AGPL-3.0-or-later
#import <Foundation/Foundation.h>
#include "SDK/iOSVMHWHook.h"
#include <pthread.h>
#include <errno.h>
#include <unistd.h>

__attribute__((noinline,optnone)) static int original(int value) { return value + 1; }
__attribute__((noinline,optnone)) static int replacement(int value) { return value + 100; }
static int (*volatile invoke)(int) = original;
typedef struct { int rounds; int failure; } Worker;
static void *foreignThread(void *context) {
    return (void *)(uintptr_t)(IOSVMHWSetEnabled(context, false) == EINVAL && IOSVMHWExit(context) == EINVAL);
}
static void save(NSDictionary *record) {
    NSURL *url = [NSURL fileURLWithPath:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/hwhook-smoke.json"]];
    NSData *data = [NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToURL:url options:NSDataWritingAtomic error:nil];
    NSLog(@"[iOSVM HWHook SDK] %@", record);
}
static void *exercise(void *opaque) {
    Worker *worker = opaque;
    for (int i = 0; i < 10; i++) {
        IOSVMHWContext *context = NULL, *nested = NULL;
        IOSVMHWHook hook = {original, replacement};
        int result = IOSVMHWEnter(&hook, 1, &context);
        if (result) { worker->failure = result; return NULL; }
        bool passed = IOSVMHWEnter(&hook, 1, &nested) == EBUSY && nested == NULL && invoke(7) == 107;
        if (i == 0) {
            pthread_t foreign; void *result = NULL;
            if (pthread_create(&foreign, NULL, foreignThread, context) != 0) passed = false;
            else { pthread_join(foreign, &result); passed = passed && result == (void *)1; }
        }
        usleep(2000);
        passed = passed && invoke(7) == 107;
        passed = IOSVMHWSetEnabled(context, false) == 0 && passed;
        passed = invoke(7) == 8 && passed;
        passed = IOSVMHWSetEnabled(context, true) == 0 && passed;
        passed = invoke(7) == 107 && passed;
        passed = IOSVMHWExit(context) == 0 && passed;
        passed = invoke(7) == 8 && passed;
        if (!passed) { worker->failure = EIO; return NULL; }
        worker->rounds++;
    }
    return NULL;
}
static void *run(void *unused) {
    @autoreleasepool {
        save(@{@"stage": @"beforeEnter", @"sdkVersion": @1});
        IOSVMHWHook hook = {original, replacement};
        IOSVMHWContext *context = NULL;
        BOOL overflowRejected = IOSVMHWEnter(&hook, IOSVMHWCapacity() + 1, &context) == ENOSPC;
        IOSVMHWHook invalid = {original, original};
        BOOL invalidRejected = IOSVMHWEnter(&invalid, 1, &context) == EINVAL;
        IOSVMHWHook duplicate[2] = {hook, hook};
        BOOL duplicateRejected = IOSVMHWCapacity() < 2 || IOSVMHWEnter(duplicate, 2, &context) == EINVAL;
        Worker workers[3] = {0}; pthread_t threads[3]; BOOL started[3] = {0};
        for (int i = 0; i < 3; i++) started[i] = pthread_create(&threads[i], NULL, exercise, &workers[i]) == 0;
        BOOL otherThreadUnaffected = YES;
        for (int i = 0; i < 100; i++) { if (invoke(7) != 8) otherThreadUnaffected = NO; usleep(200); }
        BOOL passed = overflowRejected && invalidRejected && duplicateRejected && otherThreadUnaffected;
        NSArray *arguments = NSProcessInfo.processInfo.arguments;
        BOOL runtimeArgumentsMatch = arguments.count == 3 && [arguments[1] isEqual:@"--sample"] && [arguments[2] isEqual:@"中文 参数"];
        BOOL runtimeEnvironmentMatch = getenv("IOSVM_SAMPLE") && strcmp(getenv("IOSVM_SAMPLE"), "test") == 0;
        BOOL runtimeFoundationEnvironmentMatch = [NSProcessInfo.processInfo.environment[@"IOSVM_SAMPLE"] isEqual:@"test"];
        BOOL runtimeCWDMatch = [NSFileManager.defaultManager.currentDirectoryPath.stringByResolvingSymlinksInPath isEqual:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"].stringByResolvingSymlinksInPath];
        printf("[iOSVM runtime] capture smoke marker\n"); fflush(stdout);
        if (getenv("IOSVM_CAPTURE_STRESS") && strcmp(getenv("IOSVM_CAPTURE_STRESS"), "1") == 0) {
            char buffer[8192]; memset(buffer, 'x', sizeof(buffer));
            for (int i = 0; i < 768; i++) {
                size_t offset = 0;
                while (offset < sizeof(buffer)) {
                    ssize_t n = write(STDOUT_FILENO, buffer + offset, sizeof(buffer) - offset);
                    if (n > 0) offset += n;
                    else if (errno != EINTR) { passed = NO; break; }
                }
            }
        }
        NSMutableArray *results = [NSMutableArray array];
        for (int i = 0; i < 3; i++) {
            if (started[i]) pthread_join(threads[i], NULL);
            passed = passed && started[i] && workers[i].rounds == 10 && workers[i].failure == 0;
            [results addObject:@{@"rounds": @(workers[i].rounds), @"error": @(workers[i].failure)}];
        }
        save(@{@"stage": @"finished", @"sdkVersion": @1, @"passed": @(passed), @"capacity": @(IOSVMHWCapacity()),
               @"workers": results, @"otherThreadUnaffected": @(otherThreadUnaffected),
               @"overflowRejected": @(overflowRejected), @"invalidRejected": @(invalidRejected), @"duplicateRejected": @(duplicateRejected),
               @"runtimeArgumentsMatch": @(runtimeArgumentsMatch), @"runtimeEnvironmentMatch": @(runtimeEnvironmentMatch), @"runtimeCWDMatch": @(runtimeCWDMatch),
               @"runtimeFoundationEnvironmentMatch": @(runtimeFoundationEnvironmentMatch),
               @"pid": @(NSProcessInfo.processInfo.processIdentifier)});
    }
    return NULL;
}
__attribute__((constructor)) static void start(void) {
    if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"dev.iosvm.hwhook"]) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        pthread_t thread; if (pthread_create(&thread, NULL, run, NULL) == 0) pthread_detach(thread);
    });
}
