// Go 프로그램과 실제 Windows 실행기 사이의 프로토콜 시험용.
package main

import (
	"fmt"
	"github.com/zidell/tuidock"
	"os"
	"time"
)

func main() {
	done := make(chan struct{}, 1)
	dock := tuidock.Open(func(key string) {
		fmt.Println("KEY:" + key)
		if key == "cmd+q" {
			select {
			case done <- struct{}{}:
			default:
			}
		}
	})
	if dock == nil {
		fmt.Println("NO_CONNECTION")
		os.Exit(2)
	}
	fmt.Println("CONNECTED")
	if len(os.Args) > 1 && os.Args[1] == "clipboard" {
		tuidock.Copy("한글 clipboard 🗓️")
		fmt.Println("CLIPBOARD:" + tuidock.Paste())
	}
	dock.Focus(true)
	dock.Focus(false)
	dock.Font(1)
	dock.Font(-1)
	select {
	case <-done:
	case <-time.After(20 * time.Second):
		os.Exit(3)
	}
	dock.Close()
	fmt.Println("CLOSED")
}
