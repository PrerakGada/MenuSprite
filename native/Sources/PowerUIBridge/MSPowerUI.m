#import "MSPowerUI.h"
#include <dlfcn.h>

static id MSClient(void) {
    static id client;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!dlopen("/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI", RTLD_NOW | RTLD_LOCAL)) { return; }
        Class cls = NSClassFromString(@"PowerUISmartChargeClient");
        SEL init = NSSelectorFromString(@"initWithClientName:");
        if (!cls || ![cls instancesRespondToSelector:init]) { return; }
        id (*make)(id, SEL, NSString *) = (id (*)(id, SEL, NSString *))[cls instanceMethodForSelector:init];
        client = make([cls alloc], init, @"MenuSprite");
    });
    return client;
}

/// Calls a selector shaped `-(T)name:(NSError **)error` or `-(T)name` and returns its
/// integer-like result, or `fallback` when the selector is unavailable.
static NSInteger MSCall(NSString *name, BOOL takesError, NSInteger fallback) {
    id client = MSClient();
    SEL sel = NSSelectorFromString(name);
    if (!client || ![client respondsToSelector:sel]) { return fallback; }
    NSMethodSignature *signature = [client methodSignatureForSelector:sel];
    NSInvocation *call = [NSInvocation invocationWithMethodSignature:signature];
    call.target = client; call.selector = sel;
    NSError *__autoreleasing error = nil;
    NSError *__autoreleasing *errorPointer = &error;
    if (takesError) { [call setArgument:&errorPointer atIndex:2]; }
    [call invoke];
    if (error) { return fallback; }
    NSUInteger length = signature.methodReturnLength;
    if (length == 0 || length > 8) { return fallback; }
    unsigned long long raw = 0;
    [call getReturnValue:&raw];
    switch (length) {
        case 1: return (NSInteger)(raw & 0xff);
        case 2: return (NSInteger)(raw & 0xffff);
        case 4: return (NSInteger)(raw & 0xffffffff);
        default: return (NSInteger)raw;
    }
}

@implementation MSPowerUI
+ (BOOL)isSupported { return MSCall(@"isMCLSupported", NO, 0) == 1; }
+ (NSInteger)currentLimit {
    NSInteger value = MSCall(@"getMCLLimitWithError:", YES, -1);
    return value >= 1 && value <= 100 ? value : -1;
}
+ (NSInteger)isEnabled {
    NSInteger value = MSCall(@"isMCLCurrentlyEnabled:", YES, -1);
    return value < 0 ? -1 : (value ? 1 : 0);
}
+ (BOOL)enable { return MSCall(@"enableMCL:", YES, 0) == 1; }
+ (NSArray<NSNumber *> *)availableLimits {
    id client = MSClient();
    SEL sel = NSSelectorFromString(@"availableChargeLimitsWithError:");
    if (!client || ![client respondsToSelector:sel]) { return @[]; }
    NSArray *(*call)(id, SEL, NSError **) = (NSArray *(*)(id, SEL, NSError **))[client methodForSelector:sel];
    NSError *error = nil;
    NSArray *values = call(client, sel, &error);
    return [values isKindOfClass:[NSArray class]] ? values : @[];
}
+ (BOOL)setLimit:(NSInteger)percent error:(NSError **)error {
    id client = MSClient();
    SEL sel = NSSelectorFromString(@"setMCLLimit:error:");
    if (!client || ![client respondsToSelector:sel] || percent < 0 || percent > 100) {
        if (error) { *error = [NSError errorWithDomain:@"MenuSprite.PowerUI" code:1 userInfo:@{NSLocalizedDescriptionKey: @"macOS charge limit is unavailable"}]; }
        return NO;
    }
    BOOL (*call)(id, SEL, unsigned char, NSError **) = (BOOL (*)(id, SEL, unsigned char, NSError **))[client methodForSelector:sel];
    return call(client, sel, (unsigned char)percent, error);
}
@end
