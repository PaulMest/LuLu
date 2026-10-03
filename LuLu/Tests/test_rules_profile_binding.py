#!/usr/bin/env python3
"""Compile production rule load/save methods and force profile/save interleavings."""
import pathlib, subprocess, tempfile
root=pathlib.Path(__file__).resolve().parents[2]
source=(root/'LuLu/Extension/Rules.m').read_text()
def method(signature):
    start=source.index(signature); opening=source.index('{',start); depth=1; pos=opening+1
    while depth:
        if source[pos]=='{': depth+=1
        elif source[pos]=='}': depth-=1
        pos+=1
    return source[start:pos]+'\n'
methods=''.join(method(s) for s in ['-(id)init','-(NSString*)getPath','-(id)unarchiveRulesData:','-(BOOL)load\n','-(BOOL)save\n','-(BOOL)saveToPath:'])
if '-(void)activateRules:' in source:
    methods+=method('-(void)activateRules:')
else:
    # Before the fix Profiles.add directly assigns the rules dictionary under its lock.
    methods+='-(void)activateRules:(NSMutableDictionary*)next fromPath:(NSString*)path { @synchronized(self) { self.rules=next; } }\n'
prefix=r'''
#import <Foundation/Foundation.h>
#import <os/log.h>
#import "consts.h"
#define Rules BoundRules
static os_log_t logHandle;
@interface Prefs:NSObject
@property NSString*selected; -(NSString*)getCurrentProfile;
@end
@implementation Prefs
-(NSString*)getCurrentProfile{return _selected;}
@end
static Prefs*preferences;
@interface XPCUserClient:NSObject
-(void)rulesChanged;
@end
@implementation XPCUserClient
-(void)rulesChanged{}
@end
@interface Alerts:NSObject
@property XPCUserClient*xpcUserClient;
@end
@implementation Alerts @end
static Alerts*alerts;
@interface Rule:NSObject<NSSecureCoding>
@property NSString *key,*uuid;
@property NSNumber*isDirectory;
@property NSDate*expiration;
-(BOOL)isTemporary;
@end
@implementation Rule
+(BOOL)supportsSecureCoding{return YES;}
-(BOOL)isTemporary{return NO;}
-(void)encodeWithCoder:(NSCoder*)c{[c encodeObject:_key forKey:@"key"];[c encodeObject:_uuid forKey:@"uuid"];}
-(id)initWithCoder:(NSCoder*)c{if((self=[super init])){_key=[c decodeObjectOfClass:NSString.class forKey:@"key"];_uuid=[c decodeObjectOfClass:NSString.class forKey:@"uuid"];}return self;}
@end
@interface BoundRules:NSObject
@property NSMutableDictionary*rules;
@property XPCUserClient*xpcUserClient;
@property NSString*persistencePath;
-(NSString*)getPath; -(id)unarchiveRulesData:(NSData*)data;
-(BOOL)load; -(BOOL)save; -(BOOL)saveToPath:(NSString*)path;
-(BOOL)delete:(NSString*)key rule:(NSString*)uuid;
-(void)activateRules:(NSMutableDictionary*)next fromPath:(NSString*)path;
@end
@implementation BoundRules
@synthesize rules,xpcUserClient;
-(BOOL)delete:(NSString*)key rule:(NSString*)uuid{return YES;}
'''
suffix=r'''
@end
static void check(BOOL ok,const char*m){if(!ok){fprintf(stderr,"FAIL: %s\n",m);exit(1);}}
static NSMutableDictionary*collection(NSString*label){Rule*r=[Rule new];r.key=label;r.uuid=label;return [@{label:@{KEY_RULES:@[r],KEY_PATHS:[NSMutableSet new]}} mutableCopy];}
static dispatch_semaphore_t entered,released;
static BOOL gate;
@interface GatedRules:BoundRules @end
@implementation GatedRules
-(BOOL)saveToPath:(NSString*)p{if(gate){dispatch_semaphore_signal(entered);check(dispatch_semaphore_wait(released,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC))==0,"release timed out");}return [super saveToPath:p];}
@end
int main(int argc,char**argv){@autoreleasepool{
 logHandle=os_log_create("test","rule-binding");preferences=[Prefs new];alerts=[Alerts new];alerts.xpcUserClient=[XPCUserClient new];
 NSString*root=[NSTemporaryDirectory()stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
 NSString*a=[root stringByAppendingPathComponent:@"A"],*b=[root stringByAppendingPathComponent:@"B"];
 NSFileManager*f=NSFileManager.defaultManager;[f createDirectoryAtPath:a withIntermediateDirectories:YES attributes:nil error:nil];[f createDirectoryAtPath:b withIntermediateDirectories:YES attributes:nil error:nil];
 NSString*pa=[a stringByAppendingPathComponent:RULES_FILE],*pb=[b stringByAppendingPathComponent:RULES_FILE];
 preferences.selected=a;GatedRules*r=[GatedRules new];r.rules=collection(@"A");check([r save],"initial save failed");
 BoundRules*staged=[BoundRules new];staged.rules=collection(@"B");check([staged saveToPath:pb],"staging save failed");
 NSData*originalA=[NSData dataWithContentsOfFile:pa],*originalB=[NSData dataWithContentsOfFile:pb];
 NSString*test=@(argv[1]);
 if([test isEqual:@"selection-gap"]){
  // Exactly the interval between Preferences.loadProfile and Rules.load/activation.
  preferences.selected=b;check([r save],"flow save failed");
  check([[NSData dataWithContentsOfFile:pb]isEqual:originalB],"A's rules overwrote B after cached selection changed");
  check([r load],"B load failed");check(r.rules[@"B"]!=nil && r.rules[@"A"]==nil,"B loaded the wrong rules");
 }else if([test isEqual:@"save-overlap"]){
  entered=dispatch_semaphore_create(0);released=dispatch_semaphore_create(0);dispatch_semaphore_t saved=dispatch_semaphore_create(0),activated=dispatch_semaphore_create(0);gate=YES;
  dispatch_async(dispatch_get_global_queue(0,0),^{check([r save],"gated save failed");dispatch_semaphore_signal(saved);});
  check(dispatch_semaphore_wait(entered,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC))==0,"save never entered");
  preferences.selected=b;
  dispatch_async(dispatch_get_global_queue(0,0),^{[r activateRules:collection(@"B") fromPath:pb];dispatch_semaphore_signal(activated);});
  BOOL alreadyActivated=dispatch_semaphore_wait(activated,dispatch_time(DISPATCH_TIME_NOW,100*NSEC_PER_MSEC))==0;
  dispatch_semaphore_signal(released);check(dispatch_semaphore_wait(saved,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC))==0,"save did not finish");
  if(!alreadyActivated)check(dispatch_semaphore_wait(activated,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC))==0,"activation did not finish");gate=NO;
  check([[NSData dataWithContentsOfFile:pa]isEqual:originalA],"save captured A's path but serialized B's collection");
  check([r save],"B save failed");check([[NSData dataWithContentsOfFile:pb]isEqual:originalB],"active B did not save to B");
 }else if([test isEqual:@"failed-load"]){
  preferences.selected=b;[@"bad archive" writeToFile:pb atomically:YES encoding:NSUTF8StringEncoding error:nil];check(![r load],"corrupt B archive accepted");
  check(r.rules[@"A"]!=nil,"failed load discarded active A rules");check([r save],"save after failed load failed");check([[NSData dataWithContentsOfFile:pa]isEqual:originalA],"failed load changed A binding");
 }else check(NO,"unknown case");
 [f removeItemAtPath:root error:nil];printf("PASS: %s\n",argv[1]);
}return 0;}
'''
with tempfile.TemporaryDirectory(prefix='lulu-rules-test-') as d:
    p=pathlib.Path(d);(p/'test.m').write_text(prefix+methods+suffix)
    subprocess.run(['clang','-fobjc-arc','-framework','Foundation','-I',str(root/'LuLu/Shared'),str(p/'test.m'),'-o',str(p/'test')],check=True)
    failed=False
    for case in ['selection-gap','save-overlap','failed-load']:
        failed |= subprocess.run([str(p/'test'),case]).returncode!=0
    raise SystemExit(1 if failed else 0)
