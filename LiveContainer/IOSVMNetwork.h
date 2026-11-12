#import <Foundation/Foundation.h>

enum { IOSVMTLSIdentityMetadataLimit = 64 * 1024 };

/// Installed only inside a selected guest process, before its initializers run.
@interface IOSVMNetwork : NSObject
+ (NSDictionary *)socketProxyStatus;
+ (BOOL)startWithSettings:(NSString *)settings root:(NSString *)root error:(NSError **)error;
@end
