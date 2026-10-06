# Windows판 계획

macOS에서 정한 방향을 Windows 쪽에서 이어 구현하기 위한 계획이다. 끝나면 정한 것은 `AGENTS.md`·README로 옮기고 이 파일은 지운다.

## 목표

터미널 TUI 프로그램을 Windows 작업 표시줄·시작 메뉴·Alt+Tab·AutoHotkey에서 다른 앱처럼 다루게 한다. macOS판과 같은 자체 터미널(libvterm)을 기본으로 둔다.

- 대부분의 TUI(Go Bubble Tea, Rust ratatui, Python Textual, lazygit 등)는 Windows에서도 돈다. Unix 전용(htop 등)만 대상 밖.
- 선택지는 **자체 터미널(기본) / 콘솔 창(conhost)** 두 개.
  - Windows Terminal은 넣지 않는다. 모든 창이 Windows Terminal 아이콘 하나로 묶여 앱마다 따로 고정·전환할 수 없다.
  - PowerShell·cmd는 셸이라 선택지가 아니다. 셸 선택도 없다 — Windows는 PATH를 레지스트리 환경변수로 모든 프로세스가 같게 받으니 TUI 실행 파일을 셸 없이 바로 띄운다(macOS 자체 터미널이 로그인 셸을 거치는 이유가 Windows엔 없다).

## 큰 결정

1. **Qt 6 + Gifiles 터미널 위젯을 가져온다.** Gifiles(github.com/zidell/gifiles, GPLv3 — tuidock도 GPLv3라 가져올 수 있다)의 `src/TerminalWidget.{h,cpp}`(1431줄)와 `src/Pty.h`·`src/PtyWin.cpp`(ConPTY)에 박스 문자 그리기, 한글 조합 위치(`m_markedAt`), 클릭 시 조합 확정(`commitPreedit`), 누름 미루기(`m_pendingPress`), UTF-8 끊김(`incompleteUtf8Tail`), OSC 10/11 답이 이미 있다. Win32·DirectWrite로 새로 짜지 않는다.
   - Gifiles의 ConPTY 터미널은 CI만 통과했고 실제 데스크톱에서 손으로 써 본 적은 없다(Gifiles `AGENTS.md` Status). 처음 띄울 때 그쪽 문제도 같이 나올 수 있다.
2. **exe 하나.** `tuidock.exe`가 생성기·실행기를 겸한다. macOS처럼 앱마다 번들을 찍지 않는다 — Windows 작업 표시줄은 창을 **AppUserModelID(AUMID)**로 묶으므로, 앱마다 아이콘·AUMID·인자가 다른 바로가기(`.lnk`)만 만들면 따로 고정·전환된다.
3. **libvterm은 `launcher/libvterm/`을 그대로 쓴다.** 세 번째 사본을 두지 않는다. CMake에서 `../launcher/libvterm`을 빌드(Gifiles `cmake/libvterm.cmake`와 같은 소스 목록, MSVC 경고 끔).
4. **Windows 관례를 따른다**(macOS Cmd 규칙을 Ctrl로 옮기지 않는다. Ctrl 조합은 TUI가 써야 한다). Windows Terminal과 같게:
   - Ctrl+Shift+C / Ctrl+Shift+V 복사·붙여넣기. 화면에 끌어서 선택한 글자가 있으면 Ctrl+C도 복사(없으면 프로그램에 ^C) — macOS의 "선택이 있으면 Cmd+C는 선택 복사"와 같은 생각.
   - Ctrl+= / Ctrl+- / Ctrl+0 글꼴 크기, Ctrl+, 설정 창.
   - 창 닫기(X·Alt+F4·작업 표시줄 "창 닫기")는 앱 종료. 연결된 프로그램엔 `key cmd+q`를 보내 스스로 끝나게 하고(기존 Go 처리 재사용), 연결 안 된 프로그램은 끝낸다. 최소화는 최소화. macOS의 "Cmd+W는 가림"은 옮기지 않는다 — 작업 표시줄의 X와 구분할 수 없어 닫을 방법이 없어진다.

## 구조

```
windows/
  CMakeLists.txt        Qt6 Widgets(+Gui), C++20, ../launcher/libvterm 정적 링크, 출력 tuidock.exe(WIN32 서브시스템)
  src/main.cpp          모드 나누기: 인자 없음 → 생성기 창 / run --app <id> → 실행기 / make·<program> → CLI / --help·--config-path…
  src/TermView.{h,cpp}  Gifiles TerminalWidget에서 셸 연동을 뺀 것(아래)
  src/Pty.h, PtyWin.cpp Gifiles 그대로(+ 프로그램 종료 코드 받기)
  src/Launcher.{h,cpp}  창 하나, 프로세스 수명, 소켓, 창 크기·위치 기억, AUMID
  src/Config.{h,cpp}    config.toml — launcher/config.swift의 configKeys를 그대로 옮김
  src/Maker.{h,cpp}     make: 앱 정의 파일·아이콘(.ico)·바로가기(.lnk)
  src/Settings.{h,cpp}  설정 창(Ctrl+,)
  src/Console.cpp       콘솔 창 방식
  tests/                Qt Test(offscreen)
  fonts/ → ../launcher/fonts 를 빌드 때 exe 옆 fonts\로 복사
```

`windows/`에 `go.mod`를 두지 않는다(하위 `go.mod`가 있으면 그 폴더가 모듈에서 빠진다. `launcher/`와 같은 규칙).

### TermView (Gifiles TerminalWidget에서)

- **뺄 것**: 셸 연동 전부 — `followFolder`·`runCommand`·`m_pendingCd`·`m_typed`·`commandEntered`·`cwdChanged`·`pollCwd`·OSC 7·끌어 놓기(경로 입력)·`quoteWord`·`expandCommand`·탭 신호, 스크롤백(`m_scrollback`·`m_scrollOffset`, macOS판도 없다). `Settings`·`Theme`·`Shortcuts`·`Util`·`Log` 의존은 Config 값과 작은 함수로 바꾼다.
- **macOS판(`launcher/terminal.swift`)에서 옮길 것**(Gifiles엔 없거나 다르다):
  - 대비 `contrast`(-100~100, 기본 0 = 프로그램 색 그대로). Gifiles의 WCAG `readable()`이 아니라 `AGENTS.md` "그리기"의 섞기 규칙. 흐린 글자(SGR 2)도 같다.
  - 모드 2031 다크·라이트 알림(`watchLightDark`): 바이트에서 `CSI ? 2031 h/l`·`CSI ? 996 n`을 찾고, 모양이 바뀌면 `CSI ? 997 ; 1|2 n`. 모양 변화는 `QStyleHints::colorSchemeChanged` + `theme` 설정.
  - 2칸 글자 키우기(최대 1.4배), DEC 2배 폭 줄(Gifiles에 `lineInfo` 있음, 확인만).
  - Shift+클릭 같은 칸이면 Shift 붙여 넘김. Cmd→Ctrl 바꾸기는 없다(Windows는 Ctrl+클릭이 그대로 Ctrl).
  - 휠: 마우스를 켠 프로그램엔 휠 버튼, 대체 화면엔 위·아래 화살표.
  - 오류 종료(0이 아닌 코드)면 메시지를 남기고 아무 키를 기다린다. 정상 종료면 창을 닫는다.
- 환경변수: `TERM=xterm-256color`·`COLORTERM=truecolor`·`TERM_PROGRAM=tuidock`·`TUIDOCK=<소켓 폴더>`.

### 앱 정의와 바로가기 (Maker)

- 앱 하나 = `%APPDATA%\tuidock\<id>\` 폴더:
  - `app.toml` — `name`·`command`·`args`·`terminal`(builtin|console)·글꼴 기본값. macOS Info.plist의 `TUIDock*` 키 자리.
  - `icon.ico` — 16·24·32·48·64·256. 이모지는 Qt로 그린다(Segoe UI Emoji, Qt 6.8+ DirectWrite 글꼴 엔진이 컬러 이모지를 그림 — 확인 필요). 판 없음, 둘레 8% 여백. 첫 글자 아이콘은 둥근 판 + 배경색. 규칙은 `icon/IconRender.swift`와 같게.
  - `config.toml` — 자체 터미널 설정(아래).
- 바로가기: `%APPDATA%\Microsoft\Windows\Start Menu\Programs\TUIDock\<Name>.lnk`. `IShellLinkW` + `IPropertyStore`로 대상 `tuidock.exe run --app <id>`, 아이콘 `icon.ico`, `PKEY_AppUserModel_ID = tuidock.<id>`. 실행기는 시작하자마자 `SetCurrentProcessExplicitAppUserModelID(L"tuidock.<id>")`. 둘이 같아야 고정한 바로가기와 띄운 창이 한 항목이 된다.
- **작업 표시줄 고정은 자동으로 못 한다**(Windows가 프로그램의 고정을 막는다). 시작 메뉴에 넣고 "작업 표시줄에 고정"은 사용자가 한다. CLI·생성기 창 출력에 그렇게 안내.
- CLI(문구는 영어, 옵션 이름은 macOS와 같게):
  - `tuidock.exe <program> [emoji]` 바로 만들기 — 같은 이름이면 덮어쓰고 이모지·`--terminal`·글꼴은 있던 것을 이어받는다.
  - `tuidock.exe make --name … --command … [--arg …] [--emoji|--icon|--color] [--terminal builtin|console] [--font|--font-size|--line-height] [--id] [--no-shortcut]`
  - `tuidock.exe remove <name>` — 바로가기와 앱 폴더를 지운다(macOS엔 없지만 Windows엔 휴지통에 끌 .app이 없다).
  - `<program>`은 경로나 PATH의 이름(`.exe` 생략 가능, `SearchPathW`).
- `--embed`는 두지 않는다(macOS 빌드 스크립트용이었다).
- 바로가기와 생성기 GUI 창이 여러 `tuidock.exe` 위치를 섞지 않게, 설치본 경로(`%LOCALAPPDATA%\Programs\TUIDock\tuidock.exe`)를 기준으로 바로가기를 만든다. 설치 안 된 exe로 만들면 경고.

### 실행기 (Launcher)

- 프로그램이 떠 있는 동안 상주. 프로그램 종료는 `Pty::finished` + 종료 코드.
- **같은 앱 두 번 실행**: 이미 떠 있으면 새로 띄우지 않고 그 창을 앞으로(이름 있는 뮤텍스 `tuidock.<id>` + 첫 인스턴스 소켓에 `focus`). macOS는 번들이 하나라 저절로 그랬다. 앞으로 가져오기는 `AllowSetForegroundWindow` 후 첫 인스턴스가 `SetForegroundWindow`.
- 창 크기·위치·글꼴 기억: `%APPDATA%\tuidock\<id>\state.ini`(QSettings IniFormat) `cols`·`rows`·`font`·`pos`. 새 창은 글꼴 → 칸 수 순서, 값이 없으면 화면을 거의 채운다(macOS와 같음). DPI가 다른 모니터 사이 이동(`screenChanged`)에 칸 수 유지.
- 창 아이콘은 `icon.ico`(제목 표시줄·Alt+Tab).
- 글꼴: 기본 D2Coding을 exe 옆 `fonts\`에서 `QFontDatabase::addApplicationFont`(프로세스 범위, 시스템 설치 안 함). 기본 13pt·줄간격 1.3.

### 소켓·`tuidock.go`

- **Windows AF_UNIX는 데이터그램을 지원하지 않는다**(스트림만). 지금 프로토콜(`unixgram`, 메시지 하나 = 데이터그램 하나)을 Windows에서는 **스트림, 연결 하나에 메시지 하나**(연결 → 쓰기 → 닫기)로 바꾼다. 받는 쪽은 accept 후 EOF까지 읽은 것이 메시지 하나. 보내는 패턴이 지금도 "매번 dial → write → close"라 의미는 같다.
  - `tuidock.go`를 `tuidock_unix.go`(지금 코드, `//go:build !windows`)와 `tuidock_windows.go`로 나누고 공통(`Conn`, 메시지 처리)은 남긴다. 지금 `Open`이 Windows에서 nil이라는 문서·`AGENTS.md` 문장도 고친다.
  - 소켓 폴더: `%TEMP%\tuidock-<id>\`(길면 FNV 해시, macOS와 같은 규칙). 파일 `app.sock`·`launcher.sock`.
  - 메시지는 macOS와 같다: `hello <pid>`·`focus 1|0`·`hide`(= 최소화)·`font ±1`·`bye`/`ok`, 실행기 → 프로그램 `key …`·`ping`.
- `Paste`/`Copy`: `pbpaste`·`pbcopy` 대신 Win32 클립보드(`syscall`로 user32 `OpenClipboard`·`GetClipboardData(CF_UNICODETEXT)`·`SetClipboardData`). 의존성은 늘리지 않는다(`go.mod`에 외부 모듈 없음).
- Windows에서 실행기가 연결된 프로그램에 넘길 키: 창 닫기의 `key cmd+q`. 나머지 Ctrl 조합은 pty로 그대로 들어가니 넘길 게 없다. Ctrl+Shift+C/V·글꼴·설정 키만 실행기가 먹는다.

### 설정 파일·설정 창

- `%APPDATA%\tuidock\<id>\config.toml`, 키·설명·범위·기본값은 `launcher/config.swift` `configKeys`를 그대로(한·영 설명, `font_family`·`font_size`·`line_height`·`theme`·`contrast`). 잘못된 줄은 그 키만 기본값. 파일을 지켜보다(`QFileSystemWatcher`, 이름 바꿔 저장도 다시 붙이기) 바뀌면 칸 수를 두고 창 크기를 맞춘다. Ctrl+= / -는 `font_size` 줄만 고친다.
- 실행 파일 명령: `tuidock.exe --app <id> --config-path|--print-default-config|--init-config|--check-config`. WIN32 서브시스템이라 콘솔 출력이 안 보이니 `AttachConsole(ATTACH_PARENT_PROCESS)`로 부모 콘솔에 붙여 쓴다.
- 설정 창(Ctrl+,): macOS `settings.swift`와 같은 항목 — 글꼴 목록(설치된 고정폭 + D2Coding), 크기, 줄간격(1~2), 대비(-100~+100%, 가운데 0이 기본, 1% 단위), 모양(자동·다크·라이트), "파일 열기…". 미리보기 없이 슬라이더를 끄는 동안 뒤 창에 바로 반영, 파일엔 놓을 때 쓴다. Esc는 설정 창만 닫는다.
- `theme` auto는 `QStyleHints::colorScheme()`(Windows "앱 모드"). 제목 표시줄도 어둡게(`DwmSetWindowAttribute(DWMWA_USE_IMMERSIVE_DARK_MODE)`, Qt 6.5+는 자동인지 확인).

### 콘솔 창 방식 (`--terminal console`)

- `conhost.exe <program> <args>`를 띄운다. `CREATE_NEW_CONSOLE`만 쓰면 Windows 11에서 기본 터미널이 Windows Terminal일 때 그쪽으로 가니 `conhost.exe`를 명시한다.
- 콘솔 창은 conhost 프로세스 것이라 AUMID·아이콘을 실행기가 붙인다: 창을 찾아(`conhost` 자식 pid → `EnumWindows`, 또는 프로그램 쪽 `GetConsoleWindow`) `SHGetPropertyStoreForWindow`로 `PKEY_AppUserModel_ID` 설정, `WM_SETICON`. **되는지 먼저 확인**(안 되면 콘솔 방식은 "아이콘만 다른 창"으로 축소하거나 뺀다).
- 실행기는 창 없이 상주(같은 앱 두 번 실행 방지·소켓). 글꼴·크기는 conhost 것을 쓰고 기억하지 않는다.

### 생성기 창

인자 없이 켜면 macOS GUI와 같은 창 하나: 아이콘(누르면 Windows 이모지 패널 `Win+.`을 열 입력 칸에 포커스), 드롭 칸(exe를 놓으면 바로 만들기), 오른쪽 클릭 배경색, 이미지 놓기, "실행기" 선택(자체 터미널·콘솔 창, 마지막 선택 기억), 그 밑 앱당 메모리 한 줄(실측해서 넣는다). 만든 뒤 아이콘을 바꾸면 0.8초 뒤 다시 만든다. 처음 켜면 자기 자신을 `%LOCALAPPDATA%\Programs\TUIDock\`에 설치할지 묻는다.

## 단계

각 단계는 CI에서 빌드·시험이 통과한 뒤 손으로 확인하고 다음으로 간다.

1. **뼈대**: `windows/CMakeLists.txt`, `main.cpp`(`--help`), `.github/workflows/windows.yml`(windows-latest, MSVC, Qt 6.10.1 `win64_msvc2022_64` 기본 모듈만, `windeployqt --release --compiler-runtime --no-translations`, `fonts\`·`LICENSE`·`launcher/libvterm/LICENSE`·`OFL.txt` 동봉, zip 아티팩트). Gifiles `.github/workflows/build.yml` windows 작업을 본뜬다.
2. **터미널**: `TermView` + `PtyWin`, `tuidock.exe run --command <exe>`로 창 하나에 TUI 띄우기. 손 확인: lazygit·Bubble Tea 예제·calendar-tui/ginote Windows 빌드가 뜨는지, 한글 입력(MS 한글 입력기), 마우스, 크기 바꾸기.
3. **앱 만들기**: `app.toml`·`icon.ico`·`.lnk`·AUMID, `make`·바로 만들기·`remove`, 같은 앱 두 번 실행. 손 확인: 앱 둘을 각각 작업 표시줄에 고정했을 때 따로 뜨고 아이콘이 맞는지, Alt+Tab, AutoHotkey로 창 찾기(`ahk_exe tuidock.exe`가 겹치니 창 제목이나 AUMID로).
4. **설정**: `config.toml`·실행 파일 명령·글꼴·줄간격·대비·theme·2031·Ctrl 단축키·창 크기 기억.
5. **연결**: 소켓, `tuidock_windows.go`, ginote TUI로 `hello`·`focus`·`bye`·`key cmd+q`·`Paste`/`Copy` 확인.
6. **콘솔 창 방식.**
7. **설정 창·생성기 창.**
8. **배포**: `release.yml`에 Windows 작업을 붙여 같은 태그 릴리스에 `TUIDock-windows-x64.zip` 추가(트리거 경로에 `windows/**` 추가). 코드 서명 인증서가 없어 SmartScreen 경고가 뜬다 — README에 안내. 랜딩 페이지 다운로드에 Windows 추가, README 두 개·`AGENTS.md` 갱신(`AGENTS.md` "윈도우는 대상이 아니다" 문장 교체), 이 파일 삭제.

## 시험

- 자동(Qt Test, `QT_QPA_PLATFORM=offscreen`, CI): config 읽기·검사(macOS와 같은 입력 → 같은 결과), 박스 문자, UTF-8 끊김, 대비 섞기 값, 2031 감지(바이트가 나뉘어 들어와도), 오류 종료 메시지, `make`가 만든 `app.toml`·`.ico` 크기·`.lnk`의 대상·AUMID(임시 시작 메뉴 경로로).
- 손: 위 단계별 항목. 확인한 것과 안 한 것은 `AGENTS.md` "확인 안 한 것"처럼 남긴다.

## 위험·먼저 확인할 것

- **ConPTY가 시퀀스를 삼키는지**: ConPTY는 출력을 해석해 다시 그리므로 모르는 시퀀스(`CSI ? 2031 h`, OSC 10/11 질문)가 실행기까지 안 올 수 있고, 입력 쪽(`CSI ? 997 ; 1 n`, SGR 마우스)도 콘솔 입력 레코드로 바뀌며 빠질 수 있다. 2단계에서 바로 확인. Windows 11 24H2 이후의 ConPTY 통과 모드(`PSEUDOCONSOLE_PASSTHROUGH_MODE`) 사용 가능 여부도 본다. 안 되면 2031은 Windows에서 "지원 안 함"으로 문서화.
- 컬러 이모지 아이콘 그리기(Qt DirectWrite 엔진).
- 콘솔 창에 AUMID 붙이기.
- 메모리: Qt Widgets 앱이라 macOS판(43~46MB)과 비슷하거나 작을 것으로 본다. 실측해서 생성기 창 문구와 README에.
- 프로그램이 UTF-8로 출력하는지: ConPTY는 VT를 UTF-8로 주지만 옛 Python 등은 코드 페이지를 따른다. 필요하면 `PYTHONUTF8=1`만 넣고 그 외엔 손대지 않는다.

## 옮기지 않는 것

AppleScript·외부 터미널(Terminal·iTerm2·Ghostty)·Carbon 단축키·폴링, Info.plist·`NS…UsageDescription`(Windows 개인정보 권한은 앱 단위 물음이 없다), quarantine·ad-hoc 서명, `LANG` 정하기, Dock 고정 자동화.
