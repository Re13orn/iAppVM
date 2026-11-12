// SPDX-License-Identifier: AGPL-3.0-or-later
// Dependency ordering inspired by Nyxian PEKextLoader; this loads user dylibs only.
#import "IOSVMPluginPlan.h"

@implementation IOSVMPluginPlan
+ (void)collect:(NSURL *)folder prefix:(NSString *)prefix recursive:(BOOL)recursive depth:(NSUInteger)depth nodes:(NSMutableDictionary *)nodes errors:(NSMutableArray *)errors {
    if (depth > 32 || nodes.count > 512) { [errors addObject:@"插件目录超过最大层级或数量限制。"]; return; }
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSURL *url in [fm contentsOfDirectoryAtURL:folder includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil]) {
        if (nodes.count > 512) return;
        NSString *name = url.lastPathComponent;
        if ([name hasSuffix:@".disabled"] || [name isEqual:@"TweakLoader.dylib"]) continue;
        NSString *type = [fm attributesOfItemAtPath:url.path error:nil][NSFileType];
        if ([type isEqual:NSFileTypeSymbolicLink]) continue;
        NSString *path = prefix.length ? [prefix stringByAppendingPathComponent:name] : name;
        BOOL framework = [name hasSuffix:@".framework"] && [type isEqual:NSFileTypeDirectory];
        if (framework || ([name hasSuffix:@".dylib"] && [type isEqual:NSFileTypeRegular])) {
            nodes[path] = [@{@"file": path, @"url": url, @"requires": @[]} mutableCopy];
        } else if (recursive && [type isEqual:NSFileTypeDirectory]) {
            [self collect:url prefix:path recursive:YES depth:depth + 1 nodes:nodes errors:errors];
        }
    }
}
+ (NSArray<NSDictionary *> *)planForFolder:(NSURL *)folder recursive:(BOOL)recursive errors:(NSMutableArray<NSString *> *)errors {
    NSMutableDictionary<NSString *, NSMutableDictionary *> *nodes = [NSMutableDictionary dictionary];
    [self collect:folder prefix:@"" recursive:recursive depth:0 nodes:nodes errors:errors];
    if (nodes.count > 512) { [errors addObject:@"插件数量过多，本次未加载任何插件。"]; return @[]; }
    NSURL *manifestURL = [folder URLByAppendingPathComponent:@"iOSVMPlugins.json"];
    if ([NSFileManager.defaultManager fileExistsAtPath:manifestURL.path]) {
        NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:manifestURL.path];
        NSError *error = nil;
        NSData *data = [handle readDataUpToLength:32769 error:&error]; [handle closeFile];
        id manifest = data.length <= 32768 && data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&error] : nil;
        if (![manifest isKindOfClass:NSDictionary.class] || ![manifest[@"version"] isEqual:@1] || CFGetTypeID((__bridge CFTypeRef)manifest[@"version"]) == CFBooleanGetTypeID() || ![manifest[@"plugins"] isKindOfClass:NSArray.class]) {
            [errors addObject:@"iOSVMPlugins.json 格式无效，本次未从此目录加载任何插件。"]; return @[];
        }
        NSMutableSet *declared = [NSMutableSet set];
        for (id entry in manifest[@"plugins"]) {
            if (![entry isKindOfClass:NSDictionary.class] || ![entry[@"file"] isKindOfClass:NSString.class] ||
                ![entry[@"requires"] isKindOfClass:NSArray.class] || [entry[@"requires"] count] > 512) {
                [errors addObject:@"插件依赖条目无效，本次未从此目录加载任何插件。"]; return @[];
            }
            NSString *file = entry[@"file"];
            if (!nodes[file] || [declared containsObject:file]) {
                [errors addObject:[NSString stringWithFormat:@"插件清单引用了缺失、已禁用或重复的文件：%@", file]]; return @[];
            }
            for (id dependency in entry[@"requires"]) if (![dependency isKindOfClass:NSString.class]) {
                [errors addObject:@"插件依赖必须使用文件名，本次未从此目录加载任何插件。"]; return @[];
            }
            nodes[file][@"requires"] = entry[@"requires"];
            [declared addObject:file];
        }
    }
    NSArray<NSString *> *names = [nodes.allKeys sortedArrayUsingSelector:@selector(compare:)];
    NSMutableSet *completed = [NSMutableSet set], *blocked = [NSMutableSet set];
    NSMutableArray *order = [NSMutableArray array];
    BOOL progress;
    do {
        progress = NO;
        for (NSString *file in names) {
            if ([completed containsObject:file] || [blocked containsObject:file]) continue;
            BOOL ready = YES, missing = NO;
            for (NSString *dependency in nodes[file][@"requires"]) {
                if (!nodes[dependency] || [blocked containsObject:dependency]) { missing = YES; break; }
                if (![completed containsObject:dependency]) ready = NO;
            }
            if (missing) {
                [errors addObject:[NSString stringWithFormat:@"已跳过 %@：依赖插件缺失、已禁用或被阻止。", file]];
                [blocked addObject:file]; progress = YES;
            } else if (ready) { [order addObject:nodes[file]]; [completed addObject:file]; progress = YES; }
        }
    } while (progress);
    for (NSString *file in names) if (![completed containsObject:file] && ![blocked containsObject:file])
        [errors addObject:[NSString stringWithFormat:@"已跳过 %@：存在依赖循环，或依赖了循环中的插件。", file]];
    return order;
}
@end
