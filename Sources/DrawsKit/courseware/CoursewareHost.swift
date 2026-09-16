import UIKit
import WebKit

/// WKWebView layer beneath [DrawsKitView] for H5 courseware (aligned with Web CoursewareHost).
final class CoursewareHost: NSObject {
    private let boardRoot: UIView
    private weak var drawsKitView: DrawsKitView?
    private let send: (String) -> Void
    private let onCoursewareStatus: (String?, String, String) -> Void

    private let transformHost = UIView()
    private let webView: WKWebView
    private let bridgeName = "DrawsKitBridge"

    private var coursewareUrl: String?
    private var coursewareResourceId: String?

    init(
        boardRoot: UIView,
        drawsKitView: DrawsKitView,
        send: @escaping (String) -> Void,
        onCoursewareStatus: @escaping (String?, String, String) -> Void
    ) {
        self.boardRoot = boardRoot
        self.drawsKitView = drawsKitView
        self.send = send
        self.onCoursewareStatus = onCoursewareStatus

        transformHost.translatesAutoresizingMaskIntoConstraints = false
        transformHost.isHidden = true
        transformHost.clipsToBounds = true

        let config = WKWebViewConfiguration()
        let contentController = WKUserContentController()
        config.userContentController = contentController

        webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.isUserInteractionEnabled = false
        webView.translatesAutoresizingMaskIntoConstraints = false

        super.init()

        contentController.add(self, name: bridgeName)
        webView.navigationDelegate = self

        boardRoot.clipsToBounds = true
        boardRoot.insertSubview(transformHost, belowSubview: drawsKitView)
        transformHost.addSubview(webView)

        NSLayoutConstraint.activate([
            transformHost.leadingAnchor.constraint(equalTo: boardRoot.leadingAnchor),
            transformHost.trailingAnchor.constraint(equalTo: boardRoot.trailingAnchor),
            transformHost.topAnchor.constraint(equalTo: boardRoot.topAnchor),
            transformHost.bottomAnchor.constraint(equalTo: boardRoot.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: transformHost.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: transformHost.trailingAnchor),
            webView.topAnchor.constraint(equalTo: transformHost.topAnchor),
            webView.bottomAnchor.constraint(equalTo: transformHost.bottomAnchor),
        ])
    }

    func sync(_ frame: [String: Any]?) {
        let cw = CoursewareRead.getCoursewareLayer(frame)
        let viewport = frame?.dict("viewport")

        if let cw, CoursewareRead.isWebViewRenderMode(cw.string("render_mode")) {
            let url = cw.string("webview_url")
            let resourceId = cw.string("resource_id")
            if !url.isEmpty, !resourceId.isEmpty {
                if url != coursewareUrl || resourceId != coursewareResourceId {
                    coursewareUrl = url
                    coursewareResourceId = resourceId
                    onCoursewareStatus(resourceId, "loading", url)
                    loadCoursewareUrl(url)
                }
                transformHost.isHidden = false
                drawsKitView?.setWebViewCoursewareActive(true)
            } else {
                hideCourseware()
            }
        } else {
            hideCourseware()
        }

        applyViewport(viewport)
    }

    func destroy() {
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: bridgeName)
        transformHost.removeFromSuperview()
        drawsKitView?.setWebViewCoursewareActive(false)
    }

    private func hideCourseware() {
        coursewareUrl = nil
        coursewareResourceId = nil
        transformHost.isHidden = true
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
        drawsKitView?.setWebViewCoursewareActive(false)
    }

    private func loadCoursewareUrl(_ url: String) {
        if url.lowercased().hasPrefix("data:text/html") {
            if let comma = url.firstIndex(of: ",") {
                let header = String(url[..<comma])
                let body = String(url[url.index(after: comma)...])
                let html: String
                if header.lowercased().contains("base64"),
                   let data = Data(base64Encoded: body),
                   let decoded = String(data: data, encoding: .utf8) {
                    html = decoded
                } else {
                    html = body.removingPercentEncoding ?? body
                }
                webView.loadHTMLString(html, baseURL: nil)
                return
            }
        }
        if let remote = URL(string: url) {
            webView.load(URLRequest(url: remote))
        }
    }

    private func applyViewport(_ viewport: [String: Any]?) {
        guard let viewport else { return }
        let scale = CGFloat(viewport.double("scale", default: 100) / 100)
        let ox = CGFloat(viewport.double("offset_x"))
        let oy = CGFloat(viewport.double("offset_y"))
        transformHost.layer.anchorPoint = .zero
        transformHost.transform = CGAffineTransform(translationX: ox, y: oy).scaledBy(x: scale, y: scale)
    }

    private func forwardH5Message(_ json: String) {
        guard let data = json.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        send(PlatformEvents.h5CoursewareMessage(payload: payload))
    }
}

extension CoursewareHost: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let rid = coursewareResourceId, let loadedUrl = coursewareUrl else { return }
        onCoursewareStatus(rid, "ready", loadedUrl)
        send(PlatformEvents.coursewareReady(resourceId: rid))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard let rid = coursewareResourceId, let loadedUrl = coursewareUrl else { return }
        onCoursewareStatus(rid, "error", loadedUrl)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard let rid = coursewareResourceId, let loadedUrl = coursewareUrl else { return }
        onCoursewareStatus(rid, "error", loadedUrl)
    }
}

extension CoursewareHost: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == bridgeName else { return }
        if let json = message.body as? String {
            forwardH5Message(json)
        } else if let dict = message.body as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: dict),
                  let json = String(data: data, encoding: .utf8) {
            forwardH5Message(json)
        }
    }
}
