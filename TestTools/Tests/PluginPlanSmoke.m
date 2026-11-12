#import <Foundation/Foundation.h>
#import "../../TweakLoader/IOSVMPluginPlan.h"
static void require(BOOL value, NSString *message) { if (!value) { NSLog(@"FAIL: %@", message); exit(1); } }
static void manifest(NSURL *root, NSArray *plugins) {
    [[NSJSONSerialization dataWithJSONObject:@{@"version": @1, @"plugins": plugins} options:0 error:nil] writeToURL:[root URLByAppendingPathComponent:@"iOSVMPlugins.json"] atomically:YES];
}
int main(void) {
    @autoreleasepool {
        NSFileManager *fm = NSFileManager.defaultManager;
        NSURL *root = [fm.temporaryDirectory URLByAppendingPathComponent:NSUUID.UUID.UUIDString];
        [fm createDirectoryAtURL:[root URLByAppendingPathComponent:@"nested"] withIntermediateDirectories:YES attributes:nil error:nil];
        for (NSString *file in @[@"A.dylib", @"B.dylib", @"C.dylib", @"Off.dylib.disabled", @"nested/D.dylib"])
            [[NSData data] writeToURL:[root URLByAppendingPathComponent:file] atomically:YES];
        [fm createSymbolicLinkAtURL:[root URLByAppendingPathComponent:@"loop"] withDestinationURL:root error:nil];
        [fm createSymbolicLinkAtURL:[root URLByAppendingPathComponent:@"Alias.dylib"] withDestinationURL:[root URLByAppendingPathComponent:@"A.dylib"] error:nil];
        NSMutableArray *errors = [NSMutableArray array];
        NSArray *plan = [IOSVMPluginPlan planForFolder:root recursive:YES errors:errors];
        require([[plan valueForKey:@"file"] isEqual:@[@"A.dylib", @"B.dylib", @"C.dylib", @"nested/D.dylib"]] && errors.count == 0, @"discovery/order/link exclusion");
        manifest(root, @[@{@"file": @"A.dylib", @"requires": @[@"nested/D.dylib"]}, @{@"file": @"nested/D.dylib", @"requires": @[@"B.dylib"]}]);
        plan = [IOSVMPluginPlan planForFolder:root recursive:YES errors:errors];
        NSArray *names = [plan valueForKey:@"file"];
        require([names indexOfObject:@"B.dylib"] < [names indexOfObject:@"nested/D.dylib"] && [names indexOfObject:@"nested/D.dylib"] < [names indexOfObject:@"A.dylib"], @"dependency order");
        manifest(root, @[@{@"file": @"A.dylib", @"requires": @[@"B.dylib"]}, @{@"file": @"B.dylib", @"requires": @[@"A.dylib"]}, @{@"file": @"C.dylib", @"requires": @[@"A.dylib"]}]);
        [errors removeAllObjects]; plan = [IOSVMPluginPlan planForFolder:root recursive:YES errors:errors];
        require([[plan valueForKey:@"file"] isEqual:@[@"nested/D.dylib"]] && errors.count == 3, @"cycle and transitive dependent rejection");
        manifest(root, @[@{@"file": @"A.dylib", @"requires": @[@"Off.dylib.disabled"]}, @{@"file": @"B.dylib", @"requires": @[@"A.dylib"]}]);
        [errors removeAllObjects]; plan = [IOSVMPluginPlan planForFolder:root recursive:YES errors:errors];
        require([[plan valueForKey:@"file"] isEqual:@[@"C.dylib", @"nested/D.dylib"]] && errors.count == 2, @"missing/disabled propagation");
        manifest(root, @[@{@"file": @"../outside.dylib", @"requires": @[]}]);
        [errors removeAllObjects]; require([IOSVMPluginPlan planForFolder:root recursive:YES errors:errors].count == 0 && errors.count, @"outside file rejected");
        [fm removeItemAtURL:root error:nil];
        printf("PASS: plugin discovery, deterministic dependency order, cycles, missing/disabled propagation, symlink exclusion\n");
    }
    return 0;
}
