#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <fcntl.h>
#include <unistd.h>

// This probe deliberately uses Objective-C dispatch, without executable-page patches.
static int logFD = -1;
static dispatch_queue_t logQueue;
static NSUInteger eventCount;

static void recordEvent(NSString *event, NSDictionary *fields) {
    if (logFD < 0) return;
    dispatch_async(logQueue, ^{
        @autoreleasepool {
            // Bound each launch's output; a noisy app must not fill the device.
            if (eventCount++ >= 10000) return;
            NSMutableDictionary *record = [fields mutableCopy];
            record[@"event"] = event;
            record[@"time"] = @([[NSDate date] timeIntervalSince1970]);
            NSData *data = [NSJSONSerialization dataWithJSONObject:record options:0 error:nil];
            if (!data) return;
            NSMutableData *line = [data mutableCopy];
            [line appendBytes:"\n" length:1];
            const uint8_t *bytes = line.bytes;
            NSUInteger remaining = line.length;
            while (remaining) {
                ssize_t count = write(logFD, bytes, remaining);
                if (count < 0 && errno == EINTR) continue;
                if (count <= 0) break;
                remaining -= count;
                bytes += count;
            }
        }
    });
}

@interface UIViewController (iOSVMProbe)
- (void)iosvm_viewDidAppear:(BOOL)animated;
@end

@implementation UIViewController (iOSVMProbe)
- (void)iosvm_viewDidAppear:(BOOL)animated {
    [self iosvm_viewDidAppear:animated];
    recordEvent(@"viewDidAppear", @{@"class": NSStringFromClass(self.class)});
}
@end

__attribute__((constructor)) static void startProbe(void) {
    @autoreleasepool {
        const char *home = getenv("HOME");
        if (!home) return;
        NSURL *directory = [NSURL fileURLWithPath:[@(home) stringByAppendingPathComponent:@"Documents/iOSVMProbe"] isDirectory:YES];
        NSError *error = nil;
        if (![NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:&error]) {
            NSLog(@"[iOSVMProbe] Cannot create session directory: %@", error);
            return;
        }
        // Keep the last 20 sessions, including the one about to be created.
        NSArray<NSURL *> *files = [NSFileManager.defaultManager contentsOfDirectoryAtURL:directory includingPropertiesForKeys:nil options:0 error:nil];
        NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(NSURL *url, NSDictionary *bindings) {
            return [url.lastPathComponent hasPrefix:@"session-"] && [url.pathExtension isEqualToString:@"jsonl"];
        }];
        files = [[files filteredArrayUsingPredicate:predicate] sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
            return [a.lastPathComponent compare:b.lastPathComponent];
        }];
        if (files.count >= 20) {
            for (NSUInteger i = 0; i < files.count - 19; i++) {
                [NSFileManager.defaultManager removeItemAtURL:files[i] error:nil];
            }
        }
        NSString *name = [NSString stringWithFormat:@"session-%.0f-%@.jsonl", NSDate.date.timeIntervalSince1970 * 1000, NSUUID.UUID.UUIDString];
        NSURL *log = [directory URLByAppendingPathComponent:name];
        logFD = open(log.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
        if (logFD < 0) {
            NSLog(@"[iOSVMProbe] Cannot open log: %s", strerror(errno));
            return;
        }
        logQueue = dispatch_queue_create("dev.iosvm.probe.log", DISPATCH_QUEUE_SERIAL);
        recordEvent(@"probeLoaded", @{
            @"version": @1,
            @"bundleIdentifier": NSBundle.mainBundle.bundleIdentifier ?: @"",
            @"bundlePath": NSBundle.mainBundle.bundlePath ?: @"",
            @"home": @(home),
            @"pid": @(getpid()),
            @"systemVersion": UIDevice.currentDevice.systemVersion
        });
        Method original = class_getInstanceMethod(UIViewController.class, @selector(viewDidAppear:));
        Method replacement = class_getInstanceMethod(UIViewController.class, @selector(iosvm_viewDidAppear:));
        if (original && replacement) {
            method_exchangeImplementations(original, replacement);
            recordEvent(@"hookInstalled", @{@"method": @"-[UIViewController viewDidAppear:]"});
        } else {
            recordEvent(@"hookFailed", @{@"method": @"-[UIViewController viewDidAppear:]"});
        }
        NSLog(@"[iOSVMProbe] Session: %@", log.path);
    }
}
