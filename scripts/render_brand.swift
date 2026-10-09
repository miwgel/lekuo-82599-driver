// Original Lekuo Control artwork. Run with: swift scripts/render_brand.swift
// Generates deterministic vector artwork and the macOS icon sizes without
// external fonts, image services, or embedded author/device metadata.
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let brand = root.appendingPathComponent("Brand")
let icons = root.appendingPathComponent("Lekuo82599App/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: brand, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: icons, withIntermediateDirectories: true)

// A paired transmission lane forms an L. The open right side and contact bars
// reference an SFP+ port without borrowing a vendor's logo.
let dark = NSColor(srgbRed: 0.045, green: 0.105, blue: 0.145, alpha: 1)
let mint = NSColor(srgbRed: 0.39, green: 0.91, blue: 0.77, alpha: 1)
let pale = NSColor(srgbRed: 0.89, green: 0.98, blue: 0.96, alpha: 1)
let laneA: [(CGFloat, CGFloat)] = [(326, 294), (326, 658), (682, 658)]
let laneB: [(CGFloat, CGFloat)] = [(464, 294), (464, 520), (682, 520)]

func lane(_ points: [(CGFloat, CGFloat)], color: NSColor) {
    let path = NSBezierPath()
    path.lineWidth = 78
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    path.move(to: NSPoint(x: points[0].0, y: points[0].1))
    for p in points.dropFirst() { path.line(to: NSPoint(x: p.0, y: p.1)) }
    color.setStroke()
    path.stroke()
}

func render(size: Int) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let transform = NSAffineTransform()
    transform.translateX(by: 0, yBy: CGFloat(size))
    transform.scaleX(by: CGFloat(size) / 1024, yBy: -CGFloat(size) / 1024)
    transform.concat()
    dark.setFill()
    NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896),
                 xRadius: 202, yRadius: 202).fill()
    lane(laneA, color: mint)
    lane(laneB, color: pale)
    mint.withAlphaComponent(0.45).setFill()
    for x in [CGFloat(326), 464] {
        NSBezierPath(roundedRect: NSRect(x: x - 24, y: 760, width: 48, height: 68),
                     xRadius: 24, yRadius: 24).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: icons.appendingPathComponent("icon-\(size).png"))
}

for size in [16, 32, 64, 128, 256, 512, 1024] { try render(size: size) }
let svg = """
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" role="img" aria-label="Lekuo Control paired transmission lanes">
  <rect x="64" y="64" width="896" height="896" rx="202" fill="#0b1b25"/>
  <g fill="none" stroke-width="78" stroke-linecap="round" stroke-linejoin="round">
    <path d="M326 294V658H682" stroke="#63e8c4"/>
    <path d="M464 294V520H682" stroke="#e3faf5"/>
  </g>
  <g fill="#63e8c4" opacity=".45">
    <rect x="302" y="760" width="48" height="68" rx="24"/>
    <rect x="440" y="760" width="48" height="68" rx="24"/>
  </g>
</svg>
"""
try (svg + "\n").write(to: brand.appendingPathComponent("icon.svg"), atomically: true, encoding: .utf8)
let images = [16, 32, 128, 256, 512].flatMap { size in
    [1, 2].map { scale in
        ["idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x", "filename": "icon-\(size * scale).png"]
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: icons.appendingPathComponent("Contents.json"))
print("Generated Lekuo Control vector artwork and seven macOS icon sizes.")
