#import "include/Header.h"
#import <AVFoundation/AVAudioSession.h>

// Connect
SPTGaiaDeviceManager *gaia;

// Shuffle and repeat
SPTNowPlayingPlaybackController *playbackController;

// Offline toggle
SPCore *core;
SettingsViewController *offlineViewController;
BOOL isCurrentViewOfflineView;

// Save to playlist/collection
SPTStatefulPlayer *statefulPlayer;
SPPlaylistContainer *playlistContainer;
SPPlaylistContainerCallbacksHolder *callbacksHolder;
SPTNowPlayingAuxiliaryActionsModel *auxActionModel;

// Incognito Mode
SPSession *session;

static int fetchCallCount = 0;

// Method that updates changes to .plist
void writeToSettings() {
    if (![preferences writeToFile:prefPath atomically:YES]) {
        HBLogError(@"Could not save preferences!");
    }
}

// Method that fetches playlists
void fetchPlaylists() {
    playlistContainer = [callbacksHolder playlists];
    playlists = [[NSMutableArray alloc] init];
    
    for (SPPlaylist *list in playlistContainer.actualPlaylists) {
        if (list.isWriteable && ![list.name isEqualToString:@""]) {
            playlist = [[NSMutableDictionary alloc] init];
            [playlist setObject:[list.URL absoluteString] forKey:@"URL"];
            [playlist setObject:list.name forKey:@"name"];
            [playlists addObject:playlist];
        }
    }
    
    // Save playlists to plist in order to share with SpringBoard
    [preferences setObject:playlists forKey:playlistsKey];
    [playlists release];
    [playlist release];
    writeToSettings();
}


/* Notifications methods */
// Update preferences
void updateSettings(CFNotificationCenterRef center,
                         void *observer,
                         CFStringRef name,
                         const void *object,
                         CFDictionaryRef userInfo) {

    preferences = [[NSMutableDictionary alloc] initWithContentsOfFile:prefPath];
}

// Offline
void doEnableOfflineMode(CFNotificationCenterRef center,
                     void *observer,
                     CFStringRef name,
                     const void *object,
                     CFDictionaryRef userInfo) {
    
    [core setForcedOffline:YES];
}

void doDisableOfflineMode(CFNotificationCenterRef center,
                         void *observer,
                         CFStringRef name,
                         const void *object,
                         CFDictionaryRef userInfo) {
    
    [core setForcedOffline:NO];
}

// Shuffle
void doToggleShuffle(CFNotificationCenterRef center,
                     void *observer,
                     CFStringRef name,
                     const void *object,
                     CFDictionaryRef userInfo) {
    
    // Update state
    preferences = [[NSMutableDictionary alloc] initWithContentsOfFile:prefPath];
    BOOL enable = ![[preferences objectForKey:shuffleKey] boolValue];
    [playbackController setGlobalShuffleMode:enable];
    
    [preferences setObject:[NSNumber numberWithBool:enable] forKey:shuffleKey];
    writeToSettings();
}

// Repeat
void doEnableRepeat(CFNotificationCenterRef center,
                     void *observer,
                     CFStringRef name,
                     const void *object,
                     CFDictionaryRef userInfo) {
    [playbackController setRepeatMode:2];
}

void doDisableRepeat(CFNotificationCenterRef center,
                    void *observer,
                    CFStringRef name,
                    const void *object,
                    CFDictionaryRef userInfo) {
    [playbackController setRepeatMode:0];
}

// Connect
void doChangeConnectDevice(CFNotificationCenterRef center,
                           void *observer,
                           CFStringRef name,
                           const void *object,
                           CFDictionaryRef userInfo) {
    // Update device
    preferences = [[NSMutableDictionary alloc] initWithContentsOfFile:prefPath];
    NSString *deviceName = [preferences objectForKey:activeDeviceKey];

    for (SPTGaiaDevice *device in [gaia devices]) {
        if ([device.name isEqualToString:deviceName]) {
            [gaia activateDevice:device withCallback:nil];
            return;
        }
    }

     // No matching names
     [gaia activateDevice:nil withCallback:nil];
}

// Add to playlist
void addCurrentTrackToPlaylist(CFNotificationCenterRef center,
                           void *observer,
                           CFStringRef name,
                           const void *object,
                           CFDictionaryRef userInfo) {
    NSString *chosenPlaylist;
    
    // Has user specified playlist in Preferences?
    if (specifiedPlaylistName != nil && ![specifiedPlaylistName isEqualToString:@""]) {
        HBLogDebug(@"Recieved notification and will add to specified playlist: %@", specifiedPlaylistName);
        chosenPlaylist = [preferences objectForKey:@"specifiedPlaylistName"];
    } else {
        // Update chosen playlist
        preferences = [[NSMutableDictionary alloc] initWithContentsOfFile:prefPath];
        chosenPlaylist = [preferences objectForKey:chosenPlaylistKey];
    }

    for (SPPlaylist *playlist in playlistContainer.actualPlaylists) {
        if ([playlist.name isEqualToString:chosenPlaylist]) {
            SPPlayerTrack *currentTrack = ((SPPlayerTrack *)[statefulPlayer currentTrack]);
            for (NSURL* trackURL in [playlist trackURLSet]) {
                if ([[preferences objectForKey:@"skipDuplicates"] boolValue] && [trackURL.absoluteString isEqualToString:currentTrack.URI.absoluteString]) {
                    HBLogDebug(@"Found duplicate!");
                    return;
                }
            }

            HBLogDebug(@"Adding track '%@' to playlist '%@'", currentTrack.URI, playlist.name);
            NSArray *tracks = [[NSArray alloc] initWithObjects:currentTrack.URI, nil];
            [playlist addTrackURLs:tracks];
            [tracks release];
            return;
        }
    }
    HBLogDebug(@"Found no such playlist!");
}

// Add to collection
void toggleCurrentTrackInCollection(CFNotificationCenterRef center,
                               void *observer,
                               CFStringRef name,
                               const void *object,
                               CFDictionaryRef userInfo) {
    BOOL inCollection = [auxActionModel isInCollection];
    inCollection ? [auxActionModel removeFromCollection] : [auxActionModel addToCollection];
}

// Incognito Mode
void toggleIncognitoMode(CFNotificationCenterRef center,
                                    void *observer,
                                    CFStringRef name,
                                    const void *object,
                                    CFDictionaryRef userInfo) {
    BOOL enabled = [session isIncognitoModeEnabled];
    enabled ? [session disableIncognitoMode] : [session enableIncognitoMode];
}
/* ------- */

/* Hooks */
// Class that forces Offline Mode
%hook SPCore

- (id)init {
    return core = %orig;
}

- (void)setForcedOffline:(BOOL)arg {
    if (!isCurrentViewOfflineView) {
        return %orig;
    }
    // Else show alert saying why you cannot toggle in this menu
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Not allowed in this view"
                                                                             message:@"Toggling the flipswitch while here crashes Spotify. I have therefore disabled this so you can continue enjoying the music uninterrupted!"
                                                                      preferredStyle:UIAlertControllerStyleAlert];
    [alertController addAction:[UIAlertAction actionWithTitle:@"Fine by me" style:UIAlertActionStyleCancel handler:^(UIAlertAction * _Nonnull action) {
        [alertController dismissViewControllerAnimated:YES completion:nil];
    }]];
    [offlineViewController presentViewController:alertController animated:YES completion:nil];
    return;
}

%end


%hook SPBarViewController

// A little later in app launch
- (void)viewDidLoad {
    %orig;

    // Init offline mode
    [core setForcedOffline:[[preferences objectForKey:offlineKey] boolValue]];
}

%end


// Update list of playlists on change of "Recently Played" section
// is also executed on app launch
%hook SPTRecentlyPlayedEntityList

- (void)recentlyPlayedModelDidReload:(id)arg {
    %orig;

    // Only fetch once instead of twice
    if (fetchCallCount % 2 == 0) {
        fetchPlaylists();
    }
    fetchCallCount++;
}

%end


%hook SPTPlaylistCosmosModel

// Fortunately the URL is given, so we can match it against the smaller array
// and remove the matching playlist.
- (void)removePlaylistOrFolderURL:(NSURL *)url inFolderURL:(id)arg2 completion:(id)arg3 {
    %orig;

    playlists = [[preferences objectForKey:playlistsKey] mutableCopy];
    for (int i = 0; i < playlists.count; i++) {
        NSMutableDictionary *playlist = [playlists objectAtIndex:i];
        if ([playlist[@"URL"] isEqualToString:url.absoluteString]) {
            HBLogDebug(@"Removed playlist with url: %@", url.absoluteString);

            // Remove playlist from array
            [playlists removeObjectAtIndex:i];
            [preferences setObject:playlists forKey:playlistsKey];

            writeToSettings();
            [playlists release];
        }
    }
}

- (void)renamePlaylistURL:(NSURL *)url name:(NSString *)name completion:arg {
    %orig;


    playlists = [[preferences objectForKey:playlistsKey] mutableCopy];
    for (int i = 0; i < playlists.count; i++) {
        NSMutableDictionary *playlist = [playlists objectAtIndex:i];
        if ([playlist[@"URL"] isEqualToString:url.absoluteString]) {
            HBLogDebug(@"Renaming playlist with url: %@", url.absoluteString);

            playlist[@"name"] = name;
            [preferences setObject:playlists forKey:playlistsKey];

            writeToSettings();
            [playlists release];
        }
    }
}

%end


%hook SPTNowPlayingPlaybackController

// Saves controller
- (id)initWithPlayer:(id)arg1 trackPosition:(id)arg2 adsManager:(id)arg3 trackMetadataQueue:(id)arg4 {
    return playbackController = %orig;
}

// Method that changes repeat mode
- (void)setRepeatMode:(NSUInteger)value {
    %orig;

    // Update value
    [preferences setObject:[NSNumber numberWithInteger:value] forKey:repeatKey];
    writeToSettings();
}

%end



%hook SettingsViewController

// Prevents crash at Offline view in Settings
- (void)viewDidLayoutSubviews {
    %orig;
    if (self.sections.count >= 1) {
        NSString *className = NSStringFromClass([self.sections[1] class]);
        
        // Is current SettingsViewController the one with offline settings?
        // in that case, set isCurrentViewOFflineView to YES so that we
        // cannot toggle offline mode - Spotify will then crash!
        if ([className isEqualToString:@"OfflineSettingsSection"]) {
            offlineViewController = self;
            isCurrentViewOfflineView = YES;
        }
    }
}

%end


%hook SPNavigationController

// Reset state after going back from "Playback" setting view
- (void)viewWillLayoutSubviews {
    %orig;
    offlineViewController = nil;
    isCurrentViewOfflineView = NO;
}

%end


%hook Adjust

// Saves updated Offline Mode value (both through flipswitch and manually)
- (void)setOfflineMode:(BOOL)arg {
    %orig;

    // Update flipswitch state
    [preferences setObject:[NSNumber numberWithBool:arg] forKey:offlineKey];
    // Update Connectify settings
    [preferences setObject:@"" forKey:activeDeviceKey];
    [preferences setObject:@[] forKey:devicesKey];
    writeToSettings();
}

%end


%hook SPTNowPlayingMusicHeadUnitViewController

// Saves updated shuffle value
- (void)shuffleButtonPressed:(id)arg {
    %orig;
    BOOL current = [[preferences objectForKey:shuffleKey] boolValue];
    [preferences setObject:[NSNumber numberWithBool:current] forKey:shuffleKey];
    writeToSettings();

}

%end



// Connect classes

%hook SPTPlayerFeatureImplementation

// Save Spotify Connect Mananger
- (void)loadGaia {
    %orig;
    gaia = [self gaiaDeviceManager];
}

%end


%hook SPTGaiaDeviceManager

// Save Spotify Connect devices
- (void)rebuildDeviceList {
    %orig;
    if ([[self devices] count] > 0) {
        deviceNames = [[NSMutableArray alloc] init];
        for (SPTGaiaDevice *device in self.devices) {
            [deviceNames addObject:device.name];
        }
        [preferences setObject:deviceNames forKey:devicesKey];
        [deviceNames release];
    }

    SPTGaiaDevice *currentDevice = [self activeDevice];
    if (currentDevice != nil) {
        [preferences setObject:currentDevice.name forKey:activeDeviceKey];
    }

    writeToSettings();
}

// Method that changes Connect device
- (void)activateDevice:(SPTGaiaDevice *)device withCallback:(id)arg {
    %orig;
    [preferences setObject: (device ? device.name : @"") forKey:activeDeviceKey];
    writeToSettings();
}

%end



// Add to playlist

%hook SPPlaylistContainerCallbacksHolder

- (id)initWithObjc:(id)arg {
    return callbacksHolder ? %orig : callbacksHolder = %orig;
}

%end


// Class that stores current track
%hook SPTStatefulPlayer

- (id)initWithPlayer:(id)arg {
    return statefulPlayer = %orig;
}

%end



%hook SPTNowPlayingBarModel

- (void)setCurrentTrackURL:(SPPlayerTrack *)track {
    %orig;
    
    preferences = [[NSMutableDictionary alloc] initWithContentsOfFile:prefPath];
    
    // Pause if volume is 0 % and changing track
        if ([[preferences objectForKey:@"pauseOnMute"] boolValue] && ![playbackController isPaused] && track != nil && [[AVAudioSession sharedInstance] outputVolume] == 0) {
            HBLogDebug(@"Pausing due to low volume!");
            [playbackController setPaused:YES];
        }
    
    // Save updated track
    [preferences setObject:[NSNumber numberWithBool:[auxActionModel isInCollection]] forKey:isCurrentTrackInCollectionKey];
    [preferences setObject:[NSNumber numberWithBool:!track] forKey:isCurrentTrackNullKey];
    writeToSettings();
}

%end


// Class used to save track to library
%hook SPTNowPlayingAuxiliaryActionsModel

- (id)initWithCollectionPlatform:(id)arg1 adsManager:(id)arg2 trackMetadataQueue:(id)arg3 showsFollowService:(id)arg4 {
    return auxActionModel = %orig;
}

- (void)setInCollection:(BOOL)arg {
    %orig;
    // Update preferences
    [preferences setObject:[NSNumber numberWithBool:arg] forKey:isCurrentTrackInCollectionKey];
    writeToSettings();
}

%end


// Incognito Mode

%hook SPSession

- (id)initWithCore:(id)arg1 coreCreateOptions:(id)arg2 session:(id)arg3 clientVersionString:(id)arg4 acceptLanguages:(id)arg5 {
    return session = %orig;
}

- (void)enableIncognitoMode {
    %orig;
    
    [preferences setObject:[NSNumber numberWithBool:YES] forKey:incognitoKey];
    writeToSettings();
}

- (void)disableIncognitoMode {
    %orig;
    
    [preferences setObject:[NSNumber numberWithBool:NO] forKey:incognitoKey];
    writeToSettings();
}

%end

/* ------- */


%hook SPUser

- (id)initWithUserData:(id)arg {
    SPUser *user = %orig;

    // Removing this key will create instances of `SPPlaylistContainerCallbacksHolder` which enables us to get list of playlists.
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:[NSString stringWithFormat:@"%@.com.spotify.feature.abba.ios_cosmos_image_loader", user.username]];
    return user;
}

%end


%ctor {
    // Init settings file
    preferences = [[NSMutableDictionary alloc] initWithContentsOfFile:prefPath];
    if (!preferences) preferences = [[NSMutableDictionary alloc] init];
        
        
    // Set activeDevice to null
    [preferences setObject:@"" forKey:activeDeviceKey];
    writeToSettings();
    
    
    // Add observers
    // Preferences
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, &updateSettings, CFStringRef(preferencesChangedNotification), NULL, 0);
    
    // Offline:
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, &doEnableOfflineMode, CFStringRef(doEnableOfflineModeNotification), NULL, 0);
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, &doDisableOfflineMode, CFStringRef(doDisableOfflineModeNotification), NULL, 0);
    
    // Shuffle:
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, &doToggleShuffle, CFStringRef(doToggleShuffleNotification), NULL, 0);
    
    // Repeat:
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, &doEnableRepeat, CFStringRef(doEnableRepeatNotification), NULL, 0);
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, &doDisableRepeat, CFStringRef(doDisableRepeatNotification), NULL, 0);
    
    // Connect:
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, &doChangeConnectDevice, CFStringRef(doChangeConnectDeviceNotification), NULL, 0);
    
    // Add to playlist:
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, &addCurrentTrackToPlaylist, CFStringRef(addCurrentTrackToPlaylistNotification), NULL, 0);
    
    // Add to collection:
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, &toggleCurrentTrackInCollection, CFStringRef(toggleCurrentTrackInCollectionNotification), NULL, 0);
    
    // Shuffle:
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, &toggleIncognitoMode, CFStringRef(toggleIncognitoModeNotification), NULL, 0);
}
