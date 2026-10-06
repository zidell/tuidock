// tuidock 실행기. 터미널 TUI 프로그램을 터미널 창(Terminal·iTerm2·Ghostty)에 띄우고, 그 창이 단독 앱처럼 굴게 한다.
//  - Dock 아이콘·실행 중 점·Cmd+Tab 항목이 앱마다 따로 생긴다(Terminal 창은 모두 "터미널" 하나로 묶이므로).
//  - Dock 클릭·Cmd+Tab으로 이 앱을 고르면 그 창을 앞으로(숨긴 창도 다시 보인다). 프로그램이 끝나면 같이 끝난다.
//  - 창 크기(글자 칸)·글꼴 크기를 기억했다가 다음에 같은 크기로 연다.
//  - Cmd+H는 그 창만 숨긴다. 창이 포커스인 동안 나머지 Cmd 조합은 Terminal 대신 프로그램이 받는다(프로토콜 참고).
// 창 자체는 없다(그리는 건 터미널). 설정은 Info.plist(TUIDock*)에서 읽는다. 만들기: tuidock make
// 터미널(TUIDockTerminal): terminal(Info.plist에 키가 없을 때도)·iterm2는 그 앱 하나에 창을 열고 AppleScript로 다룬다.
// ghostty는 창 하나만 가릴 방법이 없어(AppleScript·동작 모두) 앱마다 Ghostty를 따로 띄우고 그 프로세스를 다룬다(앱당 메모리 70~100MB).
// builtin(자체 터미널, terminal.swift)은 이 프로세스가 창을 직접 갖는다. 터미널 앱을 다루는 부분(AppleScript·단축키 가로채기·
// 맨 앞 창 확인)은 쓰지 않고, 창·메뉴·Cmd 키가 처음부터 이 앱 것이다.
//
// 프로토콜: 소켓 폴더($TMPDIR/tuidock-<번들 ID>)의 유닉스 데이터그램 두 개. 프로그램엔 환경변수 TUIDOCK으로 폴더를 넘긴다.
//   app.sock       실행기 → 프로그램: "key cmd+a"·"key cmd+shift+="  "ping"(→ hello로 답)  "ok"(bye에 대한 답)
//   launcher.sock  프로그램 → 실행기: "hello <pid>"  "focus 1"/"focus 0"  "hide"  "font +1"/"font -1"  "bye"
// 따르지 않는 프로그램도 Dock 기능·Cmd+H·W·Q·창 크기 기억은 그대로 쓰고, 나머지 터미널 단축키는 막힌다(Cmd+C·V만 터미널 몫).
import AppKit
import Carbon.HIToolbox
import UniformTypeIdentifiers

let info = Bundle.main.infoDictionary ?? [:]
let bundleID = Bundle.main.bundleIdentifier ?? "tuidock"
enum Host: String {
    case terminal, iterm2, ghostty, builtin
    var bundleID: String {
        switch self {
        case .terminal: "com.apple.Terminal"
        case .iterm2: "com.googlecode.iterm2"
        case .ghostty: "com.mitchellh.ghostty"
        case .builtin: Bundle.main.bundleIdentifier ?? ""
        }
    }
}
let host = Host(rawValue: (info["TUIDockTerminal"] as? String ?? "").lowercased()) ?? .terminal

func expand(_ p: String) -> String { (p as NSString).expandingTildeInPath }

// 실행할 파일: TUIDockCommand가 실행 가능하면 그것(개발 중 번들 밖 파일을 갈아 끼울 때), 아니면 번들 안 TUIDockEmbedded.
func commandPath() -> String {
    let c = expand(info["TUIDockCommand"] as? String ?? "")
    if !c.isEmpty, FileManager.default.isExecutableFile(atPath: c) { return c }
    if let e = info["TUIDockEmbedded"] as? String, let r = Bundle.main.resourceURL { return r.appendingPathComponent(e).path }
    return c
}

let arguments = info["TUIDockArguments"] as? [String] ?? []

// 소켓 폴더. 경로가 sun_path(104바이트)를 넘을 만큼 길면 번들 ID 대신 해시를 쓴다.
let sockDir: String = {
    let base = NSTemporaryDirectory()
    var name = bundleID
    if (base + "tuidock-" + name + "/launcher.sock").utf8.count > 100 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in bundleID.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        name = String(h, radix: 16)
    }
    return base + "tuidock-" + name
}()

// AppleScript 문자열·셸 인자 따옴표
func q(_ s: String) -> String {
    "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}
func sh(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

func runScript(_ src: String) -> String? {
    var err: NSDictionary?
    let r = NSAppleScript(source: src)?.executeAndReturnError(&err)
    if let err {
        NSLog("tuidock: %@", err)
        return nil
    }
    return r?.stringValue
}

// tellTab은 tty가 같은 탭을 t, 그 창을 w로 두고 body를 실행한다. 못 찾으면 "".
func tellTab(_ tty: String, _ body: String) -> String {
    runScript("""
    tell application "Terminal"
        repeat with w in windows
            repeat with t in tabs of w
                if tty of t is \(q(tty)) then
                    \(body)
                end if
            end repeat
        end repeat
    end tell
    return ""
    """) ?? ""
}

// tellITerm은 iTerm2 창 id(= 화면 창 번호)로 그 창을 w, 그 세션을 s로 두고 body를 실행한다. 못 찾으면 "".
func tellITerm(_ id: Int, _ body: String) -> String {
    runScript("""
    tell application "iTerm"
        try
            set w to window id \(id)
            set s to current session of w
        on error
            return ""
        end try
        \(body)
    end tell
    return ""
    """) ?? ""
}

func run(_ path: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return "" }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

func unixAddr(_ path: String) -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { dst in
        dst.copyBytes(from: Array(path.utf8.prefix(dst.count - 1)))
    }
    return addr
}

// Cmd 조합 중 프로그램에 넘기는 키(물리 키 위치라 한글 자판이어도 같다). 이름은 Shift 없는 글자.
let keys: [(Int, String)] = [
    (kVK_ANSI_A, "a"), (kVK_ANSI_B, "b"), (kVK_ANSI_C, "c"), (kVK_ANSI_D, "d"), (kVK_ANSI_E, "e"), (kVK_ANSI_F, "f"),
    (kVK_ANSI_G, "g"), (kVK_ANSI_H, "h"), (kVK_ANSI_I, "i"), (kVK_ANSI_J, "j"), (kVK_ANSI_K, "k"), (kVK_ANSI_L, "l"),
    (kVK_ANSI_M, "m"), (kVK_ANSI_N, "n"), (kVK_ANSI_O, "o"), (kVK_ANSI_P, "p"), (kVK_ANSI_Q, "q"), (kVK_ANSI_R, "r"),
    (kVK_ANSI_S, "s"), (kVK_ANSI_T, "t"), (kVK_ANSI_U, "u"), (kVK_ANSI_V, "v"), (kVK_ANSI_W, "w"), (kVK_ANSI_X, "x"),
    (kVK_ANSI_Y, "y"), (kVK_ANSI_Z, "z"),
    (kVK_ANSI_0, "0"), (kVK_ANSI_1, "1"), (kVK_ANSI_2, "2"), (kVK_ANSI_3, "3"), (kVK_ANSI_4, "4"),
    (kVK_ANSI_5, "5"), (kVK_ANSI_6, "6"), (kVK_ANSI_7, "7"), (kVK_ANSI_8, "8"), (kVK_ANSI_9, "9"),
    (kVK_ANSI_Minus, "-"), (kVK_ANSI_Equal, "="), (kVK_ANSI_LeftBracket, "["), (kVK_ANSI_RightBracket, "]"),
    (kVK_ANSI_Backslash, "\\"), (kVK_ANSI_Semicolon, ";"), (kVK_ANSI_Quote, "'"), (kVK_ANSI_Comma, ","),
    (kVK_ANSI_Period, "."), (kVK_ANSI_Slash, "/"), (kVK_ANSI_Grave, "`"),
    (kVK_LeftArrow, "left"), (kVK_RightArrow, "right"), (kVK_UpArrow, "up"), (kVK_DownArrow, "down"),
    (kVK_Return, "enter"), (kVK_Delete, "backspace"),
]
// 넘기지 않는 것(macOS 공통 동작 그대로): Cmd+H·Cmd+W(실행기가 그 창만 숨김 — 앱처럼 창 닫기는 가리기, 종료는 Cmd+Q), Cmd+M(터미널이 맨 앞 창 = 이 창을 최소화),
// Cmd+`·Cmd+Shift+`(창 전환 — 다른 터미널 창으로 가는 길이라 막으면 갇힌다), Cmd+Shift+3~6(스크린샷), Cmd+Shift+Q(로그아웃).
// Cmd+Tab·Cmd+Space 등 시스템 단축키는 애초에 못 가로챈다.
let keepCmd: Set<String> = ["h", "w", "m", "`"]
let keepCmdShift: Set<String> = ["3", "4", "5", "6", "q", "`"]
// 연결 안 된 프로그램(키를 받을 수 없음)이면 터미널 단축키(Cmd+T 새 탭, Cmd+N 새 창, Cmd +/- …)를 버린다.
// 프로그램이 받지 않는 키로 Terminal 기능이 돌면 단독 앱이 아니다(사용자 지시). 남기는 건 macOS 기본 복사·붙여넣기(Cmd+C·V)와
// quitRef가 받는 Cmd+Q뿐.
let passCmd: Set<String> = ["c", "v", "q"]

final class Dock: NSObject, NSApplicationDelegate {
    var tty: String? // 프로그램이 도는 터미널 탭(/dev/ttysNNN). Terminal 창은 이걸로 찾는다(창 제목과 무관)
    var pid: pid_t = 0
    var exitWatch: DispatchSourceProcess?
    var sock: Int32 = -1
    var sockSource: DispatchSourceRead?
    var hideRef: EventHotKeyRef?
    var keyRefs: [EventHotKeyRef] = []
    var closeRef: EventHotKeyRef? // Cmd+W(이 창 숨김). 이 창이 맨 앞일 때만이라 다른 터미널 창의 Cmd+W는 그대로
    var quitRef: EventHotKeyRef? // Cmd+Q(앱 종료). 연결된 프로그램은 Cmd+Q를 직접 받으므로 연결 안 됐을 때만
    var connected = false // 프로그램이 hello를 보냄(프로토콜을 따름)
    var closeWindow = false // 일부러 끝냄(Dock·Cmd+Q·bye) → 프로그램이 끝난 뒤 남는 빈 창을 닫는다. 오류로 끝나면 메시지가 남게 둔다
    var winID = 0 // Terminal·iTerm2: 그 창의 AppleScript 창 id = 화면 창 번호(CGWindowList)
    var lastShow = Date.distantPast
    var hostApp: NSRunningApplication? // Ghostty: 이 앱 몫으로 따로 띄운 Ghostty
    var frontPoll: Timer?
    var ourFront = false // 맨 앞 창이 그 창
    var keyMode = 0 // 0 없음, 1 프로그램에 넘김(연결·포커스), 2 터미널 단축키 막기(연결 안 됨·맨 앞)
    var hostFront = false // 터미널(Ghostty는 그 Ghostty)이 맨 앞 앱
    var focused = false // 프로그램이 "focus 1"을 보냄(그 창이 포커스)
    var window: NSWindow? // 자체 터미널의 창
    var term: TermView?
    var bundledFont: String? // 앱에 넣은 기본 글꼴(D2Coding)을 등록했으면 그 이름
    var configWatch: DispatchSourceFileSystemObject? // 설정 파일이 바뀌면 바로 반영
    var settingsWindow: SettingsWindow? // Cmd+, 설정 창(settings.swift)
    let defaults = UserDefaults.standard

    func applicationDidFinishLaunching(_ n: Notification) {
        if host == .builtin {
            // 프로그램은 이 프로세스의 pty 자식이라 실행기만 다시 켜지는 경우가 없다(이어받기 없음)
            listen()
            setupMenu()
            return launch()
        }
        installHotKeyHandler()
        listen()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.setHostFront(self?.isHost(app) ?? false)
            // Cmd+Tab·Dock 등으로 이 앱이 앞에 옴 → 그 창을 앞으로(이 앱엔 창이 없다). 이 알림이 applicationDidBecomeActive보다
            // 30~300ms 먼저 와서(실측) 여기서 한다
            if app == NSRunningApplication.current, let self, self.tty != nil || self.hostApp != nil || self.window != nil { self.show() }
        }
        setHostFront(isHost(NSWorkspace.shared.frontmostApplication))
        // 실행기만 다시 켜졌고(재설치 등) 프로그램은 살아 있으면 hello로 답한다. 그 창을 그대로 쓴다.
        send("ping")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if self.tty == nil, self.hostApp == nil { self.launch() }
        }
    }

    // isHost는 그 앱이 이 창을 가진 터미널인지. Ghostty는 따로 띄운 그 프로세스만.
    func isHost(_ app: NSRunningApplication?) -> Bool {
        guard let app, host != .builtin else { return false }
        if host == .ghostty { return hostApp != nil && app.processIdentifier == hostApp?.processIdentifier }
        return app.bundleIdentifier == host.bundleID
    }

    // Dock 아이콘을 다시 누름. Dock 클릭은 이 앱을 활성화한 바로 뒤에 reopen도 보내 show가 두 번 돈다(실측) → 방금 했으면 건너뛴다
    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if Date().timeIntervalSince(lastShow) > 0.5 { show() }
        return false
    }

    // Dock에서 "종료"하면 창이 아직 있을 때 크기를 기억하고 프로그램도 끈다
    func applicationWillTerminate(_ n: Notification) {
        if pid != 0 {
            saveSize()
            kill(pid, SIGTERM)
            // 끝날 때까지 최대 1초. 자체 터미널은 프로그램이 이 프로세스의 자식이라 거둬야 kill(pid, 0)이 실패한다(좀비)
            for _ in 0..<20 where kill(pid, 0) == 0 && !(host == .builtin && waitpid(pid, nil, WNOHANG) == pid) { usleep(50_000) }
            closeWindow = true
        }
        if closeWindow {
            switch host {
            case .terminal:
                // 탭이 그 하나뿐이고 프로세스가 끝났을 때만(Terminal이 끝난 걸 알아채는 데 잠깐 걸린다)
                if tty != nil {
                    _ = tell("""
                    repeat 10 times
                        if busy of t is false then
                            if (count tabs of w) is 1 then close w
                            return "ok"
                        end if
                        delay 0.1
                    end repeat
                    return "ok"
                    """)
                }
            case .iterm2:
                // 보통은 iTerm2가 명령이 끝난 창을 스스로 닫는다. 남아 있으면 닫는다
                if winID != 0 {
                    _ = tellITerm(winID, """
                    repeat 10 times
                        if (is processing of s) is false then
                            close w
                            return "ok"
                        end if
                        delay 0.1
                    end repeat
                    return "ok"
                    """)
                }
            case .ghostty, .builtin:
                break // Ghostty는 아래에서 늘 끝낸다. 자체 터미널 창은 이 프로세스와 같이 사라진다
            }
        }
        // Ghostty는 이 앱 전용이라 실행기가 끝나면 늘 같이 끝낸다(프로그램이 스스로 끝나도). 종료 요청만 보내고 실행기가
        // 먼저 끝나면 창 없는 Ghostty가 남은 적이 있어(실측) 끝날 때까지 기다리고, 안 끝나면 SIGTERM
        if let hostApp, !hostApp.isTerminated {
            let hp = hostApp.processIdentifier
            hostApp.terminate()
            for _ in 0..<20 where kill(hp, 0) == 0 { usleep(50_000) }
            if kill(hp, 0) == 0 { kill(hp, SIGTERM) }
        }
        unlink(sockDir + "/launcher.sock")
    }

    // MARK: 창

    // runFile은 iTerm2·Ghostty에 넘길 실행 스크립트(인자 따옴표를 터미널마다 다르게 다루지 않게 파일로 넘긴다).
    func runFile() -> String {
        let path = sockDir + "/run.sh"
        let cmd = "exec env TUIDOCK=\(sh(sockDir)) " + ([commandPath()] + arguments).map(sh).joined(separator: " ")
        try? "#!/bin/bash\nclear\n\(cmd)\n".write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    // launch는 새 터미널 창에서 프로그램을 띄운다. 기억한 크기·글꼴이 없으면 화면을 거의 채운다.
    // exec로 셸을 프로그램으로 바꾸므로 끝나면 탭도 끝난다(Terminal은 오류로 끝나면 메시지가 창에 남는다).
    func launch() {
        let f = NSScreen.main?.frame.size ?? CGSize(width: 1600, height: 1000)
        let cols = defaults.integer(forKey: "cols"), rows = defaults.integer(forKey: "rows")
        let font = defaults.double(forKey: "font")
        let sized = cols > 20 && rows > 10
        let fill = "{40, 60, \(Int(f.width) - 40), \(Int(f.height) - 40)}"
        switch host {
        case .builtin:
            launchBuiltin(cols: sized ? cols : 0, rows: sized ? rows : 0) // 글꼴은 설정 파일
        case .terminal:
            var resize = "set bounds of front window to \(fill)"
            if sized {
                // 글꼴을 먼저 바꿔야 칸 수가 그 글꼴 기준으로 맞는다
                resize = (font >= 6 && font <= 72 ? "set font size of t to \(font)\n" : "")
                    + "set number of columns of t to \(cols)\nset number of rows of t to \(rows)"
            }
            let cmd = "clear; exec env TUIDOCK=\(sh(sockDir)) " + ([commandPath()] + arguments).map(sh).joined(separator: " ")
            let out = runScript("""
            set wasRunning to application "Terminal" is running
            tell application "Terminal"
                if wasRunning then
                    set t to do script \(q(cmd))
                else
                    activate
                    delay 0.5
                    set t to do script \(q(cmd)) in front window
                end if
                \(resize)
                return tty of t
            end tell
            """) ?? ""
            guard out.hasPrefix("/dev/") else { return NSApp.terminate(nil) }
            tty = out
            activateHost()
            findPID(tries: 30)
        case .iterm2:
            let resize = sized ? "set columns of s to \(cols)\nset rows of s to \(rows)" : "set bounds of w to \(fill)"
            let cmd = "/bin/bash " + runFile()
            // 꺼져 있던 iTerm2를 켜면 기본 창이 하나 생기므로 그 창에서 실행한다(Terminal과 같음)
            let out = runScript("""
            set wasRunning to application "iTerm" is running
            tell application "iTerm"
                if not wasRunning then
                    activate
                    delay 1
                end if
                if (not wasRunning) and (count windows) is 1 then
                    set w to front window
                    set s to current session of w
                    tell s to write text "exec " & \(q(cmd))
                else
                    set w to (create window with default profile command \(q(cmd)))
                    set s to current session of w
                end if
                \(resize)
                return ((id of w) as text) & " " & (tty of s)
            end tell
            """) ?? ""
            let p = out.split(separator: " ")
            guard p.count == 2, let id = Int(p[0]), p[1].hasPrefix("/dev/") else { return NSApp.terminate(nil) }
            winID = id
            tty = String(p[1])
            activateHost()
            findPID(tries: 30)
        case .ghostty:
            // 앱마다 Ghostty를 따로 띄운다. 칸 수·글꼴은 띄울 때 넘긴다. 아이콘(--macos-custom-icon)은 넘기지 않는다:
            // Ghostty가 그 아이콘을 공용 환경설정(CustomGhosttyIcon2)에 저장해 Dock 타일 플러그인이 모든 Ghostty.app 자리에 그린다
            // (쓰던 Ghostty 아이콘까지 바뀌었다, 2026-10-06 실측)
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: host.bundleID) else {
                NSLog("tuidock: Ghostty가 설치돼 있지 않다")
                return NSApp.terminate(nil)
            }
            var args = ["--quit-after-last-window-closed=true", "--confirm-close-surface=false", "--window-save-state=never"]
            args += sized ? ["--window-width=\(cols)", "--window-height=\(rows)"] : ["--maximize=true"]
            if font >= 6 && font <= 72 { args.append("--font-size=\(font)") }
            args += ["-e", "/bin/bash", runFile()]
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.createsNewApplicationInstance = true
            cfg.arguments = args
            NSWorkspace.shared.openApplication(at: url, configuration: cfg) { app, err in
                DispatchQueue.main.async {
                    guard let app else {
                        NSLog("tuidock: Ghostty를 띄우지 못했다: %@", err?.localizedDescription ?? "")
                        return NSApp.terminate(nil)
                    }
                    self.hostApp = app
                    self.setHostFront(self.isHost(NSWorkspace.shared.frontmostApplication))
                    self.findPID(tries: 30)
                }
            }
        }
    }

    // show는 그 창을 맨 앞으로(숨기거나 최소화한 창도). 없으면 새로 띄운다.
    // 그 창이 이미 터미널의 맨 앞 창이면(보통의 앱 전환) AppleScript 없이 바로 활성화한다. AppleScript는 실행기 안에서
    // 한 번에 약 100ms(터미널 왕복)라, 그만큼 실행기가 앞에 온 뒤 터미널이 한 박자 늦게 왔다(실측, 2026-10-06)
    func show() {
        lastShow = Date()
        switch host {
        case .builtin:
            guard let window else { return }
            NSApp.unhide(nil)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        case .terminal:
            guard tty != nil else { return launch() }
            if terminalWindowID() != 0, frontHostWindow() == winID { return activateHost() }
            let r = tell("""
            set selected of t to true
            set visible of w to true
            set index of w to 1
            return "ok"
            """)
            if r != "ok", pid == 0 { return launch() }
            activateHost()
        case .iterm2:
            guard winID != 0 else { return launch() }
            if frontHostWindow() == winID { return activateHost() }
            let r = tellITerm(winID, """
            set miniaturized of w to false
            select w
            return "ok"
            """)
            if r != "ok", pid == 0 { return launch() }
            activateHost()
        case .ghostty:
            guard let hostApp, !hostApp.isTerminated else { return pid == 0 ? launch() : () }
            hostApp.unhide()
            hostApp.activate()
        }
    }

    // activateHost는 터미널을 앞으로 올리되 맨 앞 창(= 방금 맨 앞에 둔 그 창)만 올린다. AppleScript activate는
    // 그 앱의 모든 창을 다른 앱 창 위로 끌어와서(다른 Terminal 창까지 딸려 나옴) 쓰지 않는다.
    func activateHost() {
        NSRunningApplication.runningApplications(withBundleIdentifier: host.bundleID).first?.activate(options: [])
    }

    // hideWindow는 그 창만 가린다. iTerm2는 창 하나만 가릴 수 없어 최소화(사용자 결정), Ghostty는 이 앱 몫의 Ghostty를 가린다.
    func hideWindow() {
        switch host {
        case .builtin:
            NSApp.hide(nil) // 창이 하나라 앱 가리기 = 그 창 가리기. 앞에 있던 앱으로 돌아간다
        case .terminal:
            _ = tell("set visible of w to false\nreturn \"ok\"")
        case .iterm2:
            if winID != 0 { _ = tellITerm(winID, "set miniaturized of w to true\nreturn \"ok\"") }
        case .ghostty:
            hostApp?.hide()
        }
    }

    // setFont는 Terminal만(iTerm2는 글꼴이 프로필 단위, Ghostty는 따로 띄운 프로세스를 AppleScript로 가리킬 수 없다)
    func setFont(_ delta: Double) {
        if host == .builtin, let term { return setBuiltinFont(term.fontSize + delta) }
        guard host == .terminal, tty != nil else { return }
        _ = tell("""
        set s to (font size of t) + \(delta)
        if s ≥ 6 and s ≤ 72 then set font size of t to s
        return "ok"
        """)
    }

    // saveSize는 창 크기(글자 칸)와 글꼴 크기를 기억한다. 창이 있을 때 부른다(앱 전환·bye·Dock 종료).
    // Terminal 밖에선 칸 수를 tty에서 읽는다(stty). 글꼴은 Terminal만.
    func saveSize() {
        if host == .builtin {
            guard let term, let window else { return }
            defaults.set(term.cols, forKey: "cols")
            defaults.set(term.rows, forKey: "rows")
            defaults.set(NSStringFromPoint(NSPoint(x: window.frame.minX, y: window.frame.maxY)), forKey: "topLeft")
            return
        }
        guard let tty else { return }
        if host != .terminal {
            let p = run("/bin/stty", ["-f", tty, "size"]).split(separator: " ")
            guard p.count == 2, let r = Int(p[0]), let c = Int(p[1].trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
            defaults.set(c, forKey: "cols")
            defaults.set(r, forKey: "rows")
            return
        }
        let out = tell("""
        return ((number of columns of t) as text) & " " & ((number of rows of t) as text) & " " & ((font size of t) as text)
        """)
        let p = out.split(separator: " ")
        guard p.count == 3, let c = Int(p[0]), let r = Int(p[1]) else { return }
        defaults.set(c, forKey: "cols")
        defaults.set(r, forKey: "rows")
        if let fs = Double(p[2].replacingOccurrences(of: ",", with: ".")) { defaults.set(fs, forKey: "font") }
    }

    // MARK: 프로세스

    // findPID는 프로그램 프로세스를 찾는다(최대 약 10초). 따르는 프로그램은 hello로 먼저 알려 준다.
    // Terminal·iTerm2는 그 탭의 tty에서, Ghostty는 따로 띄운 Ghostty의 자손에서 찾는다(tty는 거기서 얻는다).
    func findPID(tries: Int) {
        guard pid == 0 else { return }
        let name = (commandPath() as NSString).lastPathComponent
        // ps의 comm은 로그인 셸 꼴이면 "-"가 붙는다(Ghostty는 login으로 띄운다)
        func matches(_ comm: Substring) -> Bool {
            var c = comm.trimmingCharacters(in: .whitespaces)
            if c.hasPrefix("-") { c.removeFirst() }
            return (c as NSString).lastPathComponent == name
        }
        if let tty {
            let ps = run("/bin/ps", ["-t", String(tty.dropFirst(5)), "-o", "pid=,comm="])
            for line in ps.split(separator: "\n") {
                let f = line.split(separator: " ", maxSplits: 1)
                if f.count == 2, matches(f[1]), let p = pid_t(f[0]) { return adopt(p) }
            }
        } else if let hp = hostApp?.processIdentifier {
            var parent: [pid_t: pid_t] = [:]
            var rows: [(pid_t, String, Substring)] = []
            for line in run("/bin/ps", ["-A", "-o", "pid=,ppid=,tty=,comm="]).split(separator: "\n") {
                let f = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
                guard f.count == 4, let p = pid_t(f[0]), let pp = pid_t(f[1]) else { continue }
                parent[p] = pp
                rows.append((p, String(f[2]), f[3]))
            }
            for (p, t, comm) in rows where matches(comm) {
                var a = parent[p] ?? 1
                while a > 1, a != hp { a = parent[a] ?? 1 }
                if a == hp {
                    if t.hasPrefix("ttys") { tty = "/dev/" + t }
                    return adopt(p)
                }
            }
        }
        if tries > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.findPID(tries: tries - 1) }
        } else {
            NSApp.terminate(nil)
        }
    }

    // adopt는 프로세스 종료를 기다린다(폴링 없음). 프로그램이 자기 자신을 exec로 다시 시작해도 pid는 그대로다.
    func adopt(_ p: pid_t) {
        guard pid != p else { return }
        exitWatch?.cancel()
        pid = p
        let src = DispatchSource.makeProcessSource(identifier: p, eventMask: .exit, queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            self.pid = 0
            if host == .builtin { return self.builtinExited(p) }
            NSApp.terminate(nil)
        }
        src.resume()
        exitWatch = src
        if kill(p, 0) != 0 {
            pid = 0
            NSApp.terminate(nil)
        }
    }

    // reattach는 실행기만 다시 켜졌을 때(hello) 살아 있는 프로그램의 창을 다시 찾는다.
    func reattach(_ p: pid_t) {
        let t = run("/bin/ps", ["-p", String(p), "-o", "tty="]).trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("ttys") { tty = "/dev/" + t }
        switch host {
        case .terminal, .builtin:
            break
        case .iterm2:
            guard let tty else { break }
            winID = Int(runScript("""
            tell application "iTerm"
                repeat with w in windows
                    repeat with tb in tabs of w
                        repeat with s in sessions of tb
                            if tty of s is \(q(tty)) then return (id of w) as text
                        end repeat
                    end repeat
                end repeat
            end tell
            return ""
            """) ?? "") ?? 0
        case .ghostty:
            // 조상 중 Ghostty 프로세스가 이 앱 몫의 Ghostty
            var a = p
            while a > 1 {
                if let app = NSRunningApplication(processIdentifier: a), app.bundleIdentifier == host.bundleID {
                    hostApp = app
                    break
                }
                a = pid_t(run("/bin/ps", ["-p", String(a), "-o", "ppid="]).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1
            }
        }
        adopt(p)
    }

    // MARK: 단축키 (Carbon RegisterEventHotKey, 손쉬운 사용 권한 필요 없음. 터미널 메뉴 단축키보다 먼저 받는다)

    func installHotKeyHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = Int(hk.id)
            DispatchQueue.main.async { dock.pressed(id) }
            return noErr
        }, 1, &spec, nil, nil)
    }

    func register(_ code: Int, _ mods: Int, _ id: Int) -> EventHotKeyRef? {
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(code), UInt32(mods), EventHotKeyID(signature: OSType(0x7475_6964), id: UInt32(id)),
                            GetApplicationEventTarget(), 0, &ref)
        return ref
    }

    func setHostFront(_ on: Bool) {
        guard host != .builtin else { return } // 자체 터미널은 창·키가 이 앱 것이라 단축키를 가로채지 않는다
        if hostFront, !on { saveSize() } // 다른 앱으로 갈 때 창 크기를 기억한다
        hostFront = on
        frontPoll?.invalidate()
        frontPoll = nil
        if on, host != .ghostty {
            // 터미널 안에서 창이 바뀌는 건 알림이 없어(손쉬운 사용 권한이 있어야 받는다) 터미널이 맨 앞인 동안만 본다.
            // 화면 창 목록 조회라 한 번에 약 1ms, AppleScript를 부르지 않는다. Ghostty는 앱 몫이 따로라 앱 전환 알림으로 충분하다
            frontPoll = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.checkFront() }
        }
        checkFront()
        updateKeys()
    }

    // checkFront는 맨 앞 창이 그 창인지 보고 Cmd+H·W(숨김)·Cmd+Q(종료)를 등록·해제한다.
    // 프로그램이 연결되지 않아도 Cmd+W가 탭을 닫아 프로그램을 끝내지 않고 창을 가리게 하려는 것(Cmd+Q가 종료).
    // Cmd+H도 이 창이 맨 앞일 때만 잡는다. 터미널이 맨 앞인 동안 늘 잡으면 tuidock 앱이 여럿일 때 맨 앞 창 주인이 아닌
    // 앱이 단축키를 받아 터미널 전체를 숨겼다. 다른 터미널 창에선 터미널의 원래 Cmd+H가 돈다.
    func checkFront() {
        var on = false
        if hostFront {
            switch host {
            case .ghostty:
                on = true // 그 Ghostty가 맨 앞이면 곧 그 창
            case .builtin:
                on = false // 쓰지 않음(setHostFront가 먼저 막는다)
            case .terminal:
                on = terminalWindowID() != 0 && frontHostWindow() == winID
            case .iterm2:
                on = winID != 0 && frontHostWindow() == winID
            }
        }
        if on != ourFront {
            ourFront = on
            updateKeys()
        }
        if on, closeRef == nil {
            hideRef = register(kVK_ANSI_H, cmdKey, 1)
            closeRef = register(kVK_ANSI_W, cmdKey, 2)
        } else if !on, let r = closeRef {
            UnregisterEventHotKey(r)
            closeRef = nil
            if let h = hideRef { UnregisterEventHotKey(h) }
            hideRef = nil
        }
        // 연결 안 된 프로그램에서 Cmd+Q가 터미널로 가면 터미널 전체가 끝난다 → 이 앱만 끝낸다
        let q = on && !connected
        if q, quitRef == nil {
            quitRef = register(kVK_ANSI_Q, cmdKey, 3)
        } else if !q, let r = quitRef {
            UnregisterEventHotKey(r)
            quitRef = nil
        }
    }

    // terminalWindowID는 Terminal에서 그 탭이 든 창 id(winID)를 처음 한 번만 tty로 찾아 둔다. 못 찾으면 0.
    func terminalWindowID() -> Int {
        if let tty, winID == 0 { winID = Int(tellTab(tty, "return (id of w) as text")) ?? 0 }
        return winID
    }

    // tell은 Terminal에서 그 탭을 t, 그 창을 w로 두고 body를 실행한다. 못 찾으면 "", 그래서 body는 성공하면 빈 값이 아닌 걸 돌려준다.
    // 창 id로 바로 간다. tellTab(모든 창·탭의 tty 비교)은 창이 많으면 60~130ms 걸려 Dock·Cmd+Tab으로 열 때 그만큼 늦었다(실측, 창 9개).
    // 탭을 다른 창으로 옮겼으면 기억한 창에 없으니 창 id를 다시 찾아 한 번 더.
    func tell(_ body: String) -> String {
        for _ in 0..<2 {
            guard let tty, terminalWindowID() != 0 else { return "" }
            let r = runScript("""
            tell application "Terminal"
                try
                    set w to window id \(winID)
                on error
                    return ""
                end try
                repeat with t in tabs of w
                    if tty of t is \(q(tty)) then
                        \(body)
                    end if
                end repeat
            end tell
            return ""
            """) ?? ""
            if r != "" { return r }
            winID = 0
        }
        return ""
    }

    // frontHostWindow는 화면에 보이는 터미널 보통 창 중 맨 앞의 창 번호(목록은 앞에서 뒤 순서).
    func frontHostWindow() -> Int {
        guard let tp = NSRunningApplication.runningApplications(withBundleIdentifier: host.bundleID).first?.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return 0 }
        for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == tp && (w[kCGWindowLayer as String] as? Int) == 0 {
            return w[kCGWindowNumber as String] as? Int ?? 0
        }
        return 0
    }

    // 나머지 Cmd 조합: 이 창이 포커스인 동안만(프로그램이 알려 줌). 다른 터미널 창·앱은 원래대로.
    // 연결 안 된 프로그램이면 그 창이 맨 앞인 동안 터미널 단축키를 막는다(받은 키는 보낼 곳이 없어 버려진다).
    func updateKeys() {
        let mode = focused && hostFront ? 1 : (!connected && ourFront ? 2 : 0)
        guard mode != keyMode else { return }
        keyRefs.forEach { UnregisterEventHotKey($0) }
        keyRefs.removeAll()
        keyMode = mode
        guard mode != 0 else { return }
        for (i, k) in keys.enumerated() {
            if !keepCmd.contains(k.1), mode == 1 || !passCmd.contains(k.1), let r = register(k.0, cmdKey, 100 + i * 2) { keyRefs.append(r) }
            if !keepCmdShift.contains(k.1), let r = register(k.0, cmdKey | shiftKey, 101 + i * 2) { keyRefs.append(r) }
        }
    }

    func pressed(_ id: Int) {
        if id == 1 || id == 2 {
            hideWindow()
            return checkFront()
        }
        if id == 3 { return NSApp.terminate(nil) }
        let i = (id - 100) / 2
        guard id >= 100, i < keys.count, keyMode == 1 else { return }
        send("key cmd+" + (id % 2 == 1 ? "shift+" : "") + keys[i].1)
    }

    // MARK: 소켓

    func listen() {
        mkdir(sockDir, 0o700)
        let path = sockDir + "/launcher.sock"
        unlink(path)
        sock = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard sock >= 0 else { return }
        var addr = unixAddr(path)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(sock, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0 else { return }
        let src = DispatchSource.makeReadSource(fileDescriptor: sock, queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            var buf = [UInt8](repeating: 0, count: 256)
            let n = recv(self.sock, &buf, buf.count, 0)
            if n > 0 { self.received(String(decoding: buf[0..<n], as: UTF8.self)) }
        }
        src.resume()
        sockSource = src
    }

    func received(_ msg: String) {
        switch msg {
        case "focus 1":
            focused = true
            updateKeys()
        case "focus 0":
            focused = false
            updateKeys()
        case "hide":
            hideWindow()
        case "font +1":
            setFont(1)
        case "font -1":
            setFont(-1)
        case "bye": // 종료 직전, 창이 아직 있을 때. 다 기억한 뒤 답한다
            saveSize()
            closeWindow = true
            send("ok")
        default:
            guard msg.hasPrefix("hello "), let p = pid_t(msg.dropFirst(6)) else { return }
            connected = true
            if host == .builtin { return } // Cmd 조합은 이제 TermView가 프로그램에 넘긴다(builtinCmdKey)
            if pid != p { reattach(p) } // 실행기만 다시 켜졌을 때. 처음 띄운 경우엔 findPID가 이미 찾았거나 곧 찾는다
            setHostFront(isHost(NSWorkspace.shared.frontmostApplication)) // Cmd+Q는 이제 프로그램이 받고, 터미널 단축키 막기도 푼다
            // 이미 포커스된 창에서 시작하면 터미널이 포커스 신호를 주지 않으므로 직접 본다
            if ourFront {
                focused = true
                updateKeys()
            }
        }
    }

    func send(_ msg: String) {
        let s = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard s >= 0 else { return }
        defer { close(s) }
        var addr = unixAddr(sockDir + "/app.sock")
        _ = msg.withCString { m in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(s, m, strlen(m), 0, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
        }
    }
}

// MARK: 자체 터미널 (host == .builtin, terminal.swift)

extension Dock: NSWindowDelegate {
    // 설정 파일(config.swift): ~/Library/Application Support/<번들 ID>/config.toml. Cmd+,로 열고, 저장하면 바로 반영한다.
    struct Style {
        var font: String?
        var theme: String // auto(시스템 따라감)·dark·light
        var size, lineHeight, contrast: Double
    }

    // style은 설정 파일 값에 live(설정 창 슬라이더를 끄는 중인 값)를 덮어 읽는다.
    func style(_ live: [String: String] = [:]) -> Style {
        let c = readConfig().merging(live) { $1 }
        func num(_ key: String) -> Double { Double(configValue(key, c)) ?? 1 }
        let font = configValue("font_family", c)
        return Style(font: font.isEmpty ? bundledFont : font, theme: configValue("theme", c), size: num("font_size"),
                     lineHeight: num("line_height"), contrast: Double(configValue("contrast", c)) ?? 0)
    }

    func launchBuiltin(cols: Int, rows: Int) {
        // 앱에 넣은 기본 글꼴(D2Coding, OFL — Resources/fonts/OFL.txt)은 이 프로세스에만 등록한다(시스템에 설치하지 않음)
        if let dir = Bundle.main.resourceURL?.appendingPathComponent("fonts"),
           let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for f in files where ["ttf", "otf", "ttc"].contains(f.pathExtension.lowercased()) {
                if CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil) { bundledFont = "D2Coding" }
            }
        }
        let st = style()
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let t = TermView(rows: max(rows, 10), cols: max(cols, 20), fontName: st.font, fontSize: CGFloat(st.size), lineHeight: CGFloat(st.lineHeight))
        NSApp.appearance = appearance(st.theme) // 프로그램이 시작하며 배경색을 물을 때(OSC 11) 이미 맞는 모양이게 먼저
        t.contrast = CGFloat(st.contrast)
        // 기억한 칸 수가 없으면 화면을 거의 채운다(Terminal 방식과 같음)
        let content = cols > 20 && rows > 10 ? t.contentSize(cols: cols, rows: rows) : NSSize(width: visible.width - 80, height: visible.height - 60)
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: content), styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        let appName = info["CFBundleName"] as? String ?? "TUIDock"
        w.isReleasedWhenClosed = false
        w.title = appName
        w.contentView = t
        w.contentResizeIncrements = NSSize(width: t.cellW, height: t.cellH)
        w.delegate = self
        if let s = defaults.string(forKey: "topLeft") { w.setFrameTopLeftPoint(NSPointFromString(s)) } else { w.center() }
        w.setFrame(w.constrainFrameRect(w.frame, to: w.screen ?? NSScreen.main), display: false)
        t.onTitle = { [weak w] title in w?.title = title.isEmpty ? appName : title }
        t.onCmdKey = { [weak self] e in self?.builtinCmdKey(e) ?? false }
        t.onExitKey = { NSApp.terminate(nil) }
        window = w
        term = t
        // 로그인 셸을 거쳐 실행한다(Terminal 창에서 띄우던 것과 같은 PATH·환경). exec라 pid는 그대로 프로그램이 된다
        var shell = "/bin/zsh"
        if let pw = getpwuid(getuid()), let p = pw.pointee.pw_shell {
            let s = String(cString: p)
            if ["zsh", "bash", "sh", "ksh"].contains((s as NSString).lastPathComponent) { shell = s }
        }
        let argv = ["-" + (shell as NSString).lastPathComponent, "-i", "-c", "exec \"$0\" \"$@\"", commandPath()] + arguments
        var vars = ProcessInfo.processInfo.environment
        vars["TUIDOCK"] = sockDir
        vars["TERM"] = "xterm-256color"
        vars["COLORTERM"] = "truecolor"
        vars["TERM_PROGRAM"] = "tuidock"
        if vars["LC_ALL"] == nil { // Dock에서 띄운 앱엔 로케일 변수가 없어 한글이 깨진다
            // Terminal.app처럼 첫 선호 언어 + 지역(ko-KR → ko_KR). 실행기 번들엔 현지화가 없어 Locale.current는 en_US가 된다(실측).
            // 물려받은 LANG이 있어도 바꾼다(Terminal.app과 같음): 셸에서 open으로 띄우면 그 셸의 LANG이 넘어와 띄운 방법마다 언어가 달랐다.
            // 시스템에 없는 조합(en_KR 등)이면 다음 후보로
            let lang = Locale.preferredLanguages.first?.split(separator: "-").first.map(String.init) ?? "en"
            let appleLocale = UserDefaults.standard.string(forKey: "AppleLocale")?.split(separator: "@").first.map(String.init) ?? ""
            let region = appleLocale.split(separator: "_").dropFirst().first.map(String.init) ?? ""
            let candidates = [lang + "_" + region, appleLocale, lang + "_" + lang.uppercased(), "en_US"]
            vars["LANG"] = (candidates.first { FileManager.default.fileExists(atPath: "/usr/share/locale/\($0).UTF-8") } ?? "en_US") + ".UTF-8"
        }
        let p = t.start(path: shell, argv: argv, env: vars)
        guard p > 0 else { return NSApp.terminate(nil) }
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(t)
        NSApp.activate()
        adopt(p)
        watchConfig()
    }

    // builtinExited는 프로그램이 끝났을 때. 정상 종료·종료 요청이면 앱도 끝내고, 오류면 메시지를 남기고 아무 키를 기다린다.
    func builtinExited(_ p: pid_t) {
        var status: Int32 = 0
        waitpid(p, &status, 0)
        let sig = status & 0x7F, code = (status >> 8) & 0xFF
        if closeWindow || (sig == 0 && code == 0) || [SIGTERM, SIGHUP, SIGINT].contains(sig) { return NSApp.terminate(nil) }
        let ko = Locale.preferredLanguages.first?.hasPrefix("ko") ?? false
        let what = sig != 0 ? "signal \(sig)" : "exit \(code)"
        term?.finished(ko ? "[프로그램이 끝났습니다(\(what)). 아무 키나 누르면 닫힙니다]" : "[Program ended (\(what)). Press any key to close]")
        show()
    }

    // builtinCmdKey는 Cmd 조합. 연결된 프로그램이면 Terminal 방식과 같은 규칙으로 넘긴다(Cmd+H·W·M·`, 스크린샷 등은 남김).
    // 연결 안 된 프로그램이면 메뉴(복사·붙여넣기·글꼴·가리기·종료)로 가고, 메뉴에 없는 조합은 TermView가 버린다.
    func builtinCmdKey(_ e: NSEvent) -> Bool {
        guard connected, let name = keys.first(where: { $0.0 == Int(e.keyCode) })?.1 else { return false }
        let f = e.modifierFlags
        if f.contains(.control) || f.contains(.option) { return false }
        let shift = f.contains(.shift)
        if shift ? keepCmdShift.contains(name) : keepCmd.contains(name) { return false }
        if !shift, name == "," { return false } // Cmd+,는 이 앱 설정
        send("key cmd+" + (shift ? "shift+" : "") + name)
        return true
    }

    // applyStyle은 설정 파일을 다시 읽어 글꼴·줄간격·대비를 바꾼다. 칸 수는 그대로 두고 창 크기를 맞춘다(Terminal.app의 Cmd +/-와 같음).
    func applyStyle(_ live: [String: String] = [:]) {
        guard let term, let window else { return }
        let st = style(live)
        let c = term.cols, r = term.rows
        NSApp.appearance = appearance(st.theme)
        term.contrast = CGFloat(st.contrast)
        term.setStyle(fontName: st.font, fontSize: CGFloat(st.size), lineHeight: CGFloat(st.lineHeight))
        window.contentResizeIncrements = NSSize(width: term.cellW, height: term.cellH)
        let top = window.frame.maxY
        var f = window.frameRect(forContentRect: NSRect(origin: window.frame.origin, size: term.contentSize(cols: c, rows: r)))
        f.origin.y = top - f.height
        window.setFrame(window.constrainFrameRect(f, to: window.screen), display: true)
    }

    func appearance(_ theme: String) -> NSAppearance? {
        theme == "dark" ? NSAppearance(named: .darkAqua) : theme == "light" ? NSAppearance(named: .aqua) : nil
    }

    // setConfig는 설정 파일의 그 키 줄만 바꾼다(없으면 덧붙임). 파일이 없으면 주석 달린 기본 파일부터 만든다.
    func setConfig(_ key: String, _ value: String) {
        makeConfig()
        var lines = ((try? String(contentsOf: configURL, encoding: .utf8)) ?? "").components(separatedBy: "\n")
        if let i = lines.firstIndex(where: { l in
            let t = l.trimmingCharacters(in: .whitespaces)
            return !t.hasPrefix("#") && t.split(separator: "=", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces) == key
        }) {
            lines[i] = "\(key) = \(value)"
        } else {
            if lines.last == "" { lines.removeLast() }
            lines += ["\(key) = \(value)", ""]
        }
        try? lines.joined(separator: "\n").write(to: configURL, atomically: true, encoding: .utf8)
        applyStyle()
    }

    // makeConfig는 설정 파일이 없으면 기본 파일을 만들고 지켜보기 시작한다.
    func makeConfig() {
        if ensureConfig() { watchConfig() }
    }

    // watchConfig는 설정 파일을 지켜본다. 편집기는 대개 새 파일로 바꿔 저장하므로(이름 바꾸기·지우기) 그때마다 다시 붙는다.
    func watchConfig() {
        configWatch?.cancel()
        configWatch = nil
        let fd = open(configURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self, let w = self.configWatch else { return }
            if !w.data.intersection([.rename, .delete]).isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.watchConfig() }
            }
            self.applyStyle()
            self.settingsWindow?.refresh() // 파일을 편집기로 고쳐도 창이 따라간다
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        configWatch = src
    }

    // openSettings(Cmd+,)는 설정 창을 연다. 창의 "파일 열기…"는 설정 파일을 기본 텍스트 편집기로 연다(openSettingsFile).
    @objc func openSettings(_ s: Any?) {
        if settingsWindow == nil {
            settingsWindow = SettingsWindow(bundledFont: bundledFont, onChange: { [weak self] k, v in self?.setConfig(k, v) },
                                            onOpenFile: { [weak self] in self?.openSettingsFile() })
            settingsWindow!.model.live = { [weak self] k, v in self?.applyStyle([k: v]) }
            if let w = window { // 터미널 창 가운데 위쪽
                let f = settingsWindow!.frame
                settingsWindow!.setFrameOrigin(NSPoint(x: w.frame.midX - f.width / 2, y: w.frame.maxY - f.height - 80))
            } else {
                settingsWindow!.center()
            }
        }
        settingsWindow!.refresh()
        settingsWindow!.makeKeyAndOrderFront(nil)
    }

    func openSettingsFile() {
        makeConfig()
        if let editor = NSWorkspace.shared.urlForApplication(toOpen: .plainText) {
            NSWorkspace.shared.open([configURL], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(configURL)
        }
    }

    func setBuiltinFont(_ size: CGFloat) {
        guard size >= 6, size <= 72 else { return }
        setConfig("font_size", fmtNum(Double(size)))
    }

    @objc func biggerFont(_ s: Any?) { setFont(1) }
    @objc func smallerFont(_ s: Any?) { setFont(-1) }
    @objc func defaultFont(_ s: Any?) { setBuiltinFont(CGFloat(Double(configKeys.first { $0.key == "font_size" }!.def()) ?? 13)) }
    // Cmd+W: 설정 창이 앞이면 그 창을 닫고, 아니면 터미널 창을 가린다
    @objc func hideFromMenu(_ s: Any?) {
        if let sw = settingsWindow, NSApp.keyWindow === sw { return sw.close() }
        hideWindow()
    }

    // 메뉴: 앱(가리기·종료), 편집(복사·붙여넣기), 보기(글꼴 크기), 윈도우(최소화·닫기 = 가리기)
    func setupMenu() {
        let name = info["CFBundleName"] as? String ?? "TUIDock"
        let ko = Locale.preferredLanguages.first?.hasPrefix("ko") ?? false
        func L(_ k: String, _ e: String) -> String { ko ? k : e }
        let main = NSMenu()
        func menu(_ title: String, _ items: [NSMenuItem]) {
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            it.submenu = m
            main.addItem(it)
        }
        func item(_ t: String, _ a: Selector, _ k: String, _ mods: NSEvent.ModifierFlags = .command, _ target: AnyObject? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: a, keyEquivalent: k)
            i.keyEquivalentModifierMask = mods
            i.target = target
            return i
        }
        menu(name, [
            item(L("\(name) 가리기", "Hide \(name)"), #selector(NSApplication.hide(_:)), "h"),
            item(L("기타 가리기", "Hide Others"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item(L("모두 보기", "Show All"), #selector(NSApplication.unhideAllApplications(_:)), ""),
            .separator(),
            item(L("설정…", "Settings…"), #selector(openSettings(_:)), ",", .command, self),
            .separator(),
            item(L("\(name) 종료", "Quit \(name)"), #selector(NSApplication.terminate(_:)), "q"),
        ])
        menu(L("편집", "Edit"), [
            item(L("복사", "Copy"), #selector(TermView.copy(_:)), "c"),
            item(L("붙여넣기", "Paste"), #selector(TermView.paste(_:)), "v"),
        ])
        // Cmd+=는 Shift 없이 누른 Cmd+(보이지 않는 같은 항목)
        let plain = item(L("크게", "Bigger"), #selector(biggerFont(_:)), "=", .command, self)
        plain.isHidden = true
        plain.allowsKeyEquivalentWhenHidden = true
        menu(L("보기", "View"), [
            item(L("크게", "Bigger"), #selector(biggerFont(_:)), "+", .command, self), plain,
            item(L("작게", "Smaller"), #selector(smallerFont(_:)), "-", .command, self),
            item(L("기본 크기", "Default Size"), #selector(defaultFont(_:)), "0", .command, self),
        ])
        menu(L("윈도우", "Window"), [
            item(L("최소화", "Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m"),
            item(L("닫기", "Close"), #selector(hideFromMenu(_:)), "w", .command, self),
        ])
        NSApp.mainMenu = main
    }

    // 빨간 닫기 단추도 Cmd+W처럼 가리기(종료는 Cmd+Q·Dock)
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hideWindow()
        return false
    }
    func windowDidBecomeKey(_ n: Notification) { term?.focus(true) }
    func windowDidResignKey(_ n: Notification) { term?.focus(false) }
    func applicationDidResignActive(_ n: Notification) { if host == .builtin { saveSize() } }
}

let dock = Dock()

@main
enum Main {
    static func main() {
        // 실행 파일 명령(--help·--config-path 등, config.swift)은 창을 띄우기 전에 처리하고 끝난다
        if let code = handleCommand(Array(CommandLine.arguments.dropFirst())) { exit(code) }
        let app = NSApplication.shared
        app.delegate = dock
        app.setActivationPolicy(.regular)
        app.run()
    }
}
