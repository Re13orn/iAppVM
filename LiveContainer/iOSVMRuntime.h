// SPDX-License-Identifier: AGPL-3.0-or-later
#import <Foundation/Foundation.h>

@interface IOSVMRuntime : NSObject
+ (void)configureDebug:(NSDictionary *)options;
+ (NSDictionary *)validateConfiguration:(NSData *)data root:(NSString *)root error:(NSError **)error;
+ (BOOL)prepareAtRoot:(NSString *)root executable:(NSString *)executable arguments:(NSArray<NSString *> **)arguments error:(NSError **)error;
+ (void)stage:(NSString *)stage details:(NSDictionary *)details;
@end
