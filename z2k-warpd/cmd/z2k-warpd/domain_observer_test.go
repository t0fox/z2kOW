package main

import (
	"context"
	"errors"
	"testing"
)

func TestObserverFailureDoesNotStopTunnelEngine(t *testing.T) {
	called := false
	err := runEngineAndObserver(context.Background(), func(context.Context) error { called = true; return nil }, func(context.Context) error { return errors.New("NFLOG unavailable") })
	if err != nil || !called {
		t.Fatalf("engine did not run: called=%v err=%v", called, err)
	}
}
