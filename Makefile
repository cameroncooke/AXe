.PHONY: help build test e2e clean

help:
	@echo "Common AXe commands"
	@echo "  make build   Build AXe (rebuilds IDBKit frameworks only when they changed)"
	@echo "  make test    Run default tests (non-E2E)"
	@echo "  make e2e     Run full E2E flow (build + simulator tests)"
	@echo "  make clean   Clean Swift build artifacts"

build:
	scripts/build.sh frameworks-if-needed
	swift build

test:
	scripts/build.sh frameworks-if-needed
	swift test

e2e:
	./test-runner.sh

clean:
	swift package clean
