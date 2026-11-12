#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <mach/vm_prot.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <objc/runtime.h>
#include <objc/message.h>
#import "../LiveContainer/utils.h"
#import "IOSVMPluginPlan.h"
#import "../LiveContainer/iOSVMRuntime.h"

static NSMutableArray *pluginResults;

// The executable was converted from MH_EXECUTE to MH_DYLIB and its 4 GiB
// PAGEZERO guard was made small so dyld could map it. Some large apps inspect
// their own load commands during +load. Restore the original values in memory
// before that work begins; the mapped address layout itself is unchanged.
static NSDictionary *restoreGuestExecutableHeaderMetadata(void) {
    NSDictionary *info = NSUserDefaults.guestAppInfo;
    NSNumber *originalVMAddr = info[@"LCOriginalPageZeroVMAddr"];
    NSNumber *originalVMSize = info[@"LCOriginalPageZeroVMSize"];
    if (!originalVMAddr || !originalVMSize) {
        return @{@"state": @"unavailable", @"reason": @"No original PAGEZERO metadata"};
    }

    void *(*guestHeader)(void) = (void *(*)(void))dlsym(RTLD_DEFAULT, "getGuestAppHeader");
    struct mach_header_64 *header = guestHeader ? (struct mach_header_64 *)guestHeader() : NULL;
    if (!header || header->magic != MH_MAGIC_64) {
        return @{@"state": @"failed", @"reason": @"Guest Mach-O header unavailable"};
    }

    struct load_command *command = (struct load_command *)(header + 1);
    struct segment_command_64 *pageZero = NULL;
    for (uint32_t index = 0; index < header->ncmds && index < 2048; index++) {
        if (command->cmdsize < sizeof(struct load_command) ||
            (uint8_t *)command + command->cmdsize > (uint8_t *)header + header->sizeofcmds) {
            break;
        }
        if (command->cmd == LC_SEGMENT_64) {
            struct segment_command_64 *segment = (struct segment_command_64 *)command;
            if (!strncmp(segment->segname, "__PAGEZERO", sizeof(segment->segname))) {
                pageZero = segment;
                break;
            }
        }
        command = (struct load_command *)((uint8_t *)command + command->cmdsize);
    }
    if (!pageZero) {
        return @{@"state": @"failed", @"reason": @"Guest PAGEZERO command unavailable"};
    }
    if (pageZero->vmaddr == originalVMAddr.unsignedLongLongValue &&
        pageZero->vmsize == originalVMSize.unsignedLongLongValue) {
        return @{@"state": @"already-restored",
                 @"vmaddr": originalVMAddr,
                 @"vmsize": originalVMSize};
    }
    if (pageZero->vmaddr != (0x100000000ULL - 0x4000) || pageZero->vmsize != 0x4000) {
        return @{@"state": @"unexpected", @"vmaddr": @(pageZero->vmaddr), @"vmsize": @(pageZero->vmsize)};
    }

    vm_size_t pageSize = (vm_size_t)getpagesize();
    mach_vm_address_t page = (mach_vm_address_t)header & ~(mach_vm_address_t)(pageSize - 1);
    kern_return_t protection = vm_protect(
        mach_task_self(), (vm_address_t)page, pageSize, false,
        VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (protection != KERN_SUCCESS) {
        return @{@"state": @"failed", @"reason": @"Unable to make guest Mach-O header writable",
                 @"kr": @(protection)};
    }
    @try {
        pageZero->vmaddr = originalVMAddr.unsignedLongLongValue;
        pageZero->vmsize = originalVMSize.unsignedLongLongValue;
    } @finally {
        vm_protect(mach_task_self(), (vm_address_t)page, pageSize, false, VM_PROT_READ | VM_PROT_EXECUTE);
    }
    return @{@"state": @"restored", @"vmaddr": originalVMAddr, @"vmsize": originalVMSize};
}

static void stageHeaderCompatibility(NSDictionary *details) {
    Class runtime = NSClassFromString(@"IOSVMRuntime");
    if ([runtime respondsToSelector:@selector(stage:details:)]) {
        ((void (*)(id, SEL, id, id))objc_msgSend)(
            runtime, @selector(stage:details:), @"guestHeaderCompatibility", details);
    }
}

static NSString *loadTweakAtURL(NSURL *url) {
    NSString *tweakPath = url.path;
    NSString *tweak = tweakPath.lastPathComponent;
    if (![tweakPath hasSuffix:@".dylib"] && ![tweakPath hasSuffix:@".framework"]) {
        return nil;
    }
    if ([tweakPath hasSuffix:@".framework"]) {
        NSURL* infoPlistURL = [url URLByAppendingPathComponent:@"Info.plist"];
        NSDictionary* infoDict = [NSDictionary dictionaryWithContentsOfURL:infoPlistURL];
        NSString* binary = infoDict[@"CFBundleExecutable"];
        if(!binary || ![binary isKindOfClass:NSString.class] || ![binary isEqual:[binary lastPathComponent]] || [binary isEqual:@".."] || [binary isEqual:@"."]) {
            return [NSString stringWithFormat:@"Unable to load %@: Unable to read Info.Plist", tweak];
        }
        tweakPath = [[url URLByAppendingPathComponent:binary] path];
    }

    // The framework binary path is built from CFBundleExecutable, so a symlink
    // there would be followed by dlopen. Only ever load regular files, keeping
    // the loader's "no symlinks, no special files" discipline.
    struct stat binaryStat;
    if (lstat(tweakPath.UTF8String, &binaryStat) != 0 || !S_ISREG(binaryStat.st_mode)) {
        return [NSString stringWithFormat:@"Unable to load %@: binary path is not a regular file", tweak];
    }

    void *handle = dlopen(tweakPath.UTF8String, RTLD_LAZY | RTLD_GLOBAL);
    const char *error = dlerror();
    if (handle) {
        NSLog(@"Loaded tweak %@", tweak);
        return nil;
    } else if (error) {
        NSLog(@"Error: %s", error);
        return @(error);
    } else {
        NSLog(@"Error: dlopen(%@): Unknown error because dlerror() returns NULL", tweak);
        return [NSString stringWithFormat:@"dlopen(%@): unknown error, handle is NULL", tweakPath];
    }
}

static void loadPlannedTweaks(NSURL *folder, BOOL recursive, NSMutableArray *errors) {
    NSArray *plan = [IOSVMPluginPlan planForFolder:folder recursive:recursive errors:errors];
    NSMutableSet *loaded = [NSMutableSet set];
    for (NSDictionary *node in plan) {
        NSString *name = node[@"file"], *error = nil;
        for (NSString *dependency in node[@"requires"]) if (![loaded containsObject:dependency]) {
            error = [NSString stringWithFormat:@"Skipped %@: dependency %@ failed to load.", name, dependency]; break;
        }
        if (!error) error = loadTweakAtURL(node[@"url"]);
        if (error) [errors addObject:error]; else [loaded addObject:name];
        [pluginResults addObject:@{@"file": name, @"folder": folder.lastPathComponent, @"status": error ? @"failed" : @"loaded", @"error": error ?: @""}];
    }
}

static void showDlerrAlert(NSString *error) {
    UIWindow *window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"测试插件加载失败" message:error preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction* okAction = [UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
        window.windowScene = nil;
    }];
    [alert addAction:okAction];
    UIAlertAction* cancelAction = [UIAlertAction actionWithTitle:@"复制" style:UIAlertActionStyleCancel handler:^(UIAlertAction * action) {
        UIPasteboard.generalPasteboard.string = error;
        window.windowScene = nil;
    }];
    [alert addAction:cancelAction];
    window.rootViewController = [UIViewController new];
    window.windowLevel = 1000;
    window.windowScene = (id)UIApplication.sharedApplication.connectedScenes.anyObject;
    [window makeKeyAndVisible];
    [window.rootViewController presentViewController:alert animated:YES completion:nil];
    objc_setAssociatedObject(alert, @"window", window, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

 __attribute__((constructor))
static void TweakLoaderConstructor() {
    stageHeaderCompatibility(restoreGuestExecutableHeaderMetadata());

    const char *tweakFolderC = getenv("LC_GLOBAL_TWEAKS_FOLDER");
    if (!tweakFolderC) return;
    NSString *globalTweakFolder = @(tweakFolderC);
    unsetenv("LC_GLOBAL_TWEAKS_FOLDER");
    
    if([NSUserDefaults.guestAppInfo[@"dontInjectTweakLoader"] boolValue]) {
        // don't load any tweak since tweakloader is loaded after all initializers
        NSLog(@"Skip loading tweaks");
        return;
    }
    
    NSMutableArray *errors = [NSMutableArray new];
    pluginResults = [NSMutableArray array];
    
    NSArray<NSURL *> *globalTweaks = [NSFileManager.defaultManager contentsOfDirectoryAtURL:[NSURL fileURLWithPath:globalTweakFolder]
    includingPropertiesForKeys:@[] options:0 error:nil];
    NSString *tweakFolderName = NSUserDefaults.guestAppInfo[@"LCTweakFolder"];
    
    if([globalTweaks count] <= 1 && tweakFolderName.length == 0) {
        // nothing to load
        return;
    }

    // Load CydiaSubstrate
    const char *lcMainBundlePath;
    if(NSUserDefaults.isLiveProcess) {
        lcMainBundlePath = NSUserDefaults.lcMainBundle.bundlePath.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent.fileSystemRepresentation;
    } else {
        lcMainBundlePath = NSUserDefaults.lcMainBundle.bundlePath.fileSystemRepresentation;
    }
    char substratePath[PATH_MAX];
    snprintf(substratePath, sizeof(substratePath), "%s/Frameworks/CydiaSubstrate.framework/CydiaSubstrate", lcMainBundlePath);
    dlopen(substratePath, RTLD_LAZY | RTLD_GLOBAL);
    const char *substrateError = dlerror();
    if (substrateError) {
        [errors addObject:@(substrateError)];
    }

    // Load global tweaks
    NSLog(@"Loading tweaks from the global folder");

    loadPlannedTweaks([NSURL fileURLWithPath:globalTweakFolder], NO, errors);

    // Load selected tweak folder, recursively
    if (tweakFolderName.length > 0) {
        NSLog(@"Loading tweaks from the selected folder");
        NSString *tweakFolder = [globalTweakFolder stringByAppendingPathComponent:tweakFolderName];
        loadPlannedTweaks([NSURL fileURLWithPath:tweakFolder], YES, errors);
    }

    // Associate the inventory with the same optional runtime session, including
    // planning failures for modules that never reached dlopen.
    Class runtime = NSClassFromString(@"IOSVMRuntime");
    if ([runtime respondsToSelector:@selector(stage:details:)]) {
        ((void (*)(id, SEL, id, id))objc_msgSend)(runtime, @selector(stage:details:), @"pluginsLoaded", @{@"plugins": pluginResults, @"pluginErrors": errors});
    }

    if (errors.count > 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *error = [errors componentsJoinedByString:@"\n"];
            showDlerrAlert(error);
        });
    }
}
