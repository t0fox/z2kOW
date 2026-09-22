//go:build linux

package main

import (
	"encoding/binary"
	"fmt"
	"os"
	"syscall"
	"unsafe"
)

func openUDPTun(name string) (*os.File, error) {
	if len(name) == 0 || len(name) > 15 {
		return nil, fmt.Errorf("invalid TUN name")
	}
	fd, err := syscall.Open("/dev/net/tun", syscall.O_RDWR|syscall.O_NONBLOCK|syscall.O_CLOEXEC, 0)
	if err != nil {
		return nil, err
	}
	var req [40]byte
	copy(req[:16], name)
	binary.NativeEndian.PutUint16(req[16:18], 0x1001) // IFF_TUN | IFF_NO_PI, native endian
	_, _, e := syscall.Syscall(syscall.SYS_IOCTL, uintptr(fd), uintptr(syscall.TUNSETIFF), uintptr(unsafe.Pointer(&req[0])))
	if e != 0 {
		syscall.Close(fd)
		return nil, e
	}
	return os.NewFile(uintptr(fd), name), nil
}
