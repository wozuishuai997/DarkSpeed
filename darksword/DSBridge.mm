//
//  DSBridge.mm
//  DarkSpeed
//

#import "DSBridge.h"
#import "HUDHelper.h"
#import "HUDPresetPosition.h"
#import "SpringBoardServices.h"

#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <notify.h>
#import <os/lock.h>
#import <os/log.h>

#include <atomic>
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern "C" CFIndex CARenderServerGetDirtyFrameCount(void *);

NSString * const DSBridgeProgressNotification = @"com.huami.darkspeed.dsbridge.progress";

static os_unfair_lock g_errorLock = OS_UNFAIR_LOCK_INIT;
static NSString *g_dsLastError = @"";
static NSString *g_dsStage = @"Waiting to start";
#if USE_DARKSWORD
static std::atomic_bool g_dsReady(false);
static std::atomic_bool g_dsRunning(false);
static std::atomic_bool g_hudRequested(false);
static std::atomic_bool g_hudActive(false);
static std::atomic<double> g_dsProgress(0.0);
#endif

static NSString *ds_localized(NSString *key) {
    return [NSBundle.mainBundle localizedStringForKey:key value:key table:nil];
}

static void ds_post_progress(void) {
    notify_post("com.huami.darkspeed.dsbridge.progress");
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:DSBridgeProgressNotification object:nil];
    });
}

// 日志目录固定在 Documents 下：Info.plist 已开启 UIFileSharingEnabled，
// 因此可通过「文件」App / Finder / iMazing 直接取出，无需越狱工具。
// 路径与目录创建只做一次并缓存，避免在循环里重复系统调用。
static NSString *ds_log_directory(void) {
    static NSString *cached = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(
            NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *docs = paths.firstObject;
        if (!docs.length) return;
        NSString *dir = [docs stringByAppendingPathComponent:@"DarkSpeedLogs"];
        [NSFileManager.defaultManager createDirectoryAtPath:dir
                                withIntermediateDirectories:YES
                                                 attributes:nil
                                                      error:nil];
        cached = dir;
    });
    return cached;
}

// 单文件上限 2MB，超出后轮转为 .1，保留最近一段而不是最早的。
static const unsigned long long kDSLogFileLimit = 2ULL * 1024 * 1024;

static void ds_rotate_log_if_needed(NSString *path, unsigned long long incoming) {
    if (!path.length) return;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSDictionary *attributes = [fm attributesOfItemAtPath:path error:nil];
    unsigned long long size = [attributes[NSFileSize] unsignedLongLongValue];
    if (size + incoming <= kDSLogFileLimit) return;
    NSString *previous = [path stringByAppendingPathExtension:@"1"];
    [fm removeItemAtPath:previous error:nil];
    [fm moveItemAtPath:path toPath:previous error:nil];
}

static NSString *ds_checkpoint_log_path(void) {
    NSString *dir = ds_log_directory();
    return dir.length ? [dir stringByAppendingPathComponent:@"DSBridge.log"] : nil;
}

static void ds_append_checkpoint(NSString *message) {
    NSString *path = ds_checkpoint_log_path();
    if (!path.length || !message.length) return;
    NSString *line = [NSString stringWithFormat:@"%@  %@\n", NSDate.date, message];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return;
    ds_rotate_log_if_needed(path, data.length);
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:path]) {
        [data writeToFile:path options:NSDataWritingAtomic error:nil];
        return;
    }
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!handle) return;
    @try {
        [handle seekToEndOfFile];
        [handle writeData:data];
        [handle synchronizeFile];
    } @catch (__unused NSException *exception) {
    }
    [handle closeFile];
}

#if USE_DARKSWORD
static void ds_set_stage(NSString *stage) {
    NSString *next = [stage copy] ?: @"";
    os_unfair_lock_lock(&g_errorLock);
    g_dsStage = next;
    os_unfair_lock_unlock(&g_errorLock);
    os_log(OS_LOG_DEFAULT, "[DSBridge] stage: %{public}@", next);
    ds_append_checkpoint(next);
    ds_post_progress();
}
#endif

static void ds_set_error(NSString *message) {
    NSString *next = [message copy] ?: @"";
    os_unfair_lock_lock(&g_errorLock);
    g_dsLastError = next;
    os_unfair_lock_unlock(&g_errorLock);
    if (next.length > 0) {
        os_log_error(OS_LOG_DEFAULT, "[DSBridge] %{public}@", next);
        ds_append_checkpoint([ds_localized(@"Error: ") stringByAppendingString:next]);
        notify_post(NOTIFY_RELOAD_APP);
    }
    ds_post_progress();
}

#if USE_DARKSWORD

#import "DSRemoteCall.h"

// These vendored headers are plain C/Objective-C. Keep C linkage from this .mm.
extern "C" {
#import "darksword.h"
#import "offsets.h"
#import "utils.h"
}

static void ds_rotate_log_if_needed(NSString *path, unsigned long long incoming);
static NSString *ds_log_directory(void);
static void ds_append_checkpoint(NSString *message);
// ---------------------------------------------------------------------------
// 运行时诊断日志
//
// 设计约束（来自 1.0-19 的失败）：绝不在远程调用热路径上做文件 IO。
//   * 底层事件只入内存环形缓冲，热路径开销是一次加锁 + 一次 strlcpy；
//   * 只有定时器（30 秒）或 HUD 状态变化时才真正写盘；
//   * 不使用 freopen/setvbuf，不接管 stdout。
// 开关为设置里的「详细日志」，默认关闭。
// ---------------------------------------------------------------------------
#define DS_DIAG_RING_LINES 64
#define DS_DIAG_LINE_MAX 192

static char g_diagRing[DS_DIAG_RING_LINES][DS_DIAG_LINE_MAX];
static int g_diagRingHead = 0;      // 下一个写入位置
static int g_diagRingCount = 0;     // 已填充条数
static os_unfair_lock g_diagLock = OS_UNFAIR_LOCK_INIT;
static dispatch_source_t g_diagTimer = nil;
static uint64_t g_diagEvents = 0;   // 本次会话累计事件数
static CFAbsoluteTime g_diagStart = 0;
static std::atomic_bool g_diagEnabled(false);

static NSString *ds_diag_log_path(void) {
    NSString *dir = ds_log_directory();
    return dir.length ? [dir stringByAppendingPathComponent:@"Runtime.log"] : nil;
}

// 底层线程回调入口：只入内存，不做任何 IO。
static void ds_diag_record(const char *message) {
    if (!message || !message[0]) return;
    os_unfair_lock_lock(&g_diagLock);
    snprintf(g_diagRing[g_diagRingHead], DS_DIAG_LINE_MAX, "%s", message);
    g_diagRingHead = (g_diagRingHead + 1) % DS_DIAG_RING_LINES;
    if (g_diagRingCount < DS_DIAG_RING_LINES) g_diagRingCount++;
    g_diagEvents++;
    os_unfair_lock_unlock(&g_diagLock);
}

static void ds_diag_flush(void);

static void ds_diag_configure(BOOL enabled) {
    g_diagEnabled.store(enabled);
    if (enabled && g_diagStart <= 0) g_diagStart = CFAbsoluteTimeGetCurrent();
    if (enabled) {
        // 底层回调只需注册一次。
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{ rc_set_diag_log(ds_diag_record); });
        if (!g_diagTimer) {
            g_diagTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                 dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
            dispatch_source_set_timer(g_diagTimer,
                                      dispatch_time(DISPATCH_TIME_NOW, 30ull * NSEC_PER_SEC),
                                      30ull * NSEC_PER_SEC,
                                      5ull * NSEC_PER_SEC);
            dispatch_source_set_event_handler(g_diagTimer, ^{
                @autoreleasepool { ds_diag_flush(); }
            });
            dispatch_resume(g_diagTimer);
        }
        ds_append_checkpoint(@"detailed logging enabled");
        ds_diag_flush();
    } else {
        if (g_diagTimer) {
            dispatch_source_cancel(g_diagTimer);
            g_diagTimer = nil;
        }
        ds_append_checkpoint(@"detailed logging disabled");
    }
}


static const NSInteger kDSSpringBoardHUDTag = 0x54534844; // "TSHD"
static const CGFloat kDSHUDMinFontSize = 9.0;
static const CGFloat kDSHUDMaxFontSize = 10.0;
static const CGFloat kDSHUDMinCornerRadius = 4.5;
static const CGFloat kDSHUDMaxCornerRadius = 5.0;
static const CGFloat kDSHUDInactiveOpacity = 0.667;
static const NSTimeInterval kDSHUDFocusDuration = 3.0;
static const double kDSHUDWindowLevel = 10000010.0;
static const CACornerMask kDSCornerMaskBottom =
    kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;
static const CACornerMask kDSCornerMaskAll =
    kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner |
    kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;

static RemoteCall *g_springBoard = nil;
static uint64_t g_remoteContainer = 0;
static uint64_t g_remoteBlurView = 0;
static uint64_t g_remoteBlurEffect = 0;
static uint64_t g_remoteLabel = 0;
static uint64_t g_remoteTextAttributes = 0;
static uint64_t g_remoteSecureField = 0;
static uint64_t g_remoteSecureCanvas = 0;
static uint64_t g_remoteWindow = 0;

static NSString *ds_diag_snapshot(void) {
    NSMutableString *out = [NSMutableString string];
    UIDevice *device = UIDevice.currentDevice;
    [out appendFormat:@"== %@  uptime=%.0fs events=%llu\n",
         NSDate.date,
         CFAbsoluteTimeGetCurrent() - g_diagStart,
         g_diagEvents];
    [out appendFormat:@"hudActive=%d requested=%d label=%d window=%d container=%d\n",
         g_hudActive.load() ? 1 : 0,
         g_hudRequested.load() ? 1 : 0,
         g_remoteLabel ? 1 : 0,
         g_remoteWindow ? 1 : 0,
         g_remoteContainer ? 1 : 0];
    if (g_springBoard) {
        [out appendFormat:@"remote pid=%d trojanMem=0x%llx lastError=%@\n",
             g_springBoard.pid,
             g_springBoard.trojanMem,
             g_springBoard.lastError.length ? g_springBoard.lastError : @"(none)"];
    }
    [out appendFormat:@"os=%@ %@\n", device.systemName ?: @"?", device.systemVersion ?: @"?"];

    // PAC 探测统计：探测是否仍在按预期频率发生、端口是否安装失败、是否出现超时。
    // 这些数字是判断"线程异常端口为何失效"的直接依据。
    uint64_t probeTotal = 0, probeSigned = 0, probeTimeout = 0, probePortFail = 0;
    rc_take_probe_stats(&probeTotal, &probeSigned, &probeTimeout, &probePortFail);
    [out appendFormat:@"probes total=%llu signed=%llu timeout=%llu portFail=%llu\n",
         probeTotal, probeSigned, probeTimeout, probePortFail];

    os_unfair_lock_lock(&g_diagLock);
    int count = g_diagRingCount;
    int start = (g_diagRingHead - count + DS_DIAG_RING_LINES) % DS_DIAG_RING_LINES;
    NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithCapacity:(NSUInteger)count];
    for (int i = 0; i < count; i++) {
        const char *line = g_diagRing[(start + i) % DS_DIAG_RING_LINES];
        if (line[0]) [lines addObject:[NSString stringWithUTF8String:line] ?: @"?"];
    }
    g_diagRingCount = 0; // 已消费，避免重复落盘
    os_unfair_lock_unlock(&g_diagLock);

    for (NSString *line in lines) [out appendFormat:@"  %@\n", line];
    return out;
}

static void ds_diag_flush(void) {
    if (!g_diagEnabled.load()) return;
    NSString *path = ds_diag_log_path();
    if (!path.length) return;
    NSString *text = ds_diag_snapshot();
    if (!text.length) return;
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (!data.length) return;
    ds_rotate_log_if_needed(path, data.length);
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!handle) {
        [data writeToFile:path options:NSDataWritingAtomic error:nil];
        return;
    }
    @try {
        [handle seekToEndOfFile];
        [handle writeData:data];
        [handle synchronizeFile];
    } @catch (__unused NSException *exception) {
    }
    [handle closeFile];
}

static uint64_t g_remoteWindowScene = 0;
static uint64_t g_remoteOrientationObserver = 0;
static pid_t g_remoteWindowPid = 0;
static dispatch_source_t g_rateTimer = nil;
static AVAudioPlayer *g_keepAlivePlayer = nil;
static uint64_t g_previousInput = 0;
static uint64_t g_previousOutput = 0;
static CFAbsoluteTime g_previousSampleTime = 0;
static CFAbsoluteTime g_focusUntil = 0;
static CFIndex g_previousDirtyFrameCount = 0;
static BOOL g_needsFPSBaselineReset = YES;
static CFTimeInterval g_previousFPSSampleTime = 0;
static std::atomic<int> g_remoteOrientation(UIInterfaceOrientationUnknown);
static int g_reloadHUDToken = -1;
static int g_lockStateToken = -1;
static NSDictionary *g_lastPresentationPreferences = nil;
static UIInterfaceOrientation g_lastPresentationOrientation = UIInterfaceOrientationUnknown;
static CGRect g_lastWindowFrame = CGRectNull;
static CGRect g_lastLabelFrame = CGRectNull;
static BOOL g_lastWindowHidden = NO;
static CGFloat g_lastContainerAlpha = -1.0;
static CGFloat g_lastFontSize = -1.0;
static BOOL g_lastInverted = NO;
static BOOL g_lastBold = NO;
static BOOL g_lastHideAtSnapshot = NO;
static NSMutableDictionary<NSString *, NSNumber *> *g_remoteSelectorCache = nil;
static NSMutableDictionary<NSString *, NSNumber *> *g_remoteClassCache = nil;
static std::atomic<int> g_kernelPrefetchState(0); // 0 idle, 1 running, 2 ready, 3 failed
static dispatch_group_t g_kernelPrefetchGroup = nil;
static std::atomic<int> g_networkWarmupState(0); // 0 idle, 1 waiting, 2 ready, 3 timed out
static dispatch_group_t g_networkWarmupGroup = nil;
static const NSTimeInterval kDSNetworkWarmupTimeout = 180.0;
static const NSTimeInterval kDSNetworkRetryDelay = 3.0;

static const uint64_t kDSRemoteTextScratchOffset = 0x1000;
static const size_t kDSRemoteTextScratchCapacity = 0x800;

static void ds_update_rate(void);
static void ds_stop_rate_timer(void);
static void ds_teardown_failed_hud(NSString *reason);
static void ds_stop_keepalive(void);

typedef struct {
    BOOL landscape;
    BOOL centered;
    BOOL centeredMost;
    BOOL singleLine;
    BOOL bitrate;
    BOOL arrowPrefixes;
    BOOL inverted;
    BOOL bold;
    BOOL transparentBackground;
    BOOL followsRotation;
    BOOL hideAtSnapshot;
    BOOL displayFPS;
    BOOL passthrough;
    CGFloat fontSize;
    CGFloat cornerRadius;
    CGFloat inactiveOpacity;
    NSInteger numberOfLines;
    NSTextAlignment alignment;
    CACornerMask maskedCorners;
    CGRect windowFrame;
    CGRect blurFrame;
    CGRect labelFrame;
} DSHUDPresentation;

static dispatch_queue_t ds_bridge_queue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.huami.darkspeed.darksword", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static void ds_bridge_log(const char *message) {
    if (message && message[0]) {
        os_log(OS_LOG_DEFAULT, "[DSBridge] %{public}s", message);
    }
}

// Feed the native progress callback into the controller UI so startup shows
// measured progress instead of an indeterminate spinner.
static void ds_bridge_progress(double progress) {
    g_dsProgress.store(progress);
    ds_post_progress();
}

static uint64_t ds_env_u64(const char *name) {
    const char *value = getenv(name);
    return value && value[0] ? strtoull(value, NULL, 0) : 0;
}

static int ds_env_int(const char *name, int fallback) {
    const char *value = getenv(name);
    return value && value[0] ? (int)strtol(value, NULL, 0) : fallback;
}

static BOOL ds_has_symbol_offsets(void) {
    return kernel_symbol_offsets_are_current();
}

static dispatch_group_t ds_kernel_prefetch_group(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        g_kernelPrefetchGroup = dispatch_group_create();
    });
    return g_kernelPrefetchGroup;
}

static dispatch_group_t ds_network_warmup_group(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        g_networkWarmupGroup = dispatch_group_create();
    });
    return g_networkWarmupGroup;
}

static BOOL ds_mark_network_warmup_ready(void) {
    int expected = 1;
    if (!g_networkWarmupState.compare_exchange_strong(expected, 2)) return NO;
    dispatch_group_leave(ds_network_warmup_group());
    return YES;
}

static void ds_start_kernel_prefetch(BOOL retryFailed) {
    BOOL hasBuiltinOffsets = install_builtin_kernel_symbol_offsets();
    if (hasBuiltinOffsets || ds_has_symbol_offsets()) {
        g_kernelPrefetchState.store(2);
        ds_set_stage(ds_localized(@"System data is ready"));
        return;
    }

    int state = g_kernelPrefetchState.load();
    while (state != 1 && state != 2) {
        if (state == 3 && !retryFailed) return;
        if (g_kernelPrefetchState.compare_exchange_weak(state, 1)) break;
    }
    if (state == 1 || state == 2) return;

    ds_set_error(@"");
    ds_set_stage(ds_localized(@"Caching kernelcache"));
    dispatch_group_t group = ds_kernel_prefetch_group();
    dispatch_group_enter(group);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL ready = dlkcache();
        g_kernelPrefetchState.store(ready ? 2 : 3);
        if (ready) {
            os_log(OS_LOG_DEFAULT, "[DSBridge] kernelcache prefetch ready");
            ds_mark_network_warmup_ready();
            ds_set_error(@"");
            ds_set_stage(ds_localized(@"Kernelcache cached"));
        } else {
            os_log_error(OS_LOG_DEFAULT, "[DSBridge] kernelcache prefetch failed");
            if (g_networkWarmupState.load() == 1) {
                ds_set_stage(ds_localized(@"Requesting network access"));
            } else {
                ds_set_stage(ds_localized(@"Kernelcache cache failed"));
            }
        }
        dispatch_group_leave(group);
    });
}

static BOOL ds_wait_for_kernel_attempt(CFAbsoluteTime deadline) {
    if (ds_has_symbol_offsets()) return YES;
    if (g_kernelPrefetchState.load() != 1) return NO;

    NSTimeInterval remaining = MAX(0.0, deadline - CFAbsoluteTimeGetCurrent());
    if (remaining <= 0.0) return NO;
    long waitResult = dispatch_group_wait(
        ds_kernel_prefetch_group(),
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(remaining * NSEC_PER_SEC)));
    if (waitResult != 0) {
        os_log_error(OS_LOG_DEFAULT, "[DSBridge] kernelcache prefetch timed out");
        return NO;
    }
    return ds_has_symbol_offsets();
}

static BOOL ds_wait_for_kernel_prefetch(NSTimeInterval timeout, BOOL retryFailed) {
    BOOL hasBuiltinOffsets = install_builtin_kernel_symbol_offsets();
    if (hasBuiltinOffsets || ds_has_symbol_offsets()) {
        g_kernelPrefetchState.store(2);
        return YES;
    }

    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + timeout;
    DSBridgeWarmUpNetworkAndPrefetchKernelCache();
    ds_start_kernel_prefetch(retryFailed);
    if (ds_wait_for_kernel_attempt(deadline)) return YES;

    // Some regions show a first-network-access prompt while others do not.
    // Only wait for that optional path after a real kernelcache request has
    // failed; a successful real request is authoritative on every device.
    if (g_networkWarmupState.load() == 1) {
        NSTimeInterval remaining = MAX(0.0, deadline - CFAbsoluteTimeGetCurrent());
        if (remaining <= 0.0) return NO;
        long networkWaitResult = dispatch_group_wait(
            ds_network_warmup_group(),
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(remaining * NSEC_PER_SEC)));
        if (networkWaitResult != 0) {
            os_log_error(OS_LOG_DEFAULT,
                         "[DSBridge] network warm-up timed out while enabling HUD");
            return NO;
        }
    }
    if (ds_has_symbol_offsets()) return YES;
    if (g_networkWarmupState.load() != 2) return NO;

    ds_start_kernel_prefetch(retryFailed);
    return ds_wait_for_kernel_attempt(deadline);
}

static void ds_probe_network_until_ready(CFAbsoluteTime startedAt, NSUInteger attempt) {
    if (g_networkWarmupState.load() != 1) return;

    NSTimeInterval elapsed = MAX(0.0, CFAbsoluteTimeGetCurrent() - startedAt);
    ds_set_stage([NSString stringWithFormat:ds_localized(@"Waiting for network (%.0f seconds, attempt %lu)"),
                  elapsed, (unsigned long)attempt]);

    NSMutableURLRequest *request = [NSMutableURLRequest
        requestWithURL:[NSURL URLWithString:@"https://api.appledb.dev/ios/main.json.xz"]
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
        timeoutInterval:8.0];
    request.HTTPMethod = @"HEAD";
    [[[NSURLSession sharedSession] dataTaskWithRequest:request
        completionHandler:^(__unused NSData *data, NSURLResponse *response, NSError *error) {
            NSHTTPURLResponse *httpResponse =
                [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
            BOOL httpOK = !httpResponse ||
                (httpResponse.statusCode >= 200 && httpResponse.statusCode < 400);
            if (!error && response && httpOK) {
                if (!ds_mark_network_warmup_ready()) return;
                os_log(OS_LOG_DEFAULT, "[DSBridge] network access ready after %.0fs",
                       CFAbsoluteTimeGetCurrent() - startedAt);
                ds_set_error(@"");
                ds_set_stage(ds_localized(@"Network connected; preparing kernelcache"));
                ds_start_kernel_prefetch(YES);
                return;
            }

            NSTimeInterval totalElapsed = MAX(0.0, CFAbsoluteTimeGetCurrent() - startedAt);
            if (g_networkWarmupState.load() != 1) return;
            if (totalElapsed >= kDSNetworkWarmupTimeout) {
                int expected = 1;
                if (!g_networkWarmupState.compare_exchange_strong(expected, 3)) return;
                NSString *detail = error.localizedDescription;
                if (!detail.length && httpResponse) {
                    detail = [NSString stringWithFormat:@"HTTP %ld", (long)httpResponse.statusCode];
                }
                if (!detail.length) detail = ds_localized(@"No valid response");
                os_log_error(OS_LOG_DEFAULT,
                             "[DSBridge] network warm-up timed out: %{public}@", detail);
                ds_set_stage(ds_localized(@"Network wait timed out"));
                ds_set_error([NSString stringWithFormat:
                    ds_localized(@"Could not connect after waiting %.0f seconds: %@\nCheck DarkSpeed network access and your connection, then retry."),
                    totalElapsed, detail]);
                dispatch_group_leave(ds_network_warmup_group());
                return;
            }

            ds_set_stage([NSString stringWithFormat:
                ds_localized(@"Network is not ready; waited %.0f seconds. Retrying in %.0f seconds"),
                totalElapsed, kDSNetworkRetryDelay]);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(kDSNetworkRetryDelay * NSEC_PER_SEC)),
                           dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                ds_probe_network_until_ready(startedAt, attempt + 1);
            });
        }] resume];
}

void DSBridgeWarmUpNetworkAndPrefetchKernelCache(void) {
    BOOL hasBuiltinOffsets = install_builtin_kernel_symbol_offsets();
    if (hasBuiltinOffsets || ds_has_symbol_offsets()) {
        g_kernelPrefetchState.store(2);
        ds_set_error(@"");
        ds_set_stage(ds_localized(@"System data is ready"));
        return;
    }

    BOOL shouldStartProbe = NO;
    int expected = 0;
    if (g_networkWarmupState.compare_exchange_strong(expected, 1)) {
        shouldStartProbe = YES;
    } else if (expected == 3) {
        expected = 3;
        shouldStartProbe = g_networkWarmupState.compare_exchange_strong(expected, 1);
    }

    if (shouldStartProbe) {
        ds_set_error(@"");
        ds_set_stage(ds_localized(@"Requesting network access"));
        dispatch_group_enter(ds_network_warmup_group());
        ds_probe_network_until_ready(CFAbsoluteTimeGetCurrent(), 1);
    }

    // The real request is the source of truth. Devices that do not present a
    // regional network prompt can proceed immediately instead of being gated
    // on the separate permission/connectivity probe.
    ds_start_kernel_prefetch(YES);
}

static void ds_fail_enable(NSString *reason) {
    os_log_error(OS_LOG_DEFAULT, "[DSBridge] enable failed: %{public}@", reason);
    g_hudRequested.store(false);
    g_hudActive.store(false);
    g_dsRunning.store(false);
    g_dsProgress.store(0.0);
    ds_stop_keepalive();
    ds_set_stage(ds_localized(@"Startup failed"));
    ds_set_error(reason ?: @"");
    ds_post_progress();
}

static NSDictionary *ds_hud_preferences(void) {
    NSMutableDictionary *preferences = [[NSDictionary
        dictionaryWithContentsOfFile:JBROOT_PATH_NSSTRING(USER_DEFAULTS_PATH)] mutableCopy]
        ?: [NSMutableDictionary dictionary];

    // The original app keeps the advanced font/offset values in its standard
    // defaults rather than the HUD plist. Merge them into the remote snapshot
    // so the renderer has exactly one source of truth.
    NSUserDefaults *defaults = GetStandardUserDefaults();
    for (HUDUserDefaultsKey key in @[
        HUDUserDefaultsKeyUsesCustomFontSize,
        HUDUserDefaultsKeyRealCustomFontSize,
        HUDUserDefaultsKeyUsesCustomOffset,
        HUDUserDefaultsKeyRealCustomOffsetX,
        HUDUserDefaultsKeyRealCustomOffsetY,
    ]) {
        id value = [defaults objectForKey:key];
        if (value) preferences[key] = value;
    }
    return preferences;
}

static void ds_append_wav_value(NSMutableData *data, const void *value, NSUInteger size) {
    [data appendBytes:value length:size];
}

static NSURL *ds_silent_wav_url(void) {
    NSURL *cache = [[NSFileManager defaultManager] URLsForDirectory:NSCachesDirectory
                                                          inDomains:NSUserDomainMask].firstObject;
    return [cache URLByAppendingPathComponent:@"darkspeed-silent.wav"];
}

static BOOL ds_write_silent_wav(NSURL *url, NSError **error) {
    const uint32_t sampleRate = 8000;
    const uint16_t channels = 1;
    const uint16_t bitsPerSample = 16;
    const uint16_t blockAlign = channels * (bitsPerSample / 8);
    const uint32_t byteRate = sampleRate * blockAlign;
    const uint32_t dataSize = sampleRate * blockAlign;
    const uint32_t riffSize = 36 + dataSize;
    const uint32_t formatSize = 16;
    const uint16_t pcmFormat = 1;

    NSMutableData *wav = [NSMutableData dataWithCapacity:44 + dataSize];
    [wav appendBytes:"RIFF" length:4];
    ds_append_wav_value(wav, &riffSize, sizeof(riffSize));
    [wav appendBytes:"WAVEfmt " length:8];
    ds_append_wav_value(wav, &formatSize, sizeof(formatSize));
    ds_append_wav_value(wav, &pcmFormat, sizeof(pcmFormat));
    ds_append_wav_value(wav, &channels, sizeof(channels));
    ds_append_wav_value(wav, &sampleRate, sizeof(sampleRate));
    ds_append_wav_value(wav, &byteRate, sizeof(byteRate));
    ds_append_wav_value(wav, &blockAlign, sizeof(blockAlign));
    ds_append_wav_value(wav, &bitsPerSample, sizeof(bitsPerSample));
    [wav appendBytes:"data" length:4];
    ds_append_wav_value(wav, &dataSize, sizeof(dataSize));
    [wav increaseLengthBy:dataSize];
    return [wav writeToURL:url options:NSDataWritingAtomic error:error];
}

static BOOL ds_start_keepalive(void) {
    __block BOOL started = NO;
    dispatch_sync(dispatch_get_main_queue(), ^{
        if (g_keepAlivePlayer.playing) {
            started = YES;
            return;
        }

        NSError *error = nil;
        AVAudioSession *session = AVAudioSession.sharedInstance;
        if (![session setCategory:AVAudioSessionCategoryPlayback
                             mode:AVAudioSessionModeDefault
                          options:AVAudioSessionCategoryOptionMixWithOthers
                            error:&error] ||
            ![session setActive:YES error:&error]) {
            ds_set_error([NSString stringWithFormat:ds_localized(@"Background keep-alive failed: %@"), error.localizedDescription]);
            return;
        }

        NSURL *wavURL = ds_silent_wav_url();
        if (![[NSFileManager defaultManager] fileExistsAtPath:wavURL.path] &&
            !ds_write_silent_wav(wavURL, &error)) {
            ds_set_error([NSString stringWithFormat:ds_localized(@"Background resource preparation failed: %@"), error.localizedDescription]);
            return;
        }

        g_keepAlivePlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:wavURL error:&error];
        g_keepAlivePlayer.numberOfLoops = -1;
        g_keepAlivePlayer.volume = 0.0f;
        [g_keepAlivePlayer prepareToPlay];
        started = [g_keepAlivePlayer play];
        if (!started) {
            ds_set_error([NSString stringWithFormat:ds_localized(@"Background keep-alive playback failed: %@"), error.localizedDescription]);
            g_keepAlivePlayer = nil;
        }
    });
    return started;
}

static void ds_stop_keepalive(void) {
    dispatch_sync(dispatch_get_main_queue(), ^{
        [g_keepAlivePlayer stop];
        g_keepAlivePlayer = nil;
        [AVAudioSession.sharedInstance setActive:NO
                                     withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                           error:nil];
    });
}

static void ds_read_network_bytes(uint64_t *input, uint64_t *output) {
    *input = 0;
    *output = 0;
    struct ifaddrs *interfaces = NULL;
    if (getifaddrs(&interfaces) != 0) return;

    for (struct ifaddrs *interface = interfaces; interface; interface = interface->ifa_next) {
        if (!interface->ifa_name || !interface->ifa_addr || !interface->ifa_data) continue;
        if (interface->ifa_addr->sa_family != AF_LINK) continue;
        if (!(interface->ifa_flags & IFF_UP) && !(interface->ifa_flags & IFF_RUNNING)) continue;
        if (strncmp(interface->ifa_name, "en", 2) && strncmp(interface->ifa_name, "pdp_ip", 6)) continue;

        struct if_data *data = (struct if_data *)interface->ifa_data;
        *input += data->ifi_ibytes;
        *output += data->ifi_obytes;
    }
    freeifaddrs(interfaces);
}

static BOOL ds_pref_bool(NSDictionary *preferences, HUDUserDefaultsKey key) {
    return [preferences[key] boolValue];
}

static CGFloat ds_pref_double(NSDictionary *preferences, HUDUserDefaultsKey key,
                              CGFloat fallback) {
    NSNumber *number = preferences[key];
    return number ? number.doubleValue : fallback;
}

static NSString *ds_format_speed(double bytes, BOOL bitrate, BOOL focused) {
    double value = bitrate ? bytes * 8.0 : bytes;
    double kilo = bitrate ? 1000.0 : 1024.0;
    double mega = kilo * kilo;
    double giga = mega * kilo;
    NSString *suffix = focused ? @"" : @"/s";
    NSString *kiloUnit = bitrate ? @"Kb" : @"KB";
    NSString *megaUnit = bitrate ? @"Mb" : @"MB";
    NSString *gigaUnit = bitrate ? @"Gb" : @"GB";

    if (value < kilo) {
        return [NSString stringWithFormat:@"0\u00a0%@%@", kiloUnit, suffix];
    }
    if (value < mega) {
        return [NSString stringWithFormat:@"%.0f\u00a0%@%@", value / kilo, kiloUnit, suffix];
    }
    if (value < giga) {
        return [NSString stringWithFormat:@"%.2f\u00a0%@%@", value / mega, megaUnit, suffix];
    }
    return [NSString stringWithFormat:@"%.2f\u00a0%@%@", value / giga, gigaUnit, suffix];
}

static UIInterfaceOrientation ds_interface_orientation(void) {
    UIInterfaceOrientation remoteOrientation =
        (UIInterfaceOrientation)g_remoteOrientation.load();
    if (remoteOrientation != UIInterfaceOrientationUnknown) {
        return remoteOrientation;
    }
    __block UIInterfaceOrientation orientation = UIInterfaceOrientationPortrait;
    dispatch_sync(dispatch_get_main_queue(), ^{
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            if (windowScene.activationState == UISceneActivationStateUnattached) continue;
            orientation = windowScene.interfaceOrientation;
            break;
        }
    });
    return orientation;
}

static void ds_screen_geometry(CGRect *bounds, UIEdgeInsets *safeInsets) {
    __block CGRect currentBounds = UIScreen.mainScreen.bounds;
    __block UIEdgeInsets currentInsets = UIEdgeInsetsZero;
    dispatch_sync(dispatch_get_main_queue(), ^{
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            if (windowScene.activationState == UISceneActivationStateUnattached) continue;
            currentBounds = windowScene.coordinateSpace.bounds;
            for (UIWindow *window in windowScene.windows) {
                if (window.safeAreaInsets.top > currentInsets.top) {
                    currentInsets = window.safeAreaInsets;
                }
            }
            break;
        }
    });
    if (bounds) *bounds = currentBounds;
    if (safeInsets) *safeInsets = currentInsets;
}

static NSString *ds_display_text(NSDictionary *preferences,
                                 BOOL centered,
                                 BOOL focused,
                                 double down,
                                 double up) {
    HUDDisplayMode displayMode = (HUDDisplayMode)[preferences[HUDUserDefaultsKeyDisplayMode] integerValue];
    if (displayMode == HUDDisplayModeTime || displayMode == HUDDisplayModeTimeSeconds) {
        // 系统短/中时间格式分别显示时分/时分秒，并跟随用户的 12/24 小时制和时区。
        return [NSDateFormatter localizedStringFromDate:NSDate.date
                                             dateStyle:NSDateFormatterNoStyle
                                             timeStyle:(displayMode == HUDDisplayModeTimeSeconds
                                                 ? NSDateFormatterMediumStyle : NSDateFormatterShortStyle)];
    }
    if (displayMode == HUDDisplayModeFPS) {
        CFTimeInterval now = CACurrentMediaTime();
        CFIndex current = CARenderServerGetDirtyFrameCount(NULL);
        if (g_needsFPSBaselineReset) {
            g_previousDirtyFrameCount = current;
            g_previousFPSSampleTime = now;
            g_needsFPSBaselineReset = NO;
            return @"0 FPS";
        }
        CFIndex frameDiff = MAX((CFIndex)0, current - g_previousDirtyFrameCount);
        g_previousDirtyFrameCount = current;
        double interval = MAX(now - g_previousFPSSampleTime, 0.001);
        g_previousFPSSampleTime = now;
        CGFloat maximumFPS = UIScreen.mainScreen.maximumFramesPerSecond;
        return [NSString stringWithFormat:@"%.0f FPS", MIN((CGFloat)(frameDiff / interval), maximumFPS)];
    }

    BOOL bitrate = ds_pref_bool(preferences, HUDUserDefaultsKeyUsesBitrate);
    BOOL alternateArrows = ds_pref_bool(preferences, HUDUserDefaultsKeyUsesArrowPrefixes);
    BOOL incomingOnly = ds_pref_bool(preferences, HUDUserDefaultsKeySingleLineMode);
    NSString *downloadPrefix = alternateArrows ? @"↓" : @"▼";
    NSString *uploadPrefix = alternateArrows ? @"↑" : @"▲";
    NSString *download = [NSString stringWithFormat:@"%@\u00a0%@",
                          downloadPrefix, ds_format_speed(down, bitrate, focused)];
    if (incomingOnly) return download;

    NSString *upload = [NSString stringWithFormat:@"%@\u00a0%@",
                        uploadPrefix, ds_format_speed(up, bitrate, focused)];
    return centered
        ? [NSString stringWithFormat:@"%@\t%@", download, upload]
        : [NSString stringWithFormat:@"%@\n%@", upload, download];
}

static DSHUDPresentation ds_hud_presentation(NSDictionary *preferences,
                                             NSString *text) {
    DSHUDPresentation presentation = {};
    UIInterfaceOrientation orientation = ds_interface_orientation();
    presentation.landscape = UIInterfaceOrientationIsLandscape(orientation);

    HUDUserDefaultsKey modeKey = presentation.landscape
        ? HUDUserDefaultsKeySelectedModeLandscape
        : HUDUserDefaultsKeySelectedMode;
    NSNumber *storedMode = preferences[modeKey];
    HUDPresetPosition mode = storedMode
        ? (HUDPresetPosition)storedMode.integerValue
        : HUDPresetPositionTopCenter;
    presentation.centered =
        mode == HUDPresetPositionTopCenter || mode == HUDPresetPositionTopCenterMost;
    presentation.centeredMost = mode == HUDPresetPositionTopCenterMost;
    BOOL topMost = presentation.centeredMost || mode == HUDPresetPositionTopLeftMost ||
                   mode == HUDPresetPositionTopRightMost;
    presentation.singleLine = ds_pref_bool(preferences, HUDUserDefaultsKeySingleLineMode);
    presentation.bitrate = ds_pref_bool(preferences, HUDUserDefaultsKeyUsesBitrate);
    presentation.arrowPrefixes = ds_pref_bool(preferences, HUDUserDefaultsKeyUsesArrowPrefixes);
    presentation.inverted = ds_pref_bool(preferences, HUDUserDefaultsKeyUsesInvertedColor);
    presentation.bold = ds_pref_bool(preferences, HUDUserDefaultsKeyUsesBoldFont);
    presentation.transparentBackground = ds_pref_bool(preferences, HUDUserDefaultsKeyTransparentBackground);
    presentation.followsRotation = ds_pref_bool(preferences, HUDUserDefaultsKeyUsesRotation);
    presentation.hideAtSnapshot = ds_pref_bool(preferences, HUDUserDefaultsKeyHideAtSnapshot);
    HUDDisplayMode displayMode = (HUDDisplayMode)[preferences[HUDUserDefaultsKeyDisplayMode] integerValue];
    presentation.displayFPS = displayMode == HUDDisplayModeFPS;
    presentation.passthrough = ds_pref_bool(preferences, HUDUserDefaultsKeyPassthroughMode);

    BOOL customFont = ds_pref_bool(preferences, HUDUserDefaultsKeyUsesCustomFontSize);
    if (customFont) {
        presentation.fontSize = MIN(MAX(ds_pref_double(
            preferences, HUDUserDefaultsKeyRealCustomFontSize, kDSHUDMinFontSize), 8.0), 24.0);
        presentation.cornerRadius = presentation.fontSize / 2.0;
    } else {
        BOOL large = ds_pref_bool(preferences, HUDUserDefaultsKeyUsesLargeFont);
        presentation.fontSize = large ? kDSHUDMaxFontSize : kDSHUDMinFontSize;
        presentation.cornerRadius = large ? kDSHUDMaxCornerRadius : kDSHUDMinCornerRadius;
    }
    presentation.inactiveOpacity = presentation.inverted || presentation.transparentBackground ? 1.0 : kDSHUDInactiveOpacity;
    presentation.numberOfLines = displayMode != HUDDisplayModeSpeed || presentation.centered || presentation.singleLine ? 1 : 2;
    presentation.alignment = presentation.centered ? NSTextAlignmentCenter : NSTextAlignmentLeft;
    presentation.maskedCorners =
        presentation.centeredMost && !presentation.landscape
            ? kDSCornerMaskBottom
            : kDSCornerMaskAll;

    UIFontWeight weight = presentation.bold ? UIFontWeightBlack : (presentation.inverted ? UIFontWeightMedium : UIFontWeightRegular);
    UIFont *font = [UIFont monospacedDigitSystemFontOfSize:presentation.fontSize weight:weight];
    CGRect measured = [text boundingRectWithSize:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)
                                        options:NSStringDrawingUsesLineFragmentOrigin |
                                                NSStringDrawingUsesFontLeading
                                     attributes:@{NSFontAttributeName: font}
                                        context:nil];
    CGSize labelSize = CGSizeMake(ceil(measured.size.width), ceil(measured.size.height));
    if (labelSize.width < 1) labelSize.width = 1;
    if (labelSize.height < 1) labelSize.height = ceil(font.lineHeight);
    // 为描边留出空间，避免粗体或大字号的边缘被裁切。
    if (presentation.transparentBackground) {
        CGFloat inset = ceil(presentation.fontSize * -HUDTextOutlineStrokeWidth(presentation.bold) / 100.0);
        labelSize.width += inset * 2.0;
        labelSize.height += inset * 2.0;
    }
    CGSize hudSize = CGSizeMake(labelSize.width + 8.0, labelSize.height + 4.0);

    CGRect screenBounds;
    UIEdgeInsets safeInsets;
    ds_screen_geometry(&screenBounds, &safeInsets);
    CGFloat realOffsetX = 0;
    CGFloat realOffsetY = 0;
    if (ds_pref_bool(preferences, HUDUserDefaultsKeyUsesCustomOffset)) {
        realOffsetX = -ds_pref_double(preferences, HUDUserDefaultsKeyRealCustomOffsetX, 0);
        realOffsetY = ds_pref_double(preferences, HUDUserDefaultsKeyRealCustomOffsetY, 0);
    }

    CGFloat x = CGRectGetMidX(screenBounds) - hudSize.width / 2.0;
    // 顶部两侧内缩一个顶部安全区的距离，为屏幕圆角留出空间。
    CGFloat sidePadding = topMost && !presentation.landscape ? MAX(10.0, safeInsets.top) : 10.0;
    if (mode == HUDPresetPositionTopLeft || mode == HUDPresetPositionTopLeftMost) {
        x = CGRectGetMinX(screenBounds) + safeInsets.left + sidePadding + realOffsetX;
    } else if (mode == HUDPresetPositionTopRight || mode == HUDPresetPositionTopRightMost) {
        x = CGRectGetMaxX(screenBounds) - safeInsets.right - sidePadding - hudSize.width + realOffsetX;
    }

    CGFloat y;
    if (topMost && !presentation.landscape) {
        y = CGRectGetMinY(screenBounds);
    } else if (presentation.landscape) {
        CGFloat minimumTop = UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad
            ? 30.0 : 10.0;
        minimumTop += realOffsetY;
        NSNumber *saved = preferences[HUDUserDefaultsKeyCurrentLandscapePositionY];
        CGFloat topConstant = (!presentation.centered && saved) ? saved.doubleValue : minimumTop;
        y = CGRectGetMinY(screenBounds) + topConstant;
    } else {
        CGFloat minimumTop;
        if (safeInsets.top >= 51.0) minimumTop = -8.0;
        else if (safeInsets.top > 30.0) minimumTop = -12.0;
        else minimumTop = UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad
            ? 30.0 : 20.0;
        minimumTop += realOffsetY;
        NSNumber *saved = preferences[HUDUserDefaultsKeyCurrentPositionY];
        CGFloat topConstant = (!presentation.centered && saved) ? saved.doubleValue : minimumTop;
        y = CGRectGetMinY(screenBounds) + safeInsets.top + topConstant;
    }

    // 应用于最终位置，左／中／右及置顶均使用相同的正右负左规则。
    x += MIN(MAX(ds_pref_double(preferences, HUDUserDefaultsKeyHorizontalOffset, 0), -100.0), 100.0);
    presentation.windowFrame = CGRectMake(round(x), round(y), hudSize.width, hudSize.height);
    presentation.blurFrame = CGRectMake(0, 0, hudSize.width, hudSize.height);
    presentation.labelFrame = CGRectMake(4, 2, labelSize.width, labelSize.height);
    return presentation;
}

static void ds_reset_remote_symbol_cache(void) {
    g_remoteSelectorCache = [NSMutableDictionary dictionary];
    g_remoteClassCache = [NSMutableDictionary dictionary];
}

static uint64_t ds_remote_sel(RemoteCall *process, const char *name) {
    if (!process || !process.trojanMem || !name) return 0;
    if (!g_remoteSelectorCache) g_remoteSelectorCache = [NSMutableDictionary dictionary];
    NSString *key = [NSString stringWithUTF8String:name];
    if (!key) return 0;
    NSNumber *cached = g_remoteSelectorCache[key];
    if (cached) return cached.unsignedLongLongValue;
    uint64_t value = remote_sel(process, name);
    if (value) g_remoteSelectorCache[key] = @(value);
    return value;
}

static uint64_t ds_remote_class(RemoteCall *process, const char *name) {
    if (!process || !process.trojanMem || !name) return 0;
    if (!g_remoteClassCache) g_remoteClassCache = [NSMutableDictionary dictionary];
    NSString *key = [NSString stringWithUTF8String:name];
    if (!key) return 0;
    NSNumber *cached = g_remoteClassCache[key];
    if (cached) return cached.unsignedLongLongValue;
    uint64_t value = remote_getClass(process, name);
    if (value) g_remoteClassCache[key] = @(value);
    return value;
}

// The rate label changes every second. Keep its UTF-8 bytes in one reserved
// page instead of doing remote malloc/write/free for every sample. The latter
// eventually filled RemoteCall's finite shared-page cache and turned a failed
// write into a bogus Objective-C selector inside SpringBoard.
static uint64_t ds_remote_create_string(RemoteCall *process, NSString *value) {
    if (!process || !process.trojanMem || !value) return 0;
    const char *utf8 = value.UTF8String;
    if (!utf8) return 0;
    size_t length = strlen(utf8) + 1;
    if (length > kDSRemoteTextScratchCapacity) return 0;

    uint64_t scratch = process.trojanMem + kDSRemoteTextScratchOffset;
    if (![process remote_write:scratch from:utf8 size:length]) return 0;

    uint64_t stringClass = ds_remote_class(process, "NSString");
    uint64_t alloc = ds_remote_sel(process, "alloc");
    uint64_t init = ds_remote_sel(process, "initWithUTF8String:");
    if (!stringClass || !alloc || !init) return 0;
    uint64_t object = remote_msg(process, stringClass, alloc, 0, 0, 0, 0);
    if (!object) return 0;
    uint64_t string = remote_msg(process, object, init, scratch, 0, 0, 0);
    if (!string) {
        uint64_t release = ds_remote_sel(process, "release");
        if (release) remote_msg(process, object, release, 0, 0, 0, 0);
    }
    return string;
}

static BOOL ds_perform_on_springboard_main(RemoteCall *process, uint64_t target,
                                           uint64_t selector, uint64_t argument,
                                           BOOL waitUntilDone) {
    if (!process || !process.trojanMem || !target || !selector) return NO;
    uint64_t perform = ds_remote_sel(process, "performSelectorOnMainThread:withObject:waitUntilDone:");
    if (!perform) return NO;
    // a0=selector, a1=object, a2=waitUntilDone (BOOL as uint64 on little-endian).
    remote_msg(process, target, perform, selector, argument, waitUntilDone ? 1 : 0, 0);
    return process.trojanMem != 0;
}

static BOOL ds_remote_set_text_on_main(RemoteCall *process, uint64_t label,
                                       NSString *text, uint64_t attributes) {
    uint64_t remoteText = ds_remote_create_string(process, text);
    if (!remoteText) return NO;
    uint64_t value = remoteText;
    if (attributes) {
        uint64_t attributedClass = ds_remote_class(process, "NSAttributedString");
        uint64_t object = attributedClass
            ? remote_msg(process, attributedClass, ds_remote_sel(process, "alloc"), 0, 0, 0, 0) : 0;
        value = object ? remote_msg(process, object, ds_remote_sel(process, "initWithString:attributes:"),
                                    remoteText, attributes, 0, 0) : 0;
    }
    BOOL sent = value && ds_perform_on_springboard_main(
        process, label, ds_remote_sel(process, attributes ? "setAttributedText:" : "setText:"), value, YES);
    uint64_t release = ds_remote_sel(process, "release");
    if (release && process.trojanMem) {
        if (attributes && value) remote_msg(process, value, release, 0, 0, 0, 0);
        remote_msg(process, remoteText, release, 0, 0, 0, 0);
    }
    return sent;
}

typedef struct {
    const void *bytes;
    uint64_t size;
} DSRemoteArgument;

// RemoteCall's doRemoteCallSyncOnMainThread assumes task->threads.next is the
// main thread. On iOS 17 it can be RemoteCall's newly-created pthread instead,
// which makes UIView initialization abort SpringBoard under
// CA_ASSERT_MAIN_THREAD_TRANSACTIONS. Build an NSInvocation on the call thread,
// then synchronously ask NSObject to invoke it on SpringBoard's real main thread.
static BOOL ds_remote_invoke_on_main_result(RemoteCall *process, uint64_t target,
                                            uint64_t selector,
                                            const DSRemoteArgument *arguments,
                                            NSUInteger argumentCount,
                                            void *result,
                                            NSUInteger resultSize) {
    if (!process || !target || !selector || !process.trojanMem) return NO;

    uint64_t poolClass = ds_remote_class(process, "NSAutoreleasePool");
    uint64_t allocSelector = ds_remote_sel(process, "alloc");
    uint64_t initSelector = ds_remote_sel(process, "init");
    uint64_t drainSelector = ds_remote_sel(process, "drain");
    uint64_t autoreleasePool = poolClass && allocSelector && initSelector && drainSelector
        ? remote_msg(process,
                     remote_msg(process, poolClass, allocSelector, 0, 0, 0, 0),
                     initSelector, 0, 0, 0, 0)
        : 0;
    if (!autoreleasePool) return NO;

    @try {

    uint64_t signature = remote_msg(process, target,
                                    ds_remote_sel(process, "methodSignatureForSelector:"),
                                    selector, 0, 0, 0);
    if (!process.trojanMem) return NO;
    uint64_t invocationClass = ds_remote_class(process, "NSInvocation");
    uint64_t invocation = signature && invocationClass
        ? remote_msg(process, invocationClass,
                     ds_remote_sel(process, "invocationWithMethodSignature:"),
                     signature, 0, 0, 0)
        : 0;
    if (!invocation || !process.trojanMem) return NO;

    remote_msg(process, invocation, ds_remote_sel(process, "setTarget:"), target, 0, 0, 0);
    if (!process.trojanMem) return NO;
    remote_msg(process, invocation, ds_remote_sel(process, "setSelector:"), selector, 0, 0, 0);
    if (!process.trojanMem) return NO;

    uint64_t scratch = process.trojanMem + 0x800;
    for (NSUInteger index = 0; index < argumentCount; index++) {
        if (!arguments[index].bytes || arguments[index].size == 0 ||
            ![process remote_write:scratch
                              from:arguments[index].bytes
                              size:arguments[index].size]) {
            return NO;
        }
        remote_msg(process, invocation, ds_remote_sel(process, "setArgument:atIndex:"),
                   scratch, index + 2, 0, 0);
        if (!process.trojanMem) return NO;
        scratch += (arguments[index].size + 15) & ~15ULL;
    }

    ds_perform_on_springboard_main(process, invocation,
                                   ds_remote_sel(process, "invoke"), 0, YES);
    if (!process.trojanMem) return NO;
    if (result && resultSize > 0) {
        uint64_t resultScratch = process.trojanMem + 0xC00;
        memset(result, 0, resultSize);
        if (![process remote_write:resultScratch from:result size:resultSize]) return NO;
        remote_msg(process, invocation, ds_remote_sel(process, "getReturnValue:"),
                   resultScratch, 0, 0, 0);
        if (!process.trojanMem) return NO;
        if (![process remoteRead:resultScratch to:result size:resultSize]) return NO;
    }
    return YES;
    } @finally {
        if (process.trojanMem) {
            remote_msg(process, autoreleasePool, drainSelector, 0, 0, 0, 0);
        }
    }
}

static BOOL ds_remote_invoke_on_main(RemoteCall *process, uint64_t target,
                                     uint64_t selector,
                                     const DSRemoteArgument *arguments,
                                     NSUInteger argumentCount) {
    return ds_remote_invoke_on_main_result(process, target, selector,
                                           arguments, argumentCount, NULL, 0);
}

static BOOL ds_remote_invoke_noarg_on_main(RemoteCall *process, uint64_t target,
                                           const char *selectorName) {
    return ds_remote_invoke_on_main(process, target, ds_remote_sel(process, selectorName),
                                    NULL, 0);
}

static uint64_t ds_remote_get_object_on_main(RemoteCall *process, uint64_t target,
                                             const char *selectorName) {
    uint64_t result = 0;
    BOOL invoked = ds_remote_invoke_on_main_result(
        process, target, ds_remote_sel(process, selectorName), NULL, 0,
        &result, sizeof(result));
    return invoked ? result : 0;
}

static uint64_t ds_remote_get_retained_object_on_main(
    RemoteCall *process, uint64_t target, const char *selectorName,
    const DSRemoteArgument *arguments, NSUInteger argumentCount) {
    uint64_t result = 0;
    BOOL invoked = ds_remote_invoke_on_main_result(
        process, target, ds_remote_sel(process, selectorName),
        arguments, argumentCount, &result, sizeof(result));
    if (!invoked || !result || !process.trojanMem) return 0;

    // Retain immediately after the synchronous main-thread return. This keeps
    // factory results alive across later performSelector turns and prevents the
    // dangling-object crash seen with the former UIColor factory result.
    remote_msg(process, result, ds_remote_sel(process, "retain"), 0, 0, 0, 0);
    return process.trojanMem ? result : 0;
}

static BOOL ds_remote_set_u64_on_main(RemoteCall *process, uint64_t target,
                                      const char *selectorName, uint64_t value) {
    DSRemoteArgument argument = { &value, sizeof(value) };
    return ds_remote_invoke_on_main(process, target, ds_remote_sel(process, selectorName),
                                    &argument, 1);
}

static uint64_t ds_remote_get_u64_on_main(RemoteCall *process, uint64_t target,
                                          const char *selectorName) {
    uint64_t result = 0;
    BOOL invoked = ds_remote_invoke_on_main_result(
        process, target, ds_remote_sel(process, selectorName), NULL, 0,
        &result, sizeof(result));
    return invoked ? result : 0;
}

static BOOL ds_remote_set_double_on_main(RemoteCall *process, uint64_t target,
                                         const char *selectorName, double value) {
    DSRemoteArgument argument = { &value, sizeof(value) };
    return ds_remote_invoke_on_main(process, target, ds_remote_sel(process, selectorName),
                                    &argument, 1);
}

static BOOL ds_remote_set_rect_on_main(RemoteCall *process, uint64_t target,
                                       const char *selectorName, CGRect value) {
    DSRemoteArgument argument = { &value, sizeof(value) };
    return ds_remote_invoke_on_main(process, target, ds_remote_sel(process, selectorName),
                                    &argument, 1);
}

static uint64_t ds_remote_font(RemoteCall *process, CGFloat size, BOOL medium, BOOL bold) {
    uint64_t fontClass = ds_remote_class(process, "UIFont");
    if (!fontClass) return 0;
    double pointSize = size;
    double weight = bold ? UIFontWeightBlack : (medium ? UIFontWeightMedium : UIFontWeightRegular);
    DSRemoteArgument arguments[] = {
        { &pointSize, sizeof(pointSize) },
        { &weight, sizeof(weight) },
    };
    return ds_remote_get_retained_object_on_main(
        process, fontClass, "monospacedDigitSystemFontOfSize:weight:",
        arguments, 2);
}

static uint64_t ds_remote_stroke_attributes(RemoteCall *process, uint64_t strokeColor, uint64_t font, uint64_t textColor, BOOL bold) {
    uint64_t dictionaryClass = ds_remote_class(process, "NSDictionary");
    uint64_t numberClass = ds_remote_class(process, "NSNumber");
    if (!dictionaryClass || !numberClass || !strokeColor || !font || !textColor) return 0;
    uint64_t alloc = ds_remote_sel(process, "alloc");
    uint64_t widthObject = remote_msg(process, numberClass, alloc, 0, 0, 0, 0);
    uint64_t width = widthObject ? remote_msg(process, widthObject, ds_remote_sel(process, "initWithInt:"),
                                              (uint64_t)(int64_t)HUDTextOutlineStrokeWidth(bold), 0, 0, 0) : 0;
    uint64_t keys[] = {
        ds_remote_create_string(process, NSStrokeWidthAttributeName),
        ds_remote_create_string(process, NSStrokeColorAttributeName),
        ds_remote_create_string(process, NSFontAttributeName),
        ds_remote_create_string(process, NSForegroundColorAttributeName)
    };
    uint64_t values[] = { width, strokeColor, font, textColor };
    uint64_t attributes = 0;
    // 字符串已复制内容，可复用文字暂存区传递数组；字典复制键并持有值。
    // 描边属性只在样式变化时重建，避免每秒创建一套远端样式对象。
    uint64_t scratch = process.trojanMem + kDSRemoteTextScratchOffset;
    if (width && keys[0] && keys[1] && keys[2] && keys[3] && process.trojanMem &&
        [process remote_write:scratch from:values size:sizeof(values)] &&
        [process remote_write:scratch + sizeof(values) from:keys size:sizeof(keys)]) {
        uint64_t object = remote_msg(process, dictionaryClass, alloc, 0, 0, 0, 0);
        if (object) attributes = remote_msg(process, object, ds_remote_sel(process, "initWithObjects:forKeys:count:"),
                                             scratch, scratch + sizeof(values), 4, 0);
    }
    uint64_t release = ds_remote_sel(process, "release");
    for (uint64_t object : { width, keys[0], keys[1], keys[2], keys[3] }) {
        if (object && release && process.trojanMem) remote_msg(process, object, release, 0, 0, 0, 0);
    }
    return attributes;
}

static uint64_t ds_remote_secure_canvas(RemoteCall *process, uint64_t textField) {
    uint64_t canvasClass = ds_remote_class(process, "_UITextLayoutCanvasView");
    uint64_t subviews = ds_remote_get_retained_object_on_main(
        process, textField, "subviews", NULL, 0);
    if (!canvasClass || !subviews) return 0;

    uint64_t count = ds_remote_get_u64_on_main(process, subviews, "count");
    count = MIN(count, 16);
    for (uint64_t index = 0; index < count; index++) {
        DSRemoteArgument argument = { &index, sizeof(index) };
        uint64_t view = 0;
        if (!ds_remote_invoke_on_main_result(
                process, subviews, ds_remote_sel(process, "objectAtIndex:"),
                &argument, 1, &view, sizeof(view)) || !view) {
            continue;
        }
        uint64_t viewClass = ds_remote_get_object_on_main(process, view, "class");
        if (viewClass == canvasClass) return view;
    }
    return 0;
}

static BOOL ds_apply_snapshot_container(RemoteCall *process, BOOL hideAtSnapshot) {
    if (!process || !g_remoteWindow || !g_remoteContainer) return NO;
    BOOL canHide = g_remoteSecureField && g_remoteSecureCanvas;
    BOOL shouldHide = hideAtSnapshot && canHide;
    if (g_remoteSecureField) {
        ds_remote_set_u64_on_main(process, g_remoteSecureField,
                                  "setSecureTextEntry:", shouldHide ? 1 : 0);
    }
    uint64_t parent = shouldHide ? g_remoteSecureCanvas : g_remoteWindow;
    ds_perform_on_springboard_main(process, parent,
                                   ds_remote_sel(process, "addSubview:"),
                                   g_remoteContainer, YES);
    g_lastHideAtSnapshot = hideAtSnapshot;
    if (hideAtSnapshot && !canHide) {
        ds_append_checkpoint(ds_localized(@"Screenshot-hiding container unavailable; using normal display"));
    }
    return !hideAtSnapshot || canHide;
}

// The HUD lives in its own UIWindow anchored to SBMainWorkspace.mainWindowScene
// Adding to whatever keyWindow we can find is
// unreliable — that window may be hidden, tiny, or off-screen.
static uint64_t ds_create_springboard_hud(RemoteCall *process) {
    NSDictionary *preferences = ds_hud_preferences();
    DSHUDPresentation probe = ds_hud_presentation(preferences, @"0");
    NSString *text = ds_display_text(preferences, probe.centered, YES, 0, 0);
    DSHUDPresentation presentation = ds_hud_presentation(preferences, text);

    uint64_t alloc = ds_remote_sel(process, "alloc");
    uint64_t workspaceClass = ds_remote_class(process, "SBMainWorkspace");
    uint64_t windowClass = ds_remote_class(process, "UIWindow");
    uint64_t viewClass = ds_remote_class(process, "UIView");
    uint64_t labelClass = ds_remote_class(process, "UILabel");
    uint64_t textFieldClass = ds_remote_class(process, "UITextField");
    uint64_t colorClass = ds_remote_class(process, "UIColor");
    if (!workspaceClass || !windowClass || !viewClass ||
        !labelClass || !textFieldClass || !colorClass) return 0;

    uint64_t workspace = ds_remote_get_object_on_main(
        process, workspaceClass, "sharedInstance");
    uint64_t scene = workspace
        ? ds_remote_get_object_on_main(process, workspace, "mainWindowScene")
        : 0;
    if (!scene) return 0;

    uint64_t window = remote_msg(process, windowClass, alloc, 0, 0, 0, 0);
    uint64_t container = remote_msg(process, viewClass, alloc, 0, 0, 0, 0);
    uint64_t label = remote_msg(process, labelClass, alloc, 0, 0, 0, 0);
    uint64_t secureField = remote_msg(process, textFieldClass, alloc, 0, 0, 0, 0);
    // Safety renderer: keep the SpringBoard hierarchy to plain UIKit objects.
    // UIVisualEffectView/CABackdropLayer is intentionally not used here because
    // it starts extra render-server work immediately after RemoteCall setup.
    uint64_t blurView = remote_msg(process, viewClass, alloc, 0, 0, 0, 0);
    if (!window || !container || !label || !secureField || !blurView) return 0;
    if (!ds_remote_invoke_noarg_on_main(process, window, "init") ||
        !ds_remote_invoke_noarg_on_main(process, container, "init") ||
        !ds_remote_invoke_noarg_on_main(process, label, "init") ||
        !ds_remote_invoke_noarg_on_main(process, secureField, "init") ||
        !ds_remote_invoke_noarg_on_main(process, blurView, "init")) {
        return 0;
    }

    ds_remote_set_rect_on_main(process, window, "setFrame:", presentation.windowFrame);
    ds_perform_on_springboard_main(process, window, ds_remote_sel(process, "setWindowScene:"), scene, YES);
    // Match the original hosted HUD. Status-bar level is below SpringBoard's
    // CoverSheet, so it disappears as soon as the device enters the lock UI.
    ds_remote_set_double_on_main(process, window, "setWindowLevel:", kDSHUDWindowLevel);
    ds_remote_set_u64_on_main(process, window, "setUserInteractionEnabled:", 0);
    ds_remote_set_u64_on_main(process, window, "setOpaque:", 0);

    ds_remote_set_rect_on_main(process, container, "setFrame:", presentation.blurFrame);
    ds_remote_set_rect_on_main(process, blurView, "setFrame:", presentation.blurFrame);
    ds_remote_set_rect_on_main(process, label, "setFrame:", presentation.labelFrame);
    ds_remote_set_rect_on_main(process, secureField, "setFrame:", presentation.blurFrame);

    uint64_t clear = ds_remote_get_object_on_main(process, colorClass, "clearColor");
    uint64_t white = ds_remote_get_object_on_main(process, colorClass, "whiteColor");
    uint64_t black = ds_remote_get_object_on_main(process, colorClass, "blackColor");
    // Do not pass autoreleased factory results across separate main-thread
    // performSelector turns. The prior colorWithWhite:alpha: result was already
    // dead by setBackgroundColor:, producing SIGBUS in object_getClass.
    uint64_t safeBackground = ds_remote_get_object_on_main(
        process, colorClass, "darkGrayColor");
    if (!clear || !white || !black || !safeBackground) return 0;

    ds_perform_on_springboard_main(process, window,
                                   ds_remote_sel(process, "setBackgroundColor:"), clear, YES);
    ds_perform_on_springboard_main(process, container,
                                   ds_remote_sel(process, "setBackgroundColor:"), clear, YES);
    ds_perform_on_springboard_main(process, secureField,
                                   ds_remote_sel(process, "setBackgroundColor:"), clear, YES);
    ds_perform_on_springboard_main(process, blurView,
                                   ds_remote_sel(process, "setBackgroundColor:"),
                                   presentation.transparentBackground ? clear : (presentation.inverted ? white : safeBackground), YES);
    ds_remote_set_u64_on_main(process, container, "setTag:", (uint64_t)kDSSpringBoardHUDTag);
    ds_remote_set_u64_on_main(process, container, "setHidden:", 0);
    ds_remote_set_u64_on_main(process, container, "setUserInteractionEnabled:", 0);
    ds_remote_set_u64_on_main(process, container, "setAutoresizingMask:",
                              UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight);
    ds_remote_set_u64_on_main(process, blurView, "setAutoresizingMask:",
                              UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight);
    ds_remote_set_u64_on_main(process, secureField, "setAutoresizingMask:",
                              UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight);
    ds_remote_set_u64_on_main(process, secureField, "setUserInteractionEnabled:", 0);
    ds_remote_set_u64_on_main(process, secureField, "setOpaque:", 0);
    ds_perform_on_springboard_main(process, label,
                                   ds_remote_sel(process, "setTextColor:"),
                                   presentation.inverted ? black : white, YES);
    ds_remote_set_u64_on_main(process, label, "setNumberOfLines:",
                              (uint64_t)presentation.numberOfLines);
    ds_remote_set_u64_on_main(process, label, "setHidden:", 0);
    uint64_t font = ds_remote_font(process, presentation.fontSize,
                                   presentation.inverted, presentation.bold);
    if (!font) return 0;
    ds_perform_on_springboard_main(process, label,
                                   ds_remote_sel(process, "setFont:"), font, YES);
    ds_remote_set_u64_on_main(process, label, "setAdjustsFontSizeToFitWidth:", 0);
    ds_remote_set_u64_on_main(process, label, "setUserInteractionEnabled:", 0);
    ds_remote_set_u64_on_main(process, label, "setTextAlignment:",
                              (uint64_t)presentation.alignment);
    ds_remote_set_double_on_main(process, label, "setAlpha:", presentation.transparentBackground ? 1.0 : 0.85);

    uint64_t layer = ds_remote_get_object_on_main(process, blurView, "layer");
    if (layer) {
        ds_remote_set_double_on_main(process, layer, "setCornerRadius:",
                                     presentation.cornerRadius);
        ds_remote_set_u64_on_main(process, layer, "setMasksToBounds:", 1);
        ds_remote_set_u64_on_main(process, layer, "setMaskedCorners:",
                                  (uint64_t)presentation.maskedCorners);
    }
    ds_remote_set_double_on_main(process, container, "setAlpha:", 1.0);

    if (!process.trojanMem) return 0;
    g_remoteTextAttributes = presentation.transparentBackground
        ? ds_remote_stroke_attributes(process, presentation.inverted ? white : black, font,
                                      presentation.inverted ? black : white, presentation.bold) : 0;
    if (presentation.transparentBackground && !g_remoteTextAttributes) return 0;
    if (!ds_remote_set_text_on_main(process, label, text, g_remoteTextAttributes)) return 0;
    ds_perform_on_springboard_main(process, blurView,
                                   ds_remote_sel(process, "addSubview:"), label, YES);
    ds_perform_on_springboard_main(process, container,
                                   ds_remote_sel(process, "addSubview:"), blurView, YES);
    ds_perform_on_springboard_main(process, window,
                                   ds_remote_sel(process, "addSubview:"), secureField, YES);

    g_remoteWindow = window;
    g_remoteContainer = container;
    g_remoteSecureField = secureField;
    g_remoteSecureCanvas = ds_remote_secure_canvas(process, secureField);
    ds_apply_snapshot_container(process, presentation.hideAtSnapshot);
    ds_remote_set_u64_on_main(process, window, "setHidden:", 0);

    g_remoteWindowScene = scene;
    // 桌面窗口可能一直保持竖屏，改用原 HUD 已使用的系统界面方向观察器。
    // 在 SpringBoard 内查询，避免后台 App 自身的 scene 方向滞后。
    uint64_t observerClass = ds_remote_class(process, "FBSOrientationObserver");
    if (observerClass) {
        uint64_t observer = remote_msg(process, observerClass, alloc, 0, 0, 0, 0);
        g_remoteOrientationObserver = observer
            ? ds_remote_get_object_on_main(process, observer, "init") : 0;
    }
    g_remoteWindowPid = process.pid;
    g_remoteBlurView = blurView;
    g_remoteBlurEffect = 0;
    g_lastPresentationPreferences = [preferences copy];
    g_lastPresentationOrientation = ds_interface_orientation();
    g_lastWindowFrame = presentation.windowFrame;
    g_lastLabelFrame = presentation.labelFrame;
    g_lastWindowHidden = NO;
    g_lastContainerAlpha = 1.0;
    g_lastFontSize = presentation.fontSize;
    g_lastInverted = presentation.inverted;
    g_lastBold = presentation.bold;
    g_focusUntil = CFAbsoluteTimeGetCurrent() + kDSHUDFocusDuration;
    return label;
}

// Never release remote UIViews: dealloc on a hijacked thread crashes SpringBoard
// (same CA main-thread assert). removeFromSuperview + hide, and intentionally
// leak the tiny view hierarchy for the lifetime of the remote session.
static void ds_remove_springboard_hud(RemoteCall *process) {
    if (!g_remoteWindow || g_remoteWindowPid != process.pid) return;
    if (g_remoteTextAttributes) {
        remote_msg(process, g_remoteTextAttributes, ds_remote_sel(process, "release"), 0, 0, 0, 0);
        g_remoteTextAttributes = 0;
    }
    if (g_remoteOrientationObserver) {
        ds_remote_invoke_noarg_on_main(process, g_remoteOrientationObserver, "invalidate");
        ds_remote_invoke_noarg_on_main(process, g_remoteOrientationObserver, "release");
        g_remoteOrientationObserver = 0;
    }
    if (g_remoteContainer) {
        ds_perform_on_springboard_main(process, g_remoteContainer,
                                       ds_remote_sel(process, "removeFromSuperview"), 0, YES);
    }
    ds_remote_set_u64_on_main(process, g_remoteWindow, "setHidden:", 1);
}

static BOOL ds_apply_remote_presentation(RemoteCall *process,
                                         const DSHUDPresentation *presentation,
                                         NSString *text,
                                         BOOL focused,
                                         BOOL applyStyle) {
    if (!process || !presentation || !g_remoteWindow || !g_remoteContainer ||
        !g_remoteBlurView || !g_remoteLabel) {
        return NO;
    }

    if (!CGRectEqualToRect(g_lastWindowFrame, presentation->windowFrame)) {
        ds_remote_set_rect_on_main(process, g_remoteWindow, "setFrame:",
                                   presentation->windowFrame);
        ds_remote_set_rect_on_main(process, g_remoteContainer, "setFrame:",
                                   presentation->blurFrame);
        ds_remote_set_rect_on_main(process, g_remoteBlurView, "setFrame:",
                                   presentation->blurFrame);
        if (g_remoteSecureField) {
            ds_remote_set_rect_on_main(process, g_remoteSecureField, "setFrame:",
                                       presentation->blurFrame);
        }
        g_lastWindowFrame = presentation->windowFrame;
    }
    if (!CGRectEqualToRect(g_lastLabelFrame, presentation->labelFrame)) {
        ds_remote_set_rect_on_main(process, g_remoteLabel, "setFrame:",
                                   presentation->labelFrame);
        g_lastLabelFrame = presentation->labelFrame;
    }

    BOOL hideForLandscape = presentation->landscape && !presentation->followsRotation;
    BOOL shouldHide = hideForLandscape;
    if (shouldHide != g_lastWindowHidden) {
        ds_remote_set_u64_on_main(process, g_remoteWindow, "setHidden:", shouldHide ? 1 : 0);
        g_lastWindowHidden = shouldHide;
    }
    if (applyStyle) {
        ds_remote_set_u64_on_main(process, g_remoteLabel, "setNumberOfLines:",
                                  (uint64_t)presentation->numberOfLines);
        ds_remote_set_u64_on_main(process, g_remoteLabel, "setTextAlignment:",
                                  (uint64_t)presentation->alignment);

        uint64_t colorClass = ds_remote_class(process, "UIColor");
        uint64_t white = colorClass
            ? ds_remote_get_object_on_main(process, colorClass, "whiteColor") : 0;
        uint64_t black = colorClass
            ? ds_remote_get_object_on_main(process, colorClass, "blackColor") : 0;
        uint64_t darkGray = colorClass
            ? ds_remote_get_object_on_main(process, colorClass, "darkGrayColor") : 0;
        uint64_t textColor = presentation->inverted ? black : white;
        uint64_t backgroundColor = presentation->inverted ? white : darkGray;
        if (presentation->transparentBackground) {
            backgroundColor = ds_remote_get_object_on_main(process, colorClass, "clearColor");
        }
        if (textColor && backgroundColor) {
            ds_perform_on_springboard_main(process, g_remoteLabel,
                                           ds_remote_sel(process, "setTextColor:"), textColor, YES);
            ds_perform_on_springboard_main(process, g_remoteBlurView,
                                           ds_remote_sel(process, "setBackgroundColor:"),
                                           backgroundColor, YES);
        }

        if (fabs(g_lastFontSize - presentation->fontSize) > 0.001 ||
            g_lastInverted != presentation->inverted || g_lastBold != presentation->bold) {
            uint64_t font = ds_remote_font(process, presentation->fontSize,
                                           presentation->inverted, presentation->bold);
            if (!font) return NO;
            ds_perform_on_springboard_main(process, g_remoteLabel,
                                           ds_remote_sel(process, "setFont:"), font, YES);
            g_lastFontSize = presentation->fontSize;
            g_lastInverted = presentation->inverted;
            g_lastBold = presentation->bold;
        }

        ds_remote_set_double_on_main(process, g_remoteLabel, "setAlpha:", presentation->transparentBackground ? 1.0 : 0.85);
        uint64_t attributes = presentation->transparentBackground
            ? ds_remote_stroke_attributes(process, presentation->inverted ? white : black,
                                          ds_remote_get_object_on_main(process, g_remoteLabel, "font"),
                                          textColor, presentation->bold) : 0;
        if (presentation->transparentBackground && !attributes) return NO;
        if (g_remoteTextAttributes) {
            remote_msg(process, g_remoteTextAttributes, ds_remote_sel(process, "release"), 0, 0, 0, 0);
        }
        g_remoteTextAttributes = attributes;
        if (!presentation->transparentBackground) {
            // 切回原样时清空 attributedText，防止 UILabel 沿用旧描边。
            ds_perform_on_springboard_main(process, g_remoteLabel,
                                           ds_remote_sel(process, "setAttributedText:"), 0, YES);
        }

        uint64_t layer = ds_remote_get_object_on_main(process, g_remoteBlurView, "layer");
        if (layer) {
            ds_remote_set_double_on_main(process, layer, "setCornerRadius:",
                                         presentation->cornerRadius);
            ds_remote_set_u64_on_main(process, layer, "setMaskedCorners:",
                                      (uint64_t)presentation->maskedCorners);
        }

        if (g_lastHideAtSnapshot != presentation->hideAtSnapshot) {
            ds_apply_snapshot_container(process, presentation->hideAtSnapshot);
        }
    }
    CGFloat alpha = focused ? 1.0 : presentation->inactiveOpacity;
    if (fabs(g_lastContainerAlpha - alpha) > 0.001) {
        ds_remote_set_double_on_main(process, g_remoteContainer, "setAlpha:", alpha);
        g_lastContainerAlpha = alpha;
    }

    if (!process.trojanMem) return NO;
    return ds_remote_set_text_on_main(process, g_remoteLabel, text, g_remoteTextAttributes);
}

static void ds_update_rate(void) {
    if (!g_hudRequested.load() || !g_hudActive.load() || !g_springBoard || !g_remoteLabel) return;

    uint64_t input = 0;
    uint64_t output = 0;
    ds_read_network_bytes(&input, &output);
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    double interval = g_previousSampleTime > 0 ? MAX(now - g_previousSampleTime, 0.1) : 1.0;
    double down = g_previousSampleTime > 0 && input >= g_previousInput ? (input - g_previousInput) / interval : 0;
    double up = g_previousSampleTime > 0 && output >= g_previousOutput ? (output - g_previousOutput) / interval : 0;
    g_previousInput = input;
    g_previousOutput = output;
    g_previousSampleTime = now;
    if (g_remoteOrientationObserver || g_remoteWindowScene) {
        uint64_t orientation = g_remoteOrientationObserver
            ? ds_remote_get_u64_on_main(g_springBoard, g_remoteOrientationObserver, "activeInterfaceOrientation")
            : UIInterfaceOrientationUnknown;
        if (orientation < UIInterfaceOrientationPortrait || orientation > UIInterfaceOrientationLandscapeRight) {
            orientation = ds_remote_get_u64_on_main(g_springBoard, g_remoteWindowScene, "interfaceOrientation");
        }
        if (orientation >= UIInterfaceOrientationPortrait && orientation <= UIInterfaceOrientationLandscapeRight) {
            g_remoteOrientation.store((int)orientation);
        }
    }

    NSDictionary *preferences = ds_hud_preferences();
    DSHUDPresentation probe = ds_hud_presentation(preferences, @"0");
    BOOL focused = now < g_focusUntil;
    NSString *text = ds_display_text(
        preferences, probe.centered, focused,
        focused ? (double)input : down,
        focused ? (double)output : up);
    DSHUDPresentation presentation = ds_hud_presentation(preferences, text);
    // 比较实际设置，避免字符串哈希碰撞导致单次点击不刷新样式。
    UIInterfaceOrientation orientation = ds_interface_orientation();
    BOOL applyStyle = ![preferences isEqualToDictionary:g_lastPresentationPreferences] ||
                      orientation != g_lastPresentationOrientation;

    @try {
        if (!ds_apply_remote_presentation(
                g_springBoard, &presentation, text, focused, applyStyle)) {
            @throw [NSException exceptionWithName:@"DSRemoteHUDUpdate"
                                           reason:@"remote presentation update failed"
                                         userInfo:nil];
        }
        g_lastPresentationPreferences = [preferences copy];
        g_lastPresentationOrientation = orientation;
    } @catch (NSException *exception) {
        ds_set_error([NSString stringWithFormat:@"SpringBoard HUD update failed: %@", exception.reason]);
        // 主动收尾：把半死的连接和它注入的线程一起清掉，避免留下会在任意时刻
        // 被调度执行的危险线程（那正是后续 SpringBoard 崩溃与整机 panic 的起点）。
        ds_teardown_failed_hud(exception.reason);
    }
}
static void ds_configure_rate_timer(NSDictionary *preferences) {
    if (!g_rateTimer) return;
    // 直接调整采样与绘制定时器，不保留每秒唤醒后跳过绘制的轮询。
    int64_t interval = (int64_t)(HUDRefreshInterval(preferences) * NSEC_PER_SEC);
    dispatch_source_set_timer(g_rateTimer, dispatch_time(DISPATCH_TIME_NOW, interval),
                              (uint64_t)interval, 100 * NSEC_PER_MSEC);
}

static void ds_start_rate_timer(void) {
    if (g_rateTimer) return;
    g_previousInput = 0;
    g_previousOutput = 0;
    g_previousSampleTime = 0;
    g_previousDirtyFrameCount = 0;
    g_needsFPSBaselineReset = YES;
    g_rateTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, ds_bridge_queue());
    ds_configure_rate_timer(ds_hud_preferences());
    dispatch_source_set_event_handler(g_rateTimer, ^{
        @autoreleasepool {
            ds_update_rate();
        }
    });
    dispatch_resume(g_rateTimer);
}

static void ds_stop_rate_timer(void) {
    if (!g_rateTimer) return;
    dispatch_source_cancel(g_rateTimer);
    g_rateTimer = nil;
}

static void ds_unregister_hud_notifications(void) {
    if (g_reloadHUDToken >= 0) {
        notify_cancel(g_reloadHUDToken);
        g_reloadHUDToken = -1;
    }
    if (g_lockStateToken >= 0) {
        notify_cancel(g_lockStateToken);
        g_lockStateToken = -1;
    }
}

static void ds_register_hud_notifications(void) {
    ds_unregister_hud_notifications();
    notify_register_dispatch(NOTIFY_RELOAD_HUD, &g_reloadHUDToken,
                             ds_bridge_queue(), ^(int token) {
        (void)token;
        if (!g_hudActive.load()) return;
        NSDictionary *preferences = ds_hud_preferences();
        // 「详细日志」开关按设置实时生效。
        ds_diag_configure(ds_pref_bool(preferences, HUDUserDefaultsKeyDetailedLogging));
        ds_configure_rate_timer(preferences);
        ds_append_checkpoint([NSString stringWithFormat:
            @"HUD settings refreshed position=%@ size=%@ snapshot=%@",
            preferences[UIInterfaceOrientationIsLandscape(ds_interface_orientation())
                ? HUDUserDefaultsKeySelectedModeLandscape
                : HUDUserDefaultsKeySelectedMode] ?: @"default",
            preferences[HUDUserDefaultsKeyUsesLargeFont] ?: @NO,
            preferences[HUDUserDefaultsKeyHideAtSnapshot] ?: @NO]);
        g_focusUntil = CFAbsoluteTimeGetCurrent() + kDSHUDFocusDuration;
        g_needsFPSBaselineReset = YES;
        ds_update_rate();
    });

    notify_register_dispatch("com.apple.springboard.lockstate", &g_lockStateToken,
                             ds_bridge_queue(), ^(int token) {
        (void)token;
        mach_port_t port = SBSSpringBoardServerPort();
        if (port == MACH_PORT_NULL) return;
        BOOL locked = NO;
        BOOL passcodeSet = NO;
        SBGetScreenLockStatus(port, &locked, &passcodeSet);
        (void)passcodeSet;
        if (!g_hudActive.load() || !g_springBoard || !g_remoteWindow) return;

        // Keep the SpringBoard-hosted HUD above CoverSheet while locked.
        // Reapply the level during the transition because SpringBoard may
        // reorder its own windows as the lock scene becomes active.
        ds_remote_set_double_on_main(g_springBoard, g_remoteWindow,
                                     "setWindowLevel:", kDSHUDWindowLevel);
        if (!locked) {
            g_previousInput = 0;
            g_previousOutput = 0;
            g_previousSampleTime = 0;
            g_needsFPSBaselineReset = YES;
            g_focusUntil = CFAbsoluteTimeGetCurrent() + kDSHUDFocusDuration;
        }
        g_lastWindowHidden = ds_remote_get_u64_on_main(g_springBoard, g_remoteWindow, "isHidden") != 0;
        ds_update_rate();
    });
}

BOOL DSBridgeCompiledIn(void) {
    return YES;
}

BOOL DSBridgeIsReady(void) {
    return g_dsReady.load() && ds_is_ready();
}

BOOL DSBridgeAdoptFromEnvironment(void) {
    int control = ds_env_int("DS_CTRL_FD", ds_env_int("DS_HELPER_CTRL_FD", -1));
    int readWrite = ds_env_int("DS_RW_FD", ds_env_int("DS_HELPER_RW_FD", -1));
    uint64_t kernelBase = ds_env_u64("DS_KBASE");
    if (!kernelBase) kernelBase = ds_env_u64("DS_HELPER_KBASE");
    uint64_t kernelSlide = ds_env_u64("DS_KSLIDE");
    if (!kernelSlide) kernelSlide = ds_env_u64("DS_HELPER_KSLIDE");
    if (control < 0 || readWrite < 0 || !kernelBase) return NO;

    const char *lock = getenv("DS_XPROC_LOCK");
    if (!lock || !lock[0]) lock = getenv("DS_HELPER_DOCS");
    if (lock && lock[0]) {
        NSString *path = @(lock);
        if (![path.pathExtension isEqualToString:@"lock"]) {
            path = [path stringByAppendingPathComponent:@".darksword-krw.lock"];
        }
        ds_set_xproc_lock_path(path.fileSystemRepresentation);
    }

    if (!ds_adopt_krw(control, readWrite, kernelBase, kernelSlide)) {
        ds_set_error(ds_localized(@"Could not adopt the DarkSpeed environment."));
        return NO;
    }

    init_offsets();
    offsets_init();
    install_builtin_kernel_symbol_offsets();
    if (!ds_has_symbol_offsets() && !emergencyfixfunctiontobereplacedlateronquestionmark()) {
        ds_set_error(ds_localized(@"DarkSpeed system data is unavailable."));
        return NO;
    }
    g_dsReady.store(true);
    ds_set_stage(ds_localized(@"DarkSpeed initialization complete"));
    ds_set_error(@"");
    os_log(OS_LOG_DEFAULT, "[DSBridge] adopted DarkSword KRW for SpringBoard HUD");
    return YES;
}

BOOL DSBridgeBootstrap(void) {
    if (DSBridgeIsReady()) return YES;
    if (DSBridgeAdoptFromEnvironment()) return YES;

    ds_set_log_callback(ds_bridge_log);
    ds_set_progress_callback(ds_bridge_progress);
    os_log(OS_LOG_DEFAULT, "[DSBridge] running DarkSword chain off-main-thread");

    // offsets_init() must run BEFORE ds_run() — pe_v1() needs the socket/inpcb
    // offsets to find the corrupted socket. Without this, the search runs with
    // all offsets = 0 and retries forever (stuck at ~50%).
    init_offsets();
    offsets_init();
    // Exact build-scoped symbol offsets must be available before ds_run():
    // its final self-proc lookup already needs kernproc/allproc.
    install_builtin_kernel_symbol_offsets();

    ds_set_stage(ds_localized(@"Initializing DarkSpeed"));
    int result = ds_run();
    if (result != 0 || !ds_is_ready()) {
        ds_set_error([NSString stringWithFormat:ds_localized(@"DarkSpeed initialization failed (%d)"), result]);
        return NO;
    }

    g_dsReady.store(true);
    ds_set_stage(ds_localized(@"DarkSpeed initialization complete"));
    ds_set_error(@"");
    os_log(OS_LOG_DEFAULT, "[DSBridge] DarkSword ready");
    return YES;
}

// 远端刷新失败后的主动收尾。
//
// 实测日志显示过这条模式：某次刷新报 "remote presentation update failed" 之后 HUD 再也
// 没恢复，但连接与那条被注入的线程仍然留在 SpringBoard 里；此后才出现标记地址崩溃，
// 进而 SpringBoard 挂掉、watchdog 整机 panic。
//
// 与其把一条半死的连接留着，不如在这里主动销毁它：destroyRemoteCall 会终止被注入的
// 线程并回收远端窗口，下一次启用会重新建立一条干净的连接。代价是悬浮窗关闭（用户可
// 再开），换来的是不再留下可能在任意时刻被调度执行的危险线程。
static void ds_teardown_failed_hud(NSString *reason) {
    ds_append_checkpoint([NSString stringWithFormat:
        @"tearing down HUD after failure: %@", reason ?: @"?"]);
    ds_unregister_hud_notifications();
    ds_stop_rate_timer();
    g_hudActive.store(false);
    g_hudRequested.store(false);

    RemoteCall *process = g_springBoard;
    g_springBoard = nil;
    if (process) {
        @try {
            [process destroyRemoteCall];
        } @catch (NSException *exception) {
            os_log_error(OS_LOG_DEFAULT, "[DSBridge] teardown destroyRemoteCall exception: %{public}@",
                         exception.reason);
        }
    }
    g_remoteContainer = 0;
    g_remoteBlurView = 0;
    g_remoteLabel = 0;
    g_remoteTextAttributes = 0;
    g_remoteSecureField = 0;
    g_remoteSecureCanvas = 0;
    g_remoteWindow = 0;
    g_remoteWindowScene = 0;
    g_remoteOrientationObserver = 0;
    g_remoteWindowPid = 0;
    g_lastPresentationPreferences = nil;
    ds_reset_remote_symbol_cache();
    ds_stop_keepalive();
    ds_set_stage(ds_localized(@"HUD closed"));
    notify_post(NOTIFY_RELOAD_APP);
    ds_append_checkpoint(@"HUD torn down; re-enable to build a fresh connection");
}

static void ds_finish_disable(void) {
    ds_set_stage(ds_localized(@"Closing HUD"));
    ds_unregister_hud_notifications();
    ds_stop_rate_timer();
    RemoteCall *process = g_springBoard;
    g_springBoard = nil;
    g_hudActive.store(false);
    if (process) {
        @try {
            ds_remove_springboard_hud(process);
        } @catch (NSException *exception) {
            os_log_error(OS_LOG_DEFAULT, "[DSBridge] HUD remove exception: %{public}@", exception.reason);
        }
        @try {
            [process destroyRemoteCall];
        } @catch (NSException *exception) {
            os_log_error(OS_LOG_DEFAULT, "[DSBridge] destroyRemoteCall exception: %{public}@", exception.reason);
        }
    }
    g_remoteContainer = 0;
    g_remoteBlurView = 0;
    g_remoteBlurEffect = 0;
    g_remoteLabel = 0;
    g_remoteTextAttributes = 0;
    g_remoteSecureField = 0;
    g_remoteSecureCanvas = 0;
    g_remoteWindow = 0;
    g_remoteWindowScene = 0;
    g_remoteOrientationObserver = 0;
    g_remoteWindowPid = 0;
    g_remoteOrientation.store(UIInterfaceOrientationUnknown);
    g_lastPresentationPreferences = nil;
    g_lastPresentationOrientation = UIInterfaceOrientationUnknown;
    g_lastWindowFrame = CGRectNull;
    g_lastLabelFrame = CGRectNull;
    g_lastWindowHidden = NO;
    g_lastContainerAlpha = -1.0;
    g_lastFontSize = -1.0;
    g_lastInverted = NO;
    g_lastBold = NO;
    g_lastHideAtSnapshot = NO;
    ds_reset_remote_symbol_cache();
    ds_stop_keepalive();
    ds_set_stage(ds_localized(@"HUD closed"));
    notify_post(NOTIFY_RELOAD_APP);
    os_log(OS_LOG_DEFAULT, "[DSBridge] SpringBoard HUD disabled");
}

static void ds_finish_enable(void) {
    if (!g_hudRequested.load()) return;
    // 按设置决定是否记录诊断日志（默认关闭）。
    (void)ds_log_directory();
    ds_diag_configure(ds_pref_bool(ds_hud_preferences(), HUDUserDefaultsKeyDetailedLogging));
    g_dsRunning.store(true);
    g_dsProgress.store(0.0);
    ds_set_stage(ds_localized(@"Preparing startup"));
    ds_post_progress();

    if (!ds_start_keepalive()) {
        g_hudRequested.store(false);
        g_dsRunning.store(false);
        ds_post_progress();
        return;
    }

    g_dsProgress.store(0.03);
    ds_set_stage(ds_localized(@"Preparing system data"));
    ds_post_progress();
    if (!ds_wait_for_kernel_prefetch(240.0, YES)) {
        NSString *preparationError = DSBridgeLastError();
        ds_fail_enable(preparationError.length > 0 ? preparationError :
            ds_localized(@"Kernelcache download or parsing failed. Network access may still be pending. Check network access and retry; if it still fails, reinstall over the existing app. Restart the device only as a last resort."));
        return;
    }

    if (!DSBridgeBootstrap() || !g_hudRequested.load()) {
        ds_fail_enable(ds_localized(@"DarkSpeed startup failed. Retry or reinstall over the existing app; restart the device only as a last resort."));
        return;
    }

    g_dsProgress.store(0.96);
    ds_set_stage(ds_localized(@"Locating SpringBoard"));
    ds_post_progress();
    uint64_t sbProc = proc_find_by_name("SpringBoard");
    if (!sbProc) {
        ds_fail_enable(ds_localized(@"SpringBoard is not ready, so the HUD cannot be created. Retry or reinstall over the existing app; restart the device only as a last resort."));
        return;
    }

    @try {
        // 防抖：实测日志里出现过间隔仅 1 秒的连续开关。每次启用都会重跑整条越狱链
        // 并向 SpringBoard 注入新线程，快速反复触发只会不断累积风险，因此给一个冷却窗。
        static CFAbsoluteTime s_lastRemoteAttempt = 0;
        CFAbsoluteTime attemptNow = CFAbsoluteTimeGetCurrent();
        const CFTimeInterval kDSRemoteAttemptCooldown = 5.0;
        if (s_lastRemoteAttempt > 0 && attemptNow - s_lastRemoteAttempt < kDSRemoteAttemptCooldown) {
            ds_append_checkpoint([NSString stringWithFormat:
                @"enable attempt ignored: only %.1fs since the previous attempt (cooldown %.0fs)",
                attemptNow - s_lastRemoteAttempt, kDSRemoteAttemptCooldown]);
            g_hudRequested.store(false);
            ds_fail_enable(ds_localized(@"Please wait a few seconds before enabling the HUD again."));
            return;
        }
        s_lastRemoteAttempt = attemptNow;

        os_log(OS_LOG_DEFAULT, "[DSBridge] SpringBoard proc=0x%llx self=0x%llx — starting RemoteCall",
               (unsigned long long)sbProc, (unsigned long long)ds_get_our_proc());
        g_dsProgress.store(0.98);
        ds_set_stage(ds_localized(@"Connecting to SpringBoard"));
        ds_reset_remote_symbol_cache();
        g_springBoard = [[RemoteCall alloc] initWithProcess:@"SpringBoard" useMigFilterBypass:NO];
        if (!g_springBoard || !g_springBoard.trojanMem || g_springBoard.pid <= 1) {
            NSString *remoteError = [RemoteCall lastInitError];
            if (remoteError.length == 0 && g_springBoard) remoteError = g_springBoard.lastError;
            if (remoteError.length == 0) remoteError = @"RemoteCall init failed (no detail)";
            ds_append_checkpoint([ds_localized(@"SpringBoard connection failed: ") stringByAppendingString:remoteError]);
            // 初始化即使失败，也可能已经向 SpringBoard 注入过线程。必须显式销毁，
            // 否则那条线程会被留在标记地址上成为孤儿：反复重试会不断累积，
            // 最终被内核调度时杀死 SpringBoard。
            if (g_springBoard) {
                @try {
                    [g_springBoard destroyRemoteCall];
                } @catch (__unused NSException *exception) {
                }
            }
            g_springBoard = nil;
            ds_fail_enable([NSString stringWithFormat:
                ds_localized(@"SpringBoard connection failed: %@\nRetry or reinstall over the existing app; restart the device only as a last resort."),
                remoteError]);
            return;
        }

        g_dsProgress.store(0.99);
        ds_set_stage(ds_localized(@"Creating SpringBoard HUD"));
        g_remoteLabel = ds_create_springboard_hud(g_springBoard);
        if (!g_remoteLabel) {
            [g_springBoard destroyRemoteCall];
            g_springBoard = nil;
            ds_fail_enable(ds_localized(@"SpringBoard HUD creation failed. Retry or reinstall over the existing app; restart the device only as a last resort."));
            return;
        }
    } @catch (NSException *exception) {
        // 同上：异常路径也必须销毁连接，避免留下孤儿线程。
        if (g_springBoard) {
            @try {
                [g_springBoard destroyRemoteCall];
            } @catch (__unused NSException *inner) {
            }
        }
        g_springBoard = nil;
        ds_fail_enable([NSString stringWithFormat:
            ds_localized(@"SpringBoard HUD exception: %@\nRetry or reinstall over the existing app; restart the device only as a last resort."),
            exception.reason]);
        return;
    }

    g_hudActive.store(true);
    g_dsRunning.store(false);
    g_dsProgress.store(1.0);
    ds_set_stage(ds_localized(@"SpringBoard HUD started"));
    ds_set_error(@"");
    ds_start_rate_timer();
    ds_register_hud_notifications();
    notify_post(NOTIFY_LAUNCHED_HUD);
    ds_post_progress();
    os_log(OS_LOG_DEFAULT, "[DSBridge] SpringBoard HUD active (SpringBoard pid=%d)", g_springBoard.pid);
}

BOOL DSBridgeSetHUDEnabled(BOOL enabled) {
    g_hudRequested.store(enabled);
    dispatch_async(ds_bridge_queue(), ^{
        @autoreleasepool {
            if (enabled) {
                if (!g_hudRequested.load() || g_hudActive.load()) return;
                ds_finish_enable();
            } else {
                ds_finish_disable();
            }
        }
    });
    return YES;
}

BOOL DSBridgeHUDEnabled(void) {
    return g_hudActive.load();
}

double DSBridgeProgress(void) {
    return g_dsProgress.load();
}

BOOL DSBridgeIsRunning(void) {
    return g_dsRunning.load();
}

#else

BOOL DSBridgeCompiledIn(void) { return NO; }
BOOL DSBridgeIsReady(void) { return NO; }
void DSBridgeWarmUpNetworkAndPrefetchKernelCache(void) {}
BOOL DSBridgeAdoptFromEnvironment(void) {
    ds_set_error(ds_localized(@"DarkSpeed is not enabled in this build."));
    return NO;
}
BOOL DSBridgeBootstrap(void) {
    ds_set_error(ds_localized(@"DarkSpeed is not enabled in this build."));
    return NO;
}
BOOL DSBridgeSetHUDEnabled(BOOL enabled) {
    (void)enabled;
    return NO;
}
BOOL DSBridgeHUDEnabled(void) { return NO; }
double DSBridgeProgress(void) { return 0.0; }
BOOL DSBridgeIsRunning(void) { return NO; }

#endif

NSString *DSBridgeLastError(void) {
    os_unfair_lock_lock(&g_errorLock);
    NSString *error = [g_dsLastError copy] ?: @"";
    os_unfair_lock_unlock(&g_errorLock);
    return error;
}

NSString *DSBridgeStage(void) {
    os_unfair_lock_lock(&g_errorLock);
    NSString *stage = [g_dsStage copy] ?: @"";
    os_unfair_lock_unlock(&g_errorLock);
    return [stage isEqualToString:@"Waiting to start"] ? ds_localized(@"Waiting to start") : stage;
}
