//
//  TSSettingsController.swift
//  TrollSpeed
//
//  Created by Lessica on 2024/1/24.
//

import UIKit

@objc public protocol TSSettingsControllerDelegate {
    func displayMode() -> HUDDisplayMode
    func hudHorizontalOffset() -> Double
    func setHUDHorizontalOffset(_ offset: Double)
    func hudRefreshInterval() -> Double
    func setHUDRefreshInterval(_ interval: Double)
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
        return TSSettingsIndex.allCases[index].subtitle(highlighted: highlighted, restartRequired: restartRequired, displayMode: delegate?.displayMode() ?? .speed, fontSize: delegate?.hudFontSize() ?? 9, horizontalOffset: delegate?.hudHorizontalOffset() ?? 0, refreshInterval: delegate?.hudRefreshInterval() ?? 1)
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
        if DSBridgeCompiledIn(), index == TSSettingsIndex.usesInvertedColor.rawValue,
           delegate?.settingHighlighted(key: HUDUserDefaultsKeyTransparentBackground) == true {
            return false
        }
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
        if index == TSSettingsIndex.horizontalOffset.rawValue {
            let picker = UIAlertController(title: NSLocalizedString("Horizontal Offset", comment: ""),
                                          message: NSLocalizedString("−100 to +100. Negative moves left; positive moves right.", comment: ""),
                                          preferredStyle: .alert)
            picker.addTextField { field in
                field.keyboardType = .numbersAndPunctuation
                field.text = String(format: "%g", self.delegate?.hudHorizontalOffset() ?? 0)
            }
            let parsedOffset: () -> Double? = { [weak picker] in
                guard let text = picker?.textFields?.first?.text,
                      let value = Double(text.trimmingCharacters(in: .whitespaces)),
                      value.isFinite, (-100...100).contains(value) else { return nil }
                return value
            }
            let save = UIAlertAction(title: NSLocalizedString("Apply", comment: ""), style: .default) { [weak self] _ in
                guard let value = parsedOffset() else { return }
                self?.delegate?.setHUDHorizontalOffset(value)
                completion()
            }
            picker.textFields?.first?.addAction(UIAction { _ in
                save.isEnabled = parsedOffset() != nil
            }, for: .editingChanged)
            picker.addAction(save)
            picker.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel))
            present(picker, animated: true)
            return
        }
        if index == TSSettingsIndex.refreshInterval.rawValue {
            let current = delegate?.hudRefreshInterval() ?? 1
            let picker = UIAlertController(title: NSLocalizedString("Refresh Interval", comment: ""),
                                          message: NSLocalizedString("Controls automatic updates. Settings and lock changes still update immediately.", comment: ""),
                                          preferredStyle: .actionSheet)
            for interval in [1, 2, 3, 5, 10, 15, 30, 60] {
                let label = String(format: NSLocalizedString("Every %g seconds", comment: ""), Double(interval))
                let title = current == Double(interval) ? "✓ " + label : label
                picker.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                    self?.delegate?.setHUDRefreshInterval(Double(interval))
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
        if index == TSSettingsIndex.displayMode.rawValue || index == TSSettingsIndex.transparentBackground.rawValue {
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
