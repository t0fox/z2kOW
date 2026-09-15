BINARY=z2k-warpd
# -trimpath и -buildvcs=false обязательны: без них в бинарь попадают локальные
# пути и git-ревизия, и сверка отгруженных байтов с пересборкой не сходится.
# Тулчейн пинован: Go 1.26+ неверно собирает MIPS soft-float под эти роутеры.
GO ?= $(HOME)/go/bin/go1.25.13
GOFLAGS=-ldflags="-s -w" -trimpath -buildvcs=false
PKG=./cmd/z2k-warpd

.PHONY: all arm64 arm mipsel mips x86_64 x86 mips64el ppc64 riscv64 local test clean aliases

all: arm64 arm mipsel mips x86_64 x86 mips64el ppc64 riscv64 aliases

arm64:
	CGO_ENABLED=0 GOOS=linux GOARCH=arm64 $(GO) build $(GOFLAGS) -o builds/$(BINARY)-linux-arm64 $(PKG)

arm:
	CGO_ENABLED=0 GOOS=linux GOARCH=arm GOARM=7 $(GO) build $(GOFLAGS) -o builds/$(BINARY)-linux-arm $(PKG)

mipsel:
	CGO_ENABLED=0 GOOS=linux GOARCH=mipsle GOMIPS=softfloat $(GO) build $(GOFLAGS) -o builds/$(BINARY)-linux-mipsel $(PKG)

mips:
	CGO_ENABLED=0 GOOS=linux GOARCH=mips GOMIPS=softfloat $(GO) build $(GOFLAGS) -o builds/$(BINARY)-linux-mips $(PKG)

x86_64:
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 $(GO) build $(GOFLAGS) -o builds/$(BINARY)-linux-amd64 $(PKG)

# АРКИ ВРОВЕНЬ С ОСТАЛЬНЫМ ПРОЕКТОМ (06.09.2026).
#
# Движок собирался под пять арок, а клиент туннеля — под девять. Человек на
# неподдержанной коробке жал «Установить WARP» и получал `unsupported
# architecture`, из которого причина не читается: он думал, что у него что-то
# сломано, а сборки под него просто не было. Разницы по существу нет — движок
# на Go и кросс-компилируется всюду, где и остальное, — так что она была
# случайной, а не решением.
x86:
	CGO_ENABLED=0 GOOS=linux GOARCH=386 $(GO) build $(GOFLAGS) -o builds/$(BINARY)-linux-x86 $(PKG)

mips64el:
	CGO_ENABLED=0 GOOS=linux GOARCH=mips64le GOMIPS64=softfloat $(GO) build $(GOFLAGS) -o builds/$(BINARY)-linux-mips64el $(PKG)

ppc64:
	CGO_ENABLED=0 GOOS=linux GOARCH=ppc64 $(GO) build $(GOFLAGS) -o builds/$(BINARY)-linux-ppc64 $(PKG)

riscv64:
	CGO_ENABLED=0 GOOS=linux GOARCH=riscv64 $(GO) build $(GOFLAGS) -o builds/$(BINARY)-linux-riscv64 $(PKG)

local:
	$(GO) build $(GOFLAGS) -o $(BINARY) $(PKG)

test:
	$(GO) test ./...

clean:
	rm -f $(BINARY) builds/$(BINARY)-linux-*

# ВРЕМЕННЫЕ СИНОНИМЫ ИМЁН (05.09.2026, подлежат удалению).
#
# Шаг обновления бинарников до p-82.8 искал сборки по ГОШНОМУ написанию арки
# (mipsle, mips64le, 386), а файлы названы по-энтварному. На этих арках он не
# находил ничего, и бинарники не обновлялись никогда. Исправленный апдейтер
# приезжает роутерам только сейчас, а применять обновление будет ещё старый —
# поэтому те же файлы отгружаются вторым именем, тем, которое он ищет.
#
# КОПИРУЕМ, А НЕ ПЕРЕСОБИРАЕМ: содержимое обязано совпадать побайтово, иначе
# сверка воспроизводимости в CI покраснеет.
#
# Удалить вместе со строками в build-matrix.tsv, когда исправленный апдейтер
# будет у всех.
aliases: mipsel
	@echo "  синонимы имён (временно)"
	@cp -f builds/$(BINARY)-linux-mipsel builds/$(BINARY)-linux-mipsle
