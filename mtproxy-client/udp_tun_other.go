//go:build !linux

package main

import (
	"fmt"
	"os"
)

func openUDPTun(name string) (*os.File, error) {
	return nil, fmt.Errorf("Telegram UDP TUN requires Linux")
}
