//
//  Preferences.m
//  launchDaemon
//
//  Created by Patrick Wardle on 2/22/18.
//  Copyright (c) 2018 Objective-See. All rights reserved.
//

#import "consts.h"
#import "BlockOrAllowList.h"
#import "Preferences.h"
#import "FilterDataProvider.h"

extern FilterDataProvider* provider;

/* GLOBALS */

//log handle
extern os_log_t logHandle;

//allow list
extern BlockOrAllowList* allowList;

//block list
extern BlockOrAllowList* blockList;

@implementation Preferences

@synthesize preferences;

//init
// loads prefs
-(id)init
{
    //super
    self = [super init];
    if(nil != self)
    {
        //default prefs exist?
        // load them from disk
        if(YES == [NSFileManager.defaultManager fileExistsAtPath:[self defaultPath]])
        {
            //load
            if(YES != [self load])
            {
                //err msg
                os_log_error(logHandle, "ERROR: failed to loads preferences from %@", PREFS_FILE);
                
                //unset
                self = nil;
                
                //bail
                goto bail;
            }
            
        }
        //no prefs (yet)
        // just initialze empty dictionary
        else
        {
            //init
            self.preferences = [NSMutableDictionary dictionary];
        }
    }
    
bail:
    
    return self;
}

//default preference file (also contains the selected profile)
-(NSString*)defaultPath
{
    return [INSTALL_DIRECTORY stringByAppendingPathComponent:PREFS_FILE];
}

//get path to preferences
// either default, or in current profile directory
-(NSString*)path
{
    //current profile
    NSString* currentProfile = nil;
    
    //path
    // init with default
    NSString* path = [self defaultPath];
    
    //not found?
    // that ok, likely just first time
    if(YES != [NSFileManager.defaultManager fileExistsAtPath:path])
    {
        //dbg msg
        os_log_debug(logHandle, "default preferences file '%{public}@' not found ...first time?", path);
        
        //done
        goto bail;
    }
    
    //get current profile
    currentProfile = [self getCurrentProfile];
    if(nil != currentProfile)
    {
        //set
        path = [currentProfile stringByAppendingPathComponent:PREFS_FILE];
    }
    
bail:
    
    //dbg msg
    os_log_debug(logHandle, "using preferences file: %{public}@", path);
    
    return path;
}

//load prefs from disk, including profile switches
-(BOOL)load
{
    @synchronized(self) {
        NSString* prefsFile = [self path];
        NSMutableDictionary* next = [NSMutableDictionary dictionaryWithContentsOfFile:prefsFile];
        if(!next) {
            os_log_error(logHandle, "ERROR: failed to load preferences from %{public}@", prefsFile);
            return NO;
        }
        BOOL addedDefault = (next[PREF_ALLOW_LOCALHOST] == nil);
        if(addedDefault) next[PREF_ALLOW_LOCALHOST] = @YES;
        if(provider && ![provider prepareForPreferences:next]) return NO;
        if(addedDefault && ![next writeToFile:prefsFile atomically:YES]) return NO;
        self.preferences = next;
        if(provider) [provider didCommitPreferences:next];
        return YES;
    }
}

//update prefs
// handles logic for specific prefs & then saves
-(BOOL)update:(NSDictionary*)updates replace:(BOOL)replace
{
    //flag
    BOOL updated = NO;
    NSMutableDictionary* next = nil;
    
    //allow list
    NSString* allowListPath = nil;
    
    //block list
    NSString* blockListPath = nil;
    
    //sync
    @synchronized (self) {

    // Prepare a private candidate; published dictionaries are never mutated.
    next = replace ? [updates mutableCopy] : [self.preferences mutableCopy];
    if(!next) next = [NSMutableDictionary dictionary];
    if(!replace) [next addEntriesFromDictionary:updates];
    if(provider && ![provider prepareForPreferences:next]) goto bail;

    // Persist before publishing. A failed save leaves the old preferences intact.
    if(![next writeToFile:[self path] atomically:YES]) {
        os_log_error(logHandle, "ERROR: failed to save preferences; change rejected");
        goto bail;
    }

    //extract any allow list
    allowListPath = updates[PREF_ALLOW_LIST];
    
    //extract any block list
    blockListPath = updates[PREF_BLOCK_LIST];
    
    //(new) allow list?
    // now, trigger reload
    if(0 != [allowListPath length])
    {
        //dbg msg
        os_log_debug(logHandle, "user specified new 'allow' list: %{public}@", allowListPath);
        
        //first time?
        if(nil == allowList)
        {
            //alloc/init/load block list
            allowList = [[BlockOrAllowList alloc] init:allowListPath];
        }
        //otherwise just reload
        else
        {
            //(re)load
            [allowList load:allowListPath];
        }
    }
    //cleared allow list?
    // key present but empty -> clear stale in-memory entries
    else if(nil != allowListPath)
    {
        //dbg msg
        os_log_debug(logHandle, "user cleared 'allow' list ...clearing");

        //clear (empties items & stops any reload timer)
        [allowList clear];
    }

    //(new) block list?
    // now, trigger reload
    if(0 != [blockListPath length])
    {
        //dbg msg
        os_log_debug(logHandle, "user specified new 'block' list: %{public}@", blockListPath);

        //first time?
        if(nil == blockList)
        {
            //alloc/init/load block list
            blockList = [[BlockOrAllowList alloc] init:blockListPath];
        }
        //otherwise just reload
        else
        {
            //(re)load
            [blockList load:blockListPath];
        }
    }
    //cleared block list?
    // key present but empty -> clear stale in-memory entries
    else if(nil != blockListPath)
    {
        //dbg msg
        os_log_debug(logHandle, "user cleared 'block' list ...clearing");

        //clear (empties items & stops any reload timer)
        [blockList clear];
    }
    
    // Publish only after any lists have been loaded.
    self.preferences = next;
    if(provider) [provider didCommitPreferences:next];
    updated = YES;
        
    } //sync
    
bail:
    return updated;
}

//save to disk
-(BOOL)save
{
    //flag
    BOOL wasSaved = NO;
    
    //dbg msg
    os_log_debug(logHandle, "method '%s' invoked", __PRETTY_FUNCTION__);
    
    //init w/ default
    NSString* prefsFile = [self path];
    
    //write out preferences
    if(YES != [self.preferences writeToFile:prefsFile atomically:YES])
    {
        //err msg
        os_log_error(logHandle, "ERROR: failed to save preferences to: %{public}@", prefsFile);
        goto bail;
    }
    
    //dbg msg
    os_log_debug(logHandle, "saved preferences to %{public}@", prefsFile);
    
    //happy
    wasSaved = YES;
    
bail:
    
    return wasSaved;
}

//get current profile
// this is saved in the default preferences (and may be nil)
-(NSString*)getCurrentProfile
{
    @synchronized(self) {
    //current
    NSString* currentProfile = nil;
    
    //dbg msg
    os_log_debug(logHandle, "method '%s' invoked", __PRETTY_FUNCTION__);
    
    //load *default* prefs
    NSDictionary* defaultPreferences = [NSDictionary dictionaryWithContentsOfFile:[self defaultPath]];
    
    //extract
    currentProfile = defaultPreferences[PREF_CURRENT_PROFILE];
    
    //dbg msg
    os_log_debug(logHandle, "returning current profile %{public}@", currentProfile);
    
    return currentProfile;
    }

}

//set current profile
// this is saved in the *default* preferences (and may be nil)
-(BOOL)setCurrentProfile:(NSString*)profilePath
{
    //default pref's file
    NSString* defaultPreferencesFile = [self defaultPath];
    
    //load *default* prefs
    NSMutableDictionary* defaultPreferences = [NSMutableDictionary dictionaryWithContentsOfFile:defaultPreferencesFile];
    
    if(!defaultPreferences) return NO;

    //set
    defaultPreferences[PREF_CURRENT_PROFILE] = profilePath;
    
    //save
    if(![defaultPreferences writeToFile:defaultPreferencesFile atomically:YES]) return NO;
    
    //dbg msg
    os_log_debug(logHandle, "set current profile to %{public}@", profilePath);
    
    return YES;
}

@end
