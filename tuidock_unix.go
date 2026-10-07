// SPDX-License-Identifier: MIT (LICENSE.MIT).
//go:build !windows

package tuidock

import (
	"net"
	"os/exec"
	"strings"
)

type datagrams struct{ *net.UnixConn }

func (d datagrams) ReadMessage(buf []byte) (int, error) {
	n, _, err := d.ReadFromUnix(buf)
	return n, err
}
func listenMessages(path string) (messageListener, error) {
	c, err := net.ListenUnixgram("unixgram", &net.UnixAddr{Name: path, Net: "unixgram"})
	return datagrams{c}, err
}
func sendMessage(path, message string) {
	c, err := net.DialUnix("unixgram", nil, &net.UnixAddr{Name: path, Net: "unixgram"})
	if err != nil {
		return
	}
	defer c.Close()
	c.Write([]byte(message))
}

// Paste는 클립보드 글자. 읽지 못하면 빈 문자열.
func Paste() string {
	out, err := exec.Command("pbpaste").Output()
	if err != nil {
		return ""
	}
	return string(out)
}

// Copy는 글자를 클립보드에 넣는다.
func Copy(s string) { cmd := exec.Command("pbcopy"); cmd.Stdin = strings.NewReader(s); cmd.Run() }
