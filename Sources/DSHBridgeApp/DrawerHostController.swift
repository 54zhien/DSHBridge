import SwiftUI
import UIKit

/// UIKit 抽屉宿主。
///
/// 层级照 zen 那套：侧栏是最底下的一张固定表面，首页是浮在它上面的一块圆角卡片。
/// 展开时动的是首页——右移、缩小、长出圆角、投下阴影；侧栏自己一动不动。
/// 遮罩挂在首页容器里，所以它只会压暗首页，不会把侧栏也压暗。
@MainActor
final class DrawerHostController<Sidebar: View, Content: View>: UIViewController, UIGestureRecognizerDelegate {
    private var metrics: DrawerMetrics
    private let sidebarVC: UIHostingController<Sidebar>
    private let contentVC: UIHostingController<Content>

    /// 首页容器：位移与缩放都写在它身上，内部子视图保持原尺寸
    private let contentContainer = UIView()
    /// 首页自己的投影，必须和内容分层，否则圆角裁剪会把阴影一起裁掉
    private let shadowView = UIView()
    private let outlineView = UIView()
    private let dimView = UIView()
    private let edgeView = UIView()

    private var progress: CGFloat = 0
    private var baseline: CGFloat = 0
    private var animator: UIViewPropertyAnimator?
    private var isOpen = false

    var onOpenChanged: ((Bool) -> Void)?

    init(metrics: DrawerMetrics, sidebar: Sidebar, content: Content) {
        self.metrics = metrics
        self.sidebarVC = UIHostingController(rootView: sidebar)
        self.contentVC = UIHostingController(rootView: content)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(DSTheme.canvas)

        // 1. 侧栏：铺满，固定不动，展开时只是被首页盖住/让出来
        addChild(sidebarVC)
        sidebarVC.view.frame = view.bounds
        sidebarVC.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        sidebarVC.view.backgroundColor = UIColor(DSTheme.sidebar)
        view.addSubview(sidebarVC.view)
        sidebarVC.didMove(toParent: self)

        // 2. 首页容器
        contentContainer.frame = view.bounds
        contentContainer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentContainer.backgroundColor = .clear
        view.addSubview(contentContainer)

        // 2a. 投影层（在内容下面，圆角与内容同步）
        shadowView.frame = contentContainer.bounds
        shadowView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        shadowView.backgroundColor = UIColor(DSTheme.canvas)
        shadowView.layer.cornerCurve = .continuous
        shadowView.layer.shadowColor = UIColor.black.cgColor
        shadowView.layer.shadowRadius = 14
        shadowView.layer.shadowOffset = CGSize(width: -4, height: 0)
        shadowView.layer.shadowOpacity = 0
        shadowView.isUserInteractionEnabled = false
        contentContainer.addSubview(shadowView)

        // 2b. 内容
        addChild(contentVC)
        contentVC.view.frame = contentContainer.bounds
        contentVC.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentVC.view.backgroundColor = UIColor(DSTheme.canvas)
        contentVC.view.layer.cornerCurve = .continuous
        contentVC.view.layer.masksToBounds = true
        contentContainer.addSubview(contentVC.view)
        contentVC.didMove(toParent: self)

        // 2c. 描边：zen 那种随展开渐显的 0.75pt 边缘细线
        outlineView.frame = contentContainer.bounds
        outlineView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        outlineView.backgroundColor = .clear
        outlineView.layer.cornerCurve = .continuous
        outlineView.layer.borderWidth = 0.75
        outlineView.layer.borderColor = UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor.white.withAlphaComponent(0.16)
                : UIColor.black.withAlphaComponent(0.10)
        }.cgColor
        outlineView.isUserInteractionEnabled = false
        outlineView.alpha = 0
        contentContainer.addSubview(outlineView)

        // 2d. 遮罩：只压首页，跟着首页一起位移缩放
        dimView.frame = contentContainer.bounds
        dimView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        dimView.backgroundColor = .black
        dimView.alpha = 0
        dimView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleDimTap)))
        contentContainer.addSubview(dimView)

        // 3. 手势：内容上负责关闭，遮罩上也要能关，边缘条负责打开
        let closePan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        closePan.delegate = self
        contentVC.view.addGestureRecognizer(closePan)

        let dimPan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        dimPan.delegate = self
        dimView.addGestureRecognizer(dimPan)

        edgeView.frame = CGRect(x: 0, y: 0, width: metrics.edgeWidth, height: view.bounds.height)
        edgeView.autoresizingMask = [.flexibleHeight]
        edgeView.backgroundColor = .clear
        let openPan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        edgeView.addGestureRecognizer(openPan)
        view.addSubview(edgeView)

        apply(progress: 0)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        metrics.width = metrics.resolvedWidth(for: view.bounds.size)
        metrics.displayCornerRadius = Self.screenCornerRadius(in: view)
        edgeView.frame = CGRect(x: 0, y: 0, width: metrics.edgeWidth, height: view.bounds.height)
        apply(progress: progress)
    }

    @objc private func handleDimTap() { animate(to: 0, velocity: 0) }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: view).x
        switch gesture.state {
        case .began:
            animator?.stopAnimation(true)
            animator = nil
            baseline = progress
        case .changed:
            guard abs(gesture.velocity(in: view).x) > 1 || abs(translation) > 2 else { return }
            progress = clamp(baseline + translation / metrics.width)
            apply(progress: progress)
        case .ended, .cancelled, .failed:
            let velocity = gesture.velocity(in: view).x / metrics.width
            let target: CGFloat
            if abs(velocity) > metrics.flingVelocity {
                target = velocity > 0 ? 1 : 0
            } else {
                target = progress > metrics.openThreshold ? 1 : 0
            }
            animate(to: target, velocity: velocity)
        default:
            break
        }
    }

    private func animate(to target: CGFloat, velocity: CGFloat) {
        animator?.stopAnimation(true)
        let spring = UISpringTimingParameters(dampingRatio: 0.88, initialVelocity: CGVector(dx: velocity, dy: 0))
        let animator = UIViewPropertyAnimator(duration: 0.36, timingParameters: spring)
        animator.addAnimations { [weak self] in
            self?.apply(progress: target)
        }
        animator.addCompletion { [weak self] _ in
            guard let self else { return }
            self.progress = target
            self.animator = nil
            let open = target > 0.5
            if open != self.isOpen {
                self.isOpen = open
                self.onOpenChanged?(open)
            }
        }
        self.animator = animator
        animator.startAnimation()
    }

    /// 唯一真源：所有几何量都由 progress 派生，同一帧内一次性写入。
    private func apply(progress p: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let offset = metrics.mainAreaTranslation(progress: p, width: metrics.width)
        let scale = metrics.contentScale(at: p)
        let radius = metrics.cornerRadius(progress: p, size: contentContainer.bounds.size)

        contentContainer.transform = CGAffineTransform(translationX: offset, y: 0)
            .scaledBy(x: scale, y: scale)

        contentVC.view.layer.cornerRadius = radius
        shadowView.layer.cornerRadius = radius
        outlineView.layer.cornerRadius = radius
        shadowView.layer.shadowOpacity = Float(0.10 * p)
        shadowView.alpha = p > 0.001 ? 1 : 0
        outlineView.alpha = p
        shadowView.layer.shadowPath = UIBezierPath(roundedRect: shadowView.bounds, cornerRadius: radius).cgPath

        // 侧栏不动，只在收起时彻底隐藏，避免任何透视残留
        sidebarVC.view.alpha = 1
        sidebarVC.view.isHidden = p <= 0.001

        dimView.alpha = metrics.dim * p
        dimView.isUserInteractionEnabled = p > 0.01

        CATransaction.commit()
    }

    private func clamp(_ value: CGFloat) -> CGFloat { min(max(value, 0), 1) }

    /// 屏幕物理圆角在公开 API 里拿不到，只能读私有键；读不到就退回 48。
    private static func screenCornerRadius(in view: UIView) -> CGFloat {
        let screen = view.window?.screen ?? UIScreen.main
        if let value = screen.value(forKey: "_displayCornerRadius") as? CGFloat, value > 0 {
            return value
        }
        return 48
    }

    nonisolated func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        MainActor.assumeIsolated {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y)
        }
    }
}

/// SwiftUI 包装。侧栏与内容仍用 SwiftUI 写，只有抽屉这一层是 UIKit。
struct UIKitDrawer<Sidebar: View, Content: View>: UIViewControllerRepresentable {
    @Binding var isOpen: Bool
    var metrics = DrawerMetrics()
    @ViewBuilder var sidebar: () -> Sidebar
    @ViewBuilder var content: () -> Content

    func makeUIViewController(context: Context) -> DrawerHostController<Sidebar, Content> {
        let controller = DrawerHostController(metrics: metrics, sidebar: sidebar(), content: content())
        controller.onOpenChanged = { open in isOpen = open }
        return controller
    }

    func updateUIViewController(_ controller: DrawerHostController<Sidebar, Content>, context: Context) {}
}
