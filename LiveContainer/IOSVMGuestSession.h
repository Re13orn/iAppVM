#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSNotificationName const IOSVMProcessesDidChange;

/// Host-owned records. A launch UUID, rather than a PID/container alone, owns state.
@interface IOSVMProcessRegistry : NSObject
@property(class, nonatomic, readonly) IOSVMProcessRegistry *shared;
- (instancetype)initWithJournalDirectory:(NSURL *)directory;
- (nullable NSString *)beginBundle:(NSString *)bundle container:(NSString *)container error:(NSError **)error;
- (BOOL)updateLaunch:(NSString *)launch state:(NSString *)state details:(NSDictionary *)details;
- (BOOL)finishLaunch:(NSString *)launch state:(NSString *)state reason:(NSString *)reason;
- (nullable NSDictionary *)recordForLaunch:(NSString *)launch;
- (nullable NSDictionary *)activeRecordForContainer:(NSString *)container;
- (NSArray<NSDictionary *> *)recordsForBundle:(NSString *)bundle;
- (BOOL)isBundleBusy:(NSString *)bundle;
- (BOOL)isContainerBusy:(NSString *)container;
- (BOOL)hasActiveProcesses;
@end

/// Declarative, per-launch resources. Bookmark bytes never go into diagnostics.
@interface IOSVMGuestAccess : NSObject
+ (BOOL)validComponent:(NSString *)value;
+ (NSURL *)networkSettingsDirectoryForDocuments:(NSURL *)documents NS_SWIFT_NAME(networkSettingsDirectory(documents:));
+ (NSURL *)networkSettingsForBundle:(NSString *)bundle documents:(NSURL *)documents NS_SWIFT_NAME(networkSettings(bundle:documents:));
+ (nullable NSDictionary *)planForApplication:(NSURL *)application data:(NSURL *)data documents:(NSURL *)documents shared:(BOOL)shared shareAll:(BOOL)shareAll error:(NSError **)error;
+ (NSArray<NSDictionary *> *)publicCapabilities:(NSDictionary *)plan;
+ (nullable NSDictionary *)issuePlan:(NSDictionary *)plan error:(NSError **)error;
+ (nullable NSArray<NSURL *> *)consumePlan:(NSDictionary *)plan error:(NSError **)error;
+ (void)releaseAccess:(NSArray<NSURL *> *)access;
@end
NS_ASSUME_NONNULL_END
