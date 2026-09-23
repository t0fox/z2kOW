package main

import "context"

// The DNS observer is an optional companion; it cannot make the tunnel fail.
func runEngineAndObserver(parent context.Context, engine, observer func(context.Context) error) error {
	ctx, cancel := context.WithCancel(parent)
	done := make(chan struct{})
	go func() { defer close(done); _ = observer(ctx) }()
	err := engine(ctx)
	cancel()
	<-done
	return err
}
