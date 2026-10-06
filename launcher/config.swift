// 자체 터미널의 설정 파일(config.toml). github.com/zidell/agent-discoverable-config를 따른다:
//  - 실제 파일: ~/Library/Application Support/<번들 ID>/config.toml (실행 파일 --config-path가 출력)
//  - 앱 안 안내: Contents/Resources/readme.txt(tuidock make가 넣는다)
//  - 키 바로 위에 기능·타입·기본값·범위·적용 시점. 설명·기본값·검증·파일 만들기가 모두 아래 configKeys 한 곳에서 나온다
//  - 실행 파일 명령(--help 등)은 창을 띄우기 전에 처리하고 끝난다
// 비밀값은 없다(글꼴·화면 설정뿐).
import Foundation

enum ConfigKind {
    case text
    case number(ClosedRange<Double>, unit: String)
    case choice([String])
}

struct ConfigKey {
    let key: String
    let kind: ConfigKind
    let ko: [String] // 설명 줄(한국어)
    let en: [String]
    let def: () -> String // 기본값(만들 때 준 Info.plist 값이 있으면 그것)
}

func plistString(_ k: String) -> String? { (Bundle.main.infoDictionary?[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }

let configKeys: [ConfigKey] = [
    ConfigKey(key: "font_family", kind: .text,
              ko: ["글꼴 이름. 글꼴 모음 이름(\"Menlo\", \"JetBrains Mono\")이나 PostScript 이름(\"Menlo-Regular\").",
                   "빈 문자열이면 앱에 든 D2Coding(SIL Open Font License, Resources/fonts/OFL.txt). 없는 이름이면 시스템 고정폭 글꼴."],
              en: ["Font name: a family (\"Menlo\", \"JetBrains Mono\") or a PostScript name (\"Menlo-Regular\").",
                   "Empty: D2Coding, bundled in the app (SIL Open Font License, Resources/fonts/OFL.txt). Unknown names fall back to the system monospaced font."],
              def: { plistString("TUIDockFont") ?? "" }),
    ConfigKey(key: "font_size", kind: .number(6...72, unit: "pt"),
              ko: ["글꼴 크기. Cmd +/-로 바꾸면 이 줄이 바뀐다. Cmd 0은 기본값으로."],
              en: ["Font size. Cmd +/- rewrite this line; Cmd 0 restores the default."],
              def: { plistString("TUIDockFontSize") ?? "13" }),
    ConfigKey(key: "line_height", kind: .number(1...3, unit: ""),
              ko: ["줄간격: 글꼴 본래 줄 높이의 배수. 표·테두리 선은 줄간격과 관계없이 이어진다."],
              en: ["Line height as a multiple of the font's own. Table and border lines stay joined at any value."],
              def: { plistString("TUIDockLineHeight") ?? "1.3" }),
    ConfigKey(key: "theme", kind: .choice(["auto", "dark", "light"]),
              ko: ["화면 모양. \"auto\": 시스템 다크·라이트를 따라감, \"dark\", \"light\".",
                   "프로그램이 배경색을 물으면(OSC 11) 이 모양의 색으로 답한다. 다크·라이트 알림(모드 2031)을 켠 프로그램은 바뀔 때 바로 맞추고, 아니면 다시 켜야 그쪽 색이 바뀐다."],
              en: ["Appearance. \"auto\": follow the system's dark/light mode, \"dark\", \"light\".",
                   "When the program asks for the background color (OSC 11) it gets this appearance's. Programs that turn on dark/light notifications (mode 2031) follow changes at once; others need a restart."],
              def: { "auto" }),
    ConfigKey(key: "contrast", kind: .number(-100...100, unit: "%"),
              ko: ["대비. 0(기본)이면 프로그램 색을 손대지 않는다. +면 글자색을 흰색(다크)·검정(라이트) 쪽으로 그만큼 섞어 대비를 올리고,",
                   "-면 배경 쪽으로 섞어(-100%: 80%) 흐리게 한다. 설정 창 슬라이더와 같다."],
              en: ["Contrast. 0 (default) leaves the program's colors untouched. + blends text toward white (dark) or black (light) by that much;",
                   "- blends it toward the background (-100%: 80%). Same as the settings slider."],
              def: { "0" }),
]

let configKO = Locale.preferredLanguages.first?.hasPrefix("ko") ?? false

var configURL: URL {
    let id = Bundle.main.bundleIdentifier ?? "tuidock"
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/\(id)/config.toml")
}

// parseConfig는 `키 = 값` 줄만 읽는 작은 TOML 읽기(문자열은 "…"·'…', # 주석, 표·배열 없음).
// 알 수 있는 키는 타입·범위를 검사해 맞는 값만 돌려주고, 틀린 줄은 errors에 남긴다(그 키는 기본값을 쓴다).
func parseConfig(_ text: String) -> (values: [String: String], errors: [String]) {
    var values: [String: String] = [:], errors: [String] = []
    for (n, line) in text.components(separatedBy: "\n").enumerated() {
        let l = line.trimmingCharacters(in: .whitespaces)
        if l.isEmpty || l.hasPrefix("#") { continue }
        guard let eq = l.firstIndex(of: "=") else {
            errors.append("line \(n + 1): not `key = value`: \(l)")
            continue
        }
        let key = l[..<eq].trimmingCharacters(in: .whitespaces)
        var raw = l[l.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        var quoted = false
        if let q = raw.first, q == "\"" || q == "'" {
            let body = raw.dropFirst()
            guard let end = body.firstIndex(of: q) else {
                errors.append("line \(n + 1): \(key): unterminated string")
                continue
            }
            raw = String(body[..<end])
            quoted = true
        } else if let h = raw.firstIndex(of: "#") {
            raw = raw[..<h].trimmingCharacters(in: .whitespaces)
        }
        guard let spec = configKeys.first(where: { $0.key == key }) else {
            errors.append("line \(n + 1): unknown key \(key) (known: \(configKeys.map(\.key).joined(separator: ", ")))")
            continue
        }
        switch spec.kind {
        case .text:
            guard quoted else { errors.append("line \(n + 1): \(key): needs a quoted string, e.g. \(key) = \"Menlo\""); continue }
        case .number(let range, _):
            guard !quoted, let v = Double(raw), range.contains(v) else {
                errors.append("line \(n + 1): \(key) = \(raw): needs a number \(fmtNum(range.lowerBound))..\(fmtNum(range.upperBound)); using the default \(spec.def())")
                continue
            }
        case .choice(let allowed):
            guard quoted, allowed.contains(raw) else {
                errors.append("line \(n + 1): \(key) = \(raw): needs one of \(allowed.map { "\"\($0)\"" }.joined(separator: ", ")); using the default \"\(spec.def())\"")
                continue
            }
        }
        values[key] = raw
    }
    return (values, errors)
}

func fmtNum(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%g", v) }

// readConfig는 실제 파일의 맞는 값(없으면 빈 사전). 틀린 줄은 로그에 남긴다.
func readConfig() -> [String: String] {
    guard let text = try? String(contentsOf: configURL, encoding: .utf8) else { return [:] }
    let r = parseConfig(text)
    for e in r.errors { NSLog("tuidock config: %@", e) }
    return r.values
}

// configValue는 파일의 값, 없거나 틀렸으면 기본값.
func configValue(_ key: String, _ values: [String: String]) -> String {
    values[key] ?? configKeys.first { $0.key == key }!.def()
}

// configTemplate은 항목 설명이 붙은 기본 설정 파일.
func configTemplate() -> String {
    let name = Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "TUIDock"
    func L(_ k: String, _ e: String) -> String { configKO ? k : e }
    var out = [
        "# \(name) — " + L("tuidock 자체 터미널 설정 (TOML)", "tuidock built-in terminal settings (TOML)"),
        "# " + L("이 파일이 앱이 읽는 실제 설정이다. 저장하면 실행 중인 앱에 바로 반영된다(다시 켤 필요 없음).",
                 "This is the file the app actually reads. Saving applies it to the running app at once (no restart)."),
        "# " + L("앱의 Cmd+, 설정 창에서도 바꿀 수 있다(같은 파일에 저장). 경로·검사: \(Bundle.main.executablePath ?? "launcher") --config-path / --check-config",
                 "The app's Cmd+, settings window edits this same file. Path and check: \(Bundle.main.executablePath ?? "launcher") --config-path / --check-config"),
        "# " + L("잘못된 값은 그 줄만 무시하고 기본값을 쓴다. 비밀값(키·토큰)은 없다.",
                 "An invalid value is ignored (its default is used). There are no secrets here."),
        "",
    ]
    for k in configKeys {
        for d in configKO ? k.ko : k.en { out.append("# " + d) }
        let def = k.def()
        switch k.kind {
        case .text:
            out.append("# " + L("타입: 문자열. 기본값: \"\(def)\".", "Type: string. Default: \"\(def)\"."))
            out.append("\(k.key) = \"\(def)\"")
        case .number(let r, let unit):
            let u = unit.isEmpty ? "" : " (\(unit))"
            out.append("# " + L("타입: 수. 범위: \(fmtNum(r.lowerBound))..\(fmtNum(r.upperBound))\(u). 기본값: \(def).",
                                "Type: number. Range: \(fmtNum(r.lowerBound))..\(fmtNum(r.upperBound))\(u). Default: \(def)."))
            out.append("\(k.key) = \(def)")
        case .choice(let allowed):
            out.append("# " + L("타입: 문자열. 허용값: ", "Type: string. Allowed: ") + allowed.map { "\"\($0)\"" }.joined(separator: ", ")
                + L(". 기본값: \"\(def)\".", ". Default: \"\(def)\"."))
            out.append("\(k.key) = \"\(def)\"")
        }
        out.append("")
    }
    return out.joined(separator: "\n")
}

// ensureConfig는 설정 파일이 없으면 기본 파일을 만든다(있으면 그대로). 만들었으면 true.
@discardableResult
func ensureConfig() -> Bool {
    guard !FileManager.default.fileExists(atPath: configURL.path) else { return false }
    try? FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? configTemplate().write(to: configURL, atomically: true, encoding: .utf8)
    return true
}

// handleCommand는 실행 파일 명령(창을 띄우기 전). 처리했으면 종료 코드, 아니면 nil(앱 실행).
func handleCommand(_ args: [String]) -> Int32? {
    guard let cmd = args.first, cmd.hasPrefix("--") else { return nil }
    let builtin = (Bundle.main.infoDictionary?["TUIDockTerminal"] as? String) == "builtin"
    switch cmd {
    case "--help", "-h":
        let name = Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "this app"
        print("""
        \(name) — a tuidock app: a terminal TUI program wrapped as a macOS Dock app.
        Run without arguments to start it (or open the app).

        Settings (built-in terminal only\(builtin ? "" : "; this app runs in an external terminal, so these files are unused")):
          --config-path            Print the absolute path of the active settings file (it may not exist yet)
          --print-default-config   Print the default settings with an explanation above every key
          --init-config            Create the settings file with the defaults if it doesn't exist (never overwrites)
          --check-config           Check the settings file; prints problems and exits 1 if any
        The settings file is TOML with comments. Saving it applies to the running app at once; the app's Cmd+, settings window edits the same file.
        Guide inside the app: \(Bundle.main.resourceURL?.appendingPathComponent("readme.txt").path ?? "Contents/Resources/readme.txt")
        """)
        return 0
    case "--config-path":
        print(configURL.path)
        return 0
    case "--print-default-config":
        print(configTemplate(), terminator: "")
        return 0
    case "--init-config":
        print(ensureConfig() ? "created: \(configURL.path)" : "exists, left as is: \(configURL.path)")
        return 0
    case "--check-config":
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else {
            print("no settings file (defaults in use): \(configURL.path)")
            return 0
        }
        let r = parseConfig(text)
        for e in r.errors { print(e) }
        if r.errors.isEmpty {
            print("ok: \(configURL.path)")
            for k in configKeys { print("  \(k.key) = \(configValue(k.key, r.values))") }
        }
        return r.errors.isEmpty ? 0 : 1
    default:
        return nil
    }
}
