// SPDX-License-Identifier: MIT (LICENSE.MIT). 나머지 레포는 GPLv3(LICENSE).

// Package tuidock은 터미널 TUI 프로그램이 tuidock 실행기(Dock 앱)와 주고받는 연결이다.
//
// 실행기가 띄운 프로세스엔 환경변수 TUIDOCK(소켓 폴더)이 있다. 없으면(터미널에서 직접 실행) Open은 nil을
// 돌려주고, nil *Conn의 메서드는 아무것도 하지 않는다. 그래서 호출부는 실행기가 있는지 따지지 않아도 된다.
//
//	dock := tuidock.Open(func(key string) { p.Send(cmdKeyMsg{key}) }) // "cmd+a", "cmd+shift+=", "cmd+left"
//	dock.Focus(true)  // 터미널 포커스 신호(Bubble Tea: tea.WithReportFocus의 FocusMsg·BlurMsg)마다
//	dock.Close()      // 종료 직전(창 크기·글꼴을 실행기가 기억한다)
//
// 창이 포커스인 동안 Cmd 조합은 Terminal 대신 이 프로그램이 받는다(Cmd+H·Cmd+W는 실행기가 창을 숨기고, Cmd+M 제외). Cmd+Q(종료),
// Cmd+V(붙여넣기 — Paste로 읽는다)도 프로그램이 처리해야 한다.
// Windows는 자체 터미널의 창 닫기를 key cmd+q로 알린다. Ctrl 조합은 터미널 입력으로 직접 받는다.
package tuidock

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// Conn은 실행기와의 연결.
type Conn struct {
	dir string
	c   messageListener
	ack chan struct{}
}

// Open은 실행기가 넘기는 메시지를 받기 시작하고 실행기에 자기 pid를 알린다. onKey는 별도 고루틴에서 불린다.
func Open(onKey func(key string)) *Conn {
	dir := os.Getenv("TUIDOCK")
	if dir == "" {
		return nil
	}
	path := filepath.Join(dir, "app.sock")
	os.Remove(path) // 자기 자신을 exec로 다시 시작했거나 지난 실행이 남긴 것
	c, err := listenMessages(path)
	if err != nil {
		return nil
	}
	d := &Conn{dir: dir, c: c, ack: make(chan struct{}, 1)}
	go d.read(onKey)
	d.hello()
	return d
}

func (d *Conn) read(onKey func(string)) {
	buf := make([]byte, 256)
	for {
		n, err := d.c.ReadMessage(buf)
		if err != nil {
			return
		}
		switch s := string(buf[:n]); {
		case strings.HasPrefix(s, "key "):
			if onKey != nil {
				onKey(s[4:])
			}
		case s == "ping": // 실행기가 다시 켜짐
			d.hello()
		case s == "ok":
			select {
			case d.ack <- struct{}{}:
			default:
			}
		}
	}
}

func (d *Conn) send(msg string) {
	if d == nil {
		return
	}
	sendMessage(filepath.Join(d.dir, "launcher.sock"), msg)
}

func (d *Conn) hello() { d.send("hello " + strconv.Itoa(os.Getpid())) }

// Focus는 이 창이 포커스를 얻었는지·잃었는지 알린다. 포커스인 동안만 실행기가 Cmd 조합을 가로채 넘긴다.
func (d *Conn) Focus(on bool) {
	if on {
		d.send("focus 1")
	} else {
		d.send("focus 0")
	}
}

// Hide는 이 창만 숨긴다(Cmd+H와 같다). Dock 클릭·Cmd+Tab으로 다시 보인다.
func (d *Conn) Hide() { d.send("hide") }

// Font는 글꼴 크기를 1pt 키우거나(delta > 0) 줄인다(Terminal의 Cmd +/- 대신).
func (d *Conn) Font(delta int) {
	switch {
	case delta > 0:
		d.send("font +1")
	case delta < 0:
		d.send("font -1")
	}
}

// Close는 실행기가 창 크기·글꼴을 기억할 때까지(최대 0.5초) 기다린 뒤 연결을 닫는다. 종료 직전, 창이 아직 있을 때 부른다.
// 자기 자신을 exec로 다시 시작할 땐 부르지 않는다(같은 창을 그대로 쓴다).
func (d *Conn) Close() {
	if d == nil {
		return
	}
	d.send("bye")
	select {
	case <-d.ack:
	case <-time.After(500 * time.Millisecond):
	}
	d.c.Close()
	os.Remove(filepath.Join(d.dir, "app.sock"))
}

// 플랫폼별 소켓은 연결 하나 또는 데이터그램 하나를 메시지 하나로 읽는다.
type messageListener interface {
	ReadMessage([]byte) (int, error)
	Close() error
}
