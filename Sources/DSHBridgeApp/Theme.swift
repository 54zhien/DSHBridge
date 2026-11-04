import SwiftUI
import UIKit

/// 全局配色。全部走动态色，跟随系统深浅色切换，不写死黑白。
/// 取色参照 DeepSeek 客户端：冷灰底 + 一点偏蓝的品牌色。
enum DSTheme {
    static let accent = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.42, green: 0.55, blue: 1.0, alpha: 1)
            : UIColor(red: 0.30, green: 0.42, blue: 0.99, alpha: 1)
    })

    /// 页面底色
    static let canvas = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.098, green: 0.098, blue: 0.106, alpha: 1)
            : UIColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1)
    })

    /// 卡片 / 列表行
    static let surface = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.137, green: 0.137, blue: 0.145, alpha: 1)
            : UIColor(red: 0.969, green: 0.973, blue: 0.980, alpha: 1)
    })

    /// 侧栏底色，比内容区更深一档
    static let sidebar = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.078, green: 0.078, blue: 0.086, alpha: 1)
            : UIColor(red: 0.949, green: 0.953, blue: 0.961, alpha: 1)
    })

    static let textPrimary = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.925, green: 0.925, blue: 0.933, alpha: 1)
            : UIColor(red: 0.102, green: 0.102, blue: 0.110, alpha: 1)
    })

    static let textSecondary = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.541, green: 0.541, blue: 0.557, alpha: 1)
            : UIColor(red: 0.478, green: 0.478, blue: 0.494, alpha: 1)
    })

    static let separator = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.180, green: 0.180, blue: 0.192, alpha: 1)
            : UIColor(red: 0.910, green: 0.910, blue: 0.922, alpha: 1)
    })

    /// 鲸鱼标。浅色下纯黑，深色下反白——同一个形状，两种对比。
    static let mark = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(white: 0.96, alpha: 1)
            : UIColor(white: 0.06, alpha: 1)
    })
}

extension View {
    /// 统一的全屏底色，同时把系统底色调成同色，避免滚动到边缘露出白边。
    func dsCanvas() -> some View {
        background(DSTheme.canvas)
    }
}
