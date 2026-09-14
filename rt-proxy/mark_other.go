//go:build !linux

package main

import "syscall"

// SO_MARK — понятие Linux. На остальных системах моста нет и быть не может
// (он живёт на роутере), но сборка и тесты идут и на маке: пусть отсутствие
// метки будет явным «не метим», а не ошибкой компиляции.
func markControl(mark int) func(string, string, syscall.RawConn) error {
	_ = mark
	return nil
}
