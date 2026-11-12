// SPDX-License-Identifier: AGPL-3.0-or-later
#import <Foundation/Foundation.h>
#include <unistd.h>

// Deliberately exported, invoked by native code, and pre-instrumented by gum-graft.
__attribute__((visibility("default"), noinline, optnone))
int IOSVMFridaTestValue(int value) { return value + 1; }
static dispatch_source_t timer;
__attribute__((constructor)) static void start(void) {
    if (![NSBundle.mainBundle.bundleIdentifier isEqual:@"dev.iosvm.frida"]) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, NSEC_PER_MSEC * 50);
        __block NSUInteger tick = 0;
        dispatch_source_set_event_handler(timer, ^{
            int result = IOSVMFridaTestValue(7);
            NSDictionary *record = @{@"version": @1, @"pid": @(getpid()), @"tick": @(++tick), @"argument": @7, @"value": @(result)};
            NSData *data = [NSJSONSerialization dataWithJSONObject:record options:0 error:nil];
            [data writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/frida-smoke.json"] atomically:YES];
            if (tick >= 600) dispatch_source_cancel(timer);
        });
        dispatch_resume(timer);
    });
}
