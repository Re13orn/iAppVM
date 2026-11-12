// SPDX-License-Identifier: AGPL-3.0-or-later
#import <Foundation/Foundation.h>
@interface IOSVMPluginPlan : NSObject
+ (NSArray<NSDictionary *> *)planForFolder:(NSURL *)folder recursive:(BOOL)recursive errors:(NSMutableArray<NSString *> *)errors;
@end
