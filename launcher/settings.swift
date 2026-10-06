// 자체 터미널의 설정 창(Cmd+,). 값의 원본은 config.toml(config.swift)이다: 창에서 바꾸면 그 키 줄만 고쳐 쓰고(주석 보존),
// 파일이 바뀌면(편집기 저장 포함) 창을 다시 채운다. 항목 설명은 configKeys의 설명을 도움말로 쓴다.
// 모양은 macOS 시스템 설정과 같은 묶음 양식(SwiftUI Form .grouped). SwiftUI는 이 창을 열 때만 쓴다.
import AppKit
import SwiftUI

final class SettingsModel: ObservableObject {
    @Published var font = ""         // "" = 앱에 든 D2Coding
    @Published var size = 13.0
    @Published var lineHeight = 1.3
    @Published var theme = "auto"
    @Published var contrast = 0.0
    var families: [String] = []      // 설치된 고정폭 글꼴 모음
    var bundledFont: String?         // 앱에 든 글꼴을 등록했으면 그 이름(미리보기용)
    var loading = false              // 파일에서 채우는 중(쓰지 않음)
    let onChange: (String, String) -> Void

    init(onChange: @escaping (String, String) -> Void) { self.onChange = onChange }

    var live: ((String, String) -> Void)? // 슬라이더를 끄는 동안 뒤의 터미널 창에만 바로 반영(파일은 놓을 때 set으로 쓴다)

    func set(_ key: String, _ value: String) { if !loading { onChange(key, value) } }
    func preview(_ key: String, _ value: String) { if !loading { live?(key, value) } }

    // load는 파일의 지금 값(없거나 틀리면 기본값)으로 채운다.
    func load() {
        let c = readConfig()
        loading = true
        defer { loading = false }
        let names = NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? []
        var fam = Set(names.compactMap { NSFont(name: $0, size: 12)?.familyName }.filter { !$0.hasPrefix(".") })
        let f = configValue("font_family", c)
        let family = NSFont(name: f, size: 12)?.familyName ?? f // PostScript 이름이면 모음 이름으로
        if !family.isEmpty { fam.insert(family) }
        if let b = bundledFont { fam.remove(b) }
        families = fam.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        font = family
        size = Double(configValue("font_size", c)) ?? 13
        lineHeight = Double(configValue("line_height", c)) ?? 1.3
        theme = configValue("theme", c)
        contrast = Double(configValue("contrast", c)) ?? 0
    }
}

struct SettingsView: View {
    @ObservedObject var m: SettingsModel
    let openFile: () -> Void
    private func L(_ k: String, _ e: String) -> String { configKO ? k : e }
    private func help(_ key: String) -> String { (configKO ? configKeys.first { $0.key == key }!.ko : configKeys.first { $0.key == key }!.en).joined(separator: " ") }
    private func num(_ v: Double) -> String { fmtNum((v * 100).rounded() / 100) }

    var body: some View {
        Form {
            Section(L("글꼴", "Font")) {
                Picker(L("글꼴", "Font"), selection: Binding(get: { m.font }, set: { m.font = $0; m.set("font_family", "\"\($0)\"") })) {
                    Text(L("기본 (D2Coding)", "Default (D2Coding)")).tag("")
                    Divider()
                    ForEach(m.families, id: \.self) { Text($0).tag($0) }
                }
                .help(help("font_family"))
                Stepper(value: Binding(get: { m.size }, set: { m.size = $0; m.set("font_size", num($0)) }), in: 6...72, step: 1) {
                    HStack {
                        Text(L("크기", "Size"))
                        Spacer()
                        Text("\(num(m.size)) pt").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .help(help("font_size"))
                LabeledContent(L("줄간격", "Line height")) {
                    HStack(spacing: 10) {
                        Slider(value: Binding(get: { m.lineHeight }, set: { m.lineHeight = ($0 * 20).rounded() / 20; m.preview("line_height", num(m.lineHeight)) }),
                               in: 1...2, onEditingChanged: { editing in if !editing { m.set("line_height", num(m.lineHeight)) } })
                            .frame(width: 160)
                        Text(String(format: "%.2f", m.lineHeight)).monospacedDigit().foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
                    }
                }
                .help(help("line_height"))
            }
            Section {
                Picker(L("모양", "Appearance"), selection: Binding(get: { m.theme }, set: { m.theme = $0; m.set("theme", "\"\($0)\"") })) {
                    Text(L("자동", "Auto")).tag("auto")
                    Text(L("다크", "Dark")).tag("dark")
                    Text(L("라이트", "Light")).tag("light")
                }
                .pickerStyle(.segmented)
                .help(help("theme"))
                // 대비: 가운데 0%가 기본(프로그램 색 그대로), -100%…+100%, 1% 단위
                LabeledContent(L("대비", "Contrast")) {
                    HStack(spacing: 10) {
                        Slider(value: Binding(get: { m.contrast }, set: { m.contrast = $0.rounded(); m.preview("contrast", num(m.contrast)) }),
                               in: -100...100, onEditingChanged: { editing in if !editing { m.set("contrast", num(m.contrast)) } })
                            .frame(width: 160)
                        Text(m.contrast > 0 ? "+\(Int(m.contrast))%" : "\(Int(m.contrast))%")
                            .monospacedDigit().foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
                    }
                }
                .help(help("contrast"))
            } header: {
                Text(L("화면", "Display"))
            } footer: {
                Text(L("다크·라이트 알림(모드 2031)을 쓰지 않는 프로그램은 화면 모양을 바꾼 뒤 다시 켜야 그쪽 색도 맞춰집니다.",
                       "Programs without dark/light notifications (mode 2031) need a restart after changing the appearance so their own colors match."))
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                LabeledContent {
                    Button(L("파일 열기…", "Open File…"), action: openFile)
                } label: {
                    Text("config.toml")
                    Text(L("바꾸면 바로 반영되고 이 파일에 저장됩니다", "Changes apply at once and are saved here"))
                }
                .help(configURL.path)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}

final class SettingsWindow: NSWindow {
    let model: SettingsModel

    init(bundledFont: String?, onChange: @escaping (String, String) -> Void, onOpenFile: @escaping () -> Void) {
        model = SettingsModel(onChange: onChange)
        model.bundledFont = bundledFont
        model.load()
        super.init(contentRect: NSRect(x: 0, y: 0, width: 460, height: 400), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        title = configKO ? "설정" : "Settings"
        let host = NSHostingView(rootView: SettingsView(m: model, openFile: onOpenFile))
        contentView = host
        setContentSize(host.fittingSize)
    }

    func refresh() { model.load() }

    override func cancelOperation(_ sender: Any?) { close() } // Esc
}
