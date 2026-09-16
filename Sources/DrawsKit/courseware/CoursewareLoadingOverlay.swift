import UIKit

/// Built-in courseware loading mask when `authConfig.progressEnable` is true.
final class CoursewareLoadingOverlay {
    private weak var host: UIView?
    private var dimView: UIView?
    private var label: UILabel?
    private var spinner: UIActivityIndicatorView?

    init(host: UIView) {
        self.host = host
    }

    func show(message: String = "课件加载中…") {
        ensure()
        label?.text = message
        dimView?.isHidden = false
        spinner?.startAnimating()
    }

    func hide() {
        dimView?.isHidden = true
        spinner?.stopAnimating()
    }

    func destroy() {
        dimView?.removeFromSuperview()
        dimView = nil
        label = nil
        spinner = nil
    }

    private func ensure() {
        guard dimView == nil, let host else { return }
        let dim = UIView(frame: host.bounds)
        dim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        dim.backgroundColor = EngineDefaults.coursewareLoadingDimColor
        dim.isUserInteractionEnabled = false
        dim.isHidden = true

        let spinner = UIActivityIndicatorView(style: .large)
        spinner.color = .white
        spinner.translatesAutoresizingMaskIntoConstraints = false

        let label = UILabel()
        label.textColor = .white
        label.font = .systemFont(ofSize: EngineDefaults.coursewareLoadingFontSize)
        label.textAlignment = .center
        label.text = "课件加载中…"
        label.translatesAutoresizingMaskIntoConstraints = false

        dim.addSubview(spinner)
        dim.addSubview(label)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: dim.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: dim.centerYAnchor, constant: -20),
            label.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 12),
            label.centerXAnchor.constraint(equalTo: dim.centerXAnchor),
        ])
        host.addSubview(dim)
        self.dimView = dim
        self.spinner = spinner
        self.label = label
    }
}
