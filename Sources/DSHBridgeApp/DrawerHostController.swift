import SwiftUI
import UIKit

/// UIKit 抽屉宿主。手势回调里直接改 layer / transform，不进 SwiftUI 状态机，
/// 这是获得“完全跟手”的前提。
@MainActor
final class DrawerHostController<Sidebar: View, Content: View>: UIViewController {
    private var metrics: DrawerMetrics
    private let sidebarVC: UIHostingController<Sidebar>
    private let contentVC: UIHostingController<Content>
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

        addChild(sidebarVC)
        sidebarVC.view.frame = CGRect(x: 0, y: 0, width: metrics.width, height: UIScreen.main.bounds.height)
        sidebarVC.view.backgroundColor = UIColor(DSTheme.sidebar)
        view.addSubview(sidebarVC.view)
        sidebarVC.didMove(toParent: self)

        addChild(contentVC)
        contentVC.view.frame = view.bounds
        contentVC.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentVC.view.layer.cornerCurve = .continuous
        contentVC.view.layer.masksToBounds = true
        view.addSubview(contentVC.view)
        contentVC.didMove(toParent: self)

        dimView.frame = view.bounds
        dimView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        dimView.backgroundColor = .black
        dimView.alpha = 0
        dimView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleDimTap)))
        view.addSubview(dimView)

        // 展开后整块内容都被遮罩盖住，所以关闭手势必须挂在遮罩上，
        // 否则它永远收不到事件——这是“展开后滑不回去”的根因。
        let dimPan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        dimPan.delegate = self
        dimView.addGestureRecognizer(dimPan)

        // 左侧边缘条：负责打开
        edgeView.frame = CGRect(x: 0, y: 0, width: metrics.edgeWidth, height: view.bounds.height)
        edgeView.autoresizingMask = [.flexibleHeight]
        edgeView.backgroundColor = .clear
        let openPan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        edgeView.addGestureRecognizer(openPan)
        view.addSubview(edgeView)

        // 内容上的横向拖拽：负责关闭
        let closePan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        closePan.delegate = self
        contentVC.view.addGestureRecognizer(closePan)

        // 侧栏要压在遮罩之上，不然展开时侧栏自己也被压暗
        view.bringSubviewToFront(sidebarVC.view)
        view.bringSubviewToFront(edgeView)

        apply(progress: 0)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 抽屉宽度按屏宽算，写死会在不同机型上要么太窄要么盖满
        let proposed = (view.bounds.width * metrics.widthRatio).rounded()
        metrics.width = min(max(proposed, metrics.minWidth), metrics.maxWidth)
        sidebarVC.view.frame = CGRect(x: 0, y: 0, width: metrics.width, height: view.bounds.height)
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
            if abs(velocity) > 1.2 {
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
        let spring = UISpringTimingParameters(dampingRatio: 0.86, initialVelocity: CGVector(dx: velocity, dy: 0))
        let animator = UIViewPropertyAnimator(duration: 0.34, timingParameters: spring)
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

    /// 唯一真源：所有几何量都由 progress 派生，且在同一帧内一次性写入。
    private func apply(progress p: CGFloat) {
        let offset = metrics.width * metrics.parallax * p
        let scale = 1 - (1 - metrics.contentScale) * p
        let drawerShift = -metrics.width * metrics.drawerDepth * (1 - p)

        contentVC.view.transform = CGAffineTransform(translationX: offset, y: 0).scaledBy(x: scale, y: scale)
        contentVC.view.layer.cornerRadius = metrics.cornerRadius * p
        contentVC.view.layer.shadowColor = UIColor.black.cgColor
        contentVC.view.layer.shadowOpacity = Float(0.35 * p)
        contentVC.view.layer.shadowRadius = 24
        contentVC.view.layer.shadowOffset = CGSize(width: -8, height: 0)

        sidebarVC.view.transform = CGAffineTransform(translationX: drawerShift, y: 0)
        sidebarVC.view.alpha = 0.4 + 0.6 * p
        dimView.alpha = metrics.dim * p
    }

    private func clamp(_ value: CGFloat) -> CGFloat { min(max(value, 0), 1) }
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

extension DrawerHostController: UIGestureRecognizerDelegate {
    nonisolated func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        MainActor.assumeIsolated {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
            let velocity = pan.velocity(in: pan.view)
            // 只接管横向滑动，纵向留给内容里的滚动视图
            return abs(velocity.x) > abs(velocity.y)
        }
    }
}
