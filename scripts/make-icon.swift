// 生成应用图标 PNG：蓝绿渐变圆角方块 + 白色消息气泡与转发箭头
// 由 scripts/make-icon.sh 调用：swift scripts/make-icon.swift <输出目录>
import AppKit

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

/// 绘制指定像素尺寸的图标
func drawIcon(size: CGFloat) -> Data? {
  let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

  // macOS 图标规范：内容区约占画布 80%，四周留白
  let inset = size * 0.1
  let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
  let radius = rect.width * 0.225
  let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

  // 轻微投影
  let shadow = NSShadow()
  shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
  shadow.shadowBlurRadius = size * 0.02
  shadow.shadowOffset = NSSize(width: 0, height: -size * 0.01)
  shadow.set()

  // 背景渐变：青绿 → 蓝
  let gradient = NSGradient(
    colors: [
      NSColor(calibratedRed: 0.20, green: 0.84, blue: 0.62, alpha: 1),
      NSColor(calibratedRed: 0.10, green: 0.48, blue: 0.98, alpha: 1),
    ])!
  gradient.draw(in: path, angle: -60)
  NSShadow().set()

  // 白色 SF Symbol：消息气泡 + 转发箭头
  let config = NSImage.SymbolConfiguration(pointSize: rect.width * 0.5, weight: .semibold)
    .applying(.init(paletteColors: [.white]))
  if let symbol = NSImage(systemSymbolName: "arrowshape.turn.up.right.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(config)
  {
    let bubbleConfig = NSImage.SymbolConfiguration(pointSize: rect.width * 0.62, weight: .regular)
      .applying(.init(paletteColors: [NSColor.white.withAlphaComponent(0.95)]))
    if let bubble = NSImage(systemSymbolName: "message.fill", accessibilityDescription: nil)?
      .withSymbolConfiguration(bubbleConfig)
    {
      let b = bubble.size
      bubble.draw(
        in: NSRect(x: rect.midX - b.width / 2, y: rect.midY - b.height / 2, width: b.width, height: b.height))
    }
    // 箭头用渐变色描绘在气泡上
    let s = symbol.size
    let arrowRect = NSRect(
      x: rect.midX - s.width * 0.4, y: rect.midY - s.height * 0.38,
      width: s.width * 0.8, height: s.height * 0.8)
    let tinted = NSImage(size: arrowRect.size, flipped: false) { r in
      symbol.draw(in: r)
      NSColor(calibratedRed: 0.10, green: 0.55, blue: 0.95, alpha: 1).set()
      r.fill(using: .sourceAtop)
      return true
    }
    tinted.draw(in: arrowRect)
  }

  NSGraphicsContext.restoreGraphicsState()
  return rep.representation(using: .png, properties: [:])
}

// iconset 需要的全部尺寸
let sizes: [(name: String, px: CGFloat)] = [
  ("icon_16x16", 16), ("icon_16x16@2x", 32),
  ("icon_32x32", 32), ("icon_32x32@2x", 64),
  ("icon_128x128", 128), ("icon_128x128@2x", 256),
  ("icon_256x256", 256), ("icon_256x256@2x", 512),
  ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for item in sizes {
  guard let data = drawIcon(size: item.px) else { continue }
  try data.write(to: URL(fileURLWithPath: outputDir).appendingPathComponent(item.name + ".png"))
}
print("图标已生成到 \(outputDir)")
