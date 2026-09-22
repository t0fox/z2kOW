package main

import (
	"sync"
	"testing"
	"time"
)

func TestByteQueue_BudgetLifecycle(t *testing.T) {
	b := newMemBudget(100)
	q := newBudgetByteQueue(8, b)
	other := newBudgetByteQueue(8, b)
	other.push([]byte("keep"))
	q.push([]byte("abc"))
	q.push([]byte("defg"))
	if q.push([]byte("xx")) || b.used.Load() != 11 {
		t.Fatal("rejected push changed the shared budget")
	}
	q.pop()
	if b.used.Load() != 8 {
		t.Fatalf("pop: budget=%d, want 8", b.used.Load())
	}
	q.close()
	q.close()
	if q.push([]byte("x")) || b.used.Load() != 4 {
		t.Fatalf("close must release only its own bytes once: %d", b.used.Load())
	}
	other.close()
	if b.used.Load() != 0 {
		t.Fatalf("budget after all queues close: %d", b.used.Load())
	}
}

func TestByteQueue_BudgetConcurrentClose(t *testing.T) {
	for round := 0; round < 200; round++ {
		b := newMemBudget(0)
		q := newBudgetByteQueue(4096, b)
		q.push([]byte("initial frame"))
		start := make(chan struct{})
		var wg sync.WaitGroup
		for worker := 0; worker < 3; worker++ {
			wg.Add(1)
			go func(worker int) {
				defer wg.Done()
				<-start
				for i := 0; i < 200; i++ {
					switch worker {
					case 0:
						q.push([]byte("frame"))
					case 1:
						q.pop()
					case 2:
						q.close()
					}
					if n := b.used.Load(); n < 0 {
						t.Errorf("negative budget: %d", n)
					}
				}
			}(worker)
		}
		close(start)
		wg.Wait()
		if b.used.Load() != 0 || q.queued() != 0 {
			t.Fatalf("after close: budget=%d queued=%d", b.used.Load(), q.queued())
		}
	}
}

func TestByteQueue_CapAndOrder(t *testing.T) {
	q := newByteQueue(10)
	if !q.push([]byte("aaaa")) || !q.push([]byte("bbbb")) {
		t.Fatal("8 из 10 байт должны войти")
	}
	if q.push([]byte("ccc")) {
		t.Fatal("11 байт сверх cap приняты")
	}
	if q.queued() != 8 {
		t.Fatalf("queued=%d", q.queued())
	}
	f, ok := q.pop()
	if !ok || string(f) != "aaaa" {
		t.Fatal("FIFO нарушен")
	}
	if !q.push([]byte("ccc")) {
		t.Fatal("после pop место должно освободиться")
	}
}

func TestByteQueue_WaitAndClose(t *testing.T) {
	q := newByteQueue(100)
	done := make(chan struct{})
	got := make(chan bool, 1)
	go func() { got <- q.wait(done) }()
	select {
	case <-got:
		t.Fatal("wait вернулся на пустой очереди")
	case <-time.After(50 * time.Millisecond):
	}
	q.push([]byte("x"))
	if !<-got {
		t.Fatal("wait обязан вернуть true после push")
	}
	q.close()
	if q.push([]byte("y")) || q.wait(done) {
		t.Fatal("после close push=false, wait=false")
	}
}

func TestByteQueue_WaitCancelledByDone(t *testing.T) {
	q := newByteQueue(100)
	done := make(chan struct{})
	got := make(chan bool, 1)
	go func() { got <- q.wait(done) }()
	close(done)
	select {
	case v := <-got:
		if v {
			t.Fatal("wait после done обязан вернуть false")
		}
	case <-time.After(time.Second):
		t.Fatal("wait не проснулся по done")
	}
}

func TestMemBudget(t *testing.T) {
	b := newMemBudget(1000)
	b.add(350)
	if b.over() {
		t.Fatal("350 < 400 не over")
	}
	b.add(100)
	if !b.over() || b.belowLow() {
		t.Fatal("450 > 400 over; не ниже 300")
	}
	b.add(-200)
	if !b.belowLow() {
		t.Fatal("250 < 300")
	}
	z := newMemBudget(0)
	z.add(1 << 40)
	if z.over() {
		t.Fatal("нулевой лимит = без бюджета")
	}
}
