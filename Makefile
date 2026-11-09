.PHONY: help build test e2e e2e-devices bench-quick clean

help:
	@echo "Common AXe commands"
	@echo "  make build        Build AXe (rebuilds IDBKit frameworks only when they changed)"
	@echo "  make test         Run default tests (non-E2E)"
	@echo "  make e2e          Run the whole E2E suite on dedicated iPhone, iPad and iPhone Duo simulators"
	@echo "  make e2e-devices  Opt-in E2E checks on connected physical iPhones and iPads; fails if none are paired"
	@echo "  make bench-quick  Quick A/B timing against a baseline payload (AXE_BENCH_UDID, AXE_BENCH_BASELINE)"
	@echo "  make clean        Clean Swift build artifacts"

build:
	scripts/build.sh frameworks-if-needed
	swift build

test:
	scripts/build.sh frameworks-if-needed
	swift test

e2e:
	scripts/run-e2e.sh

e2e-devices:
	scripts/run-e2e-devices.sh

bench-quick:
	scripts/run-bench-quick.sh

clean:
	swift package clean
