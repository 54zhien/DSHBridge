// 把 DSH 的 SVG 图标数据导成 Swift 常量。
// 来源：apps/android/src/ui/dsh-icons.tsx（内联 SVG）
//       apps/android/src/ui/official-menu-icon-data.ts（结构化 JSON）
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { dirname } from 'node:path'

const DSR = process.env.DSR ?? '/tmp/dsr'
const OUT = process.argv[2] ?? 'Sources/DSHBridgeUI/DshIconCatalog.swift'

const icons = new Map()

function put(name, viewBox, strokeWidth, paths) {
  if (!paths.length) return
  icons.set(name, { viewBox, strokeWidth, paths })
}

// ── 1. official-menu-icon-data.ts ─────────────────────────────
{
  const raw = readFileSync(`${DSR}/apps/android/src/ui/official-menu-icon-data.ts`, 'utf8')
  const body = raw.slice(raw.indexOf('{'), raw.lastIndexOf('}') + 1)
  const data = JSON.parse(body)
  for (const [name, def] of Object.entries(data)) {
    const vb = Number(String(def.viewBox ?? '0 0 16 16').trim().split(/\s+/)[2] ?? 16)
    const sw = Number(def.strokeWidth ?? 1)
    const paths = (def.paths ?? []).map((p) => ({
      d: p.d,
      fill: Boolean(p.fill) && !p.stroke,
    }))
    put(name, vb, sw, paths)
  }
}

// ── 2. dsh-icons.tsx（JSX，按 if (kind === '...') 切块）─────────
{
  const raw = readFileSync(`${DSR}/apps/android/src/ui/dsh-icons.tsx`, 'utf8')
  const blocks = [...raw.matchAll(/kind === '([\w-]+)'\)\s*\{/g)]
  for (let i = 0; i < blocks.length; i++) {
    const kind = blocks[i][1]
    const start = blocks[i].index
    const end = i + 1 < blocks.length ? blocks[i + 1].index : raw.length
    const chunk = raw.slice(start, end)
    const vbMatch = chunk.match(/viewBox="0 0 (\d+(?:\.\d+)?) /)
    const viewBox = vbMatch ? Number(vbMatch[1]) : 16
    const swMatch = chunk.match(/strokeWidth=\{?([\d.]+)/)
    const strokeWidth = swMatch ? Number(swMatch[1]) : 1.3
    const paths = []
    for (const m of chunk.matchAll(/<Path\b([\s\S]*?)\/>/g)) {
      const attrs = m[1]
      const d = attrs.match(/\bd="([^"]+)"/)
      if (!d) continue
      const filled = /\bfill=\{?['"]?(?!none)/.test(attrs) && !/\bstroke=/.test(attrs)
      paths.push({ d: d[1], fill: filled })
    }
    for (const m of chunk.matchAll(/<Circle\b([\s\S]*?)\/>/g)) {
      const a = m[1]
      const g = (k) => Number((a.match(new RegExp(`\\b${k}=\\{?([\\d.]+)`)) ?? [])[1] ?? 0)
      paths.push({ circle: [g('cx'), g('cy'), g('r')] })
    }
    put(`link.${kind}`, viewBox, strokeWidth, paths)
  }
}

// ── 3. 生成 Swift ─────────────────────────────────────────────
const esc = (s) => s.replace(/\\/g, '\\\\').replace(/"/g, '\\"')

let out = `// 由 Tools/export-icons.mjs 生成，请勿手改。
// 图标来源：ds-harness-remote（MIT）apps/android/src/ui/dsh-icons.tsx、
//           official-menu-icon-data.ts。原始美术见 docs/official-menu-icons.md。
import SwiftUI

public struct IconPath: Sendable {
    public enum Kind: Sendable { case stroke, fill }
    public let d: String
    public let kind: Kind
    public init(d: String, kind: Kind) { self.d = d; self.kind = kind }
}

public struct IconCircle: Sendable {
    public let cx: CGFloat, cy: CGFloat, r: CGFloat
    public init(cx: CGFloat, cy: CGFloat, r: CGFloat) { self.cx = cx; self.cy = cy; self.r = r }
}

public struct IconDefinition: Sendable {
    public let viewBox: CGFloat
    public let strokeWidth: CGFloat
    public let paths: [IconPath]
    public let circles: [IconCircle]
}

public enum DshIcons {
    public static let catalog: [String: IconDefinition] = [
`

const names = [...icons.keys()].sort()
for (const name of names) {
  const def = icons.get(name)
  const paths = def.paths.filter((p) => p.d)
  const circles = def.paths.filter((p) => p.circle)
  out += `        "${esc(name)}": IconDefinition(viewBox: ${def.viewBox}, strokeWidth: ${def.strokeWidth}, paths: [\n`
  for (const p of paths) {
    out += `            .init(d: "${esc(p.d)}", kind: .${p.fill ? 'fill' : 'stroke'}),\n`
  }
  out += `        ], circles: [\n`
  for (const c of circles) {
    out += `            .init(cx: ${c.circle[0]}, cy: ${c.circle[1]}, r: ${c.circle[2]}),\n`
  }
  out += `        ]),\n`
}

out += `    ]
}
`

mkdirSync(dirname(OUT), { recursive: true })
writeFileSync(OUT, out)

const totalPaths = names.reduce((n, k) => n + icons.get(k).paths.length, 0)
console.log(`icons=${names.length} paths=${totalPaths} -> ${OUT}`)
console.log(names.join(', '))
