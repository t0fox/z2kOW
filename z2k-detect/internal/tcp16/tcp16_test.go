package tcp16

import (
	"bufio"
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"math/big"
	"net"
	"strconv"
	"testing"
	"time"
)

func selfCert(t *testing.T) tls.Certificate {
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

// serveHEAD поднимает TLS-сервер, отвечающий на HEAD-запросы. answer —
// сколько запросов обслужить, прежде чем закрыть соединение; delay(n) —
// задержка перед ответом на n-й запрос.
func serveHEAD(t *testing.T, answer int, delay func(n int) time.Duration) Target {
	t.Helper()
	ln, err := tls.Listen("tcp", "127.0.0.1:0", &tls.Config{Certificates: []tls.Certificate{selfCert(t)}})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func(c net.Conn) {
				defer c.Close()
				br := bufio.NewReader(c)
				for n := 0; n < answer; n++ {
					for {
						l, err := br.ReadString('\n')
						if err != nil {
							return
						}
						if l == "\r\n" {
							break
						}
					}
					if delay != nil {
						time.Sleep(delay(n))
					}
					c.Write([]byte("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"))
				}
			}(c)
		}
	}()
	h, p, _ := net.SplitHostPort(ln.Addr().String())
	port, _ := strconv.Atoi(p)
	return Target{ID: "T", ASN: "1", IP: h, Port: port}
}

// Обрыв на первых килобайтах — не «имя подошло» (ревью 25.10.2026: прежняя
// проверка Alive && !Detected засчитывала такой обрыв как успех).
func TestEarlyCloseIsNotPassed(t *testing.T) {
	for _, answer := range []int{1, 2, 3} {
		r := Probe(context.Background(), serveHEAD(t, answer, nil), "x.example")
		if r.Passed {
			t.Errorf("сервер ответил на %d из 10 запросов, а проба засчитана как прошедшая: %+v", answer, r)
		}
		if r.Detected {
			t.Errorf("обрыв до порога засчитан как блок: %+v", r)
		}
	}
	r := Probe(context.Background(), serveHEAD(t, ChunkCount, nil), "x.example")
	if !r.Passed || r.Detected {
		t.Errorf("все запросы обслужены, а проба не прошла: %+v", r)
	}
}

// Медленный здоровый сервер за порогом ловит штатное ожидание 3×RTT, но
// перепроверка с длинным ожиданием его снимает.
func TestSlowServerClearedByConfirm(t *testing.T) {
	slow := func(n int) time.Duration {
		if n == 5 {
			return 1700 * time.Millisecond
		}
		return 0
	}
	r := Probe(context.Background(), serveHEAD(t, ChunkCount, slow), "")
	if r.Passed {
		t.Skipf("на этой машине 1,7 с уложилось в штатное ожидание (%+v) — проверять перепроверку не на чем", r)
	}
	c := ProbeOpt(context.Background(), serveHEAD(t, ChunkCount, slow), "", Opts{MinReadTimeout: ConfirmReadTimeout})
	if c.Detected || !c.Passed {
		t.Errorf("длинное ожидание не сняло ложный блок: %+v", c)
	}
}

// Отменённая проба не проходит и не даёт вердикта.
func TestCanceledIsNotPassed(t *testing.T) {
	tg := serveHEAD(t, ChunkCount, func(int) time.Duration { return 200 * time.Millisecond })
	ctx, cancel := context.WithCancel(context.Background())
	go func() { time.Sleep(500 * time.Millisecond); cancel() }()
	r := Probe(ctx, tg, "")
	if r.Passed {
		t.Errorf("отменённая проба засчитана как прошедшая: %+v", r)
	}
}
