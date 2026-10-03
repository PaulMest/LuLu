#import <Foundation/Foundation.h>

// Serializes asynchronous NE settings changes, including their completions.
// The apply block is injected so transitions can be tested without a live filter.
typedef void (^LuLuPolicyCompletion)(NSError* error);
typedef void (^LuLuPolicyApply)(BOOL bypass, LuLuPolicyCompletion completion);

@interface LoopbackPolicy : NSObject
-(instancetype)initWithApply:(LuLuPolicyApply)apply;
-(void)startWithBypass:(BOOL)bypass completion:(LuLuPolicyCompletion)completion;
-(void)setBypass:(BOOL)bypass completion:(LuLuPolicyCompletion)completion;
// Synchronous bridge for XPC preference writers only. A timeout never commits policy.
-(NSError*)prepareForBypass:(BOOL)bypass timeout:(NSTimeInterval)timeout;
-(void)stopWithCompletion:(void (^)(void))completion;
@end
