//
//  HUDBackdropLabel.h
//  TrollSpeed
//
//  Created by Lessica on 2024/1/24.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface HUDBackdropLabel : UILabel
@property (nonatomic) CGFloat outlineInset;
- (void)setColorInvertEnabled:(BOOL)colorInvertEnabled;
@end

NS_ASSUME_NONNULL_END
