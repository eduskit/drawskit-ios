import UIKit

/// Full-board error mask when cloud/local bootstrap fails (avoids a silent white canvas).
final class BootstrapErrorOverlay {
    private weak var host: UIView?
    private var root: UIView?
    private var titleLabel: UILabel?
    private var messageLabel: UILabel?

    init(host: UIView) {
        self.host = host
    }

    func show(message: String) {
        ensure()
        titleLabel?.text = EngineDefaults.bootstrapErrorTitle
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        messageLabel?.text = trimmed.isEmpty
            ? EngineDefaults.bootstrapErrorFallbackMessage
            : trimmed
        root?.isHidden = false
        if let root, let host {
            host.bringSubviewToFront(root)
        }
    }

    func hide() {
        root?.isHidden = true
    }

    func destroy() {
        root?.removeFromSuperview()
        root = nil
        titleLabel = nil
        messageLabel = nil
    }

    private func ensure() {
        guard root == nil, let host else { return }
        let dim = UIView(frame: host.bounds)
        dim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        dim.backgroundColor = EngineDefaults.bootstrapErrorDimColor
        dim.isUserInteractionEnabled = true
        dim.isHidden = true

        let column = UIStackView()
        column.axis = .vertical
        column.alignment = .center
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false

        let title = UILabel()
        title.textColor = .white
        title.font = .boldSystemFont(ofSize: EngineDefaults.bootstrapErrorTitleFontSize)
        title.textAlignment = .center
        title.numberOfLines = 0
        title.text = EngineDefaults.bootstrapErrorTitle

        let message = UILabel()
        message.textColor = EngineDefaults.bootstrapErrorMessageColor
        message.font = .systemFont(ofSize: EngineDefaults.bootstrapErrorMessageFontSize)
        message.textAlignment = .center
        message.numberOfLines = 0

        column.addArrangedSubview(title)
        column.addArrangedSubview(message)
        dim.addSubview(column)
        NSLayoutConstraint.activate([
            column.centerXAnchor.constraint(equalTo: dim.centerXAnchor),
            column.centerYAnchor.constraint(equalTo: dim.centerYAnchor),
            column.leadingAnchor.constraint(greaterThanOrEqualTo: dim.leadingAnchor, constant: 24),
            column.trailingAnchor.constraint(lessThanOrEqualTo: dim.trailingAnchor, constant: -24),
        ])
        host.addSubview(dim)
        root = dim
        titleLabel = title
        messageLabel = message
    }
}
