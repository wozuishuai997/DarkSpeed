//
//  hudapp-bridging-header.h
//  TrollSpeed
//
//  Created by Lessica on 2024/1/25.
//

#ifndef hudapp_bridging_header_h
#define hudapp_bridging_header_h

#import <Foundation/Foundation.h>

#import "HUDHelper.h"
#import "DSBridge.h"

typedef NSString * HUDUserDefaultsKey;

// 保留原来布尔设置的 0/1 含义，时间模式追加为 2。
typedef NS_ENUM(NSInteger, HUDDisplayMode) {
    HUDDisplayModeSpeed = 0,
    HUDDisplayModeFPS NS_SWIFT_NAME(fps) = 1,
    HUDDisplayModeTime = 2,
    HUDDisplayModeTimeSeconds = 3,
};

static HUDUserDefaultsKey const HUDUserDefaultsKeySelectedMode = @"selectedMode";
static HUDUserDefaultsKey const HUDUserDefaultsKeySelectedModeLandscape = @"selectedModeLandscape";
static HUDUserDefaultsKey const HUDUserDefaultsKeyCurrentPositionY = @"currentPositionY";
static HUDUserDefaultsKey const HUDUserDefaultsKeyCurrentLandscapePositionY = @"currentLandscapePositionY";
static HUDUserDefaultsKey const HUDUserDefaultsKeyPassthroughMode = @"passthroughMode";
static HUDUserDefaultsKey const HUDUserDefaultsKeySingleLineMode = @"singleLineMode";
static HUDUserDefaultsKey const HUDUserDefaultsKeyUsesBitrate = @"usesBitrate";
static HUDUserDefaultsKey const HUDUserDefaultsKeyUsesArrowPrefixes = @"usesArrowPrefixes";
static HUDUserDefaultsKey const HUDUserDefaultsKeyUsesLargeFont = @"usesLargeFont";
static HUDUserDefaultsKey const HUDUserDefaultsKeyUsesRotation = @"usesRotation";
static HUDUserDefaultsKey const HUDUserDefaultsKeyUsesInvertedColor = @"usesInvertedColor";
static HUDUserDefaultsKey const HUDUserDefaultsKeyKeepInPlace = @"keepInPlace";
static HUDUserDefaultsKey const HUDUserDefaultsKeyHideAtSnapshot = @"hideAtSnapshot";
static HUDUserDefaultsKey const HUDUserDefaultsKeyDisplayMode = @"displayMode";
static HUDUserDefaultsKey const HUDUserDefaultsKeyUsesBoldFont = @"usesBoldFont";
static HUDUserDefaultsKey const HUDUserDefaultsKeyTransparentBackground = @"transparentBackground";
static HUDUserDefaultsKey const HUDUserDefaultsKeyHorizontalOffset = @"horizontalOffset";
static HUDUserDefaultsKey const HUDUserDefaultsKeyRefreshInterval = @"refreshInterval";
// 详细日志开关。默认关闭：只在需要排查时打开，避免常态写盘。
static HUDUserDefaultsKey const HUDUserDefaultsKeyDetailedLogging = @"detailedLogging";

static inline double HUDRefreshInterval(NSDictionary *preferences) {
    NSNumber *interval = preferences[HUDUserDefaultsKeyRefreshInterval];
    return interval ? MIN(MAX(interval.doubleValue, 1.0), 60.0) : 1.0;
}


// NSStrokeWidthAttributeName 的负值表示"同时绘制填充与描边"，单位是**字号百分比**。
//
// 这个值会沿轮廓把字形向外扩张；逐字描边时相邻字形的轮廓会互相侵入 —— 等宽数字的
// 字距本来就很紧，过大就会糊在一起（9 与 2 相接处即如此）。因此取足够小的值：
// 1% 在 24 号字上约 0.24pt，仍能提供对比度，但对字距的侵占显著减小。
// 需要更强对比时应调整描边颜色或背景，而不是加大这个值。
static inline int HUDTextOutlineStrokeWidth(BOOL bold) {
    return bold ? -2 : -1;
}

static HUDUserDefaultsKey const HUDUserDefaultsKeyUsesCustomFontSize = @"usesCustomFontSize";
static HUDUserDefaultsKey const HUDUserDefaultsKeyRealCustomFontSize = @"realCustomFontSize";
static HUDUserDefaultsKey const HUDUserDefaultsKeyUsesCustomOffset = @"usesCustomOffset";
static HUDUserDefaultsKey const HUDUserDefaultsKeyRealCustomOffsetX = @"realCustomOffsetX";
static HUDUserDefaultsKey const HUDUserDefaultsKeyRealCustomOffsetY = @"realCustomOffsetY";

#endif /* hudapp_bridging_header_h */
