#!/usr/bin/env python3
"""Compile production deleteProfile:reply: against XPC/profile state spies."""
import pathlib, subprocess, tempfile, sys
root=pathlib.Path(__file__).resolve().parents[2]
source=(subprocess.check_output(['git','show','HEAD:LuLu/Extension/XPCDaemon.m'],cwd=root,text=True)
        if '--baseline' in sys.argv else (root/'LuLu/Extension/XPCDaemon.m').read_text())
start=source.index('-(void)deleteProfile:');method=source[start:source.index('@end',start)]
prefix=r'''
#import <Foundation/Foundation.h>
#import <os/log.h>
static os_log_t logHandle;
@interface Prefs:NSObject
@property NSString*current; -(NSString*)getCurrentProfile;
@end
@implementation Prefs
-(NSString*)getCurrentProfile{return _current;}
@end
static Prefs*preferences;
@interface ProfileManager:NSObject
@property BOOL result,change;
-(BOOL)delete:(NSString*)name;
@end
@implementation ProfileManager
-(BOOL)delete:(NSString*)name{if(_change)preferences.current=nil;return _result;}
@end
static ProfileManager*profiles;
@interface Client:NSObject
@property int notifications; -(void)rulesChanged;
@end
@implementation Client
-(void)rulesChanged{_notifications++;}
@end
@interface Alerts:NSObject
@property Client*xpcUserClient;
@end
@implementation Alerts @end
static Alerts*alerts;
@interface Daemon:NSObject
-(void)deleteProfile:(NSString*)name reply:(void(^)(BOOL))reply;
@end
@implementation Daemon
'''
suffix=r'''
@end
int main(){@autoreleasepool{
 logHandle=os_log_create("test","notify");preferences=[Prefs new];profiles=[ProfileManager new];alerts=[Alerts new];alerts.xpcUserClient=[Client new];Daemon*d=[Daemon new];
 // A failed rollback can leave the default policy active: notify even when delete returns NO.
 preferences.current=@"Old";profiles.change=YES;profiles.result=NO;__block BOOL ok=YES;
 [d deleteProfile:@"Old" reply:^(BOOL result){ok=result;}];
 if(ok || alerts.xpcUserClient.notifications!=1){fprintf(stderr,"FAIL: active-policy change on failed deletion was not notified\n");return 1;}
 preferences.current=@"Old";profiles.change=NO;[d deleteProfile:@"Old" reply:^(BOOL result){ok=result;}];
 if(ok || alerts.xpcUserClient.notifications!=1){fprintf(stderr,"FAIL: unchanged failure emitted a notification\n");return 1;}
 profiles.change=YES;profiles.result=YES;[d deleteProfile:@"Old" reply:^(BOOL result){ok=result;}];
 if(!ok || alerts.xpcUserClient.notifications!=2){fprintf(stderr,"FAIL: successful active deletion was not notified\n");return 1;}
 puts("PASS: production XPC deletion notifies every active-profile change");
}return 0;}
'''
with tempfile.TemporaryDirectory(prefix='lulu-notify-test-') as d:
 p=pathlib.Path(d);(p/'test.m').write_text(prefix+method+suffix)
 subprocess.run(['clang','-fobjc-arc','-framework','Foundation',str(p/'test.m'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
