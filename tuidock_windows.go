// SPDX-License-Identifier: MIT (LICENSE.MIT).
//go:build windows

package tuidock

import (
	"io"
	"net"
	"runtime"
	"strings"
	"syscall"
	"time"
	"unicode/utf16"
	"unsafe"
)

// Windows AF_UNIX에는 데이터그램이 없어 연결을 닫을 때까지가 메시지 하나다.
type streams struct{ *net.UnixListener }

func listenMessages(path string) (messageListener, error) {
	c, err := net.ListenUnix("unix", &net.UnixAddr{Name: path, Net: "unix"})
	return streams{c}, err
}
func (s streams) ReadMessage(buf []byte) (int, error) {
	for {
		c, err := s.AcceptUnix()
		if err != nil {
			return 0, err
		}
		c.SetReadDeadline(time.Now().Add(500 * time.Millisecond))
		data, err := io.ReadAll(io.LimitReader(c, int64(len(buf)+1)))
		c.Close()
		if err == nil && len(data) > 0 && len(data) <= len(buf) {
			return copy(buf, data), nil
		}
	}
}
func sendMessage(path, message string) {
	if len(message) > 256 {
		return
	}
	c, err := net.DialTimeout("unix", path, 500*time.Millisecond)
	if err != nil {
		return
	}
	defer c.Close()
	c.SetWriteDeadline(time.Now().Add(500 * time.Millisecond))
	io.Copy(c, strings.NewReader(message))
	if stream, ok := c.(*net.UnixConn); ok {
		stream.CloseWrite()
	}
}

var (
	user32           = syscall.NewLazyDLL("user32.dll")
	kernel32         = syscall.NewLazyDLL("kernel32.dll")
	openClipboard    = user32.NewProc("OpenClipboard")
	closeClipboard   = user32.NewProc("CloseClipboard")
	getClipboardData = user32.NewProc("GetClipboardData")
	setClipboardData = user32.NewProc("SetClipboardData")
	emptyClipboard   = user32.NewProc("EmptyClipboard")
	globalAlloc      = kernel32.NewProc("GlobalAlloc")
	globalFree       = kernel32.NewProc("GlobalFree")
	globalLock       = kernel32.NewProc("GlobalLock")
	globalUnlock     = kernel32.NewProc("GlobalUnlock")
	globalSize       = kernel32.NewProc("GlobalSize")
	moveMemory       = kernel32.NewProc("RtlMoveMemory")
	getConsoleWindow = kernel32.NewProc("GetConsoleWindow")
	createWindow     = user32.NewProc("CreateWindowExW")
	destroyWindow    = user32.NewProc("DestroyWindow")
)

func clipboardOpen(window uintptr) bool {
	for i := 0; i < 10; i++ {
		if ok, _, _ := openClipboard.Call(window); ok != 0 {
			return true
		}
		time.Sleep(10 * time.Millisecond)
	}
	return false
}

// Paste는 Windows Unicode 클립보드를 읽는다.
func Paste() string {
	window, _, _ := getConsoleWindow.Call()
	if !clipboardOpen(window) {
		return ""
	}
	defer closeClipboard.Call()
	handle, _, _ := getClipboardData.Call(13)
	if handle == 0 {
		return ""
	}
	count, _, _ := globalSize.Call(handle)
	if count < 2 {
		return ""
	}
	ptr, _, _ := globalLock.Call(handle)
	if ptr == 0 {
		return ""
	}
	defer globalUnlock.Call(handle)
	data := make([]uint16, count/2)
	moveMemory.Call(uintptr(unsafe.Pointer(&data[0])), ptr, uintptr(len(data)*2))
	end := 0
	for end < len(data) && data[end] != 0 {
		end++
	}
	return string(utf16.Decode(data[:end]))
}

// Copy는 Windows Unicode 클립보드에 넣는다. 성공하면 메모리 소유권은 Windows로 간다.
func Copy(s string) {
	// 콘솔 없는 Go 프로그램에서도 EmptyClipboard의 소유자 HWND가 필요하다.
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	class, _ := syscall.UTF16PtrFromString("STATIC")
	window, _, _ := createWindow.Call(0, uintptr(unsafe.Pointer(class)), 0, 0, 0, 0, 0, 0, ^uintptr(2), 0, 0, 0)
	if window == 0 {
		return
	}
	defer destroyWindow.Call(window)
	data := append(utf16.Encode([]rune(s)), 0)
	handle, _, _ := globalAlloc.Call(0x0002, uintptr(len(data)*2))
	if handle == 0 {
		return
	}
	owned := true
	defer func() {
		if owned {
			globalFree.Call(handle)
		}
	}()
	ptr, _, _ := globalLock.Call(handle)
	if ptr == 0 {
		return
	}
	moveMemory.Call(ptr, uintptr(unsafe.Pointer(&data[0])), uintptr(len(data)*2))
	globalUnlock.Call(handle)
	if !clipboardOpen(window) {
		return
	}
	defer closeClipboard.Call()
	if ok, _, _ := emptyClipboard.Call(); ok == 0 {
		return
	}
	if ok, _, _ := setClipboardData.Call(13, handle); ok != 0 {
		owned = false
	}
}
