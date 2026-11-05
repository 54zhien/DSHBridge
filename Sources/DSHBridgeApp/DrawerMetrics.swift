import SwiftUI

/// 抽屉的全部可调参数与几何函数。
///
/// 结构照着 Moku 那套拆的：它把几何量做成静态函数
/// `mainAreaTranslation(progress:drawerWidth:)` 与 `drawerParallaxOffset(progress:drawerWidth:)`，
/// 宽度按 `drawerWidthFraction` 乘最短边算，并有一个 `drawerRailMinShortestSide`
/// 决定什么时候退化成图标栏。这里保留同样的分工：函数算几何，宿主只负责写图层。
struct DrawerMetrics {
    /// 实际宽度，由宿主在 layout 时算出来，不要手填
    var width: CGFloat = 320
    /// 抽屉占最短边的比例
    var widthFraction: CGFloat = 0.86
    var minWidth: CGFloat = 280
    var maxWidth: CGFloat = 380
    /// 窄于这个宽度就不再做「内容让位」，改成整屏推入（iPhone SE 之类）
    var railMinShortestSide: CGFloat = 340

    /// 完全打开时内容缩到的比例
    var contentScale: CGFloat = 0.94
    /// 内容右移占抽屉宽度的比例，小于 1 才有视差
    var parallax: CGFloat = 0.9
    /// 侧栏自身的反向位移比例：打开时往左退一点，制造纵深
    var drawerParallax: CGFloat = 0.10
    /// 侧栏自身的缩放：打开时 0.97 → 1
    var drawerScale: CGFloat = 0.97

    /// 屏幕圆角。取不到就退回 48，宁可略小也不要突出去
    var displayCornerRadius: CGFloat = 48
    /// 卡片圆角上限，照 zen 的 AppSpaceGeometry：min(24, 短边 * 0.1)
    var cornerRadiusCap: CGFloat = 24
    var dim: Double = 0.08
    var openThreshold: CGFloat = 0.5
    /// 判定为「甩」的速度阈值（宽度/秒）
    var flingVelocity: CGFloat = 1.2
    var spring = Animation.spring(response: 0.34, dampingFraction: 0.86)
    var edgeWidth: CGFloat = 24

    /// 卡片圆角。zen 的规则是跟着卡片尺寸走并封顶，不是套屏幕圆角
    func cornerRadius(progress p: CGFloat, size: CGSize) -> CGFloat {
        let base = min(cornerRadiusCap, min(size.width, size.height) * 0.1)
        return base * max(0, min(1, p))
    }

    /// 按最短边算宽度，再夹到上下限
    func resolvedWidth(for size: CGSize) -> CGFloat {
        let shortest = min(size.width, size.height)
        let proposed = (shortest * widthFraction).rounded()
        return min(max(proposed, minWidth), maxWidth)
    }

    /// 内容层的水平位移。Moku 里叫 mainAreaTranslation。
    func mainAreaTranslation(progress p: CGFloat, width: CGFloat) -> CGFloat {
        width * parallax * p
    }

    /// 侧栏自身的反向位移。Moku 里叫 drawerParallaxOffset。
    func drawerParallaxOffset(progress p: CGFloat, width: CGFloat) -> CGFloat {
        -width * drawerParallax * (1 - p)
    }

    func contentScale(at p: CGFloat) -> CGFloat {
        1 - (1 - contentScale) * p
    }

    func drawerScale(at p: CGFloat) -> CGFloat {
        drawerScale + (1 - drawerScale) * p
    }
}
