// SPDX-License-Identifier: AGPL-3.0-or-later
#import <Foundation/Foundation.h>

// Compatibility adapters must identify a known app/configuration contract. Never
// suppress UIAlertController globally or persist overrides into guest preferences.
static inline BOOL IOSVMTrustLeakContract(NSString *identifier, NSDictionary *info, NSString *executable) {
    if (![identifier isEqual:@"com.sixdays.trust"]) return NO;
    BOOL original = [info[@"CFBundleShortVersionString"] isEqual:@"26.37.29"] &&
                    [info[@"CFBundleVersion"] isEqual:@"1773014852"];
    BOOL installed = [info[@"CFBundleShortVersionString"] isEqual:@"26.41.13"] &&
                     [info[@"CFBundleVersion"] isEqual:@"1773014927"];
    if (!original && !installed) return NO;
    NSFileHandle *file = [NSFileHandle fileHandleForReadingAtPath:executable];
    if (!file) return NO;
    // Verified arm64 code: callback reads flag 0x85/0x87, named showLeakAlerts.
    // Check the tri-state override interpretation as well. Unknown/replaced builds
    // fail closed, including builds whose instrumented instructions differ.
    NSArray *checks = original ? @[
        @[@0x4c0950, @"f4830891a010805226f55794141c0012e08308916d90f0979f06007161010054"],
        @[@0xe625b4, @"21888dd2a14caef2816ecef201c0fdf2600e8dd2e0edaef280a9ccf2206cedf2c0035fd6"],
        @[@0x1abded8, @"7f0600f1e8179f1a7f0a00f1490080522001881a0c000014"],
        @[@0xbad7900, @"66656174757265466c61674f766572726964655f00"]
    ] : @[
        @[@0x438ac8, @"f4830891e0108052114b5194141c0012e083089115aef2979f06007161010054"],
        @[@0xc084f8, @"21888dd2a14caef2816ecef201c0fdf2600e8dd2e0edaef280a9ccf2206cedf2c0035fd6"],
        @[@0x188b7fc, @"7f0600f1e8179f1a7f0a00f1490080522001881a0c000014"],
        @[@0x892c1c0, @"66656174757265466c61674f766572726964655f00"]
    ];
    BOOL matches = YES;
    @try {
        for (NSArray *check in checks) {
            NSString *hex = check[1];
            NSMutableData *expected = [NSMutableData data];
            for (NSUInteger i = 0; i < hex.length; i += 2) {
                unsigned value = 0;
                [[NSScanner scannerWithString:[hex substringWithRange:NSMakeRange(i, 2)]] scanHexInt:&value];
                uint8_t byte = value; [expected appendBytes:&byte length:1];
            }
            [file seekToFileOffset:[check[0] unsignedLongLongValue]];
            if (![[file readDataOfLength:expected.length] isEqual:expected]) { matches = NO; break; }
        }
    } @catch (NSException *exception) { matches = NO; }
    [file closeFile];
    return matches;
}

static inline NSDictionary *IOSVMApplyDebugCompatibility(BOOL enabled, NSString *identifier,
                                                        NSDictionary *info, NSString *executable,
                                                        NSUserDefaults *defaults) {
    if (!enabled) return @{@"adapter": @"known-leak-alerts", @"state": @"disabled"};
    if (!IOSVMTrustLeakContract(identifier, info, executable))
        return @{@"adapter": @"known-leak-alerts", @"state": @"unsupported",
                 @"reason": @"App identity, version or executable contract did not match."};
    NSMutableDictionary *arguments = [[defaults volatileDomainForName:NSArgumentDomain] mutableCopy] ?: [NSMutableDictionary new];
    // Trust's override enum is 0=default, 1=enabled, 2=disabled (not a BOOL).
    arguments[@"featureFlagOverride_showLeakAlerts"] = @2;
    [defaults setVolatileDomain:arguments forName:NSArgumentDomain];
    BOOL verified = [defaults integerForKey:@"featureFlagOverride_showLeakAlerts"] == 2;
    return @{@"adapter": @"known-leak-alerts", @"state": verified ? @"applied" : @"failed",
             @"scope": @"process-only", @"effect": @"detector-alert-setting-only"};
}
