// 앱 아이콘 그리기: 이모지는 판 없이 이모지 그림 그대로 캔버스를 채운다(이모지 그림에 여백이 있어 판을 깔면 작아 보인다).
// 이모지가 없으면 macOS 아이콘 격자의 둥근 사각형 판(배경색)에 이름 첫 글자.
// GUI(app/TUIDockApp.swift) 미리보기와 아이콘 도구(icon/main.swift, tuidock make)가 같이 쓴다.
import AppKit

enum IconRender {
    static let defaultColor = "#2B2B2E"

    // png는 1024px 아이콘 PNG. text가 비면 "?".
    static func png(text: String, color hex: String) -> Data {
        let size = 1024
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(text: text, color: color(hex))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    static func image(text: String, color hex: String) -> NSImage {
        NSImage(data: png(text: text, color: hex)) ?? NSImage()
    }

    static func draw(text: String, color: NSColor) {
        let t = text.trimmingCharacters(in: .whitespaces)
        let glyph = t.first.map(String.init) ?? "?"
        if isEmoji(glyph) { drawEmoji(glyph) } else { drawLetter(glyph, color: color) }
    }

    // 이모지 그림 칸(글꼴 크기 정사각형, 그림 자체 여백 포함)을 860 크기(둘레 여백 82, 약 8%)로 맞춘다.
    // 칸 위치는 글리프 경계로 잰다. 캔버스를 꽉 채우면 다른 앱 아이콘보다 커 보인다.
    static func drawEmoji(_ glyph: String) {
        let ctx = NSGraphicsContext.current!.cgContext
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: glyph, attributes: [.font: NSFont.systemFont(ofSize: 1024)]))
        let box = CTLineGetImageBounds(line, ctx)
        guard box.width > 0, box.height > 0 else { return }
        let k = 860 / max(box.width, box.height)
        ctx.saveGState()
        ctx.translateBy(x: (1024 - box.width * k) / 2, y: (1024 - box.height * k) / 2)
        ctx.scaleBy(x: k, y: k)
        ctx.textPosition = CGPoint(x: -box.minX, y: -box.minY)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    // 1024 캔버스에 824 크기 둥근 사각형(위아래 여백 100) — 다른 앱 아이콘과 같은 크기로 보이게. 판이 밝으면 어두운 글씨.
    static func drawLetter(_ glyph: String, color: NSColor) {
        let ctx = NSGraphicsContext.current!.cgContext
        let body = CGRect(x: 100, y: 100, width: 824, height: 824)
        let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: CGColor(gray: 0, alpha: 0.4))
        ctx.addPath(shape)
        ctx.setFillColor(color.cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        let ink = luminance(color) > 0.6 ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.96, alpha: 1)
        let attr = NSAttributedString(string: glyph.uppercased(), attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 520, weight: .semibold), .foregroundColor: ink,
        ])
        let s = attr.size()
        attr.draw(at: CGPoint(x: body.midX - s.width / 2, y: body.midY - s.height / 2))
    }

    static func isEmoji(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value > 0x2000) }
    }

    static func color(_ hex: String) -> NSColor {
        var h = hex.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return color(defaultColor) }
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                       blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }

    static func luminance(_ c: NSColor) -> CGFloat {
        let s = c.usingColorSpace(.sRGB) ?? c
        return 0.299 * s.redComponent + 0.587 * s.greenComponent + 0.114 * s.blueComponent
    }
}
