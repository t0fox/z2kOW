package main

import (
	"context"
	"encoding/binary"
	"net"
	"testing"
	"time"
)

// Запрос обязан быть разбираемым любым резолвером: заголовок, один вопрос,
// метки с длиной впереди. Ошибка здесь не падает, а тихо даёт таймаут на
// каждом сервере — то есть выглядит как «все DNS мертвы».
func TestDNSQueryShape(t *testing.T) {
	q, err := dnsQuery(0xabcd, "example.com")
	if err != nil {
		t.Fatalf("dnsQuery: %v", err)
	}
	if got := binary.BigEndian.Uint16(q[0:2]); got != 0xabcd {
		t.Errorf("идентификатор: хотели 0xabcd, получили %#x", got)
	}
	if q[2]&0x01 == 0 {
		t.Error("не выставлен бит рекурсии (RD) — публичные резолверы ответят отказом")
	}
	if got := binary.BigEndian.Uint16(q[4:6]); got != 1 {
		t.Errorf("QDCOUNT: хотели 1, получили %d", got)
	}
	want := []byte{12: 7}
	_ = want
	if q[12] != 7 || string(q[13:20]) != "example" {
		t.Errorf("первая метка разложена неверно: % x", q[12:20])
	}
	if q[20] != 3 || string(q[21:24]) != "com" {
		t.Errorf("вторая метка разложена неверно: % x", q[20:24])
	}
	tail := q[len(q)-5:]
	if tail[0] != 0x00 || binary.BigEndian.Uint16(tail[1:3]) != 1 || binary.BigEndian.Uint16(tail[3:5]) != 1 {
		t.Errorf("хвост запроса: хотели 00 + QTYPE=A + QCLASS=IN, получили % x", tail)
	}
}

func TestDNSQueryRejectsGarbage(t *testing.T) {
	for _, name := range []string{"", "   ", "a..b"} {
		if _, err := dnsQuery(1, name); err == nil {
			t.Errorf("имя %q принято, а должно быть отвергнуто", name)
		}
	}
}

// Ответ с ЧУЖИМ идентификатором засчитываться не должен: на перехваченном
// UDP 53 посторонний пакет на наш порт — обычное дело, и он выдал бы
// молниеносное «время ответа» там, где сервер молчит.
func TestDNSRoundTripRejectsForeignID(t *testing.T) {
	pc, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Skipf("нет локального UDP: %v", err)
	}
	defer pc.Close()
	go func() {
		buf := make([]byte, 512)
		n, addr, err := pc.ReadFrom(buf)
		if err != nil || n < 12 {
			return
		}
		reply := make([]byte, n)
		copy(reply, buf[:n])
		// Портим идентификатор — как если бы ответил не тот, кого спросили.
		binary.BigEndian.PutUint16(reply[0:2], binary.BigEndian.Uint16(reply[0:2])+1)
		_, _ = pc.WriteTo(reply, addr)
	}()

	ctx := context.Background()
	if _, err := dnsRoundTrip(ctx, pc.LocalAddr().String(), "example.com", 300*time.Millisecond); err == nil {
		t.Error("чужой идентификатор засчитан за ответ")
	}
}

// Свой идентификатор — ответ принимается, число осмысленное.
func TestDNSRoundTripMeasures(t *testing.T) {
	pc, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Skipf("нет локального UDP: %v", err)
	}
	defer pc.Close()
	go func() {
		buf := make([]byte, 512)
		n, addr, err := pc.ReadFrom(buf)
		if err != nil || n < 12 {
			return
		}
		time.Sleep(20 * time.Millisecond)
		_, _ = pc.WriteTo(buf[:n], addr)
	}()

	ms, err := dnsRoundTrip(context.Background(), pc.LocalAddr().String(), "example.com", time.Second)
	if err != nil {
		t.Fatalf("dnsRoundTrip: %v", err)
	}
	if ms < 15 || ms > 500 {
		t.Errorf("время ответа вне разумного: %d мс (ждали около 20)", ms)
	}
}

// Молчащий сервер обязан кончиться таймаутом, а не висеть: вызов стоит в цикле
// по семи серверам, и один молчащий не должен вешать всю проверку.
func TestDNSRoundTripTimesOut(t *testing.T) {
	pc, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Skipf("нет локального UDP: %v", err)
	}
	defer pc.Close() // никто не отвечает

	start := time.Now()
	if _, err := dnsRoundTrip(context.Background(), pc.LocalAddr().String(), "example.com", 200*time.Millisecond); err == nil {
		t.Error("молчащий сервер засчитан за ответивший")
	}
	if el := time.Since(start); el > 2*time.Second {
		t.Errorf("таймаут не сработал: ждали 200 мс, вышло %v", el)
	}
}
