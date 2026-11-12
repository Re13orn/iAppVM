#import <Foundation/Foundation.h>
#import "../../LiveContainer/iOSVMRuntime.h"
#include <unistd.h>
#include <fcntl.h>

static NSData *json(id value) { return [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingFragmentsAllowed error:nil]; }
static void require(BOOL condition, NSString *reason) { if (!condition) { NSLog(@"FAIL: %@", reason); exit(1); } }
int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc == 3 && strcmp(argv[1], "--capture") == 0) {
            NSString *root = @(argv[2]); NSArray *arguments = nil; NSError *error = nil;
            require([IOSVMRuntime prepareAtRoot:root executable:@"/test/Demo" arguments:&arguments error:&error], error.description);
            require([arguments isEqual:@[@"/test/Demo", @"--sample", @"中文 参数"]], @"argv differs");
            require(strcmp(getenv("IOSVM_SAMPLE"), "test") == 0, @"environment differs");
            NSString *actual = NSFileManager.defaultManager.currentDirectoryPath.stringByResolvingSymlinksInPath;
            NSString *expected = [root stringByAppendingPathComponent:@"Documents"].stringByResolvingSymlinksInPath;
            require([actual isEqual:expected], [NSString stringWithFormat:@"cwd differs %@ vs %@", actual, expected]);
            [IOSVMRuntime stage:@"mainEntered" details:nil];
            char buffer[8192]; memset(buffer, 'x', sizeof(buffer));
            for (int i = 0; i < 768; i++) {
                ssize_t offset = 0;
                while (offset < sizeof(buffer)) { ssize_t n = write(1, buffer + offset, sizeof(buffer) - offset); if (n > 0) offset += n; else if (errno != EINTR) return 2; }
            }
            close(1); close(2);
            NSString *sessions = [root stringByAppendingPathComponent:@"Library/iOSVM/Sessions"];
            NSString *name = [[NSFileManager.defaultManager contentsOfDirectoryAtPath:sessions error:nil] lastObject];
            NSString *directory = [sessions stringByAppendingPathComponent:name];
            for (int i = 0; i < 200; i++) {
                NSDictionary *record = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:@"session.json"]] options:0 error:nil];
                if ([record[@"consoleTruncated"] boolValue]) return 0;
                usleep(10000);
            }
            return 3;
        }
        if (argc == 3 && strcmp(argv[1], "--debug") == 0) {
            NSString *root = @(argv[2]); NSArray *arguments = nil; NSError *error = nil;
            NSString *cwd = NSFileManager.defaultManager.currentDirectoryPath;
            [IOSVMRuntime configureDebug:@{@"captureConsole":@YES,@"automatic":@YES,@"revision":@"fixture",@"scriptCount":@2,@"scriptIDs":@[@"11111111-1111-1111-1111-111111111111"],@"scriptNames":@{@"11111111-1111-1111-1111-111111111111":@"fixture.js"}}];
            require([IOSVMRuntime prepareAtRoot:root executable:@"/test/Demo" arguments:&arguments error:&error],error.description);
            require(arguments == nil, @"debug capture changed argv");
            require([cwd isEqual:NSFileManager.defaultManager.currentDirectoryPath], @"debug capture changed cwd");
            const char *phoneDirectory=getenv("IAPPVM_PHONE_SCRIPT_LOG_DIR");
            require(phoneDirectory != NULL,@"phone script log directory missing");
            NSString *phoneFile=[@(phoneDirectory) stringByAppendingPathComponent:@"11111111-1111-1111-1111-111111111111.jsonl"];
            require([NSFileManager.defaultManager fileExistsAtPath:phoneFile],@"phone log missing");
            printf("FRIDA_DEBUG_FIXTURE\n");fflush(stdout);
            [IOSVMRuntime stage:@"pluginsLoaded" details:@{@"plugins":@[@{@"file":@"FridaGadget.dylib",@"status":@"loaded"}]}];
            close(1);close(2);
            for(int i=0;i<200;i++) {
                NSString *sessions=[root stringByAppendingPathComponent:@"Library/iOSVM/Sessions"];
                for(NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:sessions error:nil]) {
                    NSString *log=[[sessions stringByAppendingPathComponent:name] stringByAppendingPathComponent:@"console.log"];
                    if([[NSString stringWithContentsOfFile:log encoding:NSUTF8StringEncoding error:nil] containsString:@"FRIDA_DEBUG_FIXTURE"])return 0;
                }
                usleep(10000);
            }
            return 4;
        }
        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        [fm createDirectoryAtPath:[root stringByAppendingPathComponent:@"Documents"] withIntermediateDirectories:YES attributes:nil error:nil];
        NSDictionary *valid = @{@"version": @1, @"arguments": @[@"--sample", @"中文 参数"], @"environment": @{@"IOSVM_SAMPLE": @"test"}, @"workingDirectory": @"Documents", @"captureConsole": @YES};
        NSError *error = nil;
        require([IOSVMRuntime validateConfiguration:json(valid) root:root error:&error] != nil, error.description);
        NSArray *invalid = @[@[], @1, @{@"version": @YES}, @{@"version": @1, @"arguments": @1}, @{@"version": @1, @"environment": @[]}, @{@"version": @1, @"captureConsole": @1}, @{@"version": @1, @"workingDirectory": @"../"}, @{@"version": @1, @"workingDirectory": @"/tmp"}, @{@"version": @1, @"workingDirectory": @"missing"}, @{@"version": @1, @"environment": @{@"HOME": @"/tmp"}}, @{@"version": @1, @"environment": @{@"DYLD_INSERT_LIBRARIES": @"x"}}, @{@"version": @1, @"environment": @{@"LC_HOME_PATH": @"x"}}, @{@"version": @1, @"arguments": @[[NSString stringWithFormat:@"bad%Carg", (unichar)0]]}, @{@"version": @1, @"unknown": @YES}];
        for (id config in invalid) require([IOSVMRuntime validateConfiguration:json(config) root:root error:&error] == nil, @"invalid config accepted");
        [fm createSymbolicLinkAtPath:[root stringByAppendingPathComponent:@"escape"] withDestinationPath:@"/tmp" error:nil];
        require(![IOSVMRuntime validateConfiguration:json(@{@"version": @1, @"workingDirectory": @"escape"}) root:root error:&error], @"symlink escape accepted");
        require(![IOSVMRuntime validateConfiguration:[NSMutableData dataWithLength:32769] root:root error:&error], @"oversize accepted");
        [json(valid) writeToFile:[root stringByAppendingPathComponent:@"iOSVMLaunch.json"] atomically:YES];
        NSTask *task = [NSTask new]; task.executableURL = [NSURL fileURLWithPath:@(argv[0])]; task.arguments = @[@"--capture", root];
        require([task launchAndReturnError:&error], error.description); [task waitUntilExit];
        require(task.terminationStatus == 0, [NSString stringWithFormat:@"capture worker failed: status=%d root=%@", task.terminationStatus, root]);
        NSString *sessions = [root stringByAppendingPathComponent:@"Library/iOSVM/Sessions"];
        NSString *directory = [sessions stringByAppendingPathComponent:[[fm contentsOfDirectoryAtPath:sessions error:nil] lastObject]];
        require([[fm attributesOfItemAtPath:[directory stringByAppendingPathComponent:@"console.log"] error:nil][NSFileSize] unsignedIntegerValue] == 4 * 1024 * 1024, @"console quota differs");
        NSDictionary *record = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:@"session.json"]] options:0 error:nil];
        require([record[@"stage"] isEqual:@"mainEntered"] && [record[@"consoleTruncated"] boolValue], @"journal differs");
        require(record[@"environment"] == nil && record[@"arguments"] == nil, @"values leaked into metadata");
        [fm removeItemAtPath:[root stringByAppendingPathComponent:@"iOSVMLaunch.json"] error:nil];
        NSTask *debug=[NSTask new];debug.executableURL=[NSURL fileURLWithPath:@(argv[0])];debug.arguments=@[@"--debug",root];
        require([debug launchAndReturnError:&error],error.description);[debug waitUntilExit];
        require(debug.terminationStatus==0,@"debug-only capture failed");
        [fm removeItemAtPath:root error:nil];
        printf("PASS: runtime validation, cwd boundaries, argv/env, bounded nonblocking capture, session journal\n");
    }
    return 0;
}
