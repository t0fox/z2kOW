package main

import (
	"bufio"
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"errors"
	"fmt"
	"math/big"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/necronicle/z2k/z2k-detect/internal/tcp16"
)

// Подпроцесс: tcp16Cmd завершает процесс через os.Exit, и коды выхода —
// контракт со скриптом пробы, поэтому проверяем их в отдельном процессе.
func TestMain(m *testing.M) {
	if args := os.Getenv("Z2K_TCP16_SUBPROC"); args != "" {
		tcp16Cmd(context.Background(), strings.Split(args, "\x1f"))
		os.Exit(0)
	}
	os.Exit(m.Run())
}

func runTCP16(t *testing.T, args ...string) (int, string) {
	t.Helper()
	cmd := exec.Command(os.Args[0], "-test.run=^$")
	cmd.Env = append(os.Environ(), "Z2K_TCP16_SUBPROC="+strings.Join(args, "\x1f"))
	out, err := cmd.CombinedOutput()
	code := 0
	var ee *exec.ExitError
	if errors.As(err, &ee) {
		code = ee.ExitCode()
	} else if err != nil {
		t.Fatal(err)
	}
	return code, string(out)
}

func selfCertMain(t *testing.T) tls.Certificate {
	t.Helper()
	k, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "x"},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour)}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &k.PublicKey, k)
	if err != nil {
		t.Fatal(err)
	}
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: k}
}

// boxServer изображает коробку с обрывом по объёму: начиная с пятого запроса
// (накоплено больше 12 КБ) соединение замерзает — если только имя в hello не
// из белого списка. freeze=false — блока нет вовсе.
func boxServer(t *testing.T, white string, freeze bool) string {
	t.Helper()
	cert := selfCertMain(t)
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			raw, err := ln.Accept()
			if err != nil {
				return
			}
			go func(raw net.Conn) {
				defer raw.Close()
				var sni string
				c := tls.Server(raw, &tls.Config{
					Certificates: []tls.Certificate{cert},
					GetConfigForClient: func(h *tls.ClientHelloInfo) (*tls.Config, error) {
						sni = h.ServerName
						return nil, nil
					},
				})
				if err := c.Handshake(); err != nil {
					return
				}
				br := bufio.NewReader(c)
				for n := 0; n < tcp16.ChunkCount; n++ {
					for {
						l, err := br.ReadString('\n')
						if err != nil {
							return
						}
						if l == "\r\n" {
							break
						}
					}
					if freeze && n >= 4 && sni != white {
						time.Sleep(20 * time.Second)
						return
					}
					c.Write([]byte("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"))
				}
			}(raw)
		}
	}()
	return ln.Addr().String()
}

func targetsFile(t *testing.T, dir string, lines ...string) string {
	t.Helper()
	p := filepath.Join(dir, "targets.txt")
	if err := os.WriteFile(p, []byte("# id\tasn\tconfirmed\tprovider\tip\tport\n"+strings.Join(lines, "\n")+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func target(id, asn, addr string) string {
	h, p, _ := net.SplitHostPort(addr)
	return fmt.Sprintf("%s\t%s\t-\tTest\t%s\t%s", id, asn, h, p)
}

func readFile(t *testing.T, p string) string {
	t.Helper()
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

// Фатальная ошибка — не «блок есть»: отдельный код, список сетей не тронут.
func TestFatalIsNotBlock(t *testing.T) {
	dir := t.TempDir()
	tf := targetsFile(t, dir) // одни комментарии
	asnOut := filepath.Join(dir, "asn.txt")
	os.WriteFile(asnOut, []byte("13335\n"), 0o644)
	code, out := runTCP16(t, "-targets", tf, "-asn-out", asnOut)
	if code != exitFatal {
		t.Fatalf("код %d, ждали %d (фатальная ошибка); вывод: %s", code, exitFatal, out)
	}
	if got := readFile(t, asnOut); got != "13335\n" {
		t.Errorf("фатальная ошибка переписала список сетей: %q", got)
	}
}

// Мишени молчат — «не мерили»: код 3, прежний список сетей цел.
func TestNoAnswerKeepsASNList(t *testing.T) {
	dir := t.TempDir()
	ln, _ := net.Listen("tcp", "127.0.0.1:0")
	dead := ln.Addr().String()
	ln.Close() // порт закрыт: соединение отвергается
	tf := targetsFile(t, dir, target("D-01", "100", dead))
	asnOut := filepath.Join(dir, "asn.txt")
	os.WriteFile(asnOut, []byte("# прежний\n100\n"), 0o644)
	code, out := runTCP16(t, "-targets", tf, "-asn-out", asnOut, "-parallel", "2")
	if code != exitNoAnswer {
		t.Fatalf("код %d, ждали %d; вывод: %s", code, exitNoAnswer, out)
	}
	if got := readFile(t, asnOut); got != "# прежний\n100\n" {
		t.Errorf("молчащие мишени стёрли список сетей: %q", got)
	}
}

// Блок виден — код 1 и сеть в списке; сеть без ответа из прежнего списка
// переносится.
func TestBlockWritesListAndCarriesSilentASN(t *testing.T) {
	dir := t.TempDir()
	ln, _ := net.Listen("tcp", "127.0.0.1:0")
	dead := ln.Addr().String()
	ln.Close()
	tf := targetsFile(t, dir,
		target("B-01", "100", boxServer(t, "white.example", true)),
		target("D-01", "200", dead))
	asnOut := filepath.Join(dir, "asn.txt")
	os.WriteFile(asnOut, []byte("200\n"), 0o644)
	code, out := runTCP16(t, "-targets", tf, "-asn-out", asnOut, "-parallel", "4")
	if code != exitBlock {
		t.Fatalf("код %d, ждали %d; вывод: %s", code, exitBlock, out)
	}
	got := readFile(t, asnOut)
	if !strings.Contains(got, "\n100\n") || !strings.Contains(got, "\n200\n") {
		t.Errorf("в списке нет сети с блоком или перенесённой молчащей сети: %q", got)
	}
}

// Проба линии идёт к мишени с ЕЁ именем, если явного нет.
func TestRunAllUsesTargetSNI(t *testing.T) {
	tg := []tcp16.Target{{ID: "F", ASN: "54113", IP: "127.0.0.1", Port: 9, SNI: "assets.example"}}
	res := runAll(context.Background(), tg, "", 1)
	if res[0].SNI != "assets.example" {
		t.Errorf("проба ушла с именем %q вместо имени мишени", res[0].SNI)
	}
	res = runAll(context.Background(), tg, "forced.example", 1)
	if res[0].SNI != "forced.example" {
		t.Errorf("явное имя не взято: %q", res[0].SNI)
	}
}

// Подбор: имя находится только для сетей из списка пробы, прежние имена
// переносятся для сетей без мишеней, сети вне списка выбрасываются.
func TestScanPerASNListAndCarry(t *testing.T) {
	dir := t.TempDir()
	tf := targetsFile(t, dir, target("B-01", "100", boxServer(t, "good.example", true)),
		target("B-02", "400", boxServer(t, "good.example", true)))
	names := filepath.Join(dir, "names.txt")
	os.WriteFile(names, []byte("bad1.example\nbad2.example\ngood.example\n"), 0o644)
	asnIn := filepath.Join(dir, "asn.txt")
	os.WriteFile(asnIn, []byte("100\n200\n"), 0o644) // 400 — не в списке
	prev := filepath.Join(dir, "prev.txt")
	os.WriteFile(prev, []byte("200\told.example\n300\tstale.example\n"), 0o644)
	out := filepath.Join(dir, "sni.txt")
	code, log := runTCP16(t, "-targets", tf, "-scan", names, "-per-asn", "-asn-in", asnIn,
		"-prev", prev, "-sni-out", out, "-parallel", "8", "-batch", "2")
	if code != exitNoBlock {
		t.Fatalf("код %d; вывод: %s", code, log)
	}
	got := readFile(t, out)
	for _, want := range []string{"100\tgood.example\n", "200\told.example\n"} {
		if !strings.Contains(got, want) {
			t.Errorf("в карте нет %q: %q\nвывод: %s", want, got, log)
		}
	}
	for _, bad := range []string{"300\t", "400\t", "bad1", "bad2"} {
		if strings.Contains(got, bad) {
			t.Errorf("в карте лишнее %q: %q", bad, got)
		}
	}
}

// Перемер блока не увидел — прежнее имя сети остаётся.
func TestScanCarriesNameWhenBlockNotSeen(t *testing.T) {
	dir := t.TempDir()
	tf := targetsFile(t, dir, target("B-01", "100", boxServer(t, "", false)))
	names := filepath.Join(dir, "names.txt")
	os.WriteFile(names, []byte("bad1.example\n"), 0o644)
	prev := filepath.Join(dir, "prev.txt")
	os.WriteFile(prev, []byte("100\tkept.example\n"), 0o644)
	out := filepath.Join(dir, "sni.txt")
	code, log := runTCP16(t, "-targets", tf, "-scan", names, "-per-asn", "-prev", prev, "-sni-out", out, "-parallel", "4")
	if code != exitNoBlock {
		t.Fatalf("код %d; вывод: %s", code, log)
	}
	if got := readFile(t, out); !strings.Contains(got, "100\tkept.example\n") {
		t.Errorf("имя сети потеряно, хотя блок просто не увиделся: %q", got)
	}
}

// Пустой подбор — карта всё равно записана (подбор завершён), код 2.
func TestScanEmptyStillWritesMap(t *testing.T) {
	dir := t.TempDir()
	tf := targetsFile(t, dir, target("B-01", "100", boxServer(t, "never.example", true)))
	names := filepath.Join(dir, "names.txt")
	os.WriteFile(names, []byte("bad1.example\n"), 0o644)
	out := filepath.Join(dir, "sni.txt")
	code, log := runTCP16(t, "-targets", tf, "-scan", names, "-per-asn", "-sni-out", out, "-parallel", "4")
	if code != exitNoNames {
		t.Fatalf("код %d, ждали %d; вывод: %s", code, exitNoNames, log)
	}
	if _, err := os.Stat(out); err != nil {
		t.Errorf("завершённый подбор не записал карту: %v", err)
	}
}

// Вторая фаза подбора: хвост подбирается только для сетей без имени, а имена
// первой фазы переносятся все (-asn-keep шире, чем -asn-in).
func TestScanSecondPhaseKeepsFirstPhase(t *testing.T) {
	dir := t.TempDir()
	tf := targetsFile(t, dir, target("B-01", "100", boxServer(t, "tail.example", true)))
	names := filepath.Join(dir, "tail.txt")
	os.WriteFile(names, []byte("bad1.example\ntail.example\n"), 0o644)
	only := filepath.Join(dir, "missing.txt")
	os.WriteFile(only, []byte("100\n"), 0o644)
	keep := filepath.Join(dir, "asn.txt")
	os.WriteFile(keep, []byte("100\n500\n"), 0o644)
	prev := filepath.Join(dir, "prev.txt")
	os.WriteFile(prev, []byte("500\tphaseA.example\n"), 0o644)
	out := filepath.Join(dir, "sni.txt")
	code, log := runTCP16(t, "-targets", tf, "-scan", names, "-per-asn", "-asn-in", only, "-asn-keep", keep,
		"-prev", prev, "-sni-out", out, "-parallel", "4")
	if code != exitNoBlock {
		t.Fatalf("код %d; вывод: %s", code, log)
	}
	got := readFile(t, out)
	for _, want := range []string{"100\ttail.example\n", "500\tphaseA.example\n"} {
		if !strings.Contains(got, want) {
			t.Errorf("в карте нет %q: %q", want, got)
		}
	}
}
