BINARY_NAME := watchtower
VERSION     ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo "dev")
COMMIT      ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo "unknown")
BUILD_DATE  ?= $(shell date -u +"%Y-%m-%dT%H:%M:%SZ")
LDFLAGS     := -ldflags "-X watchtower/cmd.Version=$(VERSION) -X watchtower/cmd.Commit=$(COMMIT) -X watchtower/cmd.BuildDate=$(BUILD_DATE)"

.PHONY: build test lint install clean

build:
	go build $(LDFLAGS) -o $(BINARY_NAME) .

test:
	go test ./... -v

lint:
	go vet ./...

install:
	go install $(LDFLAGS) .

clean:
	rm -f $(BINARY_NAME)
