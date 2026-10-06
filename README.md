# tuidock

[English](README.en.md)

터미널 TUI 프로그램을 macOS Dock 앱으로 감싼다. 웹 주소를 앱으로 만들던 Fluid처럼, 바이너리를 끌어다 놓고 이모지 아이콘을 고르면 `.app`이 나온다.

창은 고른 실행기(터미널 · 아이텀(iTerm2) · 고스티(Ghostty) · 자체 터미널)에 뜨고, 앱은 그 창을 단독 앱처럼 다룬다.

- Dock 아이콘·실행 중 점·Cmd+Tab 항목이 따로 생긴다. Dock을 누르거나 Cmd+Tab으로 고르면 그 창이 앞으로 온다. 프로그램이 끝나면 앱도 끝난다.
- 창 크기(글자 칸)와 글꼴 크기를 기억했다가 다음에 같은 크기로 연다. 처음엔 화면을 거의 채운다.
- `Cmd+H`는 그 창만 숨긴다(다른 터미널 창은 그대로). `Cmd+W`도 그 창을 숨긴다(다른 앱처럼 창 닫기 = 가리기, 아이텀은 최소화). `Cmd+Q`는 그 앱만 끝낸다(터미널은 그대로, 남은 빈 창도 닫는다). 그 창에선 `Cmd+T`(새 탭)·`Cmd+N`(새 창) 같은 터미널 단축키가 막힌다(macOS 기본 복사·붙여넣기 `Cmd+C`·`Cmd+V`만 그대로). 프로그램이 [연결](#프로그램-쪽-연결)돼 있으면 Cmd 조합을 프로그램이 받는다.
- 프로그램이 [프로토콜](#프로그램-쪽-연결)을 따르면, 그 창에 있는 동안 Cmd 조합(`Cmd+Q`·`Cmd+V`·`Cmd+F` …)을 터미널 대신 프로그램이 받는다. 한글 입력 상태에서도 단축키가 먹는다.

도구당 메모리는 Terminal 창 약 9~14MB + 실행기 약 14MB다(Terminal.app 본체 약 115MB는 따로). 고스티는 창 하나만 가릴 방법이 없어 앱마다 고스티를 따로 띄우므로 앱당 70~100MB를 더 쓴다.

[자체 터미널](#자체-터미널)을 고르면 터미널 앱을 띄우지 않고 앱이 직접 창을 그린다. 줄간격을 벌려도 표·테두리 선이 끊기지 않는다.

## 설치

[TUIDock.dmg](https://github.com/zidell/tuidock/releases/latest/download/TUIDock.dmg)를 열어 TUIDock을 Applications로 끌어다 놓는다. 또는 터미널에서(`tuidock` 명령까지 설치, 같은 명령으로 업데이트):

```sh
curl -fsSL https://zidell.github.io/tuidock/install.sh | bash
```

DMG로 설치했는데 `tuidock` 명령도 쓰려면 `ln -sf /Applications/TUIDock.app/Contents/Resources/tuidock ~/.local/bin/tuidock`.

macOS 14 이상, Apple Silicon·Intel. 소개 페이지: https://zidell.github.io/tuidock/

## 만들기

TUIDock 앱 창엔 아이콘과 점선 칸, 아래에 실행기 선택이 있다.

- 아이콘을 누르면 macOS 이모지 창이 떠서 이모지를 고른다. 이모지는 판 없이 그대로 아이콘이 된다. 고르지 않으면 이름 첫 글자(오른쪽 클릭으로 배경색).
- 이미지를 쓰고 싶으면 아이콘에 끌어다 놓는다(PNG·JPG 등. 정사각형이 아니면 투명 여백).
- 실행 파일을 점선 칸에 끌어다 놓으면(눌러서 골라도 된다) 바로 앱이 만들어진다. 이름은 파일 이름의 첫 글자만 대문자로 바꾼 것(`htop` → `Htop`). 만든 뒤 아이콘을 바꾸면 다시 만들어 반영한다.
- 실행기는 자체 터미널과 설치된 것(터미널 · 아이텀 · 고스티) 중에서 고른다. 기본은 자체 터미널. 만든 뒤 바꾸면 다시 만든다.

앱은 `/Applications`(쓸 수 없으면 `~/Applications`)에 들어가고 Dock에 고정된다. 터미널·아이텀을 고른 앱은 처음 열 때 "터미널(또는 아이텀) 제어" 권한을 허용한다(자체 터미널·고스티는 묻지 않는다). 실행 파일은 복사하지 않고 그 경로를 실행하므로, 프로그램을 다시 빌드해도 앱은 그대로다. 파일을 옮기거나 지우면 다시 만든다.

소스에서 빌드해 설치하려면(Xcode 커맨드라인 도구 필요):

```sh
git clone https://github.com/zidell/tuidock.git
cd tuidock && scripts/build-app.sh --install
```

설치하면 `tuidock` 명령도 `~/.local/bin`에 생긴다.

### 명령으로 바로 만들기

```sh
tuidock htop 😁                  # PATH의 명령 이름
tuidock ~/Sites/foo/bin/foo 🦊   # 경로
tuidock foo                      # 이모지를 빼면 아무거나 고른다
```

GUI와 같이 `/Applications`(쓸 수 없으면 `~/Applications`)에 넣고 Dock에 고정한다(`--no-dock`이면 고정하지 않음). 이름은 파일 이름 첫 글자만 대문자로(`--name`으로 바꿀 수 있다).

- 실행 파일을 복사하지 않고 그 경로를 실행한다. 그래서 프로그램을 다시 빌드해도 앱은 다시 만들 필요가 없다.
- 같은 이름의 앱이 있으면 덮어쓴다. 이모지를 주지 않으면 있던 아이콘을 그대로 쓴다. 내용이 같으면 서명도 같아 권한을 다시 묻지 않는다. 그래서 다른 프로그램의 빌드 스크립트에 그대로 넣어도 된다.
- 셸 alias·함수는 안 된다(명령이 볼 수 없다). PATH에 있는 파일이나 경로를 넣는다.
- `--terminal builtin|terminal|iterm2|ghostty`로 실행기를 고른다(기본 builtin). 주지 않으면 같은 이름 앱의 것을 그대로 쓴다. 자체 터미널의 `--font`·`--font-size`·`--line-height`도 마찬가지다.
- `--color`·`--icon`·`--arg`·`--id`도 `make`처럼 받는다.

### 명령으로(빌드 스크립트용)

```sh
tuidock make --name "Calendar TUI" --embed ./calendar --icon icon.png --out dist
tuidock install "dist/Calendar TUI.app"     # /Applications에 넣고 Dock에 고정
```

| 옵션 | |
|---|---|
| `--name` | 앱 이름(필수) |
| `--embed 파일` | 실행 파일을 앱 안에 넣는다 |
| `--command 경로` | 앱 밖 실행 파일. 있으면 이걸 먼저 쓴다. 개발 중 바이너리를 갈아 끼울 때 쓴다(앱 서명이 그대로라 권한을 다시 묻지 않음). `~` 사용 가능 |
| `--arg 인자` | 실행 인자(여러 번) |
| `--emoji 이모지` · `--color '#RRGGBB'` | 이모지 아이콘(판 없이 그대로). 없으면 이름 첫 글자, `--color`는 그 배경색 |
| `--icon 이미지` | 이미지 아이콘: PNG·JPG·ICNS. 정사각형이 아니면 투명 여백을 붙인다 |
| `--terminal 이름` | 실행기: `builtin`(자체 터미널, 기본)·`terminal`·`iterm2`·`ghostty` |
| `--font 이름` · `--font-size pt` · `--line-height 배수` | 자체 터미널만: 글꼴(PostScript 이름, 예 `Menlo-Regular`, 기본 D2Coding)·크기(기본 13)·줄간격(글꼴 줄 높이의 1~3배, 기본 1.3) |
| `--id 번들ID` | 기본 `local.tuidock.<이름>`. 창 크기 기억도 이 ID 기준 |
| `--version` · `--resource 파일` · `--out 폴더` · `--universal` | 버전, 같이 넣을 파일, 출력 폴더, Apple Silicon + Intel 실행기 |

명령은 Xcode 커맨드라인 도구(`swiftc`·`clang`)로 실행기를 그때 빌드한다(`launcher/build.sh`, GUI 앱 안의 명령은 빌드해 둔 실행기를 쓴다).

## 자체 터미널

`--terminal builtin`(GUI에선 "자체 터미널")이면 앱이 창을 직접 갖고 그 안에서 프로그램을 돌린다(libvterm).

- Terminal.app·아이텀을 띄우지 않는다. 제어 권한도 묻지 않는다.
- 박스 그리기 문자(`│ ─ ┼ ╭ █` …)를 글꼴 대신 칸을 꽉 채우는 도형으로 그린다. 줄간격을 1.5로 벌려도 선이 이어진다(Terminal.app은 점선처럼 끊긴다).
- 창·메뉴 막대·Cmd 단축키가 그 앱 것이다. `Cmd+C`·`Cmd+V`는 복사·붙여넣기(끌어서 선택), `Cmd +`·`Cmd -`·`Cmd 0`은 글꼴 크기, `Cmd+W`·닫기 단추는 가리기, `Cmd+Q`는 종료다. [연결](#프로그램-쪽-연결)된 프로그램은 터미널 방식과 같은 Cmd 조합을 받는다.
- 프로그램은 로그인 셸을 거쳐 실행한다(Terminal 창과 같은 PATH). 오류로 끝나면 창에 메시지가 남고 아무 키나 누르면 닫힌다.
- 기본 글꼴은 앱에 함께 넣는 [D2Coding](https://github.com/naver/d2codingfont)(네이버, SIL Open Font License 1.1, 앱 안 `Resources/fonts/OFL.txt`)이다. 그 앱에서만 쓰고 시스템에 설치하지 않는다.
- 색: 기본 글자·배경은 시스템 라이트·다크 모드를 따르고, 16색은 Terminal.app "Basic"과 같다. 기본은 프로그램 색 그대로이고, 설정 창의 "대비"를 올리면 글자가 밝아지고(다크) 내리면 흐려진다.
- 설정: `Cmd+,`가 설정 창을 연다(글꼴·크기·줄간격·화면 모양·대비). 슬라이더는 끄는 동안 뒤의 창에 바로 보이고, 바꾸면 `~/Library/Application Support/<번들 ID>/config.toml`에 저장된다. 창의 "파일 열기…"로 이 파일을 텍스트 편집기에서 고쳐도 저장하면 바로 반영된다. 항목마다 바로 위에 뜻·타입·기본값·범위가 주석으로 있다. `font_family`(비우면 D2Coding)·`font_size`·`line_height`(글꼴 줄 높이의 배수, 기본 1.3)·`theme`(`auto` 시스템 따라감·`dark`·`light`)·`contrast`(대비 -100~100%, 기본 0은 프로그램 색 그대로). 프로그램이 배경색을 물으면(OSC 11) 이 모양의 색으로 답해서, 그걸로 다크·라이트를 고르는 TUI도 맞춰진다(다크·라이트 알림인 모드 2031을 켠 프로그램은 바꾸면 바로 맞춰지고, 아니면 다시 켜야 그쪽 색이 바뀐다). `Cmd +`·`Cmd -`도 이 파일의 `font_size`를 바꾼다. 파일에 없거나 잘못된 값은 만들 때 준 `--font`·`--font-size`·`--line-height`, 그다음 기본값을 쓴다.
- 에이전트·스크립트용([agent-discoverable-config](https://github.com/zidell/agent-discoverable-config)를 따른다): 앱 안 `Contents/Resources/readme.txt`가 설정 위치와 방법을 안내하고, 실행 파일 `Contents/MacOS/launcher`가 `--help`·`--config-path`(설정 파일 경로)·`--print-default-config`(설명 붙은 기본 설정)·`--init-config`(없으면 만듦, 덮어쓰지 않음)·`--check-config`(잘못된 줄과 허용값, 있으면 종료 코드 1)를 받는다. 창은 띄우지 않는다.
- 메모리(실측, 2026-10-06): 160×45칸·줄간격 1.5 창에서 앱 하나 48MB. 그중 25MB는 창 화면 버퍼라 창 크기에 비례한다. 터미널 방식은 Terminal 창 하나에 14MB(같은 칸 수, 줄간격 1)지만 Terminal.app 본체(약 115MB)가 따로 떠 있어야 한다.
- 스크롤백·탭·분할은 없다(TUI 하나를 띄우는 창이다). 휠은 TUI 화면에서 위·아래 화살표로 보낸다.

## 프로그램 쪽 연결

연결하지 않아도 Dock·Cmd+H·Cmd+W·Cmd+Q·창 크기 기억은 된다. 연결하면 Cmd 조합을 프로그램이 받는다.

실행기는 프로그램을 띄울 때 환경변수 `TUIDOCK`에 소켓 폴더를 넘긴다. 폴더 안에 유닉스 데이터그램 소켓이 두 개 있다. 메시지는 한 줄 글자다.

| 방향 | 소켓 | 메시지 |
|---|---|---|
| 실행기 → 프로그램 | `app.sock`(프로그램이 연다) | `key cmd+a` · `key cmd+shift+=` · `key cmd+left`, `ping`(→ `hello`로 답), `ok`(`bye`에 대한 답) |
| 프로그램 → 실행기 | `launcher.sock` | `hello <pid>`(시작할 때), `focus 1`/`focus 0`(터미널 포커스 신호마다), `hide`, `font +1`/`font -1`, `bye`(종료 직전) |

- 키 이름은 Shift를 뺀 글자다. `cmd+shift+/`가 `Cmd+?`다. 방향키는 `left` `right` `up` `down`, 그 밖에 `enter`, `backspace`.
- 넘기지 않는 키: `Cmd+H`·`Cmd+W`(실행기가 그 창을 숨김), `Cmd+M`(최소화), `` Cmd+` ``(창 전환), 스크린샷(`Cmd+Shift+3~6`), 로그아웃(`Cmd+Shift+Q`). `Cmd+Tab`·`Cmd+Space` 같은 시스템 단축키는 원래 못 가로챈다.
- 키는 `focus 1`과 `focus 0` 사이에만 온다. 포커스 신호는 터미널 포커스 보고(`ESC[?1004h`)로 받는다.
- `Cmd+Q`(종료), `Cmd+V`(붙여넣기)도 프로그램으로 온다. 프로그램이 처리해야 한다.

### Go

```go
import "github.com/zidell/tuidock"

p := tea.NewProgram(m, tea.WithReportFocus())
dock := tuidock.Open(func(key string) { p.Send(cmdKeyMsg{key}) })

// Update에서
case tea.FocusMsg: dock.Focus(true)
case tea.BlurMsg:  dock.Focus(false)
case cmdKeyMsg:    // "cmd+q" → 종료, "cmd+v" → tuidock.Paste() …

// 끝날 때(창이 아직 있을 때)
dock.Close()
```

터미널에서 직접 실행하면 `Open`은 nil을 돌려주고, nil의 메서드는 아무것도 하지 않는다.

## 한계

- 실행기는 터미널(Terminal.app)·아이텀(iTerm2)·고스티(Ghostty)·자체 터미널만.
- 아이텀은 창 하나만 가릴 수 없어 `Cmd+W`·`Cmd+H`가 최소화다. 글꼴 크기는 기억하지 않는다.
- 고스티는 앱마다 따로 떠서 앱당 메모리를 70~100MB 더 쓰고, Dock·Cmd+Tab에 고스티 항목이 앱마다 생긴다. 글꼴 크기는 기억하지 않는다.
- 메뉴 막대는 실행기 것이다(자체 터미널 제외). 메뉴를 마우스로 고르면 실행기 기능이 실행된다.
- 아이콘이나 실행 파일 경로를 바꿔 앱을 다시 만들면 서명이 바뀌어 권한(터미널 제어, 자체 터미널이면 프로그램이 쓰는 캘린더 등)을 한 번 더 물을 수 있다.

## 라이선스

GPLv3(`LICENSE`). 프로그램 쪽 Go 연결 `tuidock.go`만 MIT(`LICENSE.MIT`)라 GPL이 아닌 프로그램에서도 가져다 쓸 수 있다. 실행기는 프로그램을 별도 프로세스로 띄우므로 tuidock으로 만든 앱의 프로그램 라이선스에는 영향이 없다.
