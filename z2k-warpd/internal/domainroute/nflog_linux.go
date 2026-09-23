//go:build linux

package domainroute

import (
	"context"
	"errors"
	"github.com/florianl/go-nflog/v2"
)

const nflogGroup = 189

func receivePackets(ctx context.Context, handle func([]byte), onError func(error)) (func(), error) {
	nf, err := nflog.Open(&nflog.Config{Group: nflogGroup, Copymode: nflog.CopyPacket, Bufsize: 4096, QThresh: 1})
	if err != nil {
		return nil, err
	}
	if err := nf.RegisterWithErrorFunc(ctx, func(a nflog.Attribute) int {
		if a.Payload != nil {
			handle(*a.Payload)
		}
		return 0
	}, func(e error) int {
		if !errors.Is(e, context.Canceled) {
			onError(e)
		}
		return 0
	}); err != nil {
		_ = nf.Close()
		return nil, err
	}
	return func() { _ = nf.Close() }, nil
}
