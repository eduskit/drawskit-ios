import UIKit

/// Whiteboard surface: renders Rust `RenderMessage` and forwards touch to the engine.
public final class DrawsKitView: UIView {
    private weak var engine: DrawsKitEngine?
    private var pinchLastScale: CGFloat = 1
    private var webViewCoursewareActive = false

    public override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        backgroundColor = .white
        isMultipleTouchEnabled = true
        isOpaque = true
        contentMode = .redraw
        clipsToBounds = true

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        addGestureRecognizer(pinch)
    }

    func bindEngine(_ drawsKitEngine: DrawsKitEngine?) {
        engine = drawsKitEngine
    }

    func setWebViewCoursewareActive(_ active: Bool) {
        guard webViewCoursewareActive != active else { return }
        webViewCoursewareActive = active
        backgroundColor = active ? .clear : .white
        isOpaque = !active
        setNeedsDisplay()
    }

    func isWebViewCoursewareActive() -> Bool {
        webViewCoursewareActive
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        engine?.onSizeChanged(width: bounds.width, height: bounds.height)
    }

    public override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        if !webViewCoursewareActive {
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fill(rect)
        }
        engine?.render(in: ctx)
    }

    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        engine?.onTouchBegan(touch: touch, in: self)
    }

    public override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let samples = event?.coalescedTouches(for: touch) ?? [touch]
        engine?.onTouchMoved(touches: samples.isEmpty ? [touch] : samples, in: self)
    }

    public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        engine?.onTouchEnded(touch: touch, in: self)
    }

    public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        engine?.onTouchEnded(touch: touch, in: self)
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        guard let engine else { return }
        switch recognizer.state {
        case .began:
            pinchLastScale = 1
        case .changed:
            let factor = Float(recognizer.scale / pinchLastScale)
            pinchLastScale = recognizer.scale
            let point = recognizer.location(in: self)
            engine.onPinch(scaleFactor: factor, focusX: Float(point.x), focusY: Float(point.y), in: self)
        default:
            pinchLastScale = 1
        }
    }
}
