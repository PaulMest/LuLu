#!/usr/bin/env python3
"""Compile the production switchProfile: method against headless UI/XPC spies."""
import pathlib, subprocess, tempfile
root = pathlib.Path(__file__).resolve().parents[2]
source = (root / 'LuLu/App/PrefsWindowController.m').read_text()
start = source.index('-(IBAction)switchProfile:')
end = source.index('//add profile button handler', start)
method = source[start:end]
prefix = r'''
#import <Foundation/Foundation.h>
#import <os/log.h>
#define NSAlertStyleInformational 1
#define NSAlertStyleWarning 2
#define NSApplication TestApplication
static int successAlerts, warnings, profileChanges, preferenceChanges, reloads;
static os_log_t logHandle;
static void showAlert(int style, NSString* title, NSString* text, NSArray* buttons) {
 if(style==NSAlertStyleInformational) successAlerts++; else warnings++;
}
@interface AppDelegate:NSObject
-(void)profilesChanged; -(void)preferencesChanged:(NSDictionary*)p;
@end
@implementation AppDelegate
-(void)profilesChanged {profileChanges++;} -(void)preferencesChanged:(NSDictionary*)p {preferenceChanges++;}
@end
@interface TestApplication:NSObject
+(id)sharedApplication; -(id)delegate;
@end
@implementation TestApplication
+(id)sharedApplication {static TestApplication*a; if(!a)a=[self new];return a;}
-(id)delegate {static AppDelegate*d;if(!d)d=[AppDelegate new];return d;}
@end
@interface TestClient:NSObject
@property BOOL accepted;
-(BOOL)setProfile:(NSString*)p;
@end
@implementation TestClient
-(BOOL)setProfile:(NSString*)p{return self.accepted;}
@end
static TestClient*xpcDaemonClient;
@interface Controller:NSObject
@property NSDictionary*preferences;
-(NSString*)profileFromTable:(id)sender; -(void)reload; -(IBAction)switchProfile:(id)sender;
@end
@implementation Controller
-(NSString*)profileFromTable:(id)sender{return @"Restrictive";} -(void)reload{reloads++;}
'''
suffix = r'''
@end
int main(){@autoreleasepool{
 logHandle=os_log_create("test","ui"); xpcDaemonClient=[TestClient new];Controller*c=[Controller new];
 [c switchProfile:nil];
 if(successAlerts || profileChanges || preferenceChanges || warnings!=1 || reloads!=1){fprintf(stderr,"FAIL: rejected profile switch was reported as successful or did not refresh committed state\n");return 1;}
 xpcDaemonClient.accepted=YES;[c switchProfile:nil];
 if(successAlerts!=1 || profileChanges!=1 || preferenceChanges!=1){fprintf(stderr,"FAIL: successful profile switch lost notifications\n");return 1;}
 puts("PASS: production profile-switch UI handles rejection and success");
}return 0;}
'''
with tempfile.TemporaryDirectory(prefix='lulu-ui-test-') as d:
    p=pathlib.Path(d); (p/'test.m').write_text(prefix+method+suffix)
    subprocess.run(['clang','-fobjc-arc','-framework','Foundation',str(p/'test.m'),'-o',str(p/'test')],check=True)
    subprocess.run([str(p/'test')],check=True)
