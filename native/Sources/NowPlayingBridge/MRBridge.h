#import <Foundation/Foundation.h>

// Thin, defensive wrappers over the private MediaRemote framework. Every symbol is resolved at run
// time; a missing one disables only what needs it. All waits are bounded, and a callback that
// arrives after its wait writes into a box nobody reads any more.

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(uint32_t, NPCommand) {
    NPCommandPlay = 0,
    NPCommandPause = 1,
    NPCommandToggle = 2,
    NPCommandNext = 4,
    NPCommandPrevious = 5,
    NPCommandSeek = 24,
};

/// One registered MediaRemote client.
@interface NPClient : NSObject
@property (nonatomic) pid_t pid;
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, copy, nullable) NSString *parentBundleID;
@property (nonatomic, copy, nullable) NSString *displayName;
@end

/// One player's Now Playing dictionary (without artwork bytes) and, when asked for, its artwork.
@interface NPPlayerRead : NSObject
@property (nonatomic, copy, nullable) NSDictionary *info;
@property (nonatomic, copy, nullable) NSData *artwork;
@end

/// What a player's supported-commands list says. `known` is NO when the list could not be read.
@interface NPCapabilities : NSObject
@property (nonatomic) BOOL known;
@property (nonatomic) BOOL canPlay;
@property (nonatomic) BOOL canPause;
@property (nonatomic) BOOL canSeek;
@property (nonatomic) BOOL canNext;
@property (nonatomic) BOOL canPrevious;
@end

/// A supported-commands query already on its way, so it can run beside the metadata read.
@interface NPCapabilitiesRequest : NSObject
- (NPCapabilities *)waitUpTo:(double)seconds;
@end

BOOL NPLoadMediaRemote(void);
void NPRegisterForNotifications(dispatch_queue_t queue);
NSArray<NSString *> *NPNotificationNames(void);
/// The value of one of MediaRemote's exported NSString constants, or nil when it is missing.
NSString *_Nullable NPConstant(const char *symbol);

/// The pid owning the system's Now Playing session, or 0.
pid_t NPCurrentClientPID(double timeout);
/// Every registered client (at most 16), or nil when the list did not arrive in time.
NSArray<NPClient *> *_Nullable NPClients(double timeout);

/// A destination for one app. Built from a copy of the shared local path: mutating the shared one
/// would silently redirect every destination built before.
id _Nullable NPMakePlayerPath(NSString *bundleID, pid_t pid);
/// Music, Podcasts or Books.
BOOL NPIsSystemPlayer(id path);

/// Reads several players at once, keyed like `paths`; waits at most `timeout` and returns what
/// completed. A player that answered with nothing maps to a read whose info is nil.
NSDictionary<NSNumber *, NPPlayerRead *> *NPReadPlayers(NSDictionary<NSNumber *, id> *paths, BOOL artwork, double timeout);
NPCapabilitiesRequest *NPRequestCapabilities(id path);

/// Sends one command to one player. Success needs the call to return true, no send error and at
/// least one handler reporting success, within `timeout`.
BOOL NPSend(NPCommand command, NSDictionary *options, id path, double timeout);

NS_ASSUME_NONNULL_END
