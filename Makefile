.PHONY: help build test e2e clean

help:
	@echo "Common AXe commands"
	@echo "  make build   Build AXe"
	@echo "  make test    Run default tests (non-E2E)"
	@echo "  make e2e     Run full E2E flow (build + simulator tests)"
	@echo "  make clean   Clean Swift build artifacts"

build:
	swift build

test:
	swift test

e2e:
	./test-runner.sh

clean:
	swift package clean
