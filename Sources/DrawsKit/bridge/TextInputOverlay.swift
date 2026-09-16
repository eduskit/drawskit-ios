import UIKit

final class TextInputOverlay: NSObject {
    private let textView: UITextView
    private var destroyed = false
    private var allowBlurCommit = false

    init(
        boardContainer: UIView,
        canvasView: DrawsKitView,
        screenX: CGFloat,
        screenY: CGFloat,
        initialValue: String,
        textColor: String,
        textSize: Int,
        textStyle: Int,
        fontFamily: String,
        lineHeight: Float,
        scalePercent: Int,
        editing: Bool,
        fontSizePx: Float?,
        boldOverride: Bool?,
        italicOverride: Bool?,
        onCommit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        textView = UITextView()
        super.init()
        let worldFontSize = fontSizePx ?? TextMap.textSizeToFontSize(textSize)
        let scale = CGFloat(scalePercent) / 100
        let screenFontSize = CGFloat(worldFontSize) * scale
        let (bold, italic) = TextMap.textStyleFlags(textStyle)
        let isBold = boldOverride ?? bold
        let isItalic = italicOverride ?? italic

        textView.text = initialValue
        textView.textColor = Self.parseColor(textColor)
        textView.font = Self.resolveFont(
            family: fontFamily,
            size: screenFontSize,
            bold: isBold,
            italic: isItalic
        )
        textView.backgroundColor = editing ? EngineDefaults.textEditBgColor : .clear
        textView.isScrollEnabled = false
        textView.textContainerInset = UIEdgeInsets(top: 2, left: 4, bottom: 2, right: 4)
        textView.translatesAutoresizingMaskIntoConstraints = false

        boardContainer.addSubview(textView)
        let minW = max(EngineDefaults.textEditMinWidth, EngineDefaults.textEditBaseWidth * scale)
        let minH = max(
            screenFontSize * CGFloat(lineHeight) * EngineDefaults.textEditMinHeightFactor,
            EngineDefaults.textEditMinHeightBase * scale
        )
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: canvasView.leadingAnchor, constant: max(screenX, 0)),
            textView.topAnchor.constraint(equalTo: canvasView.topAnchor, constant: max(screenY, 0)),
            textView.widthAnchor.constraint(greaterThanOrEqualToConstant: minW),
            textView.heightAnchor.constraint(greaterThanOrEqualToConstant: minH),
        ])

        textView.becomeFirstResponder()
        if let end = textView.position(from: textView.endOfDocument, offset: 0) {
            textView.selectedTextRange = textView.textRange(from: end, to: end)
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onEndEditing),
            name: UITextView.textDidEndEditingNotification,
            object: textView
        )

        DispatchQueue.main.async { [weak self] in
            self?.allowBlurCommit = true
        }

        self.onCommit = onCommit
        self.onCancel = onCancel
    }

    private var onCommit: (String) -> Void = { _ in }
    private var onCancel: () -> Void = {}

    func destroy() {
        guard !destroyed else { return }
        destroyed = true
        NotificationCenter.default.removeObserver(self)
        textView.removeFromSuperview()
    }

    @objc private func onEndEditing() {
        guard allowBlurCommit, !destroyed else { return }
        commit()
    }

    private func commit() {
        guard !destroyed else { return }
        let value = textView.text ?? ""
        destroy()
        onCommit(value)
    }

    private static func parseColor(_ hex: String) -> UIColor {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6 || value.count == 8, let raw = UInt64(value, radix: 16) else { return .black }
        if value.count == 6 {
            return UIColor(
                red: CGFloat((raw >> 16) & 0xFF) / 255,
                green: CGFloat((raw >> 8) & 0xFF) / 255,
                blue: CGFloat(raw & 0xFF) / 255,
                alpha: 1
            )
        }
        return UIColor(
            red: CGFloat((raw >> 24) & 0xFF) / 255,
            green: CGFloat((raw >> 16) & 0xFF) / 255,
            blue: CGFloat((raw >> 8) & 0xFF) / 255,
            alpha: CGFloat(raw & 0xFF) / 255
        )
    }

    private static func resolveFont(family: String, size: CGFloat, bold: Bool, italic: Bool) -> UIFont {
        let base: UIFont
        switch family {
        case "serif": base = UIFont(name: "Times New Roman", size: size) ?? .systemFont(ofSize: size)
        case "monospace": base = UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        default: base = .systemFont(ofSize: size)
        }
        if bold && italic {
            return UIFont(descriptor: base.fontDescriptor.withSymbolicTraits([.traitBold, .traitItalic]) ?? base.fontDescriptor, size: size)
        }
        if bold { return UIFont.boldSystemFont(ofSize: size) }
        if italic { return UIFont.italicSystemFont(ofSize: size) }
        return base
    }
}
