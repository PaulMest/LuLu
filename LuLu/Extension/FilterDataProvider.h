//
//  FilterDataProvider.h
//  LuLu
//
//  Created by Patrick Wardle on 8/1/20.
//  Copyright (c) 2020 Objective-See. All rights reserved.
//

#import <bsm/libbsm.h>

@import OSLog;
@import NetworkExtension;

@class Process;
@class LoopbackPolicy;
#import "GrayList.h"

@interface FilterDataProvider : NEFilterDataProvider

/* PROPERTIES */

//(process) cache
@property(atomic, retain)NSCache* cache;

//graylist obj
@property(nonatomic, retain)GrayList* grayList;

//related flows
@property(nonatomic, retain)NSMutableDictionary* relatedFlows;

//timer to reap flows whose process has terminated
@property(nonatomic, strong)dispatch_source_t reapTimer;

//serialized NE loopback policy
@property(nonatomic, strong)LoopbackPolicy* loopbackPolicy;

/* METHODS */

// Called only by synchronous preference writers on XPC threads, never by NE callbacks.
-(BOOL)prepareForPreferences:(NSDictionary*)next;
-(void)didCommitPreferences:(NSDictionary*)committed;

//get best hostname from flow
// prioritizes domain names over IP addresses
-(NSString*)getBestHostnameFromFlow:(NEFilterSocketFlow*)flow;

//resume flows + drop their key(s)
// pass a (process) key to resume just that one; pass nil to resume all keys
-(void)resumeFlowsForKey:(NSString*)key verdict:(NEFilterNewFlowVerdict*)verdict;

//remove a single (specific) flow from a key's queue
-(void)removeRelatedFlow:(NEFilterSocketFlow*)flow forKey:(NSString*)key;

//reap flows whose process has terminated
// invoked periodically (timer) so paused flows of dead processes aren't held forever
-(void)reapDeadFlows;

@end
