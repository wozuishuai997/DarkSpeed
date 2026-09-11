//
//  HUDPresetPosition.h
//  TrollSpeed
//
//  Created by Lessica on 2024/1/24.
//

#import <Foundation/Foundation.h>

#ifndef __HUD_POSITION__
#define __HUD_POSITION__
typedef NS_ENUM(NSInteger, HUDPresetPosition) {
    HUDPresetPositionTopLeft = 0,
    HUDPresetPositionTopCenter,
    HUDPresetPositionTopRight,
    HUDPresetPositionTopCenterMost,
    // 追加位置，避免改变用户已保存的左、中、右及中间顶部设置。
    HUDPresetPositionTopLeftMost,
    HUDPresetPositionTopRightMost,
};
#endif /* __HUD_POSITION__ */
