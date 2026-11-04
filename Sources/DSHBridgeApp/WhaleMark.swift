import SwiftUI

/// 鲸鱼标。DSH 的标识，形状参照 DeepSeek 那头鲸，改成纯色单笔——
/// 浅色下是黑鲸，深色下自动反白。等宽高比，任意尺寸都不糊。
struct WhaleMark: View {
    var size: CGFloat = 28
    var color: Color = DSTheme.mark

    var body: some View {
        ZStack {
            WhaleShape()
                .fill(color)
            // 眼睛挖成底色，小尺寸下也能看出是只鲸鱼
            Circle()
                .fill(DSTheme.canvas)
                .frame(width: size * 0.075, height: size * 0.075)
                .offset(x: -size * 0.245, y: -size * 0.045)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct WhaleShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        var p = Path()

        // 身体：头在左，尾根收在右侧
        p.move(to: CGPoint(x: 2.6 * s, y: 14.2 * s))
        p.addCurve(to: CGPoint(x: 9.4 * s, y: 7.4 * s),
                   control1: CGPoint(x: 2.6 * s, y: 10.6 * s),
                   control2: CGPoint(x: 5.5 * s, y: 7.4 * s))
        p.addCurve(to: CGPoint(x: 17.2 * s, y: 12.0 * s),
                   control1: CGPoint(x: 13.6 * s, y: 7.4 * s),
                   control2: CGPoint(x: 16.6 * s, y: 9.2 * s))
        p.addCurve(to: CGPoint(x: 9.6 * s, y: 18.6 * s),
                   control1: CGPoint(x: 16.4 * s, y: 16.0 * s),
                   control2: CGPoint(x: 13.4 * s, y: 18.6 * s))
        p.addCurve(to: CGPoint(x: 2.6 * s, y: 14.2 * s),
                   control1: CGPoint(x: 6.4 * s, y: 18.6 * s),
                   control2: CGPoint(x: 3.4 * s, y: 16.6 * s))
        p.closeSubpath()

        // 尾鳍：从尾根向右上、右下张开
        p.move(to: CGPoint(x: 16.4 * s, y: 12.4 * s))
        p.addLine(to: CGPoint(x: 22.2 * s, y: 7.6 * s))
        p.addCurve(to: CGPoint(x: 22.2 * s, y: 16.4 * s),
                   control1: CGPoint(x: 20.0 * s, y: 10.4 * s),
                   control2: CGPoint(x: 20.0 * s, y: 13.6 * s))
        p.closeSubpath()

        return p
    }
}

#Preview {
    HStack(spacing: 24) {
        WhaleMark(size: 44)
        WhaleMark(size: 22)
    }
    .padding(40)
    .background(DSTheme.canvas)
}
