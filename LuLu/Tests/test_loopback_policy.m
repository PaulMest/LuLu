#import <Foundation/Foundation.h>
#import "LoopbackPolicy.h"
#import "LoopbackFilterSettings.h"
#import "Preferences.h"
#import "FilterDataProvider.h"
#import "BlockOrAllowList.h"

#define CHECK(condition, message) do { if(!(condition)) { fprintf(stderr, "%s\n", message); exit(1); } } while(0)
static void waitFor(dispatch_semaphore_t s) {
    CHECK(dispatch_semaphore_wait(s, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) == 0, "test timed out");
}
static NSError* failure(void) { return [NSError errorWithDomain:@"test" code:42 userInfo:nil]; }

// Controlled NE apply: completions are released explicitly to verify ordering.
@interface FakeNE : NSObject
@property NSMutableArray* actions;
@property NSMutableArray* callbacks;
@property dispatch_semaphore_t applied;
@end
@implementation FakeNE
-(id)init { self = [super init]; if(self) { _actions=[NSMutableArray array]; _callbacks=[NSMutableArray array]; _applied=dispatch_semaphore_create(0); } return self; }
-(void)apply:(BOOL)bypass completion:(LuLuPolicyCompletion)completion {
    @synchronized(self) { [self.actions addObject:@(bypass)]; [self.callbacks addObject:[completion copy]]; }
    dispatch_semaphore_signal(self.applied);
}
-(void)complete:(NSError*)error {
    LuLuPolicyCompletion c;
    @synchronized(self) { CHECK(self.callbacks.count == 1, "more than one apply in flight"); c=self.callbacks.firstObject; [self.callbacks removeObjectAtIndex:0]; }
    c(error);
}
@end

// Use the actual preference implementation, with an isolated file and fake NE.
static NSString* prefsPath;
@interface TestPreferences : Preferences
@end
@implementation TestPreferences
-(NSString*)path { return prefsPath; }
-(NSString*)defaultPath { return prefsPath; }
@end
@interface TestProvider : NSObject
@property LoopbackPolicy* policy;
-(BOOL)prepareForPreferences:(NSDictionary*)next;
-(void)didCommitPreferences:(NSDictionary*)next;
@end
@implementation TestProvider
-(BOOL)prepareForPreferences:(NSDictionary*)next {
    return [self.policy prepareForBypass:LuLuCanBypassLoopback(next) timeout:1] == nil;
}
-(void)didCommitPreferences:(NSDictionary*)next {
    [self.policy setBypass:LuLuCanBypassLoopback(next) completion:nil];
}
@end
os_log_t logHandle;
FilterDataProvider* provider;
BlockOrAllowList* allowList;
BlockOrAllowList* blockList;
// These unrelated list methods are not exercised by this test.
@implementation BlockOrAllowList
-(id)init:(NSString*)path { return [super init]; }
-(BOOL)load:(NSString*)path { return YES; }
-(void)clear {}
@end

int main(void) {
 @autoreleasepool {
    logHandle = os_log_create("test", "policy");
    // Updates before NE start must not call applySettings. Stop must not issue a new apply.
    FakeNE* lifecycleNE=[FakeNE new];
    LoopbackPolicy* lifecycle=[[LoopbackPolicy alloc] initWithApply:^(BOOL bypass, LuLuPolicyCompletion completion) { [lifecycleNE apply:bypass completion:completion]; }];
    dispatch_semaphore_t lifecycleDone=dispatch_semaphore_create(0);
    [lifecycle setBypass:YES completion:^(NSError* error) { dispatch_semaphore_signal(lifecycleDone); }];
    waitFor(lifecycleDone);
    CHECK(lifecycleNE.actions.count == 0, "applied settings before NE start");
    [lifecycle startWithBypass:YES completion:^(NSError* error) { dispatch_semaphore_signal(lifecycleDone); }];
    waitFor(lifecycleNE.applied);
    [lifecycle stopWithCompletion:^{ dispatch_semaphore_signal(lifecycleDone); }];
    [lifecycleNE complete:nil]; waitFor(lifecycleDone); waitFor(lifecycleDone);
    CHECK(lifecycleNE.actions.count == 1, "stop attempted to apply settings");
    [lifecycle startWithBypass:NO completion:^(NSError* error) { dispatch_semaphore_signal(lifecycleDone); }];
    waitFor(lifecycleNE.applied); [lifecycleNE complete:nil]; waitFor(lifecycleDone);
    CHECK(![lifecycleNE.actions.lastObject boolValue], "restart applied obsolete policy");
    FakeNE* ne = [FakeNE new];
    LoopbackPolicy* policy = [[LoopbackPolicy alloc] initWithApply:^(BOOL bypass, LuLuPolicyCompletion completion) { [ne apply:bypass completion:completion]; }];
    dispatch_semaphore_t done=dispatch_semaphore_create(0);
    [policy startWithBypass:YES completion:^(NSError* error) { CHECK(!error, "startup failed"); dispatch_semaphore_signal(done); }];
    waitFor(ne.applied);
    [policy setBypass:NO completion:^(NSError* error) { CHECK(!error, "restriction failed"); dispatch_semaphore_signal(done); }];
    CHECK(dispatch_semaphore_wait(ne.applied, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_MSEC)) != 0, "overlapping apply");
    [ne complete:nil]; waitFor(done); waitFor(ne.applied);
    CHECK(([ne.actions isEqual:@[@YES,@NO]]), "restrictive apply did not follow startup");
    [ne complete:nil]; waitFor(done);
    [policy setBypass:NO completion:^(NSError* error) { dispatch_semaphore_signal(done); }]; waitFor(done);
    CHECK(ne.actions.count == 2, "unchanged policy was reapplied");
    [policy setBypass:YES completion:^(NSError* error) { CHECK(error.code == 42, "apply failure lost"); dispatch_semaphore_signal(done); }];
    waitFor(ne.applied); [ne complete:failure()]; waitFor(done);
    [policy setBypass:NO completion:^(NSError* error) { dispatch_semaphore_signal(done); }];
    waitFor(ne.applied); [ne complete:nil]; waitFor(done);
    CHECK(ne.actions.count == 4, "failure incorrectly acknowledged desired state");
    // Timeout rejects a restrictive transition; its eventual apply remains conservative.
    [policy setBypass:YES completion:^(NSError* error) { dispatch_semaphore_signal(done); }];
    waitFor(ne.applied); [ne complete:nil]; waitFor(done);
    NSError* timeout = [policy prepareForBypass:NO timeout:.02];
    CHECK(timeout.code == 1, "timeout did not reject transition");
    waitFor(ne.applied); CHECK([ne.actions.lastObject isEqual:@NO], "timeout queued permissive settings");
    [ne complete:nil];
    [policy stopWithCompletion:^{ dispatch_semaphore_signal(done); }]; waitFor(done);
    [policy setBypass:YES completion:^(NSError* error) { dispatch_semaphore_signal(done); }]; waitFor(done);
    NSUInteger count=ne.actions.count;
    [policy startWithBypass:NO completion:^(NSError* error) { dispatch_semaphore_signal(done); }];
    waitFor(ne.applied); CHECK(ne.actions.count==count+1 && ![ne.actions.lastObject boolValue], "restart used stale permissive policy");
    [ne complete:nil]; waitFor(done);

    // Real Preferences: restrictive commits must wait, and failures must roll back.
    NSString* directory=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    CHECK([[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil], "temp directory failed");
    prefsPath=[directory stringByAppendingPathComponent:@"prefs.plist"];
    [@{PREF_ALLOW_LOCALHOST:@YES} writeToFile:prefsPath atomically:YES];
    TestPreferences* prefs=[TestPreferences new];
    CHECK(prefs != nil, "preferences init failed");
    TestProvider* testProvider=[TestProvider new]; testProvider.policy=policy; provider=(id)testProvider;
    CHECK([prefs update:@{PREF_ALLOW_LOCALHOST:@YES} replace:NO], "permissive update failed");
    waitFor(ne.applied); [ne complete:nil];
    dispatch_semaphore_t changed=dispatch_semaphore_create(0);
    __block BOOL updated=NO;
    dispatch_async(dispatch_get_global_queue(0,0), ^{ updated=[prefs update:@{PREF_BLOCK_MODE:@YES} replace:NO]; dispatch_semaphore_signal(changed); });
    waitFor(ne.applied);
    CHECK(![prefs.preferences[PREF_BLOCK_MODE] boolValue], "restrictive prefs published before NE acknowledgement");
    [ne complete:failure()]; waitFor(changed);
    CHECK(!updated && ![prefs.preferences[PREF_BLOCK_MODE] boolValue], "failed apply committed restrictive prefs");
    CHECK(![[NSDictionary dictionaryWithContentsOfFile:prefsPath][PREF_BLOCK_MODE] boolValue], "failed apply saved restrictive prefs");
    dispatch_async(dispatch_get_global_queue(0,0), ^{ updated=[prefs update:@{PREF_BLOCK_MODE:@YES} replace:NO]; dispatch_semaphore_signal(changed); });
    waitFor(ne.applied); [ne complete:nil]; waitFor(changed);
    CHECK(updated && [prefs.preferences[PREF_BLOCK_MODE] boolValue], "successful restriction not committed");
    // Simulate an unwritable destination without chmod/root assumptions.
    NSString* goodPath=prefsPath; prefsPath=[directory stringByAppendingPathComponent:@"missing/prefs.plist"];
    CHECK(![prefs update:@{PREF_BLOCK_MODE:@NO} replace:NO], "save failure unexpectedly succeeded");
    CHECK([prefs.preferences[PREF_BLOCK_MODE] boolValue], "save failure mutated published prefs");
    prefsPath=goodPath;
    CHECK([prefs update:@{PREF_BLOCK_MODE:@NO} replace:NO], "restore permissive policy failed");
    waitFor(ne.applied); [ne complete:nil];
    // Profile reload uses the same restrictive barrier as update.
    [@{PREF_ALLOW_LOCALHOST:@NO, PREF_BLOCK_MODE:@YES} writeToFile:prefsPath atomically:YES];
    dispatch_async(dispatch_get_global_queue(0,0), ^{ updated=[prefs load]; dispatch_semaphore_signal(changed); });
    waitFor(ne.applied);
    CHECK(![prefs.preferences[PREF_BLOCK_MODE] boolValue], "profile published before removing bypass");
    [ne complete:nil]; waitFor(changed);
    CHECK(updated && [prefs.preferences[PREF_BLOCK_MODE] boolValue], "profile reload missed policy transition");
    NSString* selected=@"/tmp/test-profile";
    CHECK([prefs setCurrentProfile:selected], "profile selection save failed");
    CHECK([[prefs getCurrentProfile] isEqualToString:selected], "profile selection not persisted");
    prefsPath=[directory stringByAppendingPathComponent:@"missing/prefs.plist"];
    CHECK(![prefs setCurrentProfile:@"/tmp/another-profile"], "failed profile selection reported success");
    prefsPath=goodPath;
    CHECK([[prefs getCurrentProfile] isEqualToString:selected], "failed profile selection lost old profile");
    // Stress independently enqueued toggles: all applies remain single-flight.
    dispatch_group_t group=dispatch_group_create();
    for(NSUInteger i=0;i<100;i++) {
        dispatch_group_enter(group);
        [policy setBypass:(i%2==0) completion:^(NSError* error) { dispatch_group_leave(group); }];
    }
    for(NSUInteger i=0;i<100;i++) { waitFor(ne.applied); [ne complete:nil]; }
    CHECK(dispatch_group_wait(group,dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC))==0, "queued toggles not completed");
    CHECK(![ne.actions.lastObject boolValue], "final policy was stale");
    dispatch_group_t writers=dispatch_group_create();
    for(NSUInteger i=0;i<40;i++) {
        dispatch_group_async(writers,dispatch_get_global_queue(0,0), ^{
            NSString* key=[NSString stringWithFormat:@"concurrent-%lu",(unsigned long)i];
            CHECK([prefs update:@{key:@(i)} replace:NO], "concurrent preference writer failed");
        });
    }
    CHECK(dispatch_group_wait(writers,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC)) == 0, "concurrent writers timed out");
    for(NSUInteger i=0;i<40;i++) {
        NSString* key=[NSString stringWithFormat:@"concurrent-%lu",(unsigned long)i];
        CHECK([prefs.preferences[key] isEqual:@(i)], "concurrent update was lost");
    }
    NSDictionary* committed=prefs.preferences;
    prefsPath=[directory stringByAppendingPathComponent:@"missing/prefs.plist"];
    CHECK(![prefs load] && [prefs.preferences isEqual:committed], "failed profile read replaced committed preferences");
    prefsPath=goodPath;
    provider=nil;
    printf("Passed policy ordering, failures, timeout, lifecycle, preference save rollback, profile reload, 100 queued transitions, and 40 concurrent preference writers.\n");
 }
 return 0;
}
