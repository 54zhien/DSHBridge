import SwiftUI

/// 最小可用的 SVG path 解析器。
/// 支持 M/m L/l H/h V/v C/c S/s Q/q T/t A/a Z/z，够渲染 DSH 的全部图标。
enum SVGPath {
    static func build(_ d: String) -> Path {
        var path = Path()
        var scanner = Scanner(d)
        var current = CGPoint.zero
        var start = CGPoint.zero
        var lastCubicControl: CGPoint?
        var lastQuadControl: CGPoint?

        while let cmd = scanner.nextCommand() {
            let relative = cmd.isLowercase
            switch Character(cmd.uppercased()) {
            case "M":
                var first = true
                while let p = scanner.nextPoint(relative: relative, origin: current) {
                    if first {
                        path.move(to: p)
                        start = p
                        first = false
                    } else {
                        path.addLine(to: p)
                    }
                    current = p
                }
                lastCubicControl = nil
                lastQuadControl = nil

            case "L":
                while let p = scanner.nextPoint(relative: relative, origin: current) {
                    path.addLine(to: p)
                    current = p
                }
                lastCubicControl = nil
                lastQuadControl = nil

            case "H":
                while let v = scanner.nextNumber() {
                    let x = relative ? current.x + v : v
                    current = CGPoint(x: x, y: current.y)
                    path.addLine(to: current)
                }
                lastCubicControl = nil
                lastQuadControl = nil

            case "V":
                while let v = scanner.nextNumber() {
                    let y = relative ? current.y + v : v
                    current = CGPoint(x: current.x, y: y)
                    path.addLine(to: current)
                }
                lastCubicControl = nil
                lastQuadControl = nil

            case "C":
                while let c1 = scanner.nextPoint(relative: relative, origin: current),
                      let c2 = scanner.nextPoint(relative: relative, origin: current),
                      let end = scanner.nextPoint(relative: relative, origin: current) {
                    path.addCurve(to: end, control1: c1, control2: c2)
                    lastCubicControl = c2
                    current = end
                }
                lastQuadControl = nil

            case "S":
                while let c2 = scanner.nextPoint(relative: relative, origin: current),
                      let end = scanner.nextPoint(relative: relative, origin: current) {
                    let c1 = reflect(lastCubicControl, around: current)
                    path.addCurve(to: end, control1: c1, control2: c2)
                    lastCubicControl = c2
                    current = end
                }
                lastQuadControl = nil

            case "Q":
                while let c = scanner.nextPoint(relative: relative, origin: current),
                      let end = scanner.nextPoint(relative: relative, origin: current) {
                    path.addQuadCurve(to: end, control: c)
                    lastQuadControl = c
                    current = end
                }
                lastCubicControl = nil

            case "T":
                while let end = scanner.nextPoint(relative: relative, origin: current) {
                    let c = reflect(lastQuadControl, around: current)
                    path.addQuadCurve(to: end, control: c)
                    lastQuadControl = c
                    current = end
                }
                lastCubicControl = nil

            case "A":
                while let rx = scanner.nextNumber(),
                      let ry = scanner.nextNumber(),
                      let rotation = scanner.nextNumber(),
                      let largeArc = scanner.nextFlag(),
                      let sweep = scanner.nextFlag(),
                      let end = scanner.nextPoint(relative: relative, origin: current) {
                    appendArc(
                        to: &path,
                        from: current,
                        to: end,
                        rx: abs(rx),
                        ry: abs(ry),
                        rotation: rotation,
                        largeArc: largeArc,
                        sweep: sweep
                    )
                    current = end
                }
                lastCubicControl = nil
                lastQuadControl = nil

            case "Z":
                path.closeSubpath()
                current = start
                lastCubicControl = nil
                lastQuadControl = nil

            default:
                return path
            }
        }
        return path
    }

    private static func reflect(_ control: CGPoint?, around point: CGPoint) -> CGPoint {
        guard let control else { return point }
        return CGPoint(x: 2 * point.x - control.x, y: 2 * point.y - control.y)
    }

    /// 端点参数化的椭圆弧转三次贝塞尔，每段不超过 90°。
    private static func appendArc(
        to path: inout Path,
        from start: CGPoint,
        to end: CGPoint,
        rx: CGFloat,
        ry: CGFloat,
        rotation degrees: CGFloat,
        largeArc: Bool,
        sweep: Bool
    ) {
        guard rx > 0, ry > 0, start != end else {
            path.addLine(to: end)
            return
        }

        let phi = degrees * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)

        let dx = (start.x - end.x) / 2
        let dy = (start.y - end.y) / 2
        let x1p = cosPhi * dx + sinPhi * dy
        let y1p = -sinPhi * dx + cosPhi * dy

        var rxa = rx, rya = ry
        let lambda = (x1p * x1p) / (rxa * rxa) + (y1p * y1p) / (rya * rya)
        if lambda > 1 {
            let s = sqrt(lambda)
            rxa *= s
            rya *= s
        }

        let sign: CGFloat = largeArc == sweep ? -1 : 1
        let numerator = max(0, rxa * rxa * rya * rya - rxa * rxa * y1p * y1p - rya * rya * x1p * x1p)
        let denominator = rxa * rxa * y1p * y1p + rya * rya * x1p * x1p
        let coef = denominator == 0 ? 0 : sign * sqrt(numerator / denominator)

        let cxp = coef * rxa * y1p / rya
        let cyp = -coef * rya * x1p / rxa
        let cx = cosPhi * cxp - sinPhi * cyp + (start.x + end.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (start.y + end.y) / 2

        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let dot = ux * vx + uy * vy
            let len = sqrt(ux * ux + uy * uy) * sqrt(vx * vx + vy * vy)
            guard len > 0 else { return 0 }
            var a = acos(max(-1, min(1, dot / len)))
            if ux * vy - uy * vx < 0 { a = -a }
            return a
        }

        let ux = (x1p - cxp) / rxa, uy = (y1p - cyp) / rya
        let vx = (-x1p - cxp) / rxa, vy = (-y1p - cyp) / rya
        let theta1 = angle(1, 0, ux, uy)
        var delta = angle(ux, uy, vx, vy)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }

        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let step = delta / CGFloat(segments)
        let k = 4.0 / 3.0 * tan(step / 4)

        var t = theta1
        for _ in 0..<segments {
            let t2 = t + step
            let cos1 = cos(t), sin1 = sin(t)
            let cos2 = cos(t2), sin2 = sin(t2)

            func map(_ ex: CGFloat, _ ey: CGFloat) -> CGPoint {
                CGPoint(
                    x: cx + cosPhi * rxa * ex - sinPhi * rya * ey,
                    y: cy + sinPhi * rxa * ex + cosPhi * rya * ey
                )
            }

            let p1 = map(cos1 - k * sin1, sin1 + k * cos1)
            let p2 = map(cos2 + k * sin2, sin2 - k * cos2)
            let p3 = map(cos2, sin2)
            path.addCurve(to: p3, control1: p1, control2: p2)
            t = t2
        }
    }

    // MARK: - Scanner

    private struct Scanner {
        private let scalars: [Character]
        private var index = 0

        init(_ string: String) {
            scalars = Array(string)
        }

        private mutating func skipSeparators() {
            while index < scalars.count {
                let c = scalars[index]
                if c == "," || c == " " || c == "\n" || c == "\t" || c == "\r" {
                    index += 1
                } else {
                    break
                }
            }
        }

        mutating func nextCommand() -> Character? {
            skipSeparators()
            guard index < scalars.count else { return nil }
            let c = scalars[index]
            guard c.isLetter else { return nil }
            index += 1
            return c
        }

        mutating func nextNumber() -> CGFloat? {
            skipSeparators()
            let begin = index
            if index < scalars.count, scalars[index] == "-" || scalars[index] == "+" {
                index += 1
            }
            var sawDot = false
            var sawDigit = false
            while index < scalars.count {
                let c = scalars[index]
                if c.isNumber {
                    sawDigit = true
                    index += 1
                } else if c == "." && !sawDot {
                    sawDot = true
                    index += 1
                } else if c == "e" || c == "E" {
                    index += 1
                    if index < scalars.count, scalars[index] == "-" || scalars[index] == "+" {
                        index += 1
                    }
                } else {
                    break
                }
            }
            guard sawDigit else {
                index = begin
                return nil
            }
            return CGFloat(Double(String(scalars[begin..<index])) ?? 0)
        }

        mutating func nextPoint(relative: Bool, origin: CGPoint) -> CGPoint? {
            let saved = index
            guard let x = nextNumber(), let y = nextNumber() else {
                index = saved
                return nil
            }
            return relative ? CGPoint(x: origin.x + x, y: origin.y + y) : CGPoint(x: x, y: y)
        }

        mutating func nextFlag() -> Bool? {
            skipSeparators()
            guard index < scalars.count else { return nil }
            if scalars[index] == "1" { index += 1; return true }
            if scalars[index] == "0" { index += 1; return false }
            return nil
        }
    }
}
