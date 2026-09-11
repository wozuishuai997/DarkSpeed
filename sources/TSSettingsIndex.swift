//
//  TSSettingsIndex.swift
//  TrollSpeed
//
//  Created by Lessica on 2024/1/25.
//

import Foundation

enum TSSettingsIndex: Int, CaseIterable {
    case displayMode = 0
    case passthroughMode
    case keepInPlace
    case hideAtSnapshot
    case singleLineMode
    case usesInvertedColor
    case usesRotation
    case usesLargeFont
    case usesArrowPrefixes
    case usesBitrate
    case usesBoldFont
    case transparentBackground
    case horizontalOffset
    case refreshInterval

    var key: String {
        switch self {
        case .displayMode:
            return HUDUserDefaultsKeyDisplayMode
        case .passthroughMode:
            return HUDUserDefaultsKeyPassthroughMode
        case .keepInPlace:
            return HUDUserDefaultsKeyKeepInPlace
        case .hideAtSnapshot:
            return HUDUserDefaultsKeyHideAtSnapshot
        case .singleLineMode:
            return HUDUserDefaultsKeySingleLineMode
        case .usesInvertedColor:
            return HUDUserDefaultsKeyUsesInvertedColor
        case .usesRotation:
            return HUDUserDefaultsKeyUsesRotation
        case .usesLargeFont:
            return HUDUserDefaultsKeyUsesLargeFont
        case .usesArrowPrefixes:
            return HUDUserDefaultsKeyUsesArrowPrefixes
        case .usesBitrate:
            return HUDUserDefaultsKeyUsesBitrate
        case .usesBoldFont:
            return HUDUserDefaultsKeyUsesBoldFont
        case .horizontalOffset:
            return HUDUserDefaultsKeyHorizontalOffset
        case .refreshInterval:
            return HUDUserDefaultsKeyRefreshInterval
        case .transparentBackground:
            return HUDUserDefaultsKeyTransparentBackground
        }
    }

    var title: String {
        switch self {
        case .displayMode:
            return NSLocalizedString("Display Mode", comment: "TSSettingsIndex")
        case .passthroughMode:
            return NSLocalizedString("Pass-through", comment: "TSSettingsIndex")
        case .keepInPlace:
            return NSLocalizedString("Keep In-place", comment: "TSSettingsIndex")
        case .hideAtSnapshot:
            return NSLocalizedString("Hide @snapshot", comment: "TSSettingsIndex")
        case .singleLineMode:
            return NSLocalizedString("Incoming Only", comment: "TSSettingsIndex")
        case .usesInvertedColor:
            return NSLocalizedString("Appearance", comment: "TSSettingsIndex")
        case .usesRotation:
            return NSLocalizedString("Landscape", comment: "TSSettingsIndex")
        case .usesLargeFont:
            return NSLocalizedString("Font Size", comment: "TSSettingsIndex")
        case .usesArrowPrefixes:
            return NSLocalizedString("Prefixes", comment: "TSSettingsIndex")
        case .usesBitrate:
            return NSLocalizedString("Unit", comment: "TSSettingsIndex")
        case .usesBoldFont:
            return NSLocalizedString("Bold Text", comment: "TSSettingsIndex")
        case .horizontalOffset:
            return NSLocalizedString("Horizontal Offset", comment: "TSSettingsIndex")
        case .refreshInterval:
            return NSLocalizedString("Refresh Interval", comment: "TSSettingsIndex")
        case .transparentBackground:
            return NSLocalizedString("Background", comment: "TSSettingsIndex")
        }
    }

    func subtitle(highlighted: Bool, restartRequired: Bool, displayMode: HUDDisplayMode, fontSize: Double, horizontalOffset: Double, refreshInterval: Double) -> String {
        switch self {
        case .displayMode:
            switch displayMode {
            case .timeSeconds:
                return NSLocalizedString("Time (Seconds)", comment: "TSSettingsIndex")
            case .time:
                return NSLocalizedString("Time", comment: "TSSettingsIndex")
            case .fps:
                return NSLocalizedString("FPS", comment: "TSSettingsIndex")
            default:
                return NSLocalizedString("Speed", comment: "TSSettingsIndex")
            }
        case .passthroughMode:
            if restartRequired {
                return NSLocalizedString("Re-open to apply", comment: "TSSettingsIndex")
            } else {
                return highlighted ? NSLocalizedString("ON", comment: "TSSettingsIndex") : NSLocalizedString("OFF", comment: "TSSettingsIndex")
            }
        case .keepInPlace: fallthrough
        case .hideAtSnapshot: fallthrough
        case .usesBoldFont: fallthrough
        case .singleLineMode:
            return highlighted ? NSLocalizedString("ON", comment: "TSSettingsIndex") : NSLocalizedString("OFF", comment: "TSSettingsIndex")
        case .usesInvertedColor:
            return highlighted ? NSLocalizedString("Inverted", comment: "TSSettingsIndex") : NSLocalizedString("Classic", comment: "TSSettingsIndex")
        case .usesRotation:
            return highlighted ? NSLocalizedString("Follow", comment: "TSSettingsIndex") : NSLocalizedString("Hide", comment: "TSSettingsIndex")
        case .usesLargeFont:
            return String(format: NSLocalizedString("%g pt", comment: "TSSettingsIndex"), fontSize)
        case .usesArrowPrefixes:
            return highlighted ? NSLocalizedString("↑↓", comment: "TSSettingsIndex") : NSLocalizedString("▲▼", comment: "TSSettingsIndex")
        case .usesBitrate:
            return highlighted ? NSLocalizedString("b/s", comment: "TSSettingsIndex") : NSLocalizedString("B/s", comment: "TSSettingsIndex")
        case .horizontalOffset:
            return String(format: NSLocalizedString("%+g pt", comment: "TSSettingsIndex"), horizontalOffset)
        case .refreshInterval:
            return String(format: NSLocalizedString("Every %g seconds", comment: "TSSettingsIndex"), refreshInterval)
        case .transparentBackground:
            return highlighted ? NSLocalizedString(DSBridgeCompiledIn() ? "Transparent (System)" : "Transparent", comment: "TSSettingsIndex") : NSLocalizedString("Original", comment: "TSSettingsIndex")
        }
    }
}
