#!/usr/bin/env python3
"""Exercise production add completion and delete handler against UI/XPC spies."""
import ast, pathlib, subprocess, tempfile
root=pathlib.Path(__file__).resolve().parents[2]
s=(root/'LuLu/App/PrefsWindowController.m').read_text()
def body_at(start):
    opening=s.index('{',start); depth=1; end=opening+1
    while depth:
        depth += (s[end]=='{')-(s[end]=='}'); end+=1
    return s[opening:end]
add='-(void)completeAdd:(NSInteger)returnCode '+body_at(s.index('completionHandler:^(NSModalResponse returnCode)',s.index('-(IBAction)addProfile:')))
start=s.index('-(IBAction)deleteProfile:');delete=s[start:s.index("//'check for update'",start)]
base=(root/'LuLu/Tests/test_profile_switch_ui.py').read_text()
# Reuse the same minimal Foundation UI spies; compile actual production bodies.
prefix=next(ast.literal_eval(node.value) for node in ast.parse(base).body if isinstance(node,ast.Assign) and any(isinstance(t,ast.Name) and t.id=='prefix' for t in node.targets))
prefix=prefix.replace('static void showAlert','static NSInteger showAlert').replace(' if(style==NSAlertStyleInformational)', ' if([title isEqual:@"Confirm Deletion"])return 1;\n if(style==NSAlertStyleInformational)').replace('else warnings++;','else warnings++;return 1;')
prefix=prefix.replace(' -(IBAction)switchProfile:(id)sender;', '')
prefix=prefix.replace('#define NSApplication TestApplication','#define NSApplication TestApplication\n#define NSModalResponse NSInteger\n#define NSModalResponseOK 1\n#define NSAlertSecondButtonReturn 2')
prefix=prefix.replace('-(BOOL)setProfile:(NSString*)p;','-(BOOL)setProfile:(NSString*)p;\n-(BOOL)addProfile:(NSString*)p preferences:(NSDictionary*)prefs;\n-(BOOL)deleteProfile:(NSString*)p;').replace('-(BOOL)setProfile:(NSString*)p{return self.accepted;}','-(BOOL)setProfile:(NSString*)p{return self.accepted;}\n-(BOOL)addProfile:(NSString*)p preferences:(NSDictionary*)prefs{return self.accepted;}\n-(BOOL)deleteProfile:(NSString*)p{return self.accepted;}')
prefix=prefix.replace('@interface Controller:NSObject','@interface Sheet:NSObject\n-(void)orderOut:(id)sender;\n@end\n@implementation Sheet\n-(void)orderOut:(id)sender{}\n@end\n@interface Controller:NSObject').replace('@property NSDictionary*preferences;','@property NSDictionary*preferences;\n@property NSString*profileName;\n@property NSDictionary*profilePreferences;\n@property Sheet*addProfileSheet;\n-(void)completeAdd:(NSInteger)code;\n-(IBAction)deleteProfile:(id)sender;')
suffix=r'''
@end
#define CHECK(c,m) if(!(c)){fprintf(stderr,"FAIL: %s\n",m);return 1;}
int main(){@autoreleasepool{
 logHandle=os_log_create("test","ui");xpcDaemonClient=[TestClient new];Controller*c=[Controller new];c.profileName=@"New";c.addProfileSheet=[Sheet new];
 [c completeAdd:NSModalResponseOK];
 CHECK(warnings==1 && successAlerts==0 && profileChanges==0 && preferenceChanges==0,"rejected add reported success");
 warnings=successAlerts=profileChanges=preferenceChanges=0;
 [c deleteProfile:nil];
 CHECK(warnings==1 && profileChanges==1 && preferenceChanges==1,"failed delete did not warn and refresh final state");
 warnings=successAlerts=profileChanges=preferenceChanges=0;xpcDaemonClient.accepted=YES;
 [c completeAdd:NSModalResponseOK];[c deleteProfile:nil];
 CHECK(warnings==0 && successAlerts==1 && profileChanges==2 && preferenceChanges==2,"successful edits lost notifications");
 puts("PASS: production profile add/delete UI handles failure and success");
}return 0;}
'''
with tempfile.TemporaryDirectory(prefix='lulu-edit-ui-') as d:
    p=pathlib.Path(d);(p/'test.m').write_text(prefix+add+delete+suffix)
    subprocess.run(['clang','-fobjc-arc','-framework','Foundation',str(p/'test.m'),'-o',str(p/'test')],check=True)
    subprocess.run([str(p/'test')],check=True)
