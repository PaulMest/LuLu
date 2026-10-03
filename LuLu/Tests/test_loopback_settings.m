#import <Foundation/Foundation.h>
#import "LoopbackFilterSettings.h"
#define CHECK(condition, message) do { if(!(condition)) { fprintf(stderr, "%s\n", message); return 1; } } while(0)
int main(void) {
    @autoreleasepool {
        NSUInteger checks = 0;
        for(NSUInteger flags = 0; flags < 8; flags++) {
            NSDictionary* prefs = @{PREF_ALLOW_LOCALHOST:@((flags & 1) != 0),
                                    PREF_BLOCK_MODE:@((flags & 2) != 0),
                                    PREF_USE_BLOCK_LIST:@((flags & 4) != 0)};
            NEFilterSettings* settings = LuLuCreateFilterSettings(prefs);
            NEFilterAction expected = flags == 1 ? NEFilterActionAllow : NEFilterActionFilterData;
            CHECK(settings.rules.count == 3, "missing network rule");
            CHECK(settings.rules[0].action == expected, "IPv4 policy precedence failed");
            CHECK(settings.rules[1].action == NEFilterActionFilterData, "IPv6 inspection must remain enabled");
            CHECK(settings.rules[2].action == NEFilterActionFilterData, "external traffic must stay filtered");
            CHECK(settings.defaultAction == NEFilterActionAllow, "inbound policy changed");
            CHECK(settings.rules[0].networkRule.matchRemotePrefix == 8, "IPv4 loopback range changed");
            CHECK(settings.rules[1].networkRule.matchRemotePrefix == 128, "IPv6 loopback range changed");
            CHECK([settings.rules[0].networkRule.matchRemoteEndpoint.hostname isEqualToString:@"127.0.0.0"], "wrong IPv4 endpoint");
            CHECK([settings.rules[1].networkRule.matchRemoteEndpoint.hostname isEqualToString:@"::1"], "wrong IPv6 endpoint");
            for(NEFilterRule* rule in settings.rules) {
                CHECK(rule.networkRule.matchDirection == NETrafficDirectionOutbound, "inbound rule unexpectedly added");
                CHECK(rule.networkRule.matchProtocol == NENetworkRuleProtocolAny, "protocol coverage changed");
                checks += 2;
            }
            checks += 9;
        }
        NEFilterSettings* conservative = LuLuCreateFilterSettings(@{});
        CHECK(conservative.rules[0].action == NEFilterActionFilterData, "missing preferences must be conservative");
        printf("Passed %lu native network-settings assertions.\n", (unsigned long)(checks + 1));
    }
    return 0;
}
