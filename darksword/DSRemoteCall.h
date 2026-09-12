// Objective-C++ compatible public surface for the bundled RemoteCall implementation.
// The full header uses @import and also repeats a C symbol from utils.h;
// DarkSpeed only needs this smaller ABI-compatible interface.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@class RemotePointer;

@interface RemoteCall : NSObject
@property(nonatomic, strong) NSString *lastError;
@property(nonatomic) uint64_t trojanMem;
@property(nonatomic) BOOL trojanMemIsStackFallback;
@property(nonatomic) uint64_t trojanMemScratchOffset;
@property(nonatomic) pid_t pid;

+ (NSString *)lastInitError;
- (instancetype)initWithProcess:(NSString *)process useMigFilterBypass:(BOOL)useMigFilterBypass;
- (BOOL)doRemoteCallSyncOnMainThread:(BOOL (^)(void))block;
- (NSUInteger)doRemoteCallStableWithTimeout:(int)timeout functionName:(char *)name functionPointer:(void *)ptr
                            args:(uint64_t *)args argCount:(NSUInteger)argCount;
- (BOOL)remoteRead:(uint64_t)src to:(void *)dst size:(uint64_t)size;
- (BOOL)remote_write:(uint64_t)dst from:(const void *)src size:(uint64_t)size;
- (int)destroyRemoteCall;
- (RemotePointer *)objectAtIndexedSubscript:(uint64_t)address;
@end

#ifdef __cplusplus
extern "C" {
#endif
/// PAC 探测统计。
void rc_take_probe_stats(uint64_t *total, uint64_t *signedOut,
                         uint64_t *timeoutOut, uint64_t *portFailOut);

/// 诊断回调：底层在关键事件（线程创建、探测结果、异常状态）上调用它。
/// 应用侧注册后即可把这些事件写入可离线读取的日志；未注册时开销为一次判空。
typedef void (*rc_diag_log_t)(const char *message);
void rc_set_diag_log(rc_diag_log_t callback);

uint64_t remote_sel(RemoteCall *process, const char *name);
uint64_t remote_getClass(RemoteCall *process, const char *name);
uint64_t remote_msg(RemoteCall *process, uint64_t object, uint64_t selector,
                    uint64_t argument0, uint64_t argument1,
                    uint64_t argument2, uint64_t argument3);
uint64_t remote_NSString(RemoteCall *process, const char *string);
CGRect remote_getCGRect(RemoteCall *process, uint64_t object, uint64_t selector);
void remote_setCGRect(RemoteCall *process, uint64_t object, uint64_t selector, CGRect rect);
#ifdef __cplusplus
}
#endif

#define DSRemoteArbCallWithTimeout(timeout, instance, _pc, ...) [instance doRemoteCallStableWithTimeout:timeout functionName:(char *)#_pc functionPointer:(void *)(_pc) args:(uint64_t[]){__VA_ARGS__} argCount:sizeof((uint64_t[]){__VA_ARGS__})/sizeof(uint64_t)]
#define DSRemoteArbCall(instance, _pc, ...) DSRemoteArbCallWithTimeout(5, instance, _pc, __VA_ARGS__)
