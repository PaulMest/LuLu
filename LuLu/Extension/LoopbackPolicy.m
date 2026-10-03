#import "LoopbackPolicy.h"

@interface LoopbackPolicy ()
@property(nonatomic, strong)dispatch_queue_t queue;
@property(nonatomic, copy)LuLuPolicyApply apply;
@property(nonatomic, strong)NSMutableArray* requests;
@property(nonatomic)BOOL applying;
@property(nonatomic)BOOL active;
@property(nonatomic)BOOL known;
@property(nonatomic)BOOL bypass;
@end

@implementation LoopbackPolicy
-(instancetype)initWithApply:(LuLuPolicyApply)apply
{
    self = [super init];
    if(self) {
        _queue = dispatch_queue_create("com.objective-see.lulu.loopback-policy", DISPATCH_QUEUE_SERIAL);
        _requests = [NSMutableArray array];
        _apply = [apply copy];
    }
    return self;
}

-(void)startWithBypass:(BOOL)bypass completion:(LuLuPolicyCompletion)completion
{
    [self enqueue:bypass start:YES completion:completion];
}

-(void)setBypass:(BOOL)bypass completion:(LuLuPolicyCompletion)completion
{
    [self enqueue:bypass start:NO completion:completion];
}

-(void)enqueue:(BOOL)bypass start:(BOOL)start completion:(LuLuPolicyCompletion)completion
{
    dispatch_async(self.queue, ^{
        LuLuPolicyCompletion reply = completion ?: ^(NSError* error) {};
        [self.requests addObject:@{@"bypass":@(bypass), @"start":@(start), @"reply":[reply copy]}];
        [self drain];
    });
}

-(void)drain
{
    if(self.applying || !self.requests.count) return;
    NSDictionary* request = self.requests.firstObject;
    if([request[@"stop"] boolValue]) {
        self.active = NO;
        self.known = NO;
        [self finish:nil];
        return;
    }
    if([request[@"start"] boolValue]) {
        self.active = YES;
        self.known = NO;
    }
    BOOL bypass = [request[@"bypass"] boolValue];
    if(!self.active || (self.known && bypass == self.bypass)) {
        [self finish:nil];
        return;
    }
    self.applying = YES;
    self.apply(bypass, ^(NSError* error) {
        dispatch_async(self.queue, ^{
            self.applying = NO;
            // A failed apply is never treated as an acknowledgement of policy.
            self.known = (error == nil);
            if(!error) self.bypass = bypass;
            [self finish:error];
        });
    });
}

-(void)finish:(NSError*)error
{
    LuLuPolicyCompletion reply = self.requests.firstObject[@"reply"];
    [self.requests removeObjectAtIndex:0];
    reply(error);
    // Avoid recursive draining when many unchanged preferences are queued.
    dispatch_async(self.queue, ^{ [self drain]; });
}

-(NSError*)prepareForBypass:(BOOL)bypass timeout:(NSTimeInterval)timeout
{
    if(bypass) return nil;
    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
    __block NSError* applyError = nil;
    [self setBypass:NO completion:^(NSError* error) {
        applyError = error;
        dispatch_semaphore_signal(finished);
    }];
    if(dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, timeout * NSEC_PER_SEC))) {
        return [NSError errorWithDomain:@"com.objective-see.lulu.loopback-policy"
                                   code:1 userInfo:@{NSLocalizedDescriptionKey:@"Timed out restoring loopback filtering"}];
    }
    return applyError;
}

-(void)stopWithCompletion:(void (^)(void))completion
{
    // Queue after in-flight work, without applying new settings while NE is stopping.
    dispatch_async(self.queue, ^{
        LuLuPolicyCompletion reply = ^(NSError* error) { if(completion) completion(); };
        [self.requests addObject:@{@"stop":@YES, @"reply":[reply copy]}];
        [self drain];
    });
}
@end
