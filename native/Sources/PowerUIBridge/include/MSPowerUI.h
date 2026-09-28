#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A narrow bridge to macOS's own charge limit (PowerUI's "manual charge limit", added in
/// macOS 26.4). PowerUI is private, so it is loaded at run time and every call degrades to
/// "unknown" when a class or selector is missing, rather than crashing on a future macOS.
///
/// Reading needs no privilege. Setting through PowerUI accepts only the values macOS offers
/// in System Settings (80–100 in 5% steps); anything else is written by the root helper.
@interface MSPowerUI : NSObject
/// Whether this Mac and macOS support the manual charge limit.
+ (BOOL)isSupported;
/// The limit PowerUI reports, or -1 when it cannot be read.
+ (NSInteger)currentLimit;
/// 1 enabled, 0 disabled, -1 unknown.
+ (NSInteger)isEnabled;
+ (BOOL)enable;
/// The values PowerUI itself accepts from a client.
+ (NSArray<NSNumber *> *)availableLimits;
+ (BOOL)setLimit:(NSInteger)percent error:(NSError * _Nullable * _Nullable)error;
@end

NS_ASSUME_NONNULL_END
