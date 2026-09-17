package main

import (
	"context"
	"encoding/binary"
	"flag"
	"fmt"
	"math/rand"
	"net"
	"os"
	"strings"
	"time"
)

// dnsmsCmd — сколько миллисекунд занимает обычный UDP-запрос к DNS-серверу.
//
// ЗАЧЕМ ОТДЕЛЬНАЯ КОМАНДА. Время обычного DNS в панели показывалось только там,
// где установлен пакет bind-dig: он один печатает «;; Query time: N msec».
// Пакет тянет за собой bind-libs — 2,4 МБ на флешке ради одного числа, и стоит
// далеко не у всех, поэтому у половины людей строки «Обычный DNS» были без
// времени, а DoH и DoT рядом — с временем (жалоба 16.09.2026).
//
// Оболочкой это не меряется: дробного sleep у busybox нет, `date +%s%N`
// печатает literal %N, а `nc -u` в их сборке отсутствует вовсе (проверено на
// роутере). Счётчик usleep с шагом 10 мс, которым меряется DoT, здесь не
// подходит: обычный запрос укладывается в единицы миллисекунд, и шаг в 10 мс
// огрубил бы его до неразличимости.
//
// Го здесь уже установлен на каждом роутере: z2k-detect возит проба блока по
// объёму и подбор стратегий. Команда добавляет к нему сорок строк и ни одного
// нового пакета.
//
// Замеряется ровно обмен: сокет создан заранее, таймер вокруг WriteTo/ReadFrom.
func dnsmsCmd(ctx context.Context, rest []string) {
	fs := flag.NewFlagSet("dnsms", flag.ExitOnError)
	server := fs.String("server", "", "адрес DNS-сервера")
	name := fs.String("name", "example.com", "какое имя спрашивать")
	timeout := fs.Duration("timeout", 2*time.Second, "потолок ожидания")
	_ = fs.Parse(rest)

	if *server == "" {
		fatal("нужен -server")
	}
	ms, err := dnsRoundTrip(ctx, *server, *name, *timeout)
	if err != nil {
		// Молчащий сервер — не ошибка запуска: вызывающая оболочка отличает
		// «нет ответа» от «нет команды» по коду возврата, а не по тексту.
		fmt.Fprintf(os.Stderr, "нет ответа от %s: %v\n", *server, err)
		os.Exit(1)
	}
	fmt.Println(ms)
}

// dnsRoundTrip — один запрос A-записи и ответ на него, в миллисекундах.
func dnsRoundTrip(ctx context.Context, server, name string, timeout time.Duration) (int64, error) {
	host := server
	if _, _, err := net.SplitHostPort(server); err != nil {
		host = net.JoinHostPort(server, "53")
	}
	var d net.Dialer
	conn, err := d.DialContext(ctx, "udp", host)
	if err != nil {
		return 0, err
	}
	defer conn.Close()

	// Идентификатор случайный: два подряд одинаковых запроса иначе рискуют
	// склеиться на кэширующем резолвере и второй замер покажет ноль.
	q, err := dnsQuery(uint16(rand.Intn(0xffff)), name)
	if err != nil {
		return 0, err
	}
	if err := conn.SetDeadline(time.Now().Add(timeout)); err != nil {
		return 0, err
	}

	start := time.Now()
	if _, err := conn.Write(q); err != nil {
		return 0, err
	}
	buf := make([]byte, 1500)
	n, err := conn.Read(buf)
	if err != nil {
		return 0, err
	}
	elapsed := time.Since(start)
	if n < 12 {
		return 0, fmt.Errorf("ответ короче заголовка: %d байт", n)
	}
	// Ответ обязан быть НА НАШ запрос: чужой пакет на том же порту (а на
	// перехваченном UDP 53 это обычное дело) иначе засчитался бы за ответ.
	if binary.BigEndian.Uint16(buf[:2]) != binary.BigEndian.Uint16(q[:2]) {
		return 0, fmt.Errorf("чужой идентификатор в ответе")
	}
	ms := elapsed.Milliseconds()
	if ms < 1 {
		ms = 1 // ноль миллисекунд человеку ничего не говорит и выглядит поломкой
	}
	return ms, nil
}

// dnsQuery — запрос A-записи по RFC 1035 §4.1.
func dnsQuery(id uint16, name string) ([]byte, error) {
	name = strings.TrimSuffix(strings.TrimSpace(name), ".")
	if name == "" {
		return nil, fmt.Errorf("пустое имя")
	}
	out := make([]byte, 12, 12+len(name)+6)
	binary.BigEndian.PutUint16(out[0:2], id)
	out[2] = 0x01 // RD — рекурсия
	binary.BigEndian.PutUint16(out[4:6], 1)
	for _, label := range strings.Split(name, ".") {
		if label == "" || len(label) > 63 {
			return nil, fmt.Errorf("негодная метка в имени: %q", label)
		}
		out = append(out, byte(len(label)))
		out = append(out, label...)
	}
	out = append(out, 0x00)
	out = append(out, 0x00, 0x01) // QTYPE=A
	out = append(out, 0x00, 0x01) // QCLASS=IN
	return out, nil
}
