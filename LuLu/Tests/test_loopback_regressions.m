#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <sys/stat.h>
#import "LoopbackPolicy.h"
#import "LoopbackFilterSettings.h"
#import "Preferences.h"
#import "Profiles.h"
#import "Rules.h"
#import "FilterDataProvider.h"
#import "BlockOrAllowList.h"
#define CHECK(c,m) do { if(!(c)) { fprintf(stderr,"FAIL: %s\n",m); exit(1); } } while(0)
static BOOL waitShort(dispatch_semaphore_t s) { return dispatch_semaphore_wait(s,dispatch_time(DISPATCH_TIME_NOW,150*NSEC_PER_MSEC))==0; }
static void waitFor(dispatch_semaphore_t s) { CHECK(dispatch_semaphore_wait(s,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC))==0,"operation timed out"); }
@interface FakeNE:NSObject
@property NSMutableArray *actions,*callbacks;
@property dispatch_semaphore_t applied;
@end
@implementation FakeNE
-(id)init { if((self=[super init])){_actions=[NSMutableArray new];_callbacks=[NSMutableArray new];_applied=dispatch_semaphore_create(0);}return self; }
-(void)apply:(BOOL)b completion:(LuLuPolicyCompletion)c { @synchronized(self){[_actions addObject:@(b)];[_callbacks addObject:[c copy]];}dispatch_semaphore_signal(_applied); }
-(void)complete { LuLuPolicyCompletion c;@synchronized(self){CHECK(_callbacks.count==1,"overlapping applies");c=_callbacks.firstObject;[_callbacks removeObjectAtIndex:0];}c(nil); }
@end
static NSString *defaultFile;
static BOOL rejectSelection;
static int selectionAttempts;
@interface TestPreferences:Preferences @end
@implementation TestPreferences
-(NSString*)defaultPath{return defaultFile;}
-(BOOL)setCurrentProfile:(NSString*)path{selectionAttempts++;return rejectSelection?NO:[super setCurrentProfile:path];}
@end
@interface TestProvider:NSObject
@property LoopbackPolicy* policy;
@end
@implementation TestProvider
-(BOOL)prepareForPreferences:(NSDictionary*)p{return [_policy prepareForBypass:LuLuCanBypassLoopback(p) timeout:.02]==nil;}
-(void)didCommitPreferences:(NSDictionary*)p{[_policy setBypass:LuLuCanBypassLoopback(p) completion:nil];}
@end
os_log_t logHandle;
FilterDataProvider* provider;
Preferences* preferences;
Rules* rules;
BlockOrAllowList *allowList,*blockList;
static NSString*loadedListPath;
@implementation BlockOrAllowList
-(id)init:(NSString*)p{loadedListPath=p;return [super init];} -(BOOL)load:(NSString*)p{loadedListPath=p;return YES;} -(void)clear{}
@end
// Profiles uses real filesystem/preferences and a controlled rules collaborator.
@implementation Rules
-(id)init{if((self=[super init]))_rules=[NSMutableDictionary new];return self;}
-(BOOL)generateDefaultRules{self.rules[@"default"]=@{};return YES;}
-(BOOL)save{return YES;}
-(BOOL)saveToPath:(NSString*)p{return [self.rules writeToFile:p atomically:YES];}
-(BOOL)load{return YES;}
-(void)activateRules:(NSMutableDictionary*)next fromPath:(NSString*)path{self.rules=next;}
@end
static BOOL failRemoval;
static IMP originalRemove;
static BOOL testRemove(id obj,SEL sel,NSString*path,NSError**error){if(failRemoval){if(error)*error=[NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteNoPermissionError userInfo:nil];return NO;}return ((BOOL(*)(id,SEL,NSString*,NSError**))originalRemove)(obj,sel,path,error);}
int main(int argc,char**argv){@autoreleasepool{
 CHECK(argc==2,"missing case");logHandle=os_log_create("test","regressions");NSString*test=@(argv[1]);
 NSString*root=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
 [[NSFileManager defaultManager] createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
 defaultFile=[root stringByAppendingPathComponent:@"preferences.plist"];
 NSDictionary*baseline=@{PREF_ALLOW_LOCALHOST:@YES,PREF_BLOCK_MODE:@NO};[baseline writeToFile:defaultFile atomically:YES];
 preferences=[TestPreferences new];rules=[Rules new];
 FakeNE*ne=[FakeNE new];LoopbackPolicy*policy=[[LoopbackPolicy alloc]initWithApply:^(BOOL b,LuLuPolicyCompletion c){[ne apply:b completion:c];}];
 dispatch_semaphore_t done=dispatch_semaphore_create(0);[policy startWithBypass:YES completion:^(NSError*e){dispatch_semaphore_signal(done);}];waitFor(ne.applied);[ne complete];waitFor(done);
 TestProvider*fake=[TestProvider new];fake.policy=policy;provider=(id)fake;
 if([test isEqual:@"flow-profile-read"]){
  dispatch_semaphore_t held=dispatch_semaphore_create(0),release=dispatch_semaphore_create(0),read=dispatch_semaphore_create(0);
  dispatch_async(dispatch_get_global_queue(0,0),^{@synchronized(preferences){dispatch_semaphore_signal(held);waitFor(release);}});waitFor(held);
  dispatch_async(dispatch_get_global_queue(0,0),^{[preferences getCurrentProfile];dispatch_semaphore_signal(read);});
  BOOL fast=waitShort(read);dispatch_semaphore_signal(release);CHECK(fast,"flow-path profile read blocked behind preference writer");
 }else if([test isEqual:@"timeout-recovery"] || [test isEqual:@"newer-policy"]){
  CHECK([policy prepareForBypass:NO timeout:.02]!=nil,"expected timeout");waitFor(ne.applied);
  if([test isEqual:@"newer-policy"])[policy setBypass:NO completion:^(NSError*e){dispatch_semaphore_signal(done);}];
  [ne complete];
  if([test isEqual:@"timeout-recovery"]){CHECK(waitShort(ne.applied),"late restrictive apply did not recover committed bypass");CHECK([ne.actions.lastObject boolValue],"recovery used wrong policy");[ne complete];}
  else {waitFor(done);CHECK(!waitShort(ne.applied),"late recovery overrode newer restriction");}
 }else if([test isEqual:@"save-recovery"] || [test isEqual:@"load-recovery"]){
  BOOL load=[test isEqual:@"load-recovery"];
  if(load)[@{PREF_BLOCK_MODE:@YES} writeToFile:defaultFile atomically:YES];
  chmod(root.fileSystemRepresentation,0500);
  __block BOOL ok=YES;dispatch_async(dispatch_get_global_queue(0,0),^{ok=load?[preferences load]:[preferences update:@{PREF_BLOCK_MODE:@YES} replace:NO];dispatch_semaphore_signal(done);});
  waitFor(ne.applied);[ne complete];waitFor(done);chmod(root.fileSystemRepresentation,0700);
  CHECK(!ok,"expected failed save");CHECK([preferences.preferences isEqual:baseline],"failed save changed committed preferences");
  CHECK(waitShort(ne.applied),"failed save left loopback optimization inconsistent with committed preferences");CHECK([ne.actions.lastObject boolValue],"failed-save recovery used wrong policy");[ne complete];
 }else{
  provider=nil;Profiles*profiles=[Profiles new];profiles.directory=[root stringByAppendingPathComponent:@"Profiles"];
  [[NSFileManager defaultManager]createDirectoryAtPath:profiles.directory withIntermediateDirectories:YES attributes:nil error:nil];
  NSString*original=[profiles.directory stringByAppendingPathComponent:@"Original"];
  [[NSFileManager defaultManager]createDirectoryAtPath:original withIntermediateDirectories:YES attributes:nil error:nil];
  [baseline writeToFile:[original stringByAppendingPathComponent:PREFS_FILE] atomically:YES];CHECK([preferences setCurrentProfile:original],"selection setup failed");CHECK([preferences load],"profile setup failed");
  if([test isEqual:@"delete-rollback"]){
   Method m=class_getInstanceMethod(NSFileManager.class,@selector(removeItemAtPath:error:));originalRemove=method_setImplementation(m,(IMP)testRemove);failRemoval=YES;
   BOOL ok=[profiles delete:@"Original"];failRemoval=NO;method_setImplementation(m,originalRemove);
   CHECK(!ok,"expected failed deletion");CHECK([[preferences getCurrentProfile]isEqual:original],"failed deletion switched active profile");CHECK([preferences.preferences isEqual:baseline],"failed deletion changed active preferences");
  }else if([test isEqual:@"add-cleanup"] || [test isEqual:@"add-selection-failure"]){
   selectionAttempts=0;rejectSelection=[test isEqual:@"add-selection-failure"];
   NSDictionary*invalid=[test isEqual:@"add-cleanup"]?@{@"invalid":[NSObject new]}:baseline;
   BOOL ok=[profiles add:@"Incomplete" preferences:invalid];rejectSelection=NO;
   if([test isEqual:@"add-selection-failure"])CHECK(selectionAttempts==1,"selection failure did not reach selection step");
   CHECK(!ok,"expected failed creation");CHECK(![[profiles enumerate]containsObject:@"Incomplete"],"failed creation left selectable incomplete profile");
   CHECK([[preferences getCurrentProfile]isEqual:original],"failed creation changed active profile");
  }else if([test isEqual:@"reuse-incomplete"]){
   NSString*partial=[profiles.directory stringByAppendingPathComponent:@"Partial"];
   [[NSFileManager defaultManager]createDirectoryAtPath:partial withIntermediateDirectories:YES attributes:nil error:nil];
   [baseline writeToFile:[partial stringByAppendingPathComponent:PREFS_FILE] atomically:YES];
   [@"preserve me" writeToFile:[partial stringByAppendingPathComponent:@"marker"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
   rejectSelection=YES;
   CHECK(![profiles add:@"Partial" preferences:baseline],"expected rejected replacement selection");
   rejectSelection=NO;
   CHECK([[NSFileManager defaultManager]fileExistsAtPath:[partial stringByAppendingPathComponent:@"marker"]],"failed replacement lost original folder");
   CHECK(![[profiles enumerate]containsObject:@"Partial"],"partial folder unexpectedly listed");
   CHECK([profiles add:@"Partial" preferences:baseline],"hidden incomplete folder blocked name reuse");
   CHECK([[profiles enumerate]containsObject:@"Partial"],"replacement profile missing");
   BOOL preserved=NO;
   for(NSString*name in [[NSFileManager defaultManager]contentsOfDirectoryAtPath:root error:nil]) {
    if([name hasPrefix:@".lulu-incomplete-"])preserved=[[NSFileManager defaultManager]fileExistsAtPath:[[root stringByAppendingPathComponent:name]stringByAppendingPathComponent:@"marker"]];
   }
   CHECK(preserved,"successful replacement discarded original folder");
   CHECK(![profiles add:@"Partial" preferences:baseline],"complete profile overwritten");
  }else if([test isEqual:@"profile-list"]){
   CHECK(([profiles add:@"Listed" preferences:@{PREF_ALLOW_LOCALHOST:@YES,PREF_USE_BLOCK_LIST:@YES,PREF_BLOCK_LIST:@"/tmp/profile-block-list"}]),"list profile creation failed");
   CHECK([loadedListPath isEqual:@"/tmp/profile-block-list"],"profile activation did not load its block list");
  }else if([test isEqual:@"default-selection"]){
   CHECK([preferences loadProfile:nil],"default switch failed");
   CHECK([preferences update:@{@"later":@YES} replace:NO],"later update failed");
   Preferences*restarted=[TestPreferences new];CHECK([restarted getCurrentProfile]==nil,"default preference update resurrected old selected profile");
  }else if([test isEqual:@"add-success"]){
   CHECK([profiles add:@"Complete" preferences:baseline],"creation failed");NSString*p=[profiles resolve:@"Complete"];
   CHECK([[NSFileManager defaultManager]fileExistsAtPath:[p stringByAppendingPathComponent:RULES_FILE]],"profile selected before rules were persisted");
  }else CHECK(NO,"unknown case");
 }
 provider=nil;[[NSFileManager defaultManager]removeItemAtPath:root error:nil];printf("PASS: %s\n",argv[1]);
}return 0;}
