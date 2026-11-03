SHELL := /bin/sh

BUILD_ROOT ?= /pool/build/$(shell id -un)
DPKG_BUILDPACKAGE ?= /usr/bin/dpkg-buildpackage
NATIVE ?= 1
CARGO_BUILD_JOBS ?= 2

export NATIVE CARGO_BUILD_JOBS

.PHONY: build help

help:
	@printf '%s\n' \
		'build             build the scx-loader Debian source and binary packages' \
		'NATIVE=0          disable -C target-cpu=native for cross-builds' \
		'CARGO_BUILD_JOBS=... cap Cargo parallelism (default 2)'

build:
	@bash scripts/release/build-deb.sh \
		--build-root "$(BUILD_ROOT)/scx-loader" \
		--dpkg-buildpackage "$(DPKG_BUILDPACKAGE)"
