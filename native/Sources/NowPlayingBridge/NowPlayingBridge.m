// MenuSprite's Now Playing adapter, loaded into /usr/bin/perl.
//
// From macOS 15.4 MediaRemote answers only Apple-signed processes, and /usr/bin/perl is one, so the
// app runs perl, perl loads this library, and every MediaRemote call happens here. (Loading a helper
// into perl was first published by ungive/mediaremote-adapter; this is MenuSprite's own adapter,
// written from MenuSprite's specification.)
//
// The adapter only reads and sends. It reports every candidate player it can read; the app decides
// which one to follow and tells it (`target`). Nothing polls: MediaRemote's notifications trigger a
// debounced refresh. Closing standard input ends the process.

#import "NowPlayingBridge.h"
#import "MRBridge.h"
#import <AppKit/AppKit.h>
#import <signal.h>

static const NSUInteger kMaxCommandBytes = 2048;
static const NSUInteger kMaxCandidates = 16;
static const NSUInteger kMaxArtworkBytes = 12 * 1024 * 1024;
static const double kMaxPosition = 604800;

static dispatch_queue_t gQueue;
static dispatch_queue_t gOutput;

// Everything below is touched only on gQueue.
static NSInteger gSequence;
static pid_t gFollowPID;
static NSString *gFollowBundle;
static NSArray<NPClient *> *gExtras;
static NSUInteger gRefreshGeneration;
static NSDictionary<NSNumber *, NPClient *> *gClients;
static NSMutableDictionary<NSNumber *, dispatch_source_t> *gExitWatchers;
static NSMutableDictionary<NSString *, NSNumber *> *gMusicApps;

// The recording last published, which commands are validated against.
static pid_t gPublishedPID;
static NSString *gPublishedBundle;
static NSString *gIdentity;
static NSString *gRevision;
static id gPublishedPath;
static NSString *gPublishedItemID;
static BOOL gPublishedDirect;
static BOOL gPublishedRequiresCurrent;
static NPCapabilities *gPublishedCapabilities;
static NSData *gLastArtwork;

#pragma mark - Output

static id finite(double value) { return isfinite(value) ? @(value) : nil; }

static void emit(NSDictionary *reply) {
    NSData *data = nil;
    @try {
        data = [NSJSONSerialization dataWithJSONObject:reply options:NSJSONWritingWithoutEscapingSlashes error:nil];
    } @catch (NSException *exception) {
        data = nil;
    }
    if (!data) data = [@"{\"type\":\"error\",\"message\":\"Could not encode a reply.\"}" dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableData *line = [data mutableCopy];
    [line appendBytes:"\n" length:1];
    dispatch_async(gOutput, ^{
        const uint8_t *bytes = line.bytes;
        size_t remaining = line.length;
        while (remaining > 0) {
            ssize_t written = write(STDOUT_FILENO, bytes, remaining);
            if (written < 0) {
                if (errno == EINTR) continue;
                exit(0);
            }
            bytes += written;
            remaining -= (size_t)written;
        }
    });
}

#pragma mark - Players

static BOOL isValidIdentifier(id value) {
    if (![value isKindOfClass:NSString.class]) return NO;
    NSString *string = value;
    NSUInteger bytes = [string lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    return bytes > 0 && bytes <= 512 && [string rangeOfString:@"\0"].location == NSNotFound;
}

static BOOL processRuns(pid_t pid) { return pid > 0 && (kill(pid, 0) == 0 || errno == EPERM); }

/// A (pid, bundle) pair names a live player when MediaRemote lists it that way or the running
/// app with that pid has that bundle id, so a reused pid cannot stand in for another app.
static BOOL isLivePlayer(pid_t pid, NSString *bundle) {
    if (!processRuns(pid)) return NO;
    NPClient *client = gClients[@(pid)];
    if (client) return [client.bundleID isEqualToString:bundle];
    NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    return app && !app.terminated && [app.bundleIdentifier isEqualToString:bundle];
}

static BOOL isMusicBundle(NSString *bundle, NSURL *_Nullable appURL) {
    if (!bundle) return NO;
    static NSSet *known;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ known = [NSSet setWithObjects:@"com.apple.Music", @"com.apple.iTunes", @"com.spotify.client", nil]; });
    if ([known containsObject:bundle] || [bundle hasPrefix:@"com.spotify.client."]) return YES;
    NSNumber *cached = gMusicApps[bundle];
    if (cached) return cached.boolValue;
    NSURL *url = appURL ?: [[NSWorkspace sharedWorkspace] URLForApplicationWithBundleIdentifier:bundle];
    NSString *category = url ? [NSBundle bundleWithURL:url].infoDictionary[@"LSApplicationCategoryType"] : nil;
    BOOL music = [category isKindOfClass:NSString.class] && [category isEqualToString:@"public.app-category.music"];
    if (gMusicApps.count < 512) gMusicApps[bundle] = @(music);
    return music;
}

static NSString *displayName(NPClient *client, pid_t pid, NSString *_Nullable parent) {
    if (client.displayName.length) return client.displayName;
    NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    if (app.localizedName.length) return app.localizedName;
    if (parent) return [NSRunningApplication runningApplicationsWithBundleIdentifier:parent].firstObject.localizedName;
    return nil;
}

static NSString *text(id value) { return [value isKindOfClass:NSString.class] ? value : @""; }

static double number(id value, double fallback) {
    return [value isKindOfClass:NSNumber.class] && isfinite([value doubleValue]) ? [value doubleValue] : fallback;
}

static BOOL hasTrack(NSDictionary *info) {
    NSString *title = text(info[@"kMRMediaRemoteNowPlayingInfoTitle"]);
    return [title stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length > 0;
}

static NSString *identity(NSDictionary *info, NSString *_Nullable itemID) {
    if (itemID) return [@"id:" stringByAppendingString:itemID];
    double duration = number(info[@"kMRMediaRemoteNowPlayingInfoDuration"], 0);
    return [NSString stringWithFormat:@"t:%@\x1f%@\x1f%@\x1f%.0f", text(info[@"kMRMediaRemoteNowPlayingInfoTitle"]),
            text(info[@"kMRMediaRemoteNowPlayingInfoArtist"]), text(info[@"kMRMediaRemoteNowPlayingInfoAlbum"]), round(duration)];
}

static NSString *_Nullable itemIdentifier(NSDictionary *info) {
    id value = info[@"kMRMediaRemoteNowPlayingInfoContentItemIdentifier"];
    return isValidIdentifier(value) ? value : nil;
}

#pragma mark - Refresh

static void forgetPublished(void) {
    gPublishedPID = 0;
    gPublishedBundle = nil;
    gIdentity = nil;
    gRevision = nil;
    gPublishedPath = nil;
    gPublishedItemID = nil;
    gPublishedDirect = NO;
    gPublishedRequiresCurrent = NO;
    gPublishedCapabilities = nil;
}

/// Reads every candidate without artwork and reports them.
static pid_t discover(void) {
    pid_t current = NPCurrentClientPID(0.5);
    NSArray<NPClient *> *clients = NPClients(0.2) ?: @[];
    NSMutableDictionary<NSNumber *, NPClient *> *byPID = [NSMutableDictionary dictionary];
    for (NPClient *client in clients) byPID[@(client.pid)] = client;
    gClients = byPID;

    NSMutableArray<NPClient *> *candidates = [NSMutableArray array];
    NSMutableSet<NSNumber *> *seen = [NSMutableSet set];
    void (^add)(pid_t, NSString *) = ^(pid_t pid, NSString *bundle) {
        if (candidates.count >= kMaxCandidates || pid <= 0 || !isValidIdentifier(bundle) || [seen containsObject:@(pid)]) return;
        if (!isLivePlayer(pid, bundle)) return;
        NPClient *known = byPID[@(pid)];
        NPClient *candidate = [NPClient new];
        candidate.pid = pid;
        candidate.bundleID = bundle;
        candidate.parentBundleID = known.parentBundleID;
        candidate.displayName = known.displayName;
        [seen addObject:@(pid)];
        [candidates addObject:candidate];
    };
    if (gFollowPID > 0) add(gFollowPID, gFollowBundle);
    for (NPClient *extra in gExtras) add(extra.pid, extra.bundleID);
    if (current > 0) {
        NSString *bundle = byPID[@(current)].bundleID ?: [NSRunningApplication runningApplicationWithProcessIdentifier:current].bundleIdentifier;
        if (bundle) add(current, bundle);
    }
    // The workspace keeps its list current on the main run loop; read it there, filter it here.
    __block NSArray<NSRunningApplication *> *running = @[];
    dispatch_sync(dispatch_get_main_queue(), ^{ running = NSWorkspace.sharedWorkspace.runningApplications; });
    for (NSRunningApplication *app in running) {
        if (app.bundleIdentifier && isMusicBundle(app.bundleIdentifier, app.bundleURL)) add(app.processIdentifier, app.bundleIdentifier);
    }
    for (NPClient *client in clients) add(client.pid, client.bundleID);

    NSMutableDictionary<NSNumber *, id> *paths = [NSMutableDictionary dictionary];
    for (NPClient *candidate in candidates) {
        id path = NPMakePlayerPath(candidate.bundleID, candidate.pid);
        if (path) paths[@(candidate.pid)] = path;
    }
    NSDictionary<NSNumber *, NPPlayerRead *> *reads = NPReadPlayers(paths, NO, 1.0);

    NSMutableArray *sources = [NSMutableArray array];
    for (NPClient *candidate in candidates) {
        NPPlayerRead *read = reads[@(candidate.pid)];
        if (!read) continue;
        NSString *parent = candidate.parentBundleID;
        NSMutableDictionary *entry = [@{
            @"pid": @(candidate.pid),
            @"bundle": candidate.bundleID,
            @"display": parent ?: candidate.bundleID,
            @"music": @(isMusicBundle(candidate.bundleID, nil) || (parent && isMusicBundle(parent, nil))),
            @"playing": @(number(read.info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"], 0) > 0),
            @"track": @(read.info && hasTrack(read.info)),
        } mutableCopy];
        NSString *name = displayName(candidate, candidate.pid, parent);
        if (name.length) entry[@"name"] = [name substringToIndex:MIN(name.length, (NSUInteger)256)];
        [sources addObject:entry];
    }
    NSMutableDictionary *reply = [@{@"type": @"sources", @"sources": sources} mutableCopy];
    if (current > 0) reply[@"current"] = @(current);
    emit(reply);
    return current;
}

/// Reads the followed player with artwork and publishes it.
static void readFollowed(pid_t current) {
    NSInteger sequence = gSequence;
    if (gFollowPID <= 0) { forgetPublished(); return; }
    id path = isLivePlayer(gFollowPID, gFollowBundle) ? NPMakePlayerPath(gFollowBundle, gFollowPID) : nil;
    if (!path) {
        forgetPublished();
        emit(@{@"type": @"playback", @"seq": @(sequence), @"empty": @YES});
        return;
    }
    NPCapabilitiesRequest *capabilitiesRequest = NPRequestCapabilities(path);
    NPPlayerRead *read = NPReadPlayers(@{@0: path}, YES, 2.0)[@0];
    if (!read) {
        // A lost callback must never leave stale playback on screen: stop, and let the app restart us.
        emit(@{@"type": @"error", @"message": @"The player did not answer."});
        dispatch_sync(gOutput, ^{});
        exit(1);
    }
    NSDictionary *info = read.info;
    if (!info || !hasTrack(info)) {
        forgetPublished();
        emit(@{@"type": @"playback", @"seq": @(sequence), @"empty": @YES});
        return;
    }
    NPCapabilities *capabilities = [capabilitiesRequest waitUpTo:0.2];

    NSString *itemID = itemIdentifier(info);
    NSString *recording = identity(info, itemID);
    if (gPublishedPID != gFollowPID || ![gPublishedBundle isEqualToString:gFollowBundle] || ![gIdentity isEqualToString:recording]) {
        gRevision = NSUUID.UUID.UUIDString.lowercaseString;
    }
    BOOL system = NPIsSystemPlayer(path);
    BOOL requiresCurrent = !system && current == gFollowPID;
    BOOL itemOption = NPConstant("kMRMediaRemoteOptionNowPlayingContentItemID") != nil;
    gPublishedPID = gFollowPID;
    gPublishedBundle = gFollowBundle;
    gIdentity = recording;
    gPublishedPath = path;
    gPublishedItemID = itemID;
    gPublishedDirect = (system && itemOption) || requiresCurrent;
    gPublishedRequiresCurrent = requiresCurrent;
    gPublishedCapabilities = capabilities;

    double rate = MAX(0, number(info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"], 0));
    NSMutableDictionary *reply = [@{
        @"type": @"playback", @"seq": @(sequence), @"pid": @(gFollowPID), @"bundle": gFollowBundle,
        @"display": gClients[@(gFollowPID)].parentBundleID ?: gFollowBundle,
        @"title": text(info[@"kMRMediaRemoteNowPlayingInfoTitle"]), @"artist": text(info[@"kMRMediaRemoteNowPlayingInfoArtist"]),
        @"album": text(info[@"kMRMediaRemoteNowPlayingInfoAlbum"]), @"rate": @(rate), @"playing": @(rate > 0),
        @"revision": gRevision, @"direct": @(gPublishedDirect),
    } mutableCopy];
    double duration = number(info[@"kMRMediaRemoteNowPlayingInfoDuration"], NAN);
    if (isfinite(duration) && duration > 0) reply[@"duration"] = finite(duration);
    id elapsedValue = info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"];
    double elapsed = number(elapsedValue, NAN);
    if (isfinite(elapsed)) {
        id stamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
        if ([stamp isKindOfClass:NSDate.class]) elapsed += MAX(0, -[stamp timeIntervalSinceNow]) * rate;
        reply[@"elapsed"] = finite(elapsed);
    }
    if (itemID) reply[@"item"] = itemID;
    if (capabilities.known) {
        reply[@"canPlay"] = @(capabilities.canPlay);
        reply[@"canPause"] = @(capabilities.canPause);
        reply[@"canSeek"] = @(capabilities.canSeek);
        reply[@"canNext"] = @(capabilities.canNext);
        reply[@"canPrevious"] = @(capabilities.canPrevious);
    }
    NSData *artwork = read.artwork.length <= kMaxArtworkBytes ? read.artwork : nil;
    if (artwork.length && [artwork isEqualToData:gLastArtwork]) {
        reply[@"artworkUnchanged"] = @YES;
    } else if (artwork.length) {
        reply[@"artwork"] = [artwork base64EncodedStringWithOptions:0];
        gLastArtwork = artwork;
    }
    emit(reply);
}

static void refresh(void) {
    @autoreleasepool {
        pid_t current = discover();
        readFollowed(current);
    }
}

static void scheduleRefresh(void) {
    dispatch_async(gQueue, ^{
        NSUInteger generation = ++gRefreshGeneration;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_MSEC), gQueue, ^{
            if (generation == gRefreshGeneration) refresh();
        });
    });
}

/// Watches the followed and extra players' processes so a quit is noticed without polling.
static void watchExits(void) {
    NSMutableSet<NSNumber *> *wanted = [NSMutableSet set];
    if (gFollowPID > 0) [wanted addObject:@(gFollowPID)];
    for (NPClient *extra in gExtras) [wanted addObject:@(extra.pid)];
    for (NSNumber *pid in gExitWatchers.allKeys) {
        if (![wanted containsObject:pid]) { dispatch_source_cancel(gExitWatchers[pid]); [gExitWatchers removeObjectForKey:pid]; }
    }
    for (NSNumber *pid in wanted) {
        if (gExitWatchers[pid]) continue;
        dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, (uintptr_t)pid.intValue, DISPATCH_PROC_EXIT, gQueue);
        if (!source) continue;
        dispatch_source_set_event_handler(source, ^{
            dispatch_source_cancel(source);
            [gExitWatchers removeObjectForKey:pid];
            scheduleRefresh();
        });
        gExitWatchers[pid] = source;
        dispatch_resume(source);
    }
}

#pragma mark - Commands

static BOOL isPID(id value) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID()
        && [value doubleValue] == (double)[value intValue] && [value intValue] > 0;
}

static NPClient *_Nullable playerKey(id value) {
    if (![value isKindOfClass:NSDictionary.class] || !isPID(value[@"pid"]) || !isValidIdentifier(value[@"bundle"])) return nil;
    NPClient *key = [NPClient new];
    key.pid = [value[@"pid"] intValue];
    key.bundleID = value[@"bundle"];
    return key;
}

static void handleTarget(NSDictionary *message) {
    id sequence = message[@"seq"];
    if (![sequence isKindOfClass:NSNumber.class]) return;
    NPClient *follow = message[@"follow"] ? playerKey(message[@"follow"]) : nil;
    if (message[@"follow"] && !follow) return;
    NSMutableArray<NPClient *> *extras = [NSMutableArray array];
    if ([message[@"extra"] isKindOfClass:NSArray.class]) {
        for (id entry in message[@"extra"]) {
            NPClient *key = playerKey(entry);
            if (key && extras.count < 4) [extras addObject:key];
        }
    }
    BOOL changed = follow.pid != gFollowPID || !((follow == nil && gFollowBundle == nil) || [follow.bundleID isEqualToString:gFollowBundle]);
    gSequence = [sequence integerValue];
    gFollowPID = follow.pid;
    gFollowBundle = follow.bundleID;
    gExtras = extras;
    watchExits();
    if (changed) {
        forgetPublished();
        gLastArtwork = nil;
    }
    @autoreleasepool { readFollowed(NPCurrentClientPID(0.5)); }
}

/// Checks that a gesture still refers to the recording on screen, then sends exactly one command.
static BOOL deliver(NSDictionary *message, NPCommand command) {
    if (!isPID(message[@"pid"]) || ![message[@"revision"] isKindOfClass:NSString.class]) return NO;
    pid_t pid = [message[@"pid"] intValue];
    NSString *revision = [message[@"revision"] lowercaseString];
    if (!gRevision || pid != gPublishedPID || ![revision isEqualToString:gRevision] || !gPublishedPath) return NO;
    if (!gPublishedDirect || !isLivePlayer(pid, gPublishedBundle)) return NO;
    NPCapabilities *capabilities = gPublishedCapabilities;
    if (capabilities.known) {
        if ((command == NPCommandNext && !capabilities.canNext) || (command == NPCommandPrevious && !capabilities.canPrevious)
            || (command == NPCommandPlay && !capabilities.canPlay) || (command == NPCommandPause && !capabilities.canPause)) return NO;
    }
    NSMutableDictionary *options = [NSMutableDictionary dictionary];
    if (command == NPCommandSeek) {
        id position = message[@"position"];
        NSString *key = NPConstant("kMRMediaRemoteOptionPlaybackPosition");
        if (![position isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)position) == CFBooleanGetTypeID()) return NO;
        double seconds = [position doubleValue];
        if (!key || !isfinite(seconds) || seconds < 0 || seconds > kMaxPosition || !capabilities.canSeek) return NO;
        options[key] = @(seconds);
    }
    // The player may have moved on before its notification arrived: compare fresh metadata.
    NPPlayerRead *fresh = NPReadPlayers(@{@0: gPublishedPath}, NO, 1.0)[@0];
    if (!fresh.info || !hasTrack(fresh.info) || ![identity(fresh.info, itemIdentifier(fresh.info)) isEqualToString:gIdentity]) return NO;
    // Without a content item, MediaRemote could redirect the command to whichever app owns the system
    // session, so such a player is addressed only while it owns that session.
    BOOL ownsSession = NPCurrentClientPID(0.5) == pid;
    if (gPublishedRequiresCurrent && !ownsSession) return NO;
    NSString *itemKey = NPConstant("kMRMediaRemoteOptionNowPlayingContentItemID");
    if (gPublishedItemID && itemKey) options[itemKey] = gPublishedItemID;
    else if (!ownsSession) return NO;
    return NPSend(command, options, gPublishedPath, 2.0);
}

static void handleCommand(NSDictionary *message) {
    NSString *name = message[@"cmd"];
    if (![name isKindOfClass:NSString.class]) return;
    if ([name isEqualToString:@"target"]) { handleTarget(message); return; }
    NSDictionary<NSString *, NSNumber *> *commands = @{@"play": @(NPCommandPlay), @"pause": @(NPCommandPause), @"toggle": @(NPCommandToggle),
                                                     @"next": @(NPCommandNext), @"previous": @(NPCommandPrevious), @"seek": @(NPCommandSeek)};
    NSNumber *command = commands[name];
    id identifier = message[@"id"];
    if (!command || ![identifier isKindOfClass:NSNumber.class]) return;
    BOOL ok;
    @autoreleasepool { ok = deliver(message, (NPCommand)command.unsignedIntValue); }
    emit(@{@"type": @"result", @"id": identifier, @"ok": @(ok)});
}

#pragma mark - Input

/// Frames standard input into commands. An oversize line is dropped up to its newline only.
static void startInput(void) {
    dispatch_queue_t inputQueue = dispatch_queue_create("in.prerakgada.MenuSprite.now-playing.input", DISPATCH_QUEUE_SERIAL);
    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0, inputQueue);
    __block NSMutableData *buffer = [NSMutableData data];
    __block BOOL discarding = NO;
    dispatch_source_set_event_handler(source, ^{
        uint8_t chunk[4096];
        ssize_t count = read(STDIN_FILENO, chunk, sizeof chunk);
        if (count < 0 && (errno == EINTR || errno == EAGAIN)) return;
        if (count <= 0) exit(0);
        for (ssize_t index = 0; index < count; index++) {
            if (chunk[index] != '\n') {
                if (!discarding) {
                    if (buffer.length >= kMaxCommandBytes) { discarding = YES; buffer = [NSMutableData data]; }
                    else [buffer appendBytes:&chunk[index] length:1];
                }
                continue;
            }
            if (!discarding && buffer.length > 0) {
                id message = [NSJSONSerialization JSONObjectWithData:buffer options:0 error:nil];
                if ([message isKindOfClass:NSDictionary.class]) dispatch_async(gQueue, ^{ handleCommand(message); });
            }
            discarding = NO;
            buffer = [NSMutableData data];
        }
    });
    dispatch_resume(source);
    // Keep the source alive for the life of the process.
    static dispatch_source_t retained;
    retained = source;
}

#pragma mark - Entry point

void menusprite_now_playing_watch(void *interpreter, void *cv) {
    (void)interpreter;
    (void)cv;
    signal(SIGPIPE, SIG_DFL);
    gQueue = dispatch_queue_create("in.prerakgada.MenuSprite.now-playing", DISPATCH_QUEUE_SERIAL);
    gOutput = dispatch_queue_create("in.prerakgada.MenuSprite.now-playing.output", DISPATCH_QUEUE_SERIAL);
    gExitWatchers = [NSMutableDictionary dictionary];
    gMusicApps = [NSMutableDictionary dictionary];
    if (!NPLoadMediaRemote()) {
        emit(@{@"type": @"error", @"message": @"MediaRemote is unavailable."});
        dispatch_sync(gOutput, ^{});
        exit(1);
    }
    NPRegisterForNotifications(dispatch_get_main_queue());
    for (NSString *name in NPNotificationNames()) {
        [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *note) {
            scheduleRefresh();
        }];
    }
    startInput();
    dispatch_async(gQueue, ^{ refresh(); });
    CFRunLoopRun();
    exit(0);
}
