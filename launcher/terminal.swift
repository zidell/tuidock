// 자체 터미널(TUIDockTerminal = builtin): 실행기 프로세스가 창을 직접 갖고 libvterm으로 화면을 그린다.
// Terminal·iTerm2를 띄우지 않아 그 앱 본체 메모리(약 100MB)가 들지 않고, 창·Cmd 단축키·메뉴가 처음부터 이 앱 것이다.
// 박스 그리기 문자는 글꼴 글리프 대신 칸을 꽉 채우는 도형으로 그려 줄간격을 벌려도 선이 이어진다(Terminal.app은 끊긴다).
// TUI 한 개를 띄우는 창이라 탭·분할·스크롤백·설정 창은 없다. 글꼴·줄간격은 Info.plist와 UserDefaults(launcher.swift).
import AppKit

final class TermView: NSView, NSTextInputClient {
    private var vt: OpaquePointer!
    private var screen: OpaquePointer!
    private var state: OpaquePointer!
    private var callbacks = VTermScreenCallbacks()
    private var fallbacks = VTermStateFallbacks()
    private(set) var rows: Int
    private(set) var cols: Int
    private(set) var master: Int32 = -1
    private var reader: DispatchSourceRead?
    let pad: CGFloat = 4
    // 다크·라이트 알림(모드 2031, contour 확장). 프로그램이 켜 두면 모양이 바뀔 때 CSI ? 997 ; 1(다크)·2(라이트) n을 보낸다.
    // libvterm은 이 모드를 모르니 넘기기 전 바이트에서 직접 찾는다(scanTail은 읽기 두 번에 걸친 시퀀스용 지난 끝 바이트).
    private var lightDarkMode = false
    private var reportedDark: Bool?
    private var scanTail: [UInt8] = []

    // 글꼴. 크기는 Cmd +/-로 바뀌고, 줄간격은 글꼴 본래 줄 높이의 배수
    private(set) var fontName: String?
    private(set) var fontSize: CGFloat
    private(set) var lineHeight: CGFloat
    // 대비(-100…100%, 0이면 프로그램 색 그대로). +면 글자색을 흰색(어두운 배경)·검정(밝은 배경) 쪽으로 값/100만큼,
    // -면 배경 쪽으로 (값/100)×0.8만큼 섞는다. 다크에서 올리면 밝아지고 내리면 어두워진다.
    var contrast: CGFloat = 0 {
        didSet {
            guard contrast != oldValue else { return }
            needsDisplay = true
        }
    }
    private var fonts: [CTFont] = [] // 보통·굵게·기울임·굵은 기울임
    private(set) var cellW: CGFloat = 8
    private(set) var cellH: CGFloat = 16
    private var baseline: CGFloat = 12
    private var glyphs: [UInt64: (CTFont, CGGlyph, CGFloat)] = [:] // (글자 | 모양 << 32) → 글꼴(대체 글꼴일 수 있음)·글리프·폭

    // 프로그램이 정한 속성
    private var cursor = VTermPos(row: 0, col: 0)
    private var cursorVisible = true
    private var cursorShape = Int32(VTERM_PROP_CURSORSHAPE_BLOCK)
    private(set) var mouseMode = Int32(VTERM_PROP_MOUSE_NONE)
    private var altScreen = false
    private var reverseScreen = false
    private var titleBuf = Data()
    var onTitle: ((String) -> Void)?
    var onResize: (() -> Void)? // 칸 수가 바뀜(창 크기 조절·글꼴)
    var onCmdKey: ((NSEvent) -> Bool)? // Cmd 조합. true면 처리됨(프로그램에 넘김), false면 메뉴로
    var onExitKey: (() -> Void)? // 프로그램이 오류로 끝난 뒤 아무 키
    private var exited = false

    // 입력기(한글 조합 중 글자)와 선택
    private var marked = ""
    // 조합 중 글자를 그릴 자리: 커서가 보이는 동안의 마지막 위치. TUI(Bubble Tea 등)는 프레임마다 커서를 숨기고(?25l)
    // 바뀐 칸을 쓰며 커서를 옮긴 뒤 제자리에서 다시 보인다(?25h). 출력이 나뉘어 들어와 그 중간에 그리면 숨긴 커서의
    // 중간 위치(사이드바 등)에 조합 중 글자가 찍혀서, 숨긴 동안의 이동은 따르지 않는다.
    private var markedAt = VTermPos(row: 0, col: 0)
    private var selAnchor: VTermPos?
    private var selHead: VTermPos?
    private var wheel: CGFloat = 0

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    init(rows: Int, cols: Int, fontName: String?, fontSize: CGFloat, lineHeight: CGFloat) {
        self.rows = rows
        self.cols = cols
        self.fontName = fontName
        self.fontSize = fontSize
        self.lineHeight = lineHeight
        super.init(frame: .zero)
        setFonts()
        vt = vterm_new(Int32(rows), Int32(cols))
        vterm_set_utf8(vt, 1)
        state = vterm_obtain_state(vt)
        screen = vterm_obtain_screen(vt)
        vterm_screen_enable_altscreen(screen, 1)
        vterm_state_set_bold_highbright(state, 1) // Terminal.app처럼 굵은 글자는 밝은 색
        // Terminal.app "Basic" 프로필의 16색
        let palette: [(UInt8, UInt8, UInt8)] = [
            (0, 0, 0), (153, 0, 0), (0, 166, 0), (153, 153, 0), (0, 0, 178), (178, 0, 178), (0, 166, 178), (191, 191, 191),
            (102, 102, 102), (229, 0, 0), (0, 217, 0), (229, 229, 0), (0, 0, 255), (229, 0, 229), (0, 229, 229), (229, 229, 229),
        ]
        for (i, c) in palette.enumerated() {
            var col = VTermColor()
            vterm_color_rgb(&col, c.0, c.1, c.2)
            vterm_state_set_palette_color(state, Int32(i), &col)
        }
        let me = Unmanaged.passUnretained(self).toOpaque()
        vterm_output_set_callback(vt, { bytes, len, user in
            guard let bytes, let user else { return }
            let v = Unmanaged<TermView>.fromOpaque(user).takeUnretainedValue()
            var off = 0
            while off < len {
                let n = write(v.master, bytes + off, len - off)
                if n <= 0 { break }
                off += n
            }
        }, me)
        callbacks.damage = { rect, user in
            TermView.of(user).damage(Int(rect.start_row), Int(rect.end_row))
            return 1
        }
        callbacks.moverect = { dest, src, user in
            TermView.of(user).damage(Int(min(dest.start_row, src.start_row)), Int(max(dest.end_row, src.end_row)))
            return 1
        }
        callbacks.movecursor = { pos, old, _, user in
            let v = TermView.of(user)
            v.cursor = pos
            v.damage(Int(old.row), Int(old.row) + 1)
            v.damage(Int(pos.row), Int(pos.row) + 1)
            if v.cursorVisible { v.moveMarked() }
            return 1
        }
        callbacks.settermprop = { prop, val, user in
            guard let val else { return 0 }
            TermView.of(user).setProp(prop, val.pointee)
            return 1
        }
        callbacks.bell = { _ in
            NSSound.beep()
            return 1
        }
        vterm_screen_set_callbacks(screen, &callbacks, me)
        // OSC 10·11 "?"(글자·배경색 묻기)에 답한다. calendar-tui(lipgloss) 같은 TUI가 이걸로 다크·라이트를 고른다.
        // 답이 없으면 어둡다고 보고 라이트 모드에서도 어두운 배경용 색을 쓴다(Terminal.app은 답한다)
        fallbacks.osc = { cmd, frag, user in
            guard cmd == 10 || cmd == 11, frag.initial, frag.final, frag.len == 1, frag.str?.pointee == 0x3F else { return 0 }
            TermView.of(user).reportColor(Int(cmd))
            return 1
        }
        vterm_screen_set_unrecognised_fallbacks(screen, &fallbacks, me)
        vterm_screen_reset(screen, 1)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        reader?.cancel()
        if vt != nil { vterm_free(vt) }
    }

    private static func of(_ user: UnsafeMutableRawPointer?) -> TermView {
        Unmanaged<TermView>.fromOpaque(user!).takeUnretainedValue()
    }

    // MARK: 프로그램

    // start는 pty에서 프로그램을 띄우고 pid를 돌려준다(실패 -1).
    func start(path: String, argv: [String], env: [String: String]) -> pid_t {
        let envStrings = env.map { "\($0.key)=\($0.value)" }
        var cArgs = argv.map { strdup($0) } + [nil]
        var cEnv = envStrings.map { strdup($0) } + [nil]
        defer {
            cArgs.forEach { free($0) }
            cEnv.forEach { free($0) }
        }
        let pid = tuidock_spawn(path, &cArgs, &cEnv, Int32(rows), Int32(cols), &master)
        guard pid > 0 else { return -1 }
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
        let src = DispatchSource.makeReadSource(fileDescriptor: master, queue: .main)
        // 앞 4바이트는 지난 읽기 끝에 걸린 덜 끝난 UTF-8 글자 자리. libvterm 0.3.3은 이스케이프 코드 뒤에서 여러 바이트 글자가
        // 두 번의 쓰기로 나뉘면 U+FFFD로 바꾼다(실측: 색 지정 + "←↑ 이동"을 글자 중간에서 자르면 모두 깨짐). 그래서 넘기기 전에 끝의
        // 덜 끝난 글자를 떼어 두었다가 다음 읽기 앞에 붙인다.
        var buf = [UInt8](repeating: 0, count: 65536 + 4)
        var carry = 0
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let n = buf.withUnsafeMutableBufferPointer { read(self.master, $0.baseAddress! + carry, 65536) }
            if n > 0 {
                let total = carry + n
                let keep = Self.incompleteUTF8Tail(buf, total)
                self.watchLightDark(buf[carry..<total])
                _ = buf.withUnsafeBufferPointer { p in
                    p.baseAddress!.withMemoryRebound(to: CChar.self, capacity: total) { vterm_input_write(self.vt, $0, total - keep) }
                }
                for i in 0..<keep { buf[i] = buf[total - keep + i] }
                carry = keep
                vterm_screen_flush_damage(self.screen)
            } else if n == 0 || errno != EAGAIN {
                self.reader?.cancel() // 프로그램이 끝남. 종료 처리는 실행기가 pid로 한다
            }
        }
        src.setCancelHandler { [weak self] in
            if let self, self.master >= 0 { close(self.master); self.master = -1 }
        }
        src.resume()
        reader = src
        resizePTY()
        return pid
    }

    // watchLightDark는 프로그램 출력에서 2031 켜기·끄기와 지금 모양 묻기(CSI ? 996 n)를 찾는다.
    private func watchLightDark(_ chunk: ArraySlice<UInt8>) {
        let hay = scanTail + chunk
        scanTail = Array(hay.suffix(8))
        guard hay.contains(0x1b) else { return }
        let set = Array("\u{1b}[?2031h".utf8), reset = Array("\u{1b}[?2031l".utf8), ask = Array("\u{1b}[?996n".utf8)
        // 지난 끝 바이트에서 이미 끝난 시퀀스를 또 세지 않게, 이번 읽기 바이트에서 끝나는 것만 본다.
        let fresh = hay.count - chunk.count
        var asked = false
        for i in hay.indices where hay[i] == 0x1b {
            func at(_ seq: [UInt8]) -> Bool {
                i + seq.count > fresh && i + seq.count <= hay.count && hay[i..<i + seq.count].elementsEqual(seq)
            }
            // 켤 때는 알리지 않고 지금 모양만 기억한다(프로그램은 시작할 때 OSC 11 등으로 이미 안다).
            if at(set) { lightDarkMode = true; reportedDark = isDark } else if at(reset) { lightDarkMode = false } else if at(ask) { asked = true }
        }
        if asked { reportLightDark(force: true) }
    }

    // isDark는 OSC 11 답(reportColor)과 같은 기본 배경으로 다크·라이트를 가른다.
    private var isDark: Bool {
        var dark = true
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if let c = defaultBG.usingColorSpace(.sRGB) { dark = Self.luminance(c) < 0.18 }
        }
        return dark
    }

    // reportLightDark는 지금 모양을 997로 알린다. force가 아니면 지난번 알린 값과 다를 때만 보낸다(모양 바뀜 알림은 여러 번 올 수 있다).
    private func reportLightDark(force: Bool) {
        guard master >= 0 else { return }
        let dark = isDark
        guard force || dark != reportedDark else { return }
        reportedDark = dark
        let out = "\u{1b}[?997;\(dark ? 1 : 2)n"
        _ = out.withCString { write(master, $0, strlen($0)) }
    }

    // finished는 프로그램이 오류로 끝났을 때 창에 알리고 아무 키나 기다린다(Terminal.app처럼 메시지가 남게).
    func finished(_ message: String) {
        exited = true
        let s = "\r\n\u{1b}[0m\u{1b}[?25l" + message
        _ = s.withCString { vterm_input_write(vt, $0, strlen($0)) }
        vterm_screen_flush_damage(screen)
    }

    // incompleteUTF8Tail은 b[0..<n] 끝에서 아직 덜 들어온 UTF-8 글자의 바이트 수(0이면 끝이 온전).
    static func incompleteUTF8Tail(_ b: [UInt8], _ n: Int) -> Int {
        var i = n - 1
        while i >= 0, i >= n - 4, b[i] & 0xC0 == 0x80 { i -= 1 } // 이어지는 바이트를 건너 첫 바이트로
        guard i >= 0, i >= n - 4 else { return 0 }
        let lead = b[i], need = lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : lead >= 0xC0 ? 2 : 1
        return n - i < need ? n - i : 0
    }

    // reportColor는 지금 화면 모양(다크·라이트)의 기본 글자색(10)·배경색(11)을 xterm 형식으로 답한다.
    private func reportColor(_ cmd: Int) {
        var out = ""
        effectiveAppearance.performAsCurrentDrawingAppearance {
            guard let c = (cmd == 10 ? defaultFG : defaultBG).usingColorSpace(.sRGB) else { return }
            func h(_ v: CGFloat) -> String { String(format: "%04x", Int((v * 65535).rounded())) }
            out = "\u{1b}]\(cmd);rgb:\(h(c.redComponent))/\(h(c.greenComponent))/\(h(c.blueComponent))\u{1b}\\"
        }
        guard master >= 0, !out.isEmpty else { return }
        _ = out.withCString { write(master, $0, strlen($0)) }
    }

    private func setProp(_ prop: VTermProp, _ val: VTermValue) {
        switch prop {
        case VTERM_PROP_CURSORVISIBLE:
            cursorVisible = val.boolean != 0
            if cursorVisible { moveMarked() }
        case VTERM_PROP_CURSORSHAPE: cursorShape = val.number
        case VTERM_PROP_MOUSE: mouseMode = val.number
        case VTERM_PROP_ALTSCREEN: altScreen = val.boolean != 0
        case VTERM_PROP_REVERSE:
            reverseScreen = val.boolean != 0
            needsDisplay = true
        case VTERM_PROP_TITLE:
            let f = val.string
            if f.initial { titleBuf.removeAll() }
            if let p = f.str { titleBuf.append(Data(bytes: p, count: Int(f.len))) }
            if f.final { onTitle?(String(decoding: titleBuf, as: UTF8.self)) }
        default: break
        }
        damage(Int(cursor.row), Int(cursor.row) + 1)
    }

    // MARK: 크기·글꼴

    private func setFonts() {
        // 고정폭 표시가 없는 글꼴도 그대로 쓴다(D2Coding은 한글이 2칸이라 isFixedPitch가 아니다). 없는 이름이면 시스템 고정폭
        // 이름은 PostScript 이름("Menlo-Regular")이나 글꼴 모음 이름("JetBrains Mono") 어느 쪽이든
        let base = fontName.flatMap { NSFont(name: $0, size: fontSize) ?? NSFontManager.shared.font(withFamily: $0, traits: [], weight: 5, size: fontSize) }
            ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let fm = NSFontManager.shared
        let bold = fm.convert(base, toHaveTrait: .boldFontMask)
        fonts = [base, bold, fm.convert(base, toHaveTrait: .italicFontMask), fm.convert(bold, toHaveTrait: .italicFontMask)]
        glyphs.removeAll()
        var g = CGGlyph(0)
        var m: UniChar = 0x4D // M
        CTFontGetGlyphsForCharacters(base, &m, &g, 1)
        var adv = CGSize.zero
        CTFontGetAdvancesForGlyphs(base, .horizontal, &g, &adv, 1)
        cellW = ceil(adv.width)
        // 글꼴 본래 줄 높이(AppKit 기본과 같이 합친 뒤 반올림). 따로 올림하면 D2Coding 13pt가 15 대신 17이 됐다
        let natural = (base.ascender - base.descender + base.leading).rounded()
        cellH = max(natural, ceil(natural * lineHeight))
        baseline = floor((cellH - natural) / 2) + (base.leading / 2).rounded() + base.ascender.rounded()
    }

    // contentSize는 cols×rows 칸이 들어가는 크기.
    func contentSize(cols c: Int, rows r: Int) -> NSSize {
        NSSize(width: CGFloat(c) * cellW + 2 * pad, height: CGFloat(r) * cellH + 2 * pad)
    }

    // setStyle은 칸 수를 그대로 두고 글꼴·줄간격을 바꾼다(창 크기는 실행기가 맞춘다).
    func setStyle(fontName: String?, fontSize: CGFloat, lineHeight: CGFloat) {
        self.fontName = fontName
        self.fontSize = fontSize
        self.lineHeight = lineHeight
        setFonts()
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let c = max(10, Int((newSize.width - 2 * pad) / cellW)), r = max(2, Int((newSize.height - 2 * pad) / cellH))
        guard c != cols || r != rows else { return }
        cols = c
        rows = r
        vterm_set_size(vt, Int32(r), Int32(c))
        vterm_screen_flush_damage(screen)
        resizePTY()
        selAnchor = nil
        needsDisplay = true
        onResize?()
    }

    private func resizePTY() {
        guard master >= 0 else { return }
        tuidock_resize(master, Int32(rows), Int32(cols), Int32(CGFloat(cols) * cellW), Int32(CGFloat(rows) * cellH))
    }

    // moveMarked는 조합 중 글자 자리를 지금 커서로 옮긴다(커서가 보일 때만 부른다).
    private func moveMarked() {
        guard markedAt.row != cursor.row || markedAt.col != cursor.col else { return }
        if !marked.isEmpty { damage(Int(markedAt.row), Int(markedAt.row) + 1) }
        markedAt = cursor
        if !marked.isEmpty { damage(Int(markedAt.row), Int(markedAt.row) + 1) }
    }

    private func damage(_ start: Int, _ end: Int) {
        let s = max(0, start), e = min(rows, max(end, start + 1))
        guard s < e else { return }
        setNeedsDisplay(NSRect(x: 0, y: pad + CGFloat(s) * cellH, width: bounds.width, height: CGFloat(e - s) * cellH).insetBy(dx: 0, dy: -1))
    }

    override func viewDidChangeEffectiveAppearance() {
        needsDisplay = true
        if lightDarkMode { reportLightDark(force: false) }
    }

    // MARK: 그리기

    private var defaultFG: NSColor { reverseScreen ? .textBackgroundColor : .textColor }
    private var defaultBG: NSColor { reverseScreen ? .textColor : .textBackgroundColor }

    private func color(_ c: VTermColor, fg: Bool) -> NSColor {
        var c = c
        if fg, c.type & UInt8(VTERM_COLOR_DEFAULT_FG.rawValue) != 0 { return defaultFG }
        if !fg, c.type & UInt8(VTERM_COLOR_DEFAULT_BG.rawValue) != 0 { return defaultBG }
        vterm_screen_convert_color_to_rgb(screen, &c)
        return NSColor(srgbRed: CGFloat(c.rgb.red) / 255, green: CGFloat(c.rgb.green) / 255, blue: CGFloat(c.rgb.blue) / 255, alpha: 1)
    }

    private static func luminance(_ c: NSColor) -> CGFloat {
        func lin(_ v: CGFloat) -> CGFloat { v <= 0.039_28 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.redComponent) + 0.7152 * lin(c.greenComponent) + 0.0722 * lin(c.blueComponent)
    }

    // readable은 contrast만큼 fg를 섞는다(위 contrast 설명). 0이면 그대로.
    private func readable(_ fg: NSColor, on bg: NSColor) -> NSColor {
        guard contrast != 0, let f = fg.usingColorSpace(.sRGB), let b = bg.usingColorSpace(.sRGB) else { return fg }
        if contrast < 0 { return f.blended(withFraction: -contrast / 100 * 0.8, of: b) ?? f }
        return f.blended(withFraction: contrast / 100, of: Self.luminance(b) < 0.18 ? .white : .black) ?? f
    }

    override func draw(_ dirty: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // 기본 배경은 시스템 텍스트 배경(라이트·다크 따라감)
        defaultBG.usingColorSpace(.sRGB)?.setFill()
        dirty.fill()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        let first = max(0, Int((dirty.minY - pad) / cellH)), last = min(rows - 1, Int((dirty.maxY - pad) / cellH))
        guard first <= last else { return }
        for r in first...last {
            let y = pad + CGFloat(r) * cellH
            let info = vterm_state_get_lineinfo(state, Int32(r))?.pointee
            if let info, info.doublewidth != 0 {
                // DEC 2배 폭(DECDWL)·2배 크기(DECDHL) 줄: 칸을 2배로 키워 그린다. 2배 크기는 위·아래 줄이 각각 절반을 그린다
                ctx.saveGState()
                ctx.clip(to: CGRect(x: 0, y: y, width: bounds.width, height: cellH))
                let dh = info.doubleheight
                ctx.translateBy(x: pad, y: dh == 2 ? y - cellH : y)
                ctx.scaleBy(x: 2, y: dh == 0 ? 1 : 2)
                drawRow(ctx, r, upTo: cols / 2)
                ctx.restoreGState()
            } else {
                ctx.saveGState()
                ctx.translateBy(x: pad, y: y)
                drawRow(ctx, r, upTo: cols)
                ctx.restoreGState()
            }
        }
        drawCursor(ctx)
    }

    // drawRow는 한 줄을 (0,0) 기준으로 그린다: 배경 → 선택 → 글자·선.
    private func drawRow(_ ctx: CGContext, _ r: Int, upTo n: Int) {
        var cell = VTermScreenCell()
        // 글자는 같은 글꼴·색끼리 모아 한 번에 그린다
        var runFont: CTFont?
        var runColor: NSColor?
        var runGlyphs: [CGGlyph] = []
        var runPos: [CGPoint] = []
        func flush() {
            if let f = runFont, let c = runColor, !runGlyphs.isEmpty {
                ctx.setFillColor(c.cgColor)
                CTFontDrawGlyphs(f, runGlyphs, runPos, runGlyphs.count, ctx)
            }
            runGlyphs.removeAll(keepingCapacity: true)
            runPos.removeAll(keepingCapacity: true)
        }
        var c = 0
        while c < n {
            vterm_screen_get_cell(screen, VTermPos(row: Int32(r), col: Int32(c)), &cell)
            let w = max(1, Int(cell.width))
            defer { c += w }
            var fg = color(cell.fg, fg: true), bg = color(cell.bg, fg: false)
            if cell.attrs.reverse != 0 { swap(&fg, &bg) }
            // SGR 2(흐리게, Claude Code의 제안 글자 등): 배경 쪽으로 절반. 그 뒤 대비 보정.
            if cell.attrs.dim != 0 { fg = fg.blended(withFraction: 0.5, of: bg) ?? fg }
            fg = readable(fg, on: bg)
            let rect = CGRect(x: CGFloat(c) * cellW, y: 0, width: CGFloat(w) * cellW, height: cellH)
            if bg != defaultBG {
                ctx.setFillColor(bg.cgColor)
                ctx.fill(rect)
            }
            if selected(r, c) {
                ctx.setFillColor(NSColor.selectedTextBackgroundColor.withAlphaComponent(0.6).cgColor)
                ctx.fill(rect)
            }
            let ch = cell.chars.0
            guard ch != 0, ch != 32, ch != 0xFFFF_FFFF, cell.attrs.conceal == 0 else { continue }
            if cell.chars.1 == 0, drawBoxGlyph(ctx, rect, ch, fg) { continue }
            let style = (cell.attrs.bold != 0 ? 1 : 0) | (cell.attrs.italic != 0 ? 2 : 0)
            if cell.chars.1 != 0 {
                // 결합 문자(악센트 등): 드물어 CTLine으로 따로
                flush()
                var s = ""
                for u in [cell.chars.0, cell.chars.1, cell.chars.2] where u != 0 { if let sc = UnicodeScalar(u) { s.unicodeScalars.append(sc) } }
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: fonts[style], .foregroundColor: fg]))
                ctx.textPosition = CGPoint(x: rect.minX, y: baseline)
                CTLineDraw(line, ctx)
            } else if let (f, g, adv) = glyph(ch, style, wide: w > 1) {
                if runFont.map({ !CFEqual($0, f) }) ?? true || runColor != fg {
                    flush()
                    runFont = f
                    runColor = fg
                }
                runGlyphs.append(g)
                runPos.append(CGPoint(x: rect.minX + max(0, (rect.width - adv) / 2) * (w > 1 ? 1 : 0), y: -baseline)) // 글자 행렬이 y를 뒤집으므로(뒤집힌 뷰) 위치도 뒤집어 준다
            }
            if cell.attrs.underline != 0 {
                ctx.setFillColor(fg.cgColor)
                ctx.fill(CGRect(x: rect.minX, y: baseline + 2, width: rect.width, height: 1))
                if cell.attrs.underline == 2 { ctx.fill(CGRect(x: rect.minX, y: baseline + 4, width: rect.width, height: 1)) }
            }
            if cell.attrs.strike != 0 {
                ctx.setFillColor(fg.cgColor)
                ctx.fill(CGRect(x: rect.minX, y: floor(cellH / 2), width: rect.width, height: 1))
            }
        }
        flush()
    }

    // glyph는 글자의 글리프를 찾는다(글꼴에 없으면 시스템 대체 글꼴, 한글·이모지 등).
    // 2칸 글자를 대체 글꼴로 그릴 땐 2칸 너비에 맞게 키운다(Terminal.app과 같음). 원래 크기면 글자가 작고 사이가 벌어진다.
    private func glyph(_ ch: UInt32, _ style: Int, wide: Bool) -> (CTFont, CGGlyph, CGFloat)? {
        let key = UInt64(ch) | UInt64(style) << 32 | (wide ? 1 << 40 : 0)
        if let g = glyphs[key] { return g }
        guard let scalar = UnicodeScalar(ch) else { return nil }
        let s = String(Character(scalar))
        var units = Array(s.utf16)
        var gl = [CGGlyph](repeating: 0, count: units.count)
        var font = fonts[style]
        if !CTFontGetGlyphsForCharacters(font, &units, &gl, units.count) || gl[0] == 0 {
            font = CTFontCreateForString(fonts[style], s as CFString, CFRange(location: 0, length: units.count))
            gl = [CGGlyph](repeating: 0, count: units.count)
            CTFontGetGlyphsForCharacters(font, &units, &gl, units.count)
        }
        var adv = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &gl, &adv, 1)
        if wide, !CFEqual(font, fonts[style]), adv.width > 0, adv.width < 2 * cellW * 0.9 {
            // 줄 높이를 넘지 않는 만큼만
            let height = CTFontGetAscent(font) + CTFontGetDescent(font)
            let scale = min(2 * cellW * 0.95 / adv.width, 1.4, cellH / max(height, 1))
            if scale > 1 {
                font = CTFontCreateCopyWithAttributes(font, CTFontGetSize(font) * scale, nil, nil)
                CTFontGetAdvancesForGlyphs(font, .horizontal, &gl, &adv, 1)
            }
        }
        let r = (font, gl[0], adv.width)
        glyphs[key] = r
        return r
    }

    private func drawCursor(_ ctx: CGContext) {
        if !marked.isEmpty {
            // 입력기 조합 중 글자는 커서가 보였던 마지막 자리에 밑줄과 함께
            let x = pad + CGFloat(markedAt.col) * cellW, y = pad + CGFloat(markedAt.row) * cellH
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: marked, attributes: [.font: fonts[0], .foregroundColor: defaultFG]))
            let w = max(cellW, ceil(CTLineGetTypographicBounds(line, nil, nil, nil)))
            ctx.setFillColor(defaultBG.cgColor)
            ctx.fill(CGRect(x: x, y: y, width: w, height: cellH))
            ctx.textPosition = CGPoint(x: x, y: y + baseline)
            CTLineDraw(line, ctx)
            ctx.setFillColor(NSColor.controlAccentColor.cgColor)
            ctx.fill(CGRect(x: x, y: y + cellH - 2, width: w, height: 2))
            return
        }
        guard cursorVisible, !exited else { return }
        let x = pad + CGFloat(cursor.col) * cellW, y = pad + CGFloat(cursor.row) * cellH
        let r = CGRect(x: x, y: y, width: cellW, height: cellH)
        let c = defaultFG
        guard window?.isKeyWindow == true else {
            ctx.setStrokeColor(c.withAlphaComponent(0.6).cgColor)
            ctx.stroke(r.insetBy(dx: 0.5, dy: 0.5), width: 1)
            return
        }
        switch cursorShape {
        case Int32(VTERM_PROP_CURSORSHAPE_BAR_LEFT):
            ctx.setFillColor(c.cgColor)
            ctx.fill(CGRect(x: x, y: y, width: 2, height: cellH))
        case Int32(VTERM_PROP_CURSORSHAPE_UNDERLINE):
            ctx.setFillColor(c.cgColor)
            ctx.fill(CGRect(x: x, y: y + cellH - 2, width: cellW, height: 2))
        default:
            ctx.setFillColor(c.withAlphaComponent(0.45).cgColor)
            ctx.fill(r)
        }
    }

    // MARK: 박스 그리기 문자 (Gifiles TerminalWidget::drawBoxGlyph와 같은 규칙)

    // U+2500–254B의 팔(가운데에서 각 변으로): 위 | 오른쪽 << 2 | 아래 << 4 | 왼쪽 << 6 (0 없음, 1 가는 선, 2 굵은 선).
    // 0은 점선(U+2504–250B)이라 글꼴 글리프를 쓴다.
    private static func arms(_ u: Int, _ r: Int, _ d: Int, _ l: Int) -> UInt8 { UInt8(u | r << 2 | d << 4 | l << 6) }
    private static let lines: [UInt8] = [
        arms(0, 1, 0, 1), arms(0, 2, 0, 2), arms(1, 0, 1, 0), arms(2, 0, 2, 0), 0, 0, 0, 0, 0, 0, 0, 0, // ─━│┃ 점선
        arms(0, 1, 1, 0), arms(0, 2, 1, 0), arms(0, 1, 2, 0), arms(0, 2, 2, 0), // ┌┍┎┏
        arms(0, 0, 1, 1), arms(0, 0, 1, 2), arms(0, 0, 2, 1), arms(0, 0, 2, 2), // ┐┑┒┓
        arms(1, 1, 0, 0), arms(1, 2, 0, 0), arms(2, 1, 0, 0), arms(2, 2, 0, 0), // └┕┖┗
        arms(1, 0, 0, 1), arms(1, 0, 0, 2), arms(2, 0, 0, 1), arms(2, 0, 0, 2), // ┘┙┚┛
        arms(1, 1, 1, 0), arms(1, 2, 1, 0), arms(2, 1, 1, 0), arms(1, 1, 2, 0), // ├┝┞┟
        arms(2, 1, 2, 0), arms(2, 2, 1, 0), arms(1, 2, 2, 0), arms(2, 2, 2, 0), // ┠┡┢┣
        arms(1, 0, 1, 1), arms(1, 0, 1, 2), arms(2, 0, 1, 1), arms(1, 0, 2, 1), // ┤┥┦┧
        arms(2, 0, 2, 1), arms(2, 0, 1, 2), arms(1, 0, 2, 2), arms(2, 0, 2, 2), // ┨┩┪┫
        arms(0, 1, 1, 1), arms(0, 1, 1, 2), arms(0, 2, 1, 1), arms(0, 2, 1, 2), // ┬┭┮┯
        arms(0, 1, 2, 1), arms(0, 1, 2, 2), arms(0, 2, 2, 1), arms(0, 2, 2, 2), // ┰┱┲┳
        arms(1, 1, 0, 1), arms(1, 1, 0, 2), arms(1, 2, 0, 1), arms(1, 2, 0, 2), // ┴┵┶┷
        arms(2, 1, 0, 1), arms(2, 1, 0, 2), arms(2, 2, 0, 1), arms(2, 2, 0, 2), // ┸┹┺┻
        arms(1, 1, 1, 1), arms(1, 1, 1, 2), arms(1, 2, 1, 1), arms(1, 2, 1, 2), // ┼┽┾┿
        arms(2, 1, 1, 1), arms(1, 1, 2, 1), arms(2, 1, 2, 1), arms(2, 1, 1, 2), // ╀╁╂╃
        arms(2, 2, 1, 1), arms(1, 1, 2, 2), arms(1, 2, 2, 1), arms(2, 2, 1, 2), // ╄╅╆╇
        arms(1, 2, 2, 2), arms(2, 1, 2, 2), arms(2, 2, 2, 1), arms(2, 2, 2, 2), // ╈╉╊╋
    ]
    // U+2574–257F: 반쪽 선
    private static let halfLines: [UInt8] = [
        arms(0, 0, 0, 1), arms(1, 0, 0, 0), arms(0, 1, 0, 0), arms(0, 0, 1, 0), // ╴╵╶╷
        arms(0, 0, 0, 2), arms(2, 0, 0, 0), arms(0, 2, 0, 0), arms(0, 0, 2, 0), // ╸╹╺╻
        arms(0, 2, 0, 1), arms(1, 0, 2, 0), arms(0, 1, 0, 2), arms(2, 0, 1, 0), // ╼╽╾╿
    ]
    // U+2596–259F: 사분면(왼쪽 위 1 | 오른쪽 위 2 | 왼쪽 아래 4 | 오른쪽 아래 8)
    private static let quadrants: [UInt8] = [4, 8, 1, 1 | 4 | 8, 1 | 8, 1 | 2 | 4, 1 | 2 | 8, 2, 2 | 4, 2 | 4 | 8]

    // drawBoxGlyph는 선(U+2500–257F)·블록(U+2580–259F)을 칸 전체에 도형으로 그린다. 아니면 false(글꼴 글리프로).
    func drawBoxGlyph(_ ctx: CGContext, _ cell: CGRect, _ ch: UInt32, _ color: NSColor) -> Bool {
        let x = cell.minX, y = cell.minY, w = cell.width, h = cell.height
        let light = max(1, (w / 8).rounded()), heavy = 2 * light
        // 선 가운데를 픽셀 경계에 두어 이웃 칸의 선과 정확히 만나게
        let cx = x + floor(w / 2), cy = y + floor(h / 2)
        ctx.setFillColor(color.cgColor)
        var a: UInt8 = 0
        if (0x2500...0x254B).contains(ch) { a = Self.lines[Int(ch - 0x2500)] }
        if (0x2574...0x257F).contains(ch) { a = Self.halfLines[Int(ch - 0x2574)] }
        if a != 0 {
            func thick(_ shift: UInt8) -> CGFloat { [0, light, heavy, heavy][Int((a >> shift) & 3)] }
            let up = thick(0), right = thick(2), down = thick(4), left = thick(6)
            // 각 팔은 변에서 가운데를 지나 교차하는 팔을 덮을 만큼 들어간다
            let hMax = max(left, right), vMax = max(up, down)
            if up > 0 { ctx.fill(CGRect(x: cx - up / 2, y: y, width: up, height: cy - y + max(hMax, up) / 2)) }
            if down > 0 { ctx.fill(CGRect(x: cx - down / 2, y: cy - max(hMax, down) / 2, width: down, height: y + h - cy + max(hMax, down) / 2)) }
            if left > 0 { ctx.fill(CGRect(x: x, y: cy - left / 2, width: cx - x + max(vMax, left) / 2, height: left)) }
            if right > 0 { ctx.fill(CGRect(x: cx - max(vMax, right) / 2, y: cy - right / 2, width: x + w - cx + max(vMax, right) / 2, height: right)) }
            return true
        }
        if (0x256D...0x2570).contains(ch) { // ╭╮╯╰
            let goesDown = ch == 0x256D || ch == 0x256E, goesRight = ch == 0x256D || ch == 0x2570
            let r = min(w, h) / 2
            ctx.saveGState()
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(light)
            ctx.move(to: CGPoint(x: cx, y: goesDown ? y + h : y))
            ctx.addLine(to: CGPoint(x: cx, y: goesDown ? cy + r : cy - r))
            ctx.addQuadCurve(to: CGPoint(x: goesRight ? cx + r : cx - r, y: cy), control: CGPoint(x: cx, y: cy))
            ctx.addLine(to: CGPoint(x: goesRight ? x + w : x, y: cy))
            ctx.strokePath()
            ctx.restoreGState()
            return true
        }
        guard (0x2580...0x259F).contains(ch) else { return false }
        func rows(_ n: UInt32) -> CGFloat { (h * CGFloat(n) / 8).rounded() }
        func cols(_ n: UInt32) -> CGFloat { (w * CGFloat(n) / 8).rounded() }
        switch ch {
        case 0x2580: ctx.fill(CGRect(x: x, y: y, width: w, height: rows(4))) // ▀
        case 0x2581...0x2588: ctx.fill(CGRect(x: x, y: y + h - rows(ch - 0x2580), width: w, height: rows(ch - 0x2580))) // ▁…█
        case 0x2589...0x258F: ctx.fill(CGRect(x: x, y: y, width: cols(0x2590 - ch), height: h)) // ▉…▏
        case 0x2590: ctx.fill(CGRect(x: x + cols(4), y: y, width: w - cols(4), height: h)) // ▐
        case 0x2591...0x2593: // ░▒▓
            ctx.setFillColor(color.withAlphaComponent(CGFloat(ch - 0x2590) / 4).cgColor)
            ctx.fill(cell)
        case 0x2594: ctx.fill(CGRect(x: x, y: y, width: w, height: rows(1))) // ▔
        case 0x2595: ctx.fill(CGRect(x: x + w - cols(1), y: y, width: cols(1), height: h)) // ▕
        default:
            let q = Self.quadrants[Int(ch - 0x2596)], mx = cols(4), my = rows(4)
            if q & 1 != 0 { ctx.fill(CGRect(x: x, y: y, width: mx, height: my)) }
            if q & 2 != 0 { ctx.fill(CGRect(x: x + mx, y: y, width: w - mx, height: my)) }
            if q & 4 != 0 { ctx.fill(CGRect(x: x, y: y + my, width: mx, height: h - my)) }
            if q & 8 != 0 { ctx.fill(CGRect(x: x + mx, y: y + my, width: w - mx, height: h - my)) }
        }
        return true
    }

    // MARK: 키보드

    private func mods(_ f: NSEvent.ModifierFlags) -> VTermModifier {
        var m = VTERM_MOD_NONE.rawValue
        if f.contains(.shift) { m |= VTERM_MOD_SHIFT.rawValue }
        if f.contains(.option) { m |= VTERM_MOD_ALT.rawValue }
        if f.contains(.control) { m |= VTERM_MOD_CTRL.rawValue }
        return VTermModifier(m)
    }

    private static let special: [UInt16: VTermKey] = [
        126: VTERM_KEY_UP, 125: VTERM_KEY_DOWN, 123: VTERM_KEY_LEFT, 124: VTERM_KEY_RIGHT,
        36: VTERM_KEY_ENTER, 76: VTERM_KEY_ENTER, 51: VTERM_KEY_BACKSPACE, 117: VTERM_KEY_DEL, 53: VTERM_KEY_ESCAPE,
        48: VTERM_KEY_TAB, 115: VTERM_KEY_HOME, 119: VTERM_KEY_END, 116: VTERM_KEY_PAGEUP, 121: VTERM_KEY_PAGEDOWN, 114: VTERM_KEY_INS,
    ]
    private static let functionKeys: [UInt16: UInt32] = [
        122: 1, 120: 2, 99: 3, 118: 4, 96: 5, 97: 6, 98: 7, 100: 8, 101: 9, 109: 10, 103: 11, 111: 12,
    ]

    private func specialKey(_ e: NSEvent) -> VTermKey? {
        if let k = Self.special[e.keyCode] { return k }
        if let n = Self.functionKeys[e.keyCode] { return VTermKey(VTERM_KEY_FUNCTION_0.rawValue + n) }
        return nil
    }

    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard e.type == .keyDown, e.modifierFlags.contains(.command), window?.firstResponder === self else { return false }
        // 화면에 끌어서 선택한 글자가 있으면 Cmd+C는 넘기지 않고 메뉴의 복사로(연결된 프로그램은 이 선택을 모른다)
        let f = e.modifierFlags.intersection([.shift, .control, .option])
        if e.keyCode == 8, f.isEmpty, let t = selectionText(), !t.isEmpty { return false }
        return onCmdKey?(e) ?? false
    }

    override func keyDown(with e: NSEvent) {
        if exited { onExitKey?(); return }
        let f = e.modifierFlags
        if f.contains(.command) { return } // 메뉴에 없는 Cmd 조합은 버린다(터미널 단축키가 없는 단독 앱)
        clearSelection()
        committedByClick = nil // 입력기가 확정을 보내지 않고 버린 경우, 다음 입력의 같은 글자를 버리지 않게
        if !marked.isEmpty { inputContext?.handleEvent(e); return }
        if let k = specialKey(e) {
            vterm_keyboard_key(vt, k, mods(f))
            return
        }
        if f.contains(.control) {
            // Ctrl 조합은 입력기를 거치지 않고 물리 키 글자로(한글 자판이어도 Ctrl+C는 c)
            if let name = keys.first(where: { $0.0 == Int(e.keyCode) })?.1, name.count == 1, let u = name.unicodeScalars.first {
                vterm_keyboard_unichar(vt, u.value, mods(f))
            } else if let s = e.charactersIgnoringModifiers {
                for u in s.unicodeScalars { vterm_keyboard_unichar(vt, u.value, mods(f)) }
            }
            return
        }
        inputContext?.handleEvent(e) // 글자는 입력기로(insertText·setMarkedText)
    }

    // 입력기가 조합을 끝낸 뒤 넘기는 명령(Enter·화살표 등): 지금 이벤트의 키로 보낸다
    override func doCommand(by selector: Selector) {
        guard let e = NSApp.currentEvent, e.type == .keyDown else { return }
        if let k = specialKey(e) { vterm_keyboard_key(vt, k, mods(e.modifierFlags)) }
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        let s = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        if let c = committedByClick {
            committedByClick = nil
            if c.text == s, Date().timeIntervalSince(c.at) < 1 { return } // commitMarked가 이미 보냄
        }
        marked = ""
        for u in s.unicodeScalars { vterm_keyboard_unichar(vt, u.value, VTERM_MOD_NONE) }
        damage(Int(markedAt.row), Int(markedAt.row) + 1)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        marked = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        damage(Int(markedAt.row), Int(markedAt.row) + 1)
    }

    func unmarkText() {
        marked = ""
        damage(Int(markedAt.row), Int(markedAt.row) + 1)
    }

    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func markedRange() -> NSRange { marked.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: (marked as NSString).length) }
    func hasMarkedText() -> Bool { !marked.isEmpty }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func characterIndex(for point: NSPoint) -> Int { NSNotFound }
    // 입력기 후보 창 위치: 조합 중 글자 자리
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let r = NSRect(x: pad + CGFloat(markedAt.col) * cellW, y: pad + CGFloat(markedAt.row) * cellH, width: cellW, height: cellH)
        guard let window else { return .zero }
        return window.convertToScreen(convert(r, to: nil))
    }

    // MARK: 붙여넣기·복사

    @objc func paste(_ sender: Any?) {
        guard let s = NSPasteboard.general.string(forType: .string), !s.isEmpty else { return }
        clearSelection()
        vterm_keyboard_start_paste(vt)
        for u in s.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r").unicodeScalars {
            vterm_keyboard_unichar(vt, u.value, VTERM_MOD_NONE)
        }
        vterm_keyboard_end_paste(vt)
    }

    @objc func copy(_ sender: Any?) {
        guard let t = selectionText(), !t.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(t, forType: .string)
    }

    // MARK: 마우스

    // cellAt은 마우스 위치의 칸. DEC 2배 폭 줄(calendar-tui 제목 등)은 칸이 2배로 그려지므로 2로 나눈다.
    private func cellAt(_ e: NSEvent) -> VTermPos {
        let p = convert(e.locationInWindow, from: nil)
        let r = min(rows - 1, max(0, Int((p.y - pad) / cellH)))
        var c = Int((p.x - pad) / cellW)
        if let info = vterm_state_get_lineinfo(state, Int32(r))?.pointee, info.doublewidth != 0 { c /= 2 }
        return VTermPos(row: Int32(r), col: Int32(min(cols - 1, max(0, c))))
    }

    // 프로그램이 마우스를 켰으면 누름·놓음을 넘긴다(Shift를 누르면 넘기지 않고 선택).
    // Shift를 누른 클릭도 넘긴다(목록 범위 선택 등). 화면 선택은 끌기로 하므로 Shift+끌기도 그대로 선택이 된다.
    private func mouseToProgram(_ e: NSEvent) -> Bool { mouseMode != Int32(VTERM_PROP_MOUSE_NONE) }
    // 누름은 놓을 때까지 미룬다: 다른 칸으로 끌면 화면 선택이 되므로, 누르는 순간 동작하는 프로그램(calendar-tui는 누름에 일정을 연다)이
    // 선택을 시작한 칸을 누른 것으로 받지 않게. 같은 칸에서 놓으면 누름·놓음을 함께 보낸다. Option을 누른 채 누르면 바로 넘기고
    // 끌기도 넘긴다(끌기를 쓰는 프로그램용).
    private var pendingPress: VTermPos? // 프로그램에 보낼 누름(아직 안 보냄)
    private var pendingMods = VTERM_MOD_NONE // 그 누름 때의 수식키(놓기 전에 키를 떼도 누를 때 것으로 보낸다)
    private var dragToProgram = false   // Option 누름: 누름·끌기·놓음을 바로 넘기는 중

    private func mouseButton(_ p: VTermPos, _ e: NSEvent, _ button: Int32, _ pressed: Bool) {
        mouseButton(p, mouseMods(e.modifierFlags), button, pressed)
    }
    private func mouseButton(_ p: VTermPos, _ m: VTermModifier, _ button: Int32, _ pressed: Bool) {
        vterm_mouse_move(vt, p.row, p.col, m)
        vterm_mouse_button(vt, button, pressed, m)
    }
    // mouseMods는 마우스 보고용 수식키다. 마우스 보고(SGR)엔 Cmd 자리가 없어 Cmd를 Ctrl로 보낸다(Cmd+클릭 = 토글 선택처럼
    // 맥에서 Cmd로 하는 클릭을 프로그램이 Ctrl 클릭으로 받는다).
    private func mouseMods(_ f: NSEvent.ModifierFlags) -> VTermModifier {
        var m = mods(f).rawValue
        if f.contains(.command) { m |= VTERM_MOD_CTRL.rawValue }
        return VTermModifier(m)
    }
    private func mouseButton(_ e: NSEvent, _ button: Int32, _ pressed: Bool) { mouseButton(cellAt(e), e, button, pressed) }

    // commitMarked는 조합 중 글자를 확정한다(Terminal.app처럼 누르면 확정). 입력기에 조합을 끝내라고 하면(discardMarkedText)
    // 구름 등은 commitComposition으로 insertText를 부르지만 비동기라 누른 것보다 늦게 와서, 그 사이 프로그램이 다른 화면으로
    // 가면 글자가 엉뚱한 곳에 들어간다. 그래서 여기서 바로 보내고, 입력기가 곧이어 같은 글자를 보내면 한 번 버린다.
    private var committedByClick: (text: String, at: Date)?
    private func commitMarked() {
        guard !marked.isEmpty else { return }
        let text = marked
        unmarkText()
        for u in text.unicodeScalars { vterm_keyboard_unichar(vt, u.value, VTERM_MOD_NONE) }
        committedByClick = (text, Date())
        inputContext?.discardMarkedText()
    }

    override func mouseDown(with e: NSEvent) {
        commitMarked()
        window?.makeFirstResponder(self)
        clearSelection()
        let p = cellAt(e)
        selAnchor = p
        if mouseToProgram(e) {
            if e.modifierFlags.contains(.option) {
                dragToProgram = true
                return mouseButton(p, e, 1, true)
            }
            pendingPress = p
            pendingMods = mouseMods(e.modifierFlags)
            return
        }
        selHead = p
    }

    // 누른 채 다른 칸으로 끌면 화면 선택으로 바꾼다(Terminal.app처럼 마우스를 쓰는 TUI에서도 끌어서 복사).
    override func mouseDragged(with e: NSEvent) {
        let p = cellAt(e)
        if dragToProgram { return vterm_mouse_move(vt, p.row, p.col, mouseMods(e.modifierFlags)) }
        if let start = pendingPress {
            guard p.row != start.row || p.col != start.col else { return }
            pendingPress = nil
        }
        guard selAnchor != nil else { return }
        selHead = p
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        if dragToProgram {
            dragToProgram = false
            selAnchor = nil
            return mouseButton(e, 1, false)
        }
        if let p = pendingPress {
            pendingPress = nil
            selAnchor = nil
            mouseButton(p, pendingMods, 1, true)
            return mouseButton(p, pendingMods, 1, false)
        }
        if let a = selAnchor, let h = selHead, a.row == h.row, a.col == h.col { clearSelection() }
    }

    override func rightMouseDown(with e: NSEvent) { commitMarked(); if mouseToProgram(e) { mouseButton(e, 3, true) } }
    override func rightMouseUp(with e: NSEvent) { if mouseToProgram(e) { mouseButton(e, 3, false) } }
    override func otherMouseDown(with e: NSEvent) { commitMarked(); if mouseToProgram(e) { mouseButton(e, 2, true) } }
    override func otherMouseUp(with e: NSEvent) { if mouseToProgram(e) { mouseButton(e, 2, false) } }

    override func mouseMoved(with e: NSEvent) {
        guard mouseMode == Int32(VTERM_PROP_MOUSE_MOVE) else { return }
        let p = cellAt(e)
        vterm_mouse_move(vt, p.row, p.col, mods(e.modifierFlags))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    // 휠: 마우스를 켠 프로그램엔 휠 버튼, 대체 화면(TUI)엔 위·아래 화살표(Terminal.app과 같음). 스크롤백은 없다.
    override func scrollWheel(with e: NSEvent) {
        wheel += e.hasPreciseScrollingDeltas ? e.scrollingDeltaY / cellH : e.scrollingDeltaY
        while abs(wheel) >= 1 {
            let up = wheel > 0
            wheel += up ? -1 : 1
            if mouseMode != Int32(VTERM_PROP_MOUSE_NONE) {
                mouseButton(e, up ? 4 : 5, true)
            } else if altScreen {
                vterm_keyboard_key(vt, up ? VTERM_KEY_UP : VTERM_KEY_DOWN, VTERM_MOD_NONE)
            }
        }
    }

    // MARK: 선택

    private func ordered() -> (VTermPos, VTermPos)? {
        guard let a = selAnchor, let h = selHead else { return nil }
        return (a.row, a.col) <= (h.row, h.col) ? (a, h) : (h, a)
    }

    private func selected(_ r: Int, _ c: Int) -> Bool {
        guard let (s, e) = ordered() else { return false }
        return (Int(s.row), Int(s.col)) <= (r, c) && (r, c) <= (Int(e.row), Int(e.col))
    }

    private func clearSelection() {
        guard selAnchor != nil else { return }
        selAnchor = nil
        selHead = nil
        needsDisplay = true
    }

    // selectionText는 선택한 칸의 글자. 줄 끝 공백은 뺀다.
    func selectionText() -> String? {
        guard let (s, e) = ordered() else { return nil }
        var out: [String] = []
        var cell = VTermScreenCell()
        for r in Int(s.row)...Int(e.row) {
            var line = ""
            let from = r == Int(s.row) ? Int(s.col) : 0, to = r == Int(e.row) ? Int(e.col) : cols - 1
            var c = from
            while c <= to {
                vterm_screen_get_cell(screen, VTermPos(row: Int32(r), col: Int32(c)), &cell)
                c += max(1, Int(cell.width))
                if cell.chars.0 == 0xFFFF_FFFF { continue }
                if cell.chars.0 == 0 { line += " "; continue }
                for u in [cell.chars.0, cell.chars.1, cell.chars.2] where u != 0 { if let sc = UnicodeScalar(u) { line.unicodeScalars.append(sc) } }
            }
            while line.hasSuffix(" ") { line.removeLast() }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }

    // MARK: 포커스

    func focus(_ on: Bool) {
        if on { vterm_state_focus_in(state) } else { vterm_state_focus_out(state) }
        damage(Int(cursor.row), Int(cursor.row) + 1)
    }
}
