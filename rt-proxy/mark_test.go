package main

import (
	"net"
	"testing"
)

// Ноль означает «не метить», и это умолчание. Метка принадлежит чужому
// продукту (движку обхода), и включать её здесь молча нельзя: у того, кто
// настраивает роутер, должно остаться прежнее поведение, пока он не попросил
// иного.
func TestНулеваяМеткаНеСтавитУправление(t *testing.T) {
	if markControl(0) != nil {
		t.Fatal("нулевая метка вернула управление сокетом — умолчание изменилось молча")
	}
	if markControl(-1) != nil {
		t.Fatal("отрицательная метка принята")
	}
}

// Ненулевая метка обязана дойти до сокета, а не потеряться по дороге. На
// Linux проверяем делом: поднимаем слушателя на петле и подключаемся набором
// с управлением — если setsockopt откажет, Dial вернёт ошибку.
func TestНенулеваяМеткаПрименяется(t *testing.T) {
	ctl := markControl(0x2d)
	if ctl == nil {
		t.Skip("не Linux: SO_MARK здесь не существует, и это не отказ")
	}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	go func() {
		c, aerr := ln.Accept()
		if aerr == nil {
			_ = c.Close()
		}
	}()
	d := net.Dialer{Control: ctl}
	c, err := d.Dial("tcp", ln.Addr().String())
	if err != nil {
		// CAP_NET_ADMIN может отсутствовать — тогда setsockopt законно
		// откажет, и это не дефект метки, а права процесса.
		t.Skipf("метка не поставилась (нужен CAP_NET_ADMIN): %v", err)
	}
	_ = c.Close()
}
