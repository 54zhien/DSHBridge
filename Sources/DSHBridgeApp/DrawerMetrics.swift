import SwiftUI

/// 抽屉的全部可调参数。位移、缩放、圆角、遮罩都由 progress 派生，
/// 不允许单独给某个量挂动画，否则两条时间轴会互相打架。
struct DrawerMetrics {
    /// 实际宽度，由宿主在 layout 时按屏宽算出来，不要手填
    var width: CGFloat = 320
    /// 抽屉占屏宽的比例
    var widthRatio: CGFloat = 0.86
    var minWidth: CGFloat = 280
    var maxWidth: CGFloat = 380
    /// 完全打开时内容缩到的比例，0.92 即缩小 8%
    var contentScale: CGFloat = 0.92
    /// 内容右移占抽屉宽度的比例，小于 1 才有视差
    var parallax: CGFloat = 0.32
    /// 抽屉自身反向位移的比例，制造纵深
    var drawerDepth: CGFloat = 0.12
    var cornerRadius: CGFloat = 20
    var dim: Double = 0.35
    var openThreshold: CGFloat = 0.5
    /// 判定为“甩”的预测位移阈值（占宽度的比例）
    var flingRatio: CGFloat = 0.35
    var spring = Animation.spring(response: 0.34, dampingFraction: 0.86)
    var edgeWidth: CGFloat = 24
}
