// TUIDock.app: 터미널 프로그램을 Dock 앱으로 만드는 창 하나짜리 앱(Fluid처럼).
// 창엔 아이콘과 드롭 칸(사용자 지시: 너저분하지 않게), 아래에 터미널 선택 한 줄. 아이콘을 누르면 이모지 창, 실행 파일을 놓으면 바로 만든다.
// 앱 이름은 실행 파일 이름의 첫 글자만 대문자로. /Applications(쓸 수 없으면 ~/Applications)에 넣고 Dock에 고정.
// 실제 만들기는 번들 안 tuidock 명령(Resources/tuidock)이 한다. 실행기·아이콘 도구도 빌드해 넣어 두어 Xcode가 필요 없다.
// 빌드: scripts/build-app.sh
import AppKit
import SwiftUI
import UniformTypeIdentifiers

let korean = Locale.preferredLanguages.first?.hasPrefix("ko") ?? false
func L(_ ko: String, _ en: String) -> String { korean ? ko : en }

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
}

@main
struct TUIDockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        Window("TUIDock", id: "main") {
            MakerView()
        }
        .windowResizability(.contentSize)
    }
}

// 배경색(아이콘 오른쪽 클릭 메뉴). 첫 값이 기본(IconRender.defaultColor).
let swatches: [(String, String, String)] = [
    ("#2B2B2E", "검정", "Black"), ("#F2F2F5", "흰색", "White"), ("#E5484D", "빨강", "Red"), ("#F2994A", "주황", "Orange"),
    ("#F2C94C", "노랑", "Yellow"), ("#30A46C", "초록", "Green"), ("#3E8EF7", "파랑", "Blue"), ("#8E4EC6", "보라", "Purple"),
]

// swatch는 메뉴에 붙일 색 동그라미.
func swatch(_ hex: String) -> NSImage {
    NSImage(size: NSSize(width: 14, height: 14), flipped: false) { r in
        IconRender.color(hex).setFill()
        NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).fill()
        return true
    }
}

// 고를 수 있는 실행기(tuidock --terminal 값, 이름, 번들 ID). 설치된 것만 보인다. 자체 터미널이 기본.
// 자체 터미널(builtin)은 앱 안에 들어 있어 늘 보인다
let terminals: [(String, String, String)] = [
    ("builtin", L("자체 터미널", "Built-in"), ""), ("terminal", L("터미널", "Terminal"), "com.apple.Terminal"),
    ("iterm2", L("아이텀", "iTerm2"), "com.googlecode.iterm2"), ("ghostty", L("고스티", "Ghostty"), "com.mitchellh.ghostty"),
]
let installedTerminals = terminals.filter {
    $0.0 == "terminal" || $0.0 == "builtin" || NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.2) != nil
}

// memoryNote는 실행기별 앱 하나의 메모리 추정(실측: 자체 터미널 창 1200×900pt 43~46MB, 실행기 14MB, Terminal 창 +14MB·본체 약 115MB,
// iTerm2 창 +21~33MB·본체 약 90MB, 따로 띄운 Ghostty 70~106MB)
func memoryNote(_ t: String) -> String {
    switch t {
    case "builtin": return L("메모리: 앱당 약 40~60MB", "Memory: about 40-60MB per app")
    case "terminal": return L("메모리: 앱당 약 30MB + Terminal 본체 약 115MB(공유)", "Memory: about 30MB per app + Terminal itself, about 115MB (shared)")
    case "iterm2": return L("메모리: 앱당 약 35~50MB + iTerm2 본체 약 90MB(공유)", "Memory: about 35-50MB per app + iTerm2 itself, about 90MB (shared)")
    case "ghostty": return L("메모리: 앱당 약 85~120MB(Ghostty를 따로 띄움)", "Memory: about 85-120MB per app (a separate Ghostty each)")
    default: return ""
    }
}

// appName은 실행 파일 이름의 첫 글자만 대문자로(htop → Htop).
func appName(_ url: URL) -> String {
    let n = url.lastPathComponent.replacingOccurrences(of: "/", with: "-")
    return n.prefix(1).uppercased() + n.dropFirst()
}

struct MakerView: View {
    @State var binary: URL?
    @State var emoji = UserDefaults.standard.string(forKey: "emoji") ?? "" // 실행 인자 -emoji 🗓️ 로 미리 고를 수 있다(화면 캡처용)
    @State var iconImage: URL? // 아이콘 자리에 놓은 이미지. 있으면 이모지 대신 그대로 쓴다
    @State var iconDropping = false
    @State var color = swatches[0].0
    @AppStorage("terminal") var terminal = "builtin" // 마지막에 고른 터미널을 다음에도
    @State var typed = "" // macOS 이모지 창이 넣는 보이지 않는 글자 칸
    @FocusState var typing: Bool
    @State var dropping = false
    @State var busy = false
    @State var result: Result?
    @State var remake: DispatchWorkItem?

    enum Result {
        case done(URL)
        case failed(String)
    }

    var iconText: String { emoji.isEmpty ? (binary.map(appName) ?? "?") : emoji }

    var body: some View {
        VStack(spacing: 10) { // 터미널 선택 줄은 가운데(사용자 지시)
            HStack(spacing: 16) {
                iconButton
                dropZone
            }
            // 선택 상자 밑에 그 실행기의 앱당 메모리 추정(실측, AGENTS.md). 같은 한 줄 자리라 골라도 창 크기가 바뀌지 않는다
            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    Text(L("실행기", "Run in")).foregroundStyle(.secondary)
                    Picker("", selection: $terminal) {
                        ForEach(installedTerminals, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Text(memoryNote(terminal))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 24)
        .frame(width: 470)
        .onAppear { if !installedTerminals.contains(where: { $0.0 == terminal }) { terminal = "builtin" } }
        .onChange(of: emoji) { _, _ in scheduleRemake() }
        .onChange(of: iconImage) { _, _ in scheduleRemake() }
        .onChange(of: color) { _, _ in scheduleRemake() }
        .onChange(of: terminal) { _, _ in scheduleRemake() }
    }

    // 아이콘: 누르면 이모지 창, 이미지를 놓으면 그 이미지, 오른쪽 클릭으로 첫 글자·배경색
    var iconButton: some View {
        Group {
            // 누르면 macOS 이모지 창. 이모지 창은 포커스된 글자 칸에 넣으므로 아이콘 위에 보이지 않는 칸을 두고
            // 거기에 받는다(창도 그 칸 옆에 뜬다). 첫 글자·배경색(첫 글자 아이콘만)은 오른쪽 클릭 메뉴.
            Button {
                typing = true
                DispatchQueue.main.async { NSApp.orderFrontCharacterPalette(nil) }
            } label: {
                Image(nsImage: iconImage.flatMap { NSImage(contentsOf: $0) } ?? IconRender.image(text: iconText, color: color))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 128, height: 128)
                    .background(RoundedRectangle(cornerRadius: 28).fill(iconDropping ? Color.accentColor.opacity(0.15) : .clear))
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help(L("눌러서 이모지 고르기, 오른쪽 클릭으로 첫 글자 아이콘·배경색. 이미지를 놓으면 그 이미지로",
                    "Click to pick an emoji, right-click for a first-letter icon and its color. Drop an image to use it"))
            .onDrop(of: [.fileURL], isTargeted: $iconDropping) { items in
                guard let item = items.first else { return false }
                _ = item.loadObject(ofClass: URL.self) { url, _ in
                    if let url, isImage(url) { DispatchQueue.main.async { iconImage = url } }
                }
                return true
            }
            .background(
                TextField("", text: $typed)
                    .frame(width: 1, height: 1)
                    .opacity(0)
                    .focused($typing)
                    .onChange(of: typed) { _, v in
                        if let last = v.last {
                            emoji = String(last)
                            iconImage = nil
                        }
                        if !v.isEmpty { typed = "" }
                    }
            )
            .contextMenu {
                // 배경색은 첫 글자 아이콘에만 쓴다(이모지는 판 없이 그린다)
                if emoji.isEmpty && iconImage == nil {
                    ForEach(swatches, id: \.0) { c in
                        Button { color = c.0 } label: {
                            Label { Text(L(c.1, c.2)) } icon: { Image(nsImage: swatch(c.0)) }
                        }
                    }
                    Divider()
                }
                Button(L("첫 글자로", "Use first letter")) {
                    emoji = ""
                    iconImage = nil
                }
                .disabled(emoji.isEmpty && iconImage == nil)
            }
        }
    }

    // 드롭 칸: 끌어다 놓거나 눌러서 고르면 바로 만든다. 만든 뒤엔 결과를 보여 준다(다른 파일을 놓으면 또 만든다).
    var dropZone: some View {
        RoundedRectangle(cornerRadius: 10)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5]))
            .foregroundStyle(dropping ? Color.accentColor : Color.secondary.opacity(0.6))
            .background(RoundedRectangle(cornerRadius: 10).fill(dropping ? Color.accentColor.opacity(0.08) : .clear))
            .frame(height: 128)
            .overlay {
                VStack(spacing: 6) {
                    if busy {
                        ProgressView().controlSize(.small)
                    } else if case .done(let url)? = result {
                        Text(url.deletingPathExtension().lastPathComponent).font(.headline)
                        HStack(spacing: 10) {
                            Button(L("열기", "Open")) { NSWorkspace.shared.open(url) }
                            Button(L("Finder에서 보기", "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        }
                        .controlSize(.small)
                        Text(L("Dock에 고정했습니다", "Pinned to the Dock")).font(.caption).foregroundStyle(.secondary)
                    } else if case .failed(let msg)? = result {
                        Text(msg).font(.caption).foregroundStyle(.red).lineLimit(4).multilineTextAlignment(.center)
                    } else {
                        Text(L("터미널 프로그램을 여기에", "Drop a terminal program here")).font(.headline)
                        Text(L("끌어다 놓거나 눌러서 고르기", "or click to choose")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10)
            }
            .contentShape(Rectangle())
            .onTapGesture { if !busy { choose() } }
            .onDrop(of: [.fileURL], isTargeted: $dropping) { items in
                guard let item = items.first, !busy else { return false }
                _ = item.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { pick(url) } }
                }
                return true
            }
    }

    func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = L("Dock 앱으로 만들 터미널 프로그램", "Terminal program to turn into a Dock app")
        if panel.runModal() == .OK, let url = panel.url { pick(url) }
    }

    func isImage(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)?.conforms(to: .image) ?? false
    }

    func pick(_ url: URL) {
        if isImage(url) { // 드롭 칸에 놓은 이미지도 아이콘으로
            iconImage = url
            return
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue,
              FileManager.default.isExecutableFile(atPath: url.path) else {
            result = .failed(L("실행 파일이 아닙니다: ", "Not an executable: ") + url.lastPathComponent)
            return
        }
        binary = url
        make()
    }

    // 만든 뒤 아이콘을 바꾸면 같은 앱을 다시 만든다(고르는 동안 여러 번 바뀌므로 잠깐 기다렸다가).
    func scheduleRemake() {
        guard binary != nil, case .done? = result else { return }
        remake?.cancel()
        let w = DispatchWorkItem { make() }
        remake = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: w)
    }

    // make는 번들 안 tuidock으로 임시 폴더에 앱을 만들고 설치한다.
    func make() {
        guard let binary, !busy else { return }
        let name = appName(binary)
        let script = Bundle.main.resourceURL!.appendingPathComponent("tuidock").path
        let fm = FileManager.default
        var dir = "/Applications"
        if !fm.isWritableFile(atPath: dir) {
            dir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        // 복사하지 않고 그 경로를 실행한다(명령의 바로 만들기와 같다). 복사본은 시스템 도구면 macOS가 바로 죽이고(플랫폼 바이너리),
        // setuid 도구는 권한을 잃고, 프로그램을 다시 빌드하면 낡는다.
        var args = ["make", "--name", name, "--command", binary.path, "--color", color, "--terminal", terminal]
        if let iconImage {
            args += ["--icon", iconImage.path]
        } else if !emoji.isEmpty {
            args += ["--emoji", emoji]
        }
        busy = true
        DispatchQueue.global().async {
            let fm = FileManager.default
            let tmp = fm.temporaryDirectory.appendingPathComponent("tuidock-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: tmp) }
            try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            var r = run(script, args + ["--out", tmp.path], env: [:])
            if r == nil {
                r = run(script, ["install", tmp.appendingPathComponent(name + ".app").path], env: ["APP_DIR": dir])
            }
            let final: Result = r.map { .failed($0) } ?? .done(URL(fileURLWithPath: dir).appendingPathComponent(name + ".app"))
            DispatchQueue.main.async {
                busy = false
                result = final
            }
        }
    }

    // run은 bash로 tuidock을 돌린다. 실패하면 오류 글자, 성공하면 nil.
    func run(_ script: String, _ args: [String], env: [String: String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script] + args
        p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        do { try p.run() } catch { return error.localizedDescription }
        let data = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if p.terminationStatus == 0 { return nil }
        let msg = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return msg.isEmpty ? L("만들지 못했습니다", "Failed") : msg
    }
}
