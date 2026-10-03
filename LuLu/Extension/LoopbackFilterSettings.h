// Loopback policy shared by the provider and its native tests.
#import <Foundation/Foundation.h>
#import <NetworkExtension/NetworkExtension.h>
#import "consts.h"

static inline BOOL LuLuCanBypassLoopback(NSDictionary* prefs)
{
    return [prefs[PREF_ALLOW_LOCALHOST] boolValue]
        && ![prefs[PREF_BLOCK_MODE] boolValue]
        && ![prefs[PREF_USE_BLOCK_LIST] boolValue];
}

static inline NEFilterSettings* LuLuCreateFilterSettingsForBypass(BOOL bypassLoopback)
{
    NEFilterAction loopbackAction = bypassLoopback ? NEFilterActionAllow : NEFilterActionFilterData;
    NSMutableArray<NEFilterRule*>* filterRules = [NSMutableArray array];
    NSArray<NSString*>* addresses = @[@"127.0.0.0", @"::1"];
    NSArray<NSNumber*>* prefixes = @[@8, @128];
    for(NSUInteger i = 0; i < addresses.count; i++) {
        NENetworkRule* networkRule = [[NENetworkRule alloc]
            initWithRemoteNetwork:[NWHostEndpoint endpointWithHostname:addresses[i] port:@"0"]
            remotePrefix:prefixes[i].unsignedIntegerValue
            localNetwork:nil localPrefix:0
            protocol:NENetworkRuleProtocolAny direction:NETrafficDirectionOutbound];
        // Keep IPv6 inspection as upstream until restrictive IPv6 transitions can be verified.
        NEFilterAction action = (i == 0) ? loopbackAction : NEFilterActionFilterData;
        [filterRules addObject:[[NEFilterRule alloc] initWithNetworkRule:networkRule action:action]];
    }
    NENetworkRule* outboundRule = [[NENetworkRule alloc]
        initWithRemoteNetwork:nil remotePrefix:0 localNetwork:nil localPrefix:0
        protocol:NENetworkRuleProtocolAny direction:NETrafficDirectionOutbound];
    [filterRules addObject:[[NEFilterRule alloc] initWithNetworkRule:outboundRule action:NEFilterActionFilterData]];
    return [[NEFilterSettings alloc] initWithRules:filterRules defaultAction:NEFilterActionAllow];
}

static inline NEFilterSettings* LuLuCreateFilterSettings(NSDictionary* prefs)
{
    return LuLuCreateFilterSettingsForBypass(LuLuCanBypassLoopback(prefs));
}
