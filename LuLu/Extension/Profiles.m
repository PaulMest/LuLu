//
//  Profiles.m
//
//  Created by Patrick Wardle on 06/21/25.
//  Copyright (c) 2025 Objective-See. All rights reserved.
//

#import "Rules.h"
#import "consts.h"
#import "Profiles.h"
#import "Preferences.h"

/* GLOBALS */

//log handle
extern os_log_t logHandle;

//rules
extern Rules* rules;

//preferences
extern Preferences* preferences;

@implementation Profiles

//init
// loads profiles
-(id)init
{
    //super
    self = [super init];
    if(nil != self)
    {
        //set (base) directory
        self.directory = [INSTALL_DIRECTORY stringByAppendingPathComponent:PROFILE_DIRECTORY];
    }
        
    return self;
}

//enumerate
// return list of just profile *names*
-(NSMutableArray*)enumerate
{
    //list
    NSMutableArray* profiles = [NSMutableArray array];
    
    //no profiles?
    // not problem, but just bail here
    if(![NSFileManager.defaultManager fileExistsAtPath:self.directory])
    {
        //dbg msg
        os_log_debug(logHandle, "no profiles? didn't find profiles directory %{public}@", self.directory);
        goto bail;
    }

    //grab all items, saving only names of directories
    for(NSString* name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:self.directory error:nil])
    {
        BOOL isDir = NO;
        NSString* fullPath = [self.directory stringByAppendingPathComponent:name];
        
        //add if directory
        if([NSFileManager.defaultManager fileExistsAtPath:fullPath isDirectory:&isDir] && isDir
           && [NSFileManager.defaultManager fileExistsAtPath:[fullPath stringByAppendingPathComponent:PREFS_FILE]]
           && [NSFileManager.defaultManager fileExistsAtPath:[fullPath stringByAppendingPathComponent:RULES_FILE]])
        {
            //add
            [profiles addObject:name];
        }
    }
    
    //sort for UI
    [profiles sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];

    //dbg msg
    os_log_debug(logHandle, "profiles: %{public}@", profiles);
    
bail:
    
    return profiles;
}

//resolve a (client-supplied) profile name into a path within the profiles directory
// returns nil if the name is invalid, or if the resolved path escapes the profiles directory
-(NSString*)resolve:(NSString*)name
{
    //resolved path
    NSString* resolvedPath = nil;

    //sanitized name
    // just use last path component (e.g. strips any '../')
    NSString* sanitizedName = name.lastPathComponent;

    //sanity check
    if(0 == sanitizedName.length)
    {
        //err msg
        os_log_error(logHandle, "ERROR: profile name '%{public}@' is invalid", name);
        goto bail;
    }

    //init path
    // ...also standardize and resolve any symlinks
    resolvedPath = [[[self.directory stringByAppendingPathComponent:sanitizedName] stringByStandardizingPath] stringByResolvingSymlinksInPath];

    //sanity check
    // must (still) be within the profiles directory
    if(YES != [resolvedPath hasPrefix:[self.directory stringByAppendingString:@"/"]])
    {
        //err msg
        os_log_error(logHandle, "ERROR: resolved path '%{public}@' isn't in the profile directory %{public}@",
                     resolvedPath, self.directory);

        //unset
        resolvedPath = nil;
        goto bail;
    }

bail:

    return resolvedPath;
}

//add new profile
// and then set it to default
-(BOOL)add:(NSString*)name preferences:(NSDictionary*)newPreferences
{
    @synchronized(preferences) {
        NSFileManager* files = NSFileManager.defaultManager;
        NSString* destination = [self resolve:name];
        if(!destination) return NO;
        BOOL isDirectory = NO;
        BOOL exists = [files fileExistsAtPath:destination isDirectory:&isDirectory];
        // Preserve legacy incomplete folders outside the selectable namespace.
        if(exists && (!isDirectory ||
            ([files fileExistsAtPath:[destination stringByAppendingPathComponent:PREFS_FILE]] &&
             [files fileExistsAtPath:[destination stringByAppendingPathComponent:RULES_FILE]]))) return NO;
        NSString* preserved = exists ? [self.directory.stringByDeletingLastPathComponent stringByAppendingPathComponent:
            [@".lulu-incomplete-" stringByAppendingString:NSUUID.UUID.UUIDString]] : nil;
        if(![files createDirectoryAtPath:self.directory withIntermediateDirectories:YES attributes:nil error:nil]) return NO;
        // Stage outside the enumerated profile directory; never expose incomplete profiles.
        NSString* staging = [self.directory.stringByDeletingLastPathComponent stringByAppendingPathComponent:
            [@".lulu-profile-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        if(![files createDirectoryAtPath:staging withIntermediateDirectories:NO attributes:nil error:nil]) return NO;
        BOOL added = NO;
        BOOL moved = NO;
        BOOL preservedOld = NO;
        @try {
            NSMutableDictionary* candidate = [newPreferences mutableCopy];
            if(!candidate[PREF_ALLOW_LOCALHOST]) candidate[PREF_ALLOW_LOCALHOST] = @YES;
            if(![candidate writeToFile:[staging stringByAppendingPathComponent:PREFS_FILE] atomically:YES]) return NO;
            Rules* initialRules = [Rules new];
            if(![initialRules generateDefaultRules] || ![initialRules saveToPath:[staging stringByAppendingPathComponent:RULES_FILE]]) return NO;
            if(preserved) {
                if(![files moveItemAtPath:destination toPath:preserved error:nil]) return NO;
                preservedOld = YES;
            }
            if(![files moveItemAtPath:staging toPath:destination error:nil]) return NO;
            moved = YES;
            if(![preferences loadProfile:destination]) return NO;
            [rules activateRules:initialRules.rules fromPath:[destination stringByAppendingPathComponent:RULES_FILE]];
            added = YES;
            return YES;
        } @finally {
            if(!added && ![files removeItemAtPath:moved ? destination : staging error:nil]) {
                os_log_error(logHandle, "ERROR: failed to clean up incomplete profile");
            }
            if(!added && preservedOld && ![files moveItemAtPath:preserved toPath:destination error:nil]) {
                os_log_error(logHandle, "ERROR: could not restore incomplete profile; preserved at %{public}@", preserved);
            }
        }
    }
}

//set current profile path in *default* prefs
// note: can be called with nil to reset back to default profile
-(BOOL)set:(NSString*)profilePath
{
    @synchronized(preferences) {
        return [preferences setCurrentProfile:profilePath];
    }
}

//delete a profile
// delete folder matching name and reset to default if needed
-(BOOL)delete:(NSString*)name
{
    @synchronized(preferences) {
        NSString* profile = [self resolve:name];
        if(!profile) return NO;
        NSString* current = [preferences getCurrentProfile];
        BOOL active = [profile isEqualToString:current];
        if(active && ![preferences loadProfile:nil]) return NO;
        NSError* error = nil;
        if(![NSFileManager.defaultManager removeItemAtPath:profile error:&error]) {
            os_log_error(logHandle, "ERROR: failed to delete profile: %{public}@", error);
            if(active && ![preferences loadProfile:current]) {
                // Do not pretend rollback succeeded. XPC compares the final selection and notifies.
                os_log_error(logHandle, "ERROR: could not restore profile after failed deletion");
                [rules load];
            }
            return NO;
        }
        if(active) [rules load];
        return YES;
    }
}

@end
