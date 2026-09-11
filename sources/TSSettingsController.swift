//
//  TSSettingsController.swift
//  TrollSpeed
//
//  Created by Lessica on 2024/1/24.
//

import UIKit

@objc public protocol TSSettingsControllerDelegate {
    func displayMode() -> HUDDisplayMode
    func hudFontSize() -> Double
    func setHUDFontSize(_ size: Double)
    func settingHighlighted(key: String) -> Bool
    func settingDidSelect(key: String) -> Void
}

@objc open class TSSettingsController : SPLarkSettingsController
{
    @objc open weak var delegate: TSSettingsControllerDelegate?
    @objc open var alreadyLaunched: Bool = false
    internal var restartRequired = false

    open override func settingsCount() -> Int {
        return TSSettingsIndex.allCases.count
    }

    open override func settingTitle(index: Int, highlighted: Bool) -> String {
        return TSSettingsIndex.allCases[index].title
    }

    open override func settingSubtitle(index: Int, highlighted: Bool) -> String? {
        return TSSettingsIndex.allCases[index].subtitle(highlighted: highlighted, restartRequired: restartRequired, displayMode: delegate?.displayMode() ?? .speed, fontSize: delegate?.hudFontSize() ?? 9)
    }

    private func settingKey(index: Int) -> String {
        return TSSettingsIndex.allCases[index].key
    }

    open override func settingHighlighted(index: Int) -> Bool {
        return delegate?.settingHighlighted(key: settingKey(index: index)) ?? false
    }

    private var isSpeedMode: Bool {
        return (delegate?.displayMode() ?? .speed) == .speed
    }

    open override func settingEnabled(index: Int) -> Bool {
        guard !isSpeedMode else { return true }
        let setting = TSSettingsIndex.allCases[index]
        switch setting {
        case .singleLineMode, .usesArrowPrefixes, .usesBitrate:
            return false
        default:
            return true
        }
    }

    open override func settingColorHighlighted(index: Int) -> UIColor {
        return UIColor { traitCollection in
            if traitCollection.userInterfaceStyle == .dark {
                return UIColor(red: 28/255.0, green: 74/255.0, blue: 82/255.0, alpha: 1.0)
            } else {
                return UIColor(red: 22/255.0, green: 160/255.0, blue: 133/255.0, alpha: 1.0)
            }
        }
    }

    open override func settingDidSelect(index: Int, completion: @escaping () -> ()) {
        if index == TSSettingsIndex.usesLargeFont.rawValue {
            let currentSize = delegate?.hudFontSize() ?? 9
            let picker = UIAlertController(title: NSLocalizedString("Font Size", comment: ""),
                                          message: nil, preferredStyle: .actionSheet)
            for size in 8...24 {
                let label = String(format: NSLocalizedString("%g pt", comment: ""), Double(size))
                let title = abs(currentSize - Double(size)) < 0.01 ? "✓ " + label : label
                picker.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                    self?.delegate?.setHUDFontSize(Double(size))
                    completion()
                })
            }
            picker.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel))
            if let popover = picker.popoverPresentationController {
                popover.sourceView = collectionView
                popover.sourceRect = collectionView.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame ?? collectionView.bounds
            }
            present(picker, animated: true)
            return
        }
        if index == TSSettingsIndex.passthroughMode.rawValue && alreadyLaunched && !DSBridgeCompiledIn() {
            restartRequired = true
        }
        delegate?.settingDidSelect(key: settingKey(index: index))
        completion()

        // When display mode is toggled, update enabled/disabled state of affected cells in-place
        if index == TSSettingsIndex.displayMode.rawValue {
            for cell in collectionView.visibleCells {
                if let settingCell = cell as? SPLarkSettingsCollectionViewCell,
                   let indexPath = collectionView.indexPath(for: settingCell) {
                    settingCell.setEnabled(settingEnabled(index: indexPath.row))
                }
            }
        }
    }

    open override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        guard let currentOrientation = view.window?.windowScene?.interfaceOrientation else {
            return [.portrait]
        }
        switch currentOrientation {
        case .unknown: fallthrough
        case .portrait:
            return [.portrait]
        case .portraitUpsideDown:
            return [.portraitUpsideDown]
        case .landscapeLeft:
            return [.landscapeLeft]
        case .landscapeRight:
            return [.landscapeRight]
        @unknown default:
            return [.portrait]
        }
    }

    open override var shouldAutorotate: Bool { false }

    open override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.userInterfaceStyle != self.traitCollection.userInterfaceStyle {
            self.dismiss(animated: true, completion: nil)
        }
    }
}
