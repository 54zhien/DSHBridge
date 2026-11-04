import SwiftUI

/// 用 DSH 的矢量路径画图标，线宽跟随字重与系统「粗体文本」。
///
/// 关键在于按描边画而不是按填充画：DSH 的官方图标是 16×16 网格、线宽 1，
/// 圆角端点圆角连接，和 SF Symbols 的构造方式同源。线宽按图标边长取比例，
/// 于是 16pt 和 28pt 下的粗细观感一致，不会大图标显细、小图标显糊。
public struct WeightedIcon: View {
    private let name: String
    private let size: CGFloat
    private let weight: Font.Weight
    private let tint: Color

    @Environment(\.legibilityWeight) private var legibility

    public init(_ name: String, size: CGFloat = 18, weight: Font.Weight = .regular, tint: Color = .primary) {
        self.name = name
        self.size = size
        self.weight = weight
        self.tint = tint
    }

    public var body: some View {
        let definition = DshIcons.catalog[name]
        let shapes = IconGeometry.shapes(for: name)
        let viewBox = definition?.viewBox ?? 16

        ZStack {
            if let definition, !shapes.isEmpty {
                ScaledPaths(paths: shapes.filter { $0.kind == .fill }.map(\.path), viewBox: viewBox)
                    .fill(tint)

                ScaledPaths(paths: shapes.filter { $0.kind == .stroke }.map(\.path), viewBox: viewBox)
                    .stroke(
                        tint,
                        style: StrokeStyle(
                            lineWidth: strokePoints,
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )

                if !definition.circles.isEmpty {
                    ScaledCircles(circles: definition.circles, viewBox: viewBox)
                        .fill(tint)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// 线宽（点）。系统开启「粗体文本」时抬到中黑，跟文字一起变粗。
    private var strokePoints: CGFloat {
        let effective = legibility == .bold
            ? max(rank(weight), rank(.semibold))
            : rank(weight)
        return size * Self.ratio(forRank: effective)
    }

    private func rank(_ weight: Font.Weight) -> Int {
        switch weight {
        case .ultraLight: 0
        case .thin: 1
        case .light: 2
        case .regular: 3
        case .medium: 4
        case .semibold: 5
        case .bold: 6
        case .heavy: 7
        case .black: 8
        default: 3
        }
    }

    private static func ratio(forRank rank: Int) -> CGFloat {
        switch rank {
        case 0: 0.060
        case 1: 0.065
        case 2: 0.072
        case 4: 0.093
        case 5: 0.100
        case 6: 0.112
        case 7: 0.122
        case 8: 0.132
        default: 0.085
        }
    }
}

private struct ScaledPaths: Shape {
    let paths: [Path]
    let viewBox: CGFloat

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        guard side > 0, viewBox > 0 else { return Path() }
        let scale = side / viewBox
        let transform = CGAffineTransform(scaleX: scale, y: scale)
        var combined = Path()
        for path in paths {
            combined.addPath(path.applying(transform))
        }
        return combined
    }
}

private struct ScaledCircles: Shape {
    let circles: [IconCircle]
    let viewBox: CGFloat

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        guard side > 0, viewBox > 0 else { return Path() }
        let scale = side / viewBox
        var combined = Path()
        for circle in circles {
            let box = CGRect(
                x: (circle.cx - circle.r) * scale,
                y: (circle.cy - circle.r) * scale,
                width: circle.r * 2 * scale,
                height: circle.r * 2 * scale
            )
            combined.addEllipse(in: box)
        }
        return combined
    }
}

/// 解析后的路径缓存。列表滚动时同一图标反复绘制，
/// 每次重新解析 `d` 字符串是纯浪费。
@MainActor
enum IconGeometry {
    struct CachedShape {
        let path: Path
        let kind: IconPath.Kind
    }

    private static var storage: [String: [CachedShape]] = [:]

    static func shapes(for name: String) -> [CachedShape] {
        if let cached = storage[name] { return cached }
        guard let definition = DshIcons.catalog[name] else { return [] }
        let built = definition.paths.map { CachedShape(path: SVGPath.build($0.d), kind: $0.kind) }
        storage[name] = built
        return built
    }
}

/// 目视校对用：把所有图标按字重排开。
public struct IconGallery: View {
    private let columns = [GridItem(.adaptive(minimum: 64), spacing: 12)]
    @State private var weight: Font.Weight = .regular

    public init() {}

    public var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(DshIcons.catalog.keys.sorted(), id: \.self) { name in
                    VStack(spacing: 6) {
                        WeightedIcon(name, size: 26, weight: weight)
                            .frame(height: 30)
                        Text(name)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
            }
            .padding()
        }
        .safeAreaInset(edge: .bottom) {
            Picker("字重", selection: $weight) {
                Text("常规").tag(Font.Weight.regular)
                Text("中黑").tag(Font.Weight.semibold)
                Text("加粗").tag(Font.Weight.bold)
            }
            .pickerStyle(.segmented)
            .padding()
        }
    }
}
