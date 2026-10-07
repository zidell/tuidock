# tuidock 에이전트 지침

사용법은 `README.md`(한국어)·`README.en.md`(영어, 같은 내용으로 맞춘다), 개발·설계 규칙은 이 파일에 둔다. 새로 정한 규칙·결정은 여기에 반영한다(지난 경과가 아니라 지금 알아야 할 것만).

## 구조

| 파일 | 역할 |
|---|---|
| `app/TUIDockApp.swift` | GUI 생성기 TUIDock.app(SwiftUI, 창 하나). 만들기는 번들 안 `tuidock`을 부른다 |
| `scripts/build-app.sh` | TUIDock.app 빌드(`dist/`), `--install`이면 `/Applications` + `~/.local/bin/tuidock` 링크. 실행기·아이콘 도구를 빌드해 Resources에 넣는다 |
| `tuidock` | 생성기 명령(bash): 바로 만들기, `make`(번들 만들기), `install`(/Applications + Dock 고정) |
| `launcher/launcher.swift` | 실행기(번들의 `Contents/MacOS/launcher`). 외부 터미널 제어와, 자체 터미널의 창·메뉴(`extension Dock`) |
| `launcher/terminal.swift` | 자체 터미널(`--terminal builtin`)의 화면·입력(`TermView`) |
| `launcher/config.swift` | 자체 터미널 설정 파일(`config.toml`)의 키 목록·읽기·검사·기본 파일, 실행 파일 명령(`--config-path` 등) |
| `launcher/settings.swift` | 자체 터미널 설정 창(Cmd+,, SwiftUI `Form`). 값은 `config.toml`에 쓴다 |
| `launcher/fonts/` | 자체 터미널 기본 글꼴 D2Coding 1.4.0 Regular·Bold와 `OFL.txt` |
| `launcher/build.sh`, `bridge.h`, `pty.c`, `libvterm/` | 실행기 빌드(Swift 네 파일 + C). libvterm 0.3.3은 Gifiles(`~/Sites/gifiles/third_party/libvterm`)가 고친 것과 바이트 단위로 같게 둔다(MIT). pty는 Swift에서 fork를 못 써서 C |
| `icon/IconRender.swift`, `icon/main.swift` | 아이콘 그리기. GUI 미리보기와 아이콘 도구가 같은 코드를 쓴다 |
| `tuidock.go` | 프로그램 쪽 Go 연결(`Open`·`Focus`·`Hide`·`Font`·`Close`·`Paste`·`Copy`) |

- calendar-tui `scripts/package.sh`가 `go list -m`로 이 모듈 폴더를 찾아 `tuidock make`를 부른다. 그래서 `tuidock`·`launcher/`는 Go 모듈 zip에 들어가야 한다(하위 폴더에 `go.mod`를 두지 않는다). 모듈 캐시 파일은 실행 비트가 없어 `bash tuidock`으로 부른다.
- 쓰는 앱: Calendar TUI(calendar-tui `dev.local.sh`가 빌드마다 `tuidock <바이너리> 🗓️ --name "Calendar TUI" --terminal builtin`), Ginote TUI(ginote `docs/TUI.md`, `--terminal builtin`, Go 연결 있음). calendar-tui는 Go 연결이 없어 연결 안 된 프로그램 쪽 동작이 실제로 쓰인다.

## 시험

- 컴파일: `bash launcher/build.sh <출력>`. 번들: `tuidock make --name T --command <바이너리> --out <임시 폴더>`. 설치까지: `scripts/build-app.sh --install`.
- GUI와 같은 조건의 만들기: `env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin bash <앱>/Contents/Resources/tuidock make …`, 설치는 `APP_DIR=<임시 폴더> … install --no-dock`.
- 외부 터미널 방식은 새 번들 ID·새 서명마다 터미널 제어 권한을 물으니 실행기 수정은 모아서 설치·확인한다.
- 실제 키·마우스: 키는 System Events, 마우스는 `CGEvent` 게시(이 셸은 손쉬운 사용 권한은 없고 이벤트 게시 권한은 있다). 대상 앱을 먼저 activate해야 클릭이 다른 창에 가지 않는다. 사용자가 다른 앱을 쓰는 중이면 입력이 그쪽으로 들어가므로 보내지 않는다. 창 확인은 `screencapture -x -o -l <창 번호>`(창 번호는 `CGWindowListCopyWindowInfo`에서 pid로).
- 입력기가 한글이면 `keystroke "q"`가 `ㅂ`가 되고, 구름 입력기는 `TISSelectInputSource`로 바꾼 직후 합성 키를 대문자로 내거나 한글 모드가 늦게 붙는다(입력기 쪽 현상). F10은 macOS가 먼저 잡는다.
- 자체 터미널을 셸에서 띄워도 `LANG`은 시스템 언어로 정해진다. 시스템 `log`는 zsh 함수에 가려지니 `/usr/bin/log`.

## 설계

목적: 터미널 TUI 프로그램을 Dock·Cmd+Tab·단축키 도구(BetterTouchTool 등)에서 다른 앱처럼 다루게 실행기 `.app`을 찍어 낸다. 바이너리는 그대로 둔다.

### 생성기

- **앱마다 번들 하나.** Dock·Cmd+Tab 항목은 번들 단위다. 실행기 바이너리는 같고 Info.plist(`TUIDockCommand`·`TUIDockEmbedded`·`TUIDockArguments`·`TUIDockTerminal`·글꼴 값)만 다르다.
- **GUI**: 창엔 아이콘과 드롭 칸만. 이름은 실행 파일 이름의 첫 글자만 대문자, 놓으면 바로 만든다. 아이콘을 누르면 macOS 이모지 창(`orderFrontCharacterPalette`, 아이콘 뒤 보이지 않는 글자 칸에 받음), 오른쪽 클릭으로 첫 글자 아이콘 배경색, 이미지를 놓으면 그 이미지. 만든 뒤 아이콘을 바꾸면 0.8초 뒤 다시 만든다. 아래 "실행기" 선택 상자는 자체 터미널(기본)과 설치된 터미널(터미널·아이텀·고스티), 마지막 선택을 기억한다. 선택 상자 밑엔 고른 실행기의 앱당 메모리 추정 한 줄만(`memoryNote`, 다른 설명은 넣지 않는다). 수치는 실측: 자체 터미널 창 1200×900pt 43~46MB, 실행기 14MB + Terminal 창 +14MB(본체 약 115MB), iTerm2 창 +21~33MB(본체 약 90MB), 따로 띄운 Ghostty 70~106MB. 실행 인자 `-emoji 🗓️`로 이모지를 미리 고른 채 뜬다.
- **바로 만들기** `tuidock <실행 파일> [이모지]`(첫 인자가 `make`·`install`이 아닐 때): 빌드 스크립트에서 쓰는 모드. `--command`(경로 참조)로 만든다. 같은 이름 앱은 덮어쓰고, 이모지·`--terminal`·글꼴 값을 안 주면 있던 앱의 것을 이어받는다(`oldkey`, 키가 없으면 빈 값. `TUIDockTerminal`이 없는 옛 앱은 terminal). 새 앱의 기본 실행기는 자체 터미널(`builtin`). Info.plist에 `TUIDockTerminal`이 없으면 실행기는 Terminal 방식으로 돈다. 아이콘을 이어받아 내용이 같으면 CDHash가 같다. alias는 자식 프로세스가 못 보므로 받지 않는다. 스크립트는 `readlink -f`로 원본 옆 실행기를 찾는다.
- **경로 실행이 기본**(`--command`): Apple 플랫폼 바이너리는 복사하면 SIGKILL되고 setuid는 권한을 잃는다. `--embed`(복사)는 빌드 스크립트용(calendar-tui 패키징).
- **아이콘**: 이모지는 판 없이 그림 칸을 1024 캔버스 둘레 8% 여백(860 칸)에. 첫 글자 아이콘만 824 둥근 판 + 배경색. `--icon`이면 그 이미지.
- **CLI 문구는 영어**(도움말·오류·출력). 코드 주석은 한국어.
- 내려받은 TUIDock에서 만든 앱이 막히지 않게 `make`가 `xattr -dr com.apple.quarantine`을 한다.
- **서명**: 만든 앱은 ad-hoc(`codesign -s -`). 개발 중엔 `--command`로 번들 밖 바이너리를 바꾸면 번들을 다시 만들 일이 없다.

### 실행기 공통

- **상주한다.** 프로그램이 떠 있는 동안 같이 산다. 프로그램 pid 종료는 `DispatchSource.makeProcessSource`로 받는다. Dock 종료면 프로그램에 SIGTERM.
- **소켓**: `$TMPDIR/tuidock-<번들 ID>/app.sock`(길면 FNV 해시). 프로그램엔 환경변수 `TUIDOCK`으로 폴더를 넘긴다. 메시지: `hello <pid>`·`focus`·`font ±1`·`bye`(실행기가 기록 후 `ok`) 등. 붙여넣기는 데이터그램 크기 제한 때문에 프로그램이 `pbpaste`로 읽는다.
- **창 크기·글꼴 기억**: 실행기 `UserDefaults`(`cols`·`rows`·`font`, 자체 터미널은 `topLeft`도). 새 창엔 글꼴 → 칸 수 순서. 기억한 값이 없으면 화면을 거의 채운다.
- **Cmd 단축키 규칙**(모든 터미널 방식 공통, `keepCmd`·`keepCmdShift`·`passCmd`): 터미널은 껍데기라 터미널 자체 단축키는 돌지 않게 한다.
  - 실행기가 처리: `Cmd+H`·`Cmd+W`는 그 창만 가림(iTerm2는 최소화), `Cmd+Q`는 연결 안 된 프로그램이면 앱 종료(연결된 프로그램엔 `key cmd+q`).
  - 그대로 둠: `Cmd+M`, `` Cmd+` ``, `Cmd+Shift+3~6`, `Cmd+Shift+Q`, 연결 안 된 프로그램의 `Cmd+C`·`Cmd+V`.
  - 연결된 프로그램엔 나머지 Cmd 조합을 `key cmd+…`로 넘기고, 연결 안 된 프로그램이면 버린다(Cmd+T 새 탭 등이 돌면 단독 앱이 아니다).
- **일부러 끝낼 때**(Dock 종료·Cmd+Q·`bye`)는 남는 빈 창을 닫고, 스스로·오류로 끝나면 메시지가 보이게 창을 둔다.
- **윈도우**: `windows/`의 Qt 6.10 + ConPTY + 기존 libvterm 자체 터미널. 생성기·앱별 바로가기/AUMID·설정·Go 연결·ZIP 배포를 지원한다.

### Windows

- `windows/src/TermView.{h,cpp}`는 Gifiles TerminalWidget의 그리기·IME·선택·마우스를 가져온 GPLv3 코드다. 셸 연동·탭·스크롤백·드롭 입력은 제거했다. libvterm은 `launcher/libvterm`을 직접 빌드하고 수정·복제하지 않는다.
- `windows/src/PtyWin.cpp`: 프로그램을 셸 없이 직접 실행한다. CRT 인자 이스케이프, UTF-8 환경, 별도 reader/writer/waiter 스레드. 종료 때 reader는 EOF까지 읽고 마지막 출력 뒤 종료 코드를 알린다. 스레드는 모두 join하며, `ClosePseudoConsole` 전에 읽기를 멈추면 교착할 수 있다.
- 정상 종료 0은 창 닫기, 오류 종료는 코드 메시지와 아무 키 대기. 연결된 프로그램은 첫 창 닫기에서 `key cmd+q`를 받아 저장·종료할 수 있다(다시 닫기 또는 5초 무응답이면 종료). Ctrl+Shift+C/V, 선택이 있는 Ctrl+C, Ctrl+=/-/0·Ctrl+,는 실행기가 처리하고 나머지 Ctrl은 프로그램으로 간다.
- `Maker`: `%APPDATA%/tuidock/<id>`의 app.toml·icon.ico·config.toml·state.ini. 실행 파일은 복사하지 않는다. 이름이 같으면 기존 ID를 재사용하고 지정하지 않은 아이콘·터미널·글꼴 기본값과 사용자 config를 이어받는다. 시작 메뉴 Programs/TUIDock의 `.lnk`에는 앱별 AUMID를 넣고 실제 창에도 같은 ID와 재실행 명령·아이콘을 설정한다. 바로가기는 설치본 `%LOCALAPPDATA%/Programs/TUIDock/tuidock.exe`를 우선한다. 영구 작업표시줄 고정은 사용자 조작이며 로그인 Startup은 등록하지 않는다.
- `Generator`: macOS와 같은 470폭 가로 구성(128 아이콘 + 클릭 가능한 드롭 칸), 아래 실행기·실측 메모리·제작 후 실행 체크·제작 버튼. 이모지 수신 칸은 아이콘 뒤 투명한 1px 칸이며 Win+.로 연다. 입력마다 마지막 grapheme 하나로 교체한다(국기·피부색·ZWJ 포함). 실행 파일 선택 후 명시적 제작, 이후 아이콘 변경은 800ms 뒤 다시 만들고 실행 중인 창도 reload 메시지로 갱신한다. Windows 이모지는 실제 알파 영역을 캔버스에 맞추고 자체 아이콘은 macOS 바깥 여백·그림자를 제거한다. 원본 macOS PNG는 바꾸지 않는다.
- 콘솔 창 모드는 Windows 11 빌드 26200에서 conhost HWND 식별 실기 시험에 실패해 제외했다. 지원되지 않는 console 값은 CLI·정의 읽기에서 거부한다. 외부 터미널이나 제목 기반 창 찾기를 우회로로 넣지 않는다.
- `Config` 키 목록 하나에서 타입·범위·기본값·템플릿·검사를 만든다. QSaveFile 원자 저장, 파일/디렉터리 감시, 주석 보존. 설정 창은 Ctrl+,로 필요할 때 생성하며 슬라이더는 실시간 미리보기 후 놓을 때 저장한다. theme은 Windows 앱 모드를 따른다.
- `LocalSocket`은 네이티브 AF_UNIX 스트림(Qt named pipe가 아님). 256바이트·1초·16클라이언트 제한, 접속 순서대로 메시지 전달. 앱별 Local 뮤텍스로 중복 실행을 막고 전경 권한을 기존 인스턴스에 넘긴다. Go는 Windows 스트림과 Unix 데이터그램을 플랫폼 파일로 분리한다. Windows 송신은 CloseWrite 후 Close로 RST 유실을 막는다. clipboard는 CF_UNICODETEXT, 복사는 OS 스레드에 고정한 숨은 HWND를 소유자로 사용한다.
- 빌드·시험·패키지: `powershell -NoProfile -ExecutionPolicy Bypass -File windows/build.ps1 -QtRoot <Qt 6.10.1 msvc2022_64> -Package`. VS 2022 C++·CMake·Go 1.21 이상 필요. `build-win-release/Release`에 exe, `dist/TUIDock-windows-x64`에 Qt·MSVC 런타임·D2Coding·라이선스 동봉 실행본, 같은 이름 ZIP. Windows CI와 릴리스 작업은 같은 스크립트를 실행한다. 릴리스는 버전을 한 번 결정한 뒤 두 플랫폼 아티팩트가 성공했을 때 같은 태그로 배포한다.
- 자동 시험은 `windows/tests/`의 실제 ConPTY fixture + Qt Test. 실행 인자(빈 값·공백·따옴표·끝 역슬래시·한글), cwd/env, UTF-8 모든 분할 경계, 박스 문자, 종료 코드·마지막 출력 순서, 자식이 자손을 남기고 끝나는 경우, 시작 실패, 대량 출력 중 닫기, Ctrl 입력·IME 확정·붙여넣기, VT 왕복, CLI를 확인한다. Microsoft Edit가 설치됐으면 임시 한글 문서 표시·크기 변경·Ctrl+Q 종료도 시험한다.
- 자동 시험은 설정 원자 저장·2031 분할 감지·대비·ICO 모든 크기·바로가기 AUMID·실제 Go 소켓/클립보드·드롭/제작/이모지 교체·창 상태/연결 종료도 검사한다. Windows 데스크톱에서 실제 마우스로 파일 선택·제작을 눌러 Edit 창과 시작 메뉴 바로가기가 생기는 것을 확인했다.
- 실측(Windows 11 빌드 26200): ConPTY 출력에 CSI 2031 h·996 n·1006 h가 전달되고, 입력의 CSI 997 응답과 SGR 마우스가 프로그램에 그대로 도착한다. OSC 10/11 `?`는 실행기 출력에 오지 않는다. 2031 지원·모양 변경 알림을 구현했고 미문서 ConPTY 플래그는 사용하지 않는다. Edit 실행 시 앱 메모리 약 64 MB.
- **확인 안 한 것**: 실제 MS 한글 입력기 조합·클릭 확정, 실제 마우스 선택/휠, DPI가 다른 모니터, Windows 10·이전 Windows 11, GitHub CI 실행. Qt 이벤트로 확정 문자열·Ctrl 입력을 보낸 시험과 실제 키/마우스 확인을 구분한다.

### 외부 터미널(`--terminal terminal|iterm2|ghostty`)

- **Terminal.app**: `do script`로 `clear; exec env TUIDOCK=… <바이너리>`. 탭은 `tty`로 기억하고(창 제목은 겹칠 수 있다) 이후엔 기억한 창 id로 간다. pid는 `ps -t <tty>`.
- **실행기만 다시 켜진 경우**: `app.sock`에 `ping`을 보내 0.3초 안에 `hello <pid>`가 오면 그 창을 이어받는다.
- **앞으로 가져오기**: AppleScript로는 그 창을 터미널 안에서 맨 앞에만 두고(`set index`·`select`), 앱 활성화는 `NSRunningApplication.activate(options: [])`(AppleScript `activate`는 그 앱의 모든 창을 올린다). 그 창이 이미 맨 앞이면 AppleScript 없이 바로 활성화하고(AppleScript 왕복 약 100ms), 작업 공간 활성화 알림에서 바로 `show`(`applicationDidBecomeActive`는 30~300ms 늦다), reopen은 0.5초 안에 `show`했으면 건너뛴다.
- **단축키 가로채기**: Terminal은 Cmd 조합을 프로그램에 넘기지 않아 Carbon `RegisterEventHotKey`로 받는다(손쉬운 사용 권한 불필요). 그 창이 터미널의 맨 앞 창일 때만 등록한다 — 다른 창에서 잡은 키를 터미널에 되돌려 줄 방법이 없고, tuidock 앱이 여럿이면 엉뚱한 앱이 받는다. 맨 앞 창 확인은 Terminal이 앞인 동안만 0.25초마다 `CGWindowListCopyWindowInfo`(약 1ms, 권한 없이 받을 알림이 없어 유일한 폴링). 연결된 프로그램이 이미 포커스된 창에서 시작하면 포커스 신호가 없으니 `hello` 때 직접 확인한다. 메뉴 막대는 Terminal 것이 남는다.
- **iTerm2**: `create window with default profile command`, `$TMPDIR/tuidock-<ID>/run.sh`를 실행(따옴표 처리를 터미널마다 다르게 하지 않으려고). 창 id = 화면 창 번호. 창을 가릴 수 없어 Cmd+W·H는 최소화. 칸 수는 세션 `columns`/`rows`, 글꼴은 프로필 단위라 기억하지 않는다.
- **Ghostty**: AppleScript로 가리기·칸 수를 못 해서 앱마다 Ghostty를 따로 띄운다(`createsNewApplicationInstance`, `-e /bin/bash run.sh`, `--window-width/height`·`--font-size`·`--quit-after-last-window-closed`·`--confirm-close-surface=false`·`--window-save-state=never`). 가리기 = 그 프로세스 hide, 칸 수 = `stty -f <tty> size`, 실행기가 끝날 때 그 Ghostty를 terminate → 1초 → SIGTERM. `--macos-custom-icon`은 쓰지 않는다(공용 설정 `CustomGhosttyIcon2`에 저장돼 쓰던 Ghostty 아이콘까지 바뀐다). Ghostty 하나 70~106MB.
- 메모리: 실행기 약 14MB(빈 앱 12MB + `NSAppleScript` 2MB).

### 자체 터미널(`--terminal builtin`)

AppKit + libvterm, CoreText로 칸 단위 그리기. 실행기가 창을 직접 가져 메뉴·Cmd 키가 이 앱 것이다(AppleScript·단축키 가로채기·폴링 없음, `setHostFront`가 막음). SwiftTerm 앱은 무거워(101MB) 쓰지 않는다.

- **박스 문자**(U+2500–259F)는 글꼴 대신 칸을 채우는 도형으로 그린다(Gifiles `TerminalWidget::drawBoxGlyph`와 같은 규칙, 점선 문자만 글꼴). 줄간격을 벌려도 선이 이어진다.
- **프로세스는 앱마다 따로**(Dock·Cmd+Tab이 프로세스 단위). 프로그램은 pty 자식이라 이어받기·ping이 없다.
- **실행**: 로그인·대화형 셸(`-zsh -i -c 'exec "$0" "$@"'`)로 Terminal과 같은 PATH. `TERM=xterm-256color`·`COLORTERM=truecolor`·`TERM_PROGRAM=tuidock`. `LANG`은 늘 선호 언어 + 지역(`ko_KR.UTF-8`, `/usr/share/locale`에 있는 조합만)으로 정한다(물려받은 값도 바꿈, `LC_ALL`이 있으면 그대로). 실행기 번들엔 현지화가 없어 `Locale.current`는 쓸 수 없다.
- **개인정보 권한**: 프로그램이 앱의 자식이라 macOS가 앱을 권한 주체로 본다(외부 터미널 방식에선 터미널이 주체). 사용 설명이 없으면 묻지도 않고 거부하므로 `make`가 builtin 앱에 캘린더·미리 알림·연락처·사진·카메라·마이크·위치·음성 인식 `NS…UsageDescription`을 넣는다. 물음 창은 프로그램이 요청할 때만 뜨고 앱마다 한 번 허용해야 한다.
- **종료**: 오류 종료(0이 아닌 코드, SIGTERM·SIGHUP·SIGINT 외 시그널)면 메시지를 남기고 아무 키를 기다린다.
- **Cmd 키**: 메뉴(가리기·종료, 복사·붙여넣기, 글꼴 크기, 최소화·닫기 = 가리기, 설정). 연결된 프로그램엔 공통 규칙으로 넘기고(`builtinCmdKey`, `TermView.performKeyEquivalent`) Cmd+,는 넘기지 않는다. 화면에 끌어서 선택한 글자가 있으면 Cmd+C는 넘기지 않고 그 선택을 복사한다(프로그램은 이 선택을 모른다). 메뉴에 없는 조합은 버린다.
- **입력**: 글자는 입력기(`insertText`·`setMarkedText`), Ctrl 조합은 물리 키 글자로. 조합 중 글자는 커서가 보이던 마지막 자리에 그린다(`markedAt`). Bubble Tea 같은 TUI는 프레임마다 커서를 숨기고 바뀐 칸을 쓴 뒤 제자리에서 다시 보이는데, 출력이 나뉘어 들어와 그 중간에 그리면 숨긴 커서의 중간 위치(사이드바 등)에 조합 중 글자가 번쩍여서, 숨긴 동안의 이동은 따르지 않는다. 커서를 계속 숨기는 화면에서는 마지막으로 보였던 자리에 그린다. 마우스를 누르면 조합을 확정한다(`commitMarked`, Terminal.app과 같음). 안 그러면 누른 뒤 다른 화면으로 가도 조합 중 글자가 그 자리에 떠 있다. 입력기의 확정(`discardMarkedText` → 구름 `commitComposition` → `insertText`)은 비동기라 클릭보다 늦게 와서 글자가 엉뚱한 화면에 들어가므로, 실행기가 먼저 보내고 1초 안에 오는 같은 글자는 버린다.
- **마우스**: 누른 채 다른 칸으로 끌면 화면 선택. 누름은 놓을 때까지 미뤄 같은 칸에서 놓으면 누름·놓음을 함께 보낸다(누름에 동작하는 프로그램이 선택 시작을 클릭으로 받지 않게). Option을 누르고 누르면 누름·끌기·놓음을 바로 넘긴다. Shift+클릭도 같은 칸에서 놓으면 Shift를 붙여 넘기고(목록 범위 선택), 끌면 화면 선택이다. 마우스 보고(SGR)엔 Cmd 자리가 없어 Cmd+클릭은 Ctrl+클릭으로 넘긴다(`mouseMods`, Ginote 목록의 토글 선택). DEC 2배 폭 줄은 클릭 칸을 2로 나눈다. 휠은 마우스를 켠 프로그램엔 휠 버튼, 대체 화면엔 위·아래 화살표. Gifiles는 끌기 선택이 없다(Shift 선택만) — 이 동작은 tuidock에만 있다.
- **그리기**:
  - 대비 `contrast`(-100~100%): **기본 0은 프로그램 색을 손대지 않는다**(기본값에 보정이 걸리면 TUI를 만드는 쪽이 자기 색이 실제로 어떻게 보이는지 알 수 없다). +는 글자색을 흰색(다크)·검정(라이트) 쪽으로 값/100만큼, -는 배경 쪽으로 값/100×0.8만큼 섞는다. 다크에서 올리면 밝아지고 내리면 어두워진다. 선 문자·흐린 글자도 같다. calendar-tui 달력 선(256색 235)처럼 Terminal.app의 밝힘에 기대는 TUI는 +로 올려 쓴다.
  - 흐린 글자(SGR 2): Gifiles 패치 libvterm의 `dim`. 글자색을 배경 쪽으로 절반 섞은 뒤 대비 보정.
  - 2칸 글자는 2칸 너비의 95%까지(최대 1.4배, 줄 높이 안) 키운다. 글자 위치는 `-baseline`(글자 행렬이 y를 뒤집는다).
  - DEC 2배 폭·크기 줄은 `vterm_state_get_lineinfo`를 보고 키워 그린다.
- **libvterm 0.3.3 UTF-8 버그**: 이스케이프 코드 뒤 여러 바이트 글자가 두 번의 `vterm_input_write`로 나뉘면 U+FFFD가 된다. libvterm은 Gifiles와 같게 두고, 읽은 끝의 덜 끝난 글자를 다음 읽기로 넘긴다(`incompleteUTF8Tail`). Gifiles도 같은 조건이면 깨질 수 있다.
- **다크·라이트**: `theme` = auto·dark·light → `NSApp.appearance`. 프로그램이 묻는 OSC 10·11 "?"에 그 모양의 기본색으로 답한다(`vterm_screen_set_unrecognised_fallbacks`). 답이 없으면 lipgloss가 어둡다고 본다. TUI는 보통 시작 때 한 번만 묻는다. 그래서 모드 2031(contour의 다크·라이트 알림)을 지원한다: 프로그램이 `CSI ? 2031 h`를 켜 두면 모양이 바뀔 때(`viewDidChangeEffectiveAppearance`, 시스템·`theme` 둘 다) `CSI ? 997 ; 1|2 n`(다크|라이트)을 보내고, `CSI ? 996 n`에도 답한다. libvterm이 모르는 모드라 넘기기 전 바이트에서 찾는다(`watchLightDark`, Gifiles와 같아야 하는 libvterm은 고치지 않는다). 켤 때는 알리지 않고, 지난번과 같은 모양이면 다시 보내지 않는다. 다크 판정은 OSC 11 답과 같은 기본 배경. 2031을 안 켠 TUI는 다시 켜야 맞는다(Ginote TUI는 켠다).
- **글꼴·줄간격**: 기본 D2Coding 1.4.0(SIL OFL 1.1: 전문 동봉·단독 판매 금지·수정 시 이름 변경). `make`가 builtin이고 `--font`가 없으면 `launcher/fonts/`를 앱 `Resources/fonts/`에 복사하고, 실행기가 `.process` 범위로만 등록한다. D2Coding은 `isFixedPitch`가 아니라 고정폭 검사를 하지 않는다. 기본 13pt·줄간격 1.3. 줄 높이 1.0 = ascender − descender + leading을 합친 뒤 반올림.
- **설정 파일**([agent-discoverable-config](https://github.com/zidell/agent-discoverable-config) 규칙): `~/Library/Application Support/<번들 ID>/config.toml`. 키 `font_family`·`font_size`·`line_height`·`theme`·`contrast`. 키 목록 `configKeys` 한 곳에서 설명·타입·기본값(Info.plist 값 우선)·범위 검사·기본 파일·`--check-config`가 모두 나온다. 잘못된 줄은 그 키만 기본값. 실행 파일 명령 `--help`·`--config-path`·`--print-default-config`·`--init-config`·`--check-config`는 NSApplication 전에 처리한다. `make`가 `Resources/readme.txt`를 넣는다. 비밀값은 없다. 파일을 지켜보다(이름 바꿔 저장도 다시 붙음) 바뀌면 칸 수를 그대로 두고 창 크기를 맞춰 반영한다. Cmd +/-는 `font_size` 줄만 고친다.
- **설정 창**(Cmd+,, `settings.swift`): 시스템 설정과 같은 묶음 양식(SwiftUI `Form` `.grouped`) — 미리보기는 없고 뒤의 터미널 창이 미리보기다(슬라이더를 끄는 동안 `model.live` → `applyStyle(live)`로 바로 반영, 파일은 놓을 때 쓴다), 글꼴 목록(설치된 고정폭 + 기본 D2Coding), 크기, 줄간격(1~2) 슬라이더, "대비" 슬라이더(-100~+100%, 가운데 0%가 기본 = 프로그램 색 그대로, 1% 단위. 칸으로 나누거나 끔·원본 같은 말을 붙이면 헷갈린다), 모양 분할 단추, "파일 열기…". 값을 바꾸면 `setConfig`로 그 키 줄만 고쳐 써서 주석이 남고, 파일이 바뀌면 창이 다시 채워진다. Esc·Cmd+W는 설정 창만 닫는다. SwiftUI를 링크해도 창을 열기 전 메모리는 같다.
- 스크롤백·탭·분할은 두지 않는다(TUI 하나를 띄우는 창).
- **메모리**: 창 픽셀에 비례(IOSurface). 160×45칸·줄간격 1.5 약 48~58MB, 화면 가득 78~120MB. 앱 둘이면 자체 터미널 약 96MB, Terminal 방식 약 143MB(Terminal 본체 포함).
- **확인 안 한 것**: Ctrl 조합, Cmd +/-.

## 배포

- 공개 레포 github.com/zidell/tuidock. 라이선스는 GPLv3(`LICENSE`)이고 Go 연결 파일과 연결 시험은 MIT(`LICENSE.MIT`, 첫 줄 SPDX) — Go는 정적 링크라 GPL이면 연결을 쓰는 프로그램까지 GPL이 되기 때문이다. 랜딩 페이지는 GitHub Pages(`main`의 `docs/`) https://zidell.github.io/tuidock/. 커밋 작성자 이메일은 그대로 둔다.
- **랜딩 페이지** `docs/index.html`: 기본 HTML, 한·영 전환(`data-l`). 순서: 소개·창 캡처·Dock 모양 아이콘 줄 → 다운로드 → 개발 동기 → 작동 방식 → CLI 실행법 → 권한 설정. 캡처 `docs/window.png`·`window-en.png`는 `open -n -g dist/TUIDock.app --args -emoji 🗓️ [-AppleLanguages '(en)']`로 띄워 `screencapture`. 예시 아이콘 `docs/icons/`는 아이콘 도구로.
- Windows 캡처 `docs/window-windows.png`·`window-windows-en.png`는 `tuidock.exe gui --emoji 🗓️ --language ko|en`의 실제 창이다. Win32 창 좌표를 사용할 때 스레드 DPI를 Per Monitor V2로 맞춘 뒤 창 범위만 캡처한다. 두 플랫폼 소개·설치·단축키·CLI 차이를 한·영으로 함께 설명한다. `docs/install.ps1`은 Windows PowerShell 5.1/PowerShell 7에서 최신 ZIP→native install→사용자 PATH·환경 변경 알림까지 처리하며 앱을 자동 실행하지 않는다. `-ZipUrl <로컬 ZIP>`·`-NoPath`로 격리된 설치 시험을 한다.
- **TUIDock 자신의 아이콘**: `swift scripts/make-icon.swift app/AppIcon.png`, 페이지용 `docs/icon.png`(256).
- **릴리스** `.github/workflows/release.yml`: `main` 푸시 중 앱 코드(`app/`·`launcher/`·`icon/`·`tuidock`·`scripts/build-app.sh`·워크플로)가 바뀐 것만, 마지막 `v` 태그의 패치 +1로 태그·릴리스(`gh release create --target`). 부·주 버전은 `git tag v0.3.0 && git push --atomic origin main v0.3.0`. 겹친 푸시는 `concurrency`로 하나씩. 수동 실행은 아티팩트만, 단 끝 커밋에 `v` 태그가 있으면 그 버전으로 릴리스(앱 코드를 안 바꾼 푸시의 태그용). 2026-10 히스토리를 한 커밋으로 합치며 v0.1.0~v0.2.14 태그·릴리스를 지웠지만 Go 모듈 프록시·sumdb에 남아 있어(ginote `tui/go.mod`가 v0.2.0을 씀) 그 번호는 다시 쓰지 않는다. 새로 시작한 번호는 v0.3.0. 과정: macOS 러너에서 `UNIVERSAL=1 scripts/build-app.sh` → Developer ID 서명(안쪽 `launcher`·`icon` 먼저, `--options runtime --timestamp`) → DMG 서명 → 공증 → staple → `TUIDock.dmg`·`TUIDock-macos.zip` 업로드. 페이지 다운로드와 `docs/install.sh`는 최신 릴리스를 받는다.
- 비밀값 이름은 ginote(`~/Sites/ginote` `docs/DESKTOP.md`)와 같다: `APPLE_CERTIFICATE`(p12 base64)·`APPLE_CERTIFICATE_PASSWORD`·`APPLE_SIGNING_IDENTITY`·`APPLE_ID`·`APPLE_PASSWORD`(앱 암호)·`APPLE_TEAM_ID`. 사용자 설정은 한 단계씩 안내한다.
- **확인 안 한 것**: 외부 터미널에서 연결 안 된 프로그램의 Cmd+C·V 통과(Cmd+T·N 막기는 확인), GUI의 이모지 창·이미지 놓기·색 메뉴·실제 드롭(같은 만들기 명령은 확인).
