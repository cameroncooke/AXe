.PHONY: help build test e2e clean

help:
	@echo "Common AXe commands"
	@echo "  make build   Build AXe (rebuilds IDBKit frameworks only when they changed)"
	@echo "  make test    Run default tests (non-E2E)"
	@echo "  make e2e     Run the whole E2E suite on dedicated iPhone, iPad and iPhone Duo simulators"
	@echo "  make clean   Clean Swift build artifacts"

build:
	scripts/build.sh frameworks-if-needed
	swift build

test:
	scripts/build.sh frameworks-if-needed
	swift test

e2e:
	scripts/run-e2e.sh

clean:
	swift package clean
