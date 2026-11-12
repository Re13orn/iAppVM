#import <Foundation/Foundation.h>
#import "../../LiveContainer/IOSVMDebugCompatibility.h"

int main(int argc, const char **argv) { @autoreleasepool {
    if (argc == 3 && [@(argv[1]) isEqual:@"--verify-fresh-process"]) {
        NSUserDefaults *fresh = [[NSUserDefaults alloc] initWithSuiteName:@(argv[2])];
        return [fresh integerForKey:@"featureFlagOverride_showLeakAlerts"] == 1 ? 0 : 1;
    }
    NSCAssert(argc == 2 || argc == 3, @"Pass the verified Trust executable, optionally 26.41.13 (code only).");
    BOOL newer = argc == 3 && [@(argv[2]) isEqual:@"26.41.13"];
    NSString *suite = [@"dev.iappvm.compatibility-test." stringByAppendingString:NSUUID.UUID.UUIDString];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    NSString *key = @"featureFlagOverride_showLeakAlerts";
    NSDictionary *info = @{@"CFBundleShortVersionString": newer ? @"26.41.13" : @"26.37.29",
                           @"CFBundleVersion": newer ? @"1773014927" : @"1773014852"};
    NSString *exe = @(argv[1]);
    [defaults setInteger:1 forKey:key];
    [defaults setVolatileDomain:@{@"unrelatedArgument": @"preserved"} forName:NSArgumentDomain];
    NSCAssert(IOSVMTrustLeakContract(@"com.sixdays.trust", info, exe), @"Known binary must match");
    NSCAssert(!IOSVMTrustLeakContract(@"another.app", info, exe), @"Other apps refused");
    NSCAssert(!IOSVMTrustLeakContract(@"com.sixdays.trust", @{}, exe), @"Unknown version refused");
    NSCAssert(!IOSVMTrustLeakContract(@"com.sixdays.trust", info, @"/missing"), @"Missing executable refused");
    NSDictionary *off = IOSVMApplyDebugCompatibility(NO, @"com.sixdays.trust", info, exe, defaults);
    NSCAssert([off[@"state"] isEqual:@"disabled"] && [defaults integerForKey:key] == 1, @"Off preserves app choice");
    NSDictionary *on = IOSVMApplyDebugCompatibility(YES, @"com.sixdays.trust", info, exe, defaults);
    NSCAssert([on[@"state"] isEqual:@"applied"] && [defaults integerForKey:key] == 2, @"Temporary override takes precedence");
    NSCAssert([[defaults stringForKey:@"unrelatedArgument"] isEqual:@"preserved"], @"Other arguments retained");
    NSCAssert([[defaults persistentDomainForName:suite][key] isEqual:@1], @"Guest persistent value untouched");
    [defaults synchronize];
    NSTask *child = [NSTask new];
    child.executableURL = [NSURL fileURLWithPath:NSProcessInfo.processInfo.arguments[0]];
    child.arguments = @[@"--verify-fresh-process", suite];
    NSCAssert([child launchAndReturnError:nil], @"Launch independent process");
    [child waitUntilExit];
    NSCAssert(child.terminationStatus == 0, @"Next process sees original choice");
    NSDictionary *unsupported = IOSVMApplyDebugCompatibility(YES, @"another.app", info, exe, defaults);
    NSCAssert([unsupported[@"state"] isEqual:@"unsupported"] && [defaults integerForKey:key] == 2, @"Unsupported adapter cannot change existing process override");
    // A package with the same marketing version but altered code is rejected.
    NSString *copy = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSCAssert([NSFileManager.defaultManager copyItemAtPath:exe toPath:copy error:nil], @"Fixture copy");
    NSFileHandle *file = [NSFileHandle fileHandleForWritingAtPath:copy];
    [file seekToFileOffset:newer ? 0x438ac8 : 0x4c0950]; [file writeData:[NSData dataWithBytes:"\0\0\0\0" length:4]]; [file closeFile];
    NSCAssert(!IOSVMTrustLeakContract(@"com.sixdays.trust", info, copy), @"Changed executable refused");
    [NSFileManager.defaultManager removeItemAtPath:copy error:nil];
    [defaults removePersistentDomainForName:suite];
    puts("PASS: identity/code guards, override precedence, persistent data preservation and restoration");
    return 0;
} }
