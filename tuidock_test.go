// SPDX-License-Identifier: MIT (LICENSE.MIT).
package tuidock

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestNoLauncher(t *testing.T) {
	t.Setenv("TUIDOCK", "")
	conn := Open(nil)
	if conn != nil {
		t.Fatal("expected nil")
	}
	conn.Focus(true)
	conn.Hide()
	conn.Font(1)
	conn.Close()
}
func TestProtocol(t *testing.T) {
	// AF_UNIX의 108바이트 제한을 넘지 않는 짧은 경로를 쓴다.
	dir, err := os.MkdirTemp("", "td-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)
	listener, err := listenMessages(filepath.Join(dir, "launcher.sock"))
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	received := make(chan string, 16)
	go func() {
		b := make([]byte, 256)
		for {
			n, err := listener.ReadMessage(b)
			if err != nil {
				return
			}
			received <- string(b[:n])
		}
	}()
	t.Setenv("TUIDOCK", dir)
	keys := make(chan string, 1)
	conn := Open(func(s string) { keys <- s })
	if conn == nil {
		t.Fatal("Open failed")
	}
	expect := func(prefix string) {
		t.Helper()
		select {
		case s := <-received:
			if len(s) < len(prefix) || s[:len(prefix)] != prefix {
				t.Fatalf("got %q, want %q", s, prefix)
			}
		case <-time.After(time.Second):
			t.Fatal("message timeout")
		}
	}
	expect("hello ")
	conn.Focus(true)
	expect("focus 1")
	conn.Focus(false)
	expect("focus 0")
	conn.Hide()
	expect("hide")
	conn.Font(1)
	expect("font +1")
	conn.Font(-1)
	expect("font -1")
	sendMessage(filepath.Join(dir, "app.sock"), "key cmd+q")
	select {
	case s := <-keys:
		if s != "cmd+q" {
			t.Fatal(s)
		}
	case <-time.After(time.Second):
		t.Fatal("key timeout")
	}
	sendMessage(filepath.Join(dir, "app.sock"), "ping")
	expect("hello ")
	closed := make(chan struct{})
	go func() { conn.Close(); close(closed) }()
	expect("bye")
	sendMessage(filepath.Join(dir, "app.sock"), "ok")
	select {
	case <-closed:
	case <-time.After(time.Second):
		t.Fatal("Close timeout")
	}
}
