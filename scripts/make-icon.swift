// TUIDock 자신의 앱 아이콘(1024px PNG): 어두운 판 위 Dock 선반에 터미널 타일(>_)이 올라앉고 실행 중 점이 붙은 모습.
// 사용: swift scripts/make-icon.swift app/AppIcon.png   (build-app.sh가 그 PNG로 AppIcon.icns를 만든다)
import AppKit

let size = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func fillGradient(_ path: CGPath, _ top: CGColor, _ bottom: CGColor, _ r: CGRect) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [bottom, top] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: r.midX, y: r.minY), end: CGPoint(x: r.midX, y: r.maxY), options: [])
    ctx.restoreGState()
}

// macOS 아이콘 격자: 1024 캔버스에 824 둥근 판(둘레 여백 100)
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let plate = rounded(body, 185)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: rgb(0x000000, 0.4))
ctx.addPath(plate)
ctx.setFillColor(rgb(0x2A2A30))
ctx.fillPath()
ctx.restoreGState()
fillGradient(plate, rgb(0x3B3F4A), rgb(0x16171B), body)

// Dock 선반: 반투명 막대
let shelf = CGRect(x: 160, y: 170, width: 704, height: 150)
ctx.addPath(rounded(shelf, 44))
ctx.setFillColor(rgb(0xFFFFFF, 0.13))
ctx.fillPath()
ctx.addPath(rounded(shelf.insetBy(dx: 1.5, dy: 1.5), 43))
ctx.setStrokeColor(rgb(0xFFFFFF, 0.22))
ctx.setLineWidth(3)
ctx.strokePath()

// 선반에 올라앉은 터미널 타일
let tile = CGRect(x: 302, y: 236, width: 420, height: 420)
let tilePath = rounded(tile, 96)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: rgb(0x000000, 0.55))
ctx.addPath(tilePath)
ctx.setFillColor(rgb(0x0E0F12))
ctx.fillPath()
ctx.restoreGState()
fillGradient(tilePath, rgb(0x23262D), rgb(0x0B0C0E), tile)
ctx.addPath(rounded(tile.insetBy(dx: 2, dy: 2), 94))
ctx.setStrokeColor(rgb(0xFFFFFF, 0.16))
ctx.setLineWidth(4)
ctx.strokePath()

// >_
let prompt = NSAttributedString(string: ">_", attributes: [
    .font: NSFont.monospacedSystemFont(ofSize: 210, weight: .bold),
    .foregroundColor: NSColor(cgColor: rgb(0x5BE38C))!,
])
let ps = prompt.size()
prompt.draw(at: CGPoint(x: tile.midX - ps.width / 2, y: tile.midY - ps.height / 2 + 6))

// 실행 중 점
ctx.addEllipse(in: CGRect(x: 512 - 14, y: 194, width: 28, height: 28))
ctx.setFillColor(rgb(0xFFFFFF, 0.85))
ctx.fillPath()

try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
