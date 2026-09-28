#import "MRBridge.h"
#import <dlfcn.h>
#import <objc/message.h>

typedef void (*MRRegisterFn)(dispatch_queue_t);
typedef void (*MRGetClientFn)(dispatch_queue_t, void (^)(id _Nullable));
typedef void (*MRGetClientsFn)(dispatch_queue_t, void (^)(NSArray *_Nullable));
typedef int32_t (*MRClientPIDFn)(id);
typedef NSString *_Nullable (*MRClientStringFn)(id);
typedef void (*MRInfoForPlayerFn)(id, Boolean, dispatch_queue_t, void (^)(NSDictionary *_Nullable, void *_Nullable));
typedef CFDataRef _Nullable (*MRArtworkCopyDataFn)(void *);
typedef void (*MRSupportedFn)(id, dispatch_queue_t, void (^)(NSArray *_Nullable));
typedef uint32_t (*MRCommandInfoCommandFn)(id);
typedef Boolean (*MRCommandInfoEnabledFn)(id);
typedef Boolean (*MRSendToPlayerFn)(uint32_t, NSDictionary *_Nullable, id, uint32_t, dispatch_queue_t,
                                    void (^)(uintptr_t, NSArray *_Nullable));

static void *gMediaRemote;
static dispatch_queue_t gCallbacks;

static void *symbol(const char *name) { return gMediaRemote ? dlsym(gMediaRemote, name) : NULL; }

@implementation NPClient
@end

@implementation NPPlayerRead
@end

@implementation NPCapabilities
@end

/// Collects answers from callbacks that may arrive late, on any thread.
@interface NPWaitBox : NSObject
@property (nonatomic, strong) dispatch_semaphore_t semaphore;
@property (nonatomic, strong) NSMutableDictionary *results;
@end

@implementation NPWaitBox
- (instancetype)init {
    if ((self = [super init])) {
        _semaphore = dispatch_semaphore_create(0);
        _results = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)store:(id)value forKey:(id<NSCopying>)key {
    @synchronized (self) { self.results[key] = value; }
    dispatch_semaphore_signal(self.semaphore);
}

/// Waits for `count` answers or until the deadline, then returns a snapshot of what arrived.
- (NSDictionary *)waitFor:(NSUInteger)count seconds:(double)seconds {
    dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC));
    for (NSUInteger index = 0; index < count; index++) {
        if (dispatch_semaphore_wait(self.semaphore, deadline) != 0) break;
    }
    @synchronized (self) { return [self.results copy]; }
}
@end

@interface NPCapabilitiesRequest ()
@property (nonatomic, strong) NPWaitBox *box;
@end

@implementation NPCapabilitiesRequest
- (NPCapabilities *)waitUpTo:(double)seconds {
    NSDictionary *answer = [self.box waitFor:1 seconds:seconds];
    return answer[@0] ?: [NPCapabilities new];
}
@end

BOOL NPLoadMediaRemote(void) {
    if (!gMediaRemote) {
        gMediaRemote = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW | RTLD_LOCAL);
        gCallbacks = dispatch_queue_create("in.prerakgada.MenuSprite.now-playing.callbacks", DISPATCH_QUEUE_CONCURRENT);
    }
    return gMediaRemote != NULL;
}

void NPRegisterForNotifications(dispatch_queue_t queue) {
    MRRegisterFn registerFn = (MRRegisterFn)symbol("MRMediaRemoteRegisterForNowPlayingNotifications");
    if (registerFn) registerFn(queue);
}

NSString *NPConstant(const char *name) {
    NSString *__unsafe_unretained *pointer = (NSString *__unsafe_unretained *)symbol(name);
    return pointer ? *pointer : nil;
}

NSArray<NSString *> *NPNotificationNames(void) {
    const char *names[] = {
        "kMRMediaRemoteNowPlayingInfoDidChangeNotification",
        "kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
        "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
        "kMRMediaRemotePlayerNowPlayingInfoDidChangeNotification",
        "kMRMediaRemoteNowPlayingPlayerStateDidChange",
        "kMRMediaRemoteNowPlayingApplicationClientStateDidChange",
    };
    NSMutableArray *result = [NSMutableArray array];
    for (size_t index = 0; index < sizeof(names) / sizeof(names[0]); index++) {
        // The exported constant is the name; fall back to the symbol's own spelling.
        [result addObject:NPConstant(names[index]) ?: @(names[index])];
    }
    return result;
}

pid_t NPCurrentClientPID(double timeout) {
    MRGetClientFn getClient = (MRGetClientFn)symbol("MRMediaRemoteGetNowPlayingClient");
    MRClientPIDFn getPID = (MRClientPIDFn)symbol("MRNowPlayingClientGetProcessIdentifier");
    if (!getClient || !getPID) return 0;
    NPWaitBox *box = [NPWaitBox new];
    getClient(gCallbacks, ^(id client) {
        [box store:@(client ? getPID(client) : 0) forKey:@0];
    });
    NSNumber *pid = [box waitFor:1 seconds:timeout][@0];
    return pid.intValue > 0 ? pid.intValue : 0;
}

NSArray<NPClient *> *NPClients(double timeout) {
    MRGetClientsFn getClients = (MRGetClientsFn)symbol("MRMediaRemoteGetNowPlayingClients");
    MRClientPIDFn getPID = (MRClientPIDFn)symbol("MRNowPlayingClientGetProcessIdentifier");
    MRClientStringFn getBundle = (MRClientStringFn)symbol("MRNowPlayingClientGetBundleIdentifier");
    MRClientStringFn getParent = (MRClientStringFn)symbol("MRNowPlayingClientGetParentAppBundleIdentifier");
    MRClientStringFn getName = (MRClientStringFn)symbol("MRNowPlayingClientGetDisplayName");
    if (!getClients || !getPID || !getBundle) return nil;
    NPWaitBox *box = [NPWaitBox new];
    getClients(gCallbacks, ^(NSArray *list) {
        NSMutableArray *clients = [NSMutableArray array];
        for (id entry in list) {
            if (clients.count >= 16) break;
            NSString *bundle = getBundle(entry);
            pid_t pid = getPID(entry);
            if (pid <= 0 || ![bundle isKindOfClass:NSString.class] || bundle.length == 0) continue;
            NPClient *client = [NPClient new];
            client.pid = pid;
            client.bundleID = bundle;
            NSString *parent = getParent ? getParent(entry) : nil;
            client.parentBundleID = [parent isKindOfClass:NSString.class] && parent.length ? parent : nil;
            NSString *name = getName ? getName(entry) : nil;
            client.displayName = [name isKindOfClass:NSString.class] && name.length ? name : nil;
            [clients addObject:client];
        }
        [box store:clients forKey:@0];
    });
    return [box waitFor:1 seconds:timeout][@0];
}

id NPMakePlayerPath(NSString *bundleID, pid_t pid) {
    Class pathClass = NSClassFromString(@"MRPlayerPath");
    Class clientClass = NSClassFromString(@"MRClient");
    SEL local = NSSelectorFromString(@"localPlayerPath");
    SEL initBundle = NSSelectorFromString(@"initWithBundleIdentifier:");
    SEL setPID = NSSelectorFromString(@"setProcessIdentifier:");
    SEL setClient = NSSelectorFromString(@"setClient:");
    SEL setPlayer = NSSelectorFromString(@"setPlayer:");
    if (!pathClass || !clientClass || ![pathClass respondsToSelector:local]) return nil;
    if (![clientClass instancesRespondToSelector:initBundle] || ![clientClass instancesRespondToSelector:setPID]) return nil;
    if (![pathClass instancesRespondToSelector:setClient] || ![pathClass instancesRespondToSelector:setPlayer]) return nil;
    id shared = ((id (*)(id, SEL))objc_msgSend)(pathClass, local);
    if (![shared conformsToProtocol:@protocol(NSCopying)]) return nil;
    id path = [shared copy];
    id client = ((id (*)(id, SEL))objc_msgSend)(clientClass, @selector(alloc));
    client = ((id (*)(id, SEL, NSString *))objc_msgSend)(client, initBundle, bundleID);
    if (!path || !client) return nil;
    ((void (*)(id, SEL, int32_t))objc_msgSend)(client, setPID, pid);
    ((void (*)(id, SEL, id))objc_msgSend)(path, setClient, client);
    // Nil selects the app's active player; "default" would be a different one.
    ((void (*)(id, SEL, id))objc_msgSend)(path, setPlayer, nil);
    return path;
}

BOOL NPIsSystemPlayer(id path) {
    for (NSString *name in @[@"isSystemMediaApplication", @"isSystemPodcastsApplication", @"isSystemBooksApplication"]) {
        SEL selector = NSSelectorFromString(name);
        if ([path respondsToSelector:selector] && ((BOOL (*)(id, SEL))objc_msgSend)(path, selector)) return YES;
    }
    return NO;
}

NSDictionary<NSNumber *, NPPlayerRead *> *NPReadPlayers(NSDictionary<NSNumber *, id> *paths, BOOL artwork, double timeout) {
    MRInfoForPlayerFn read = (MRInfoForPlayerFn)symbol("MRMediaRemoteGetNowPlayingInfoForPlayer");
    MRArtworkCopyDataFn copyArtwork = (MRArtworkCopyDataFn)symbol("MRNowPlayingArtworkCopyImageData");
    NSString *artworkKey = NPConstant("kMRMediaRemoteNowPlayingInfoArtworkData") ?: @"kMRMediaRemoteNowPlayingInfoArtworkData";
    if (!read || paths.count == 0) return @{};
    NPWaitBox *box = [NPWaitBox new];
    [paths enumerateKeysAndObjectsUsingBlock:^(NSNumber *key, id path, BOOL *stop) {
        read(path, artwork, gCallbacks, ^(NSDictionary *info, void *artworkRef) {
            NPPlayerRead *result = [NPPlayerRead new];
            if ([info isKindOfClass:NSDictionary.class]) {
                NSMutableDictionary *copy = [info mutableCopy];
                id bytes = copy[artworkKey];
                [copy removeObjectForKey:artworkKey];
                result.info = copy;
                if (artwork) {
                    if ([bytes isKindOfClass:NSData.class] && [bytes length] > 0) {
                        result.artwork = bytes;
                    } else if (artworkRef && copyArtwork) {
                        CFDataRef data = copyArtwork(artworkRef);
                        if (data) result.artwork = CFBridgingRelease(data);
                    }
                }
            }
            [box store:result forKey:key];
        });
    }];
    return [box waitFor:paths.count seconds:timeout];
}

NPCapabilitiesRequest *NPRequestCapabilities(id path) {
    NPCapabilitiesRequest *request = [NPCapabilitiesRequest new];
    request.box = [NPWaitBox new];
    MRSupportedFn supported = (MRSupportedFn)symbol("MRMediaRemoteGetSupportedCommandsForPlayer");
    MRCommandInfoCommandFn commandOf = (MRCommandInfoCommandFn)symbol("MRMediaRemoteCommandInfoGetCommand");
    MRCommandInfoEnabledFn enabledOf = (MRCommandInfoEnabledFn)symbol("MRMediaRemoteCommandInfoGetEnabled");
    if (!supported || !commandOf || !enabledOf) return request;
    BOOL positionKnown = NPConstant("kMRMediaRemoteOptionPlaybackPosition") != nil;
    NPWaitBox *box = request.box;
    supported(path, gCallbacks, ^(NSArray *commands) {
        if (![commands isKindOfClass:NSArray.class]) return;
        NSMutableSet<NSNumber *> *enabled = [NSMutableSet set];
        for (id entry in commands) {
            if (enabledOf(entry)) [enabled addObject:@(commandOf(entry))];
        }
        NPCapabilities *capabilities = [NPCapabilities new];
        capabilities.known = YES;
        capabilities.canPlay = [enabled containsObject:@(NPCommandPlay)];
        capabilities.canPause = [enabled containsObject:@(NPCommandPause)];
        capabilities.canSeek = positionKnown && [enabled containsObject:@(NPCommandSeek)];
        capabilities.canNext = [enabled containsObject:@(NPCommandNext)];
        capabilities.canPrevious = [enabled containsObject:@(NPCommandPrevious)];
        [box store:capabilities forKey:@0];
    });
    return request;
}

BOOL NPSend(NPCommand command, NSDictionary *options, id path, double timeout) {
    MRSendToPlayerFn send = (MRSendToPlayerFn)symbol("MRMediaRemoteSendCommandToPlayer");
    if (!send) return NO;
    NPWaitBox *box = [NPWaitBox new];
    Boolean accepted = send(command, options, path, 0, gCallbacks, ^(uintptr_t error, NSArray *statuses) {
        BOOL handled = NO;
        if ([statuses isKindOfClass:NSArray.class]) {
            for (id status in statuses) {
                if ([status isKindOfClass:NSNumber.class] && [status unsignedIntValue] == 0) handled = YES;
            }
        }
        [box store:@(error == 0 && handled) forKey:@0];
    });
    if (!accepted) return NO;
    return [[box waitFor:1 seconds:timeout][@0] boolValue];
}
