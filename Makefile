SHELL := bash
PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin

.PHONY: help setup check syntax lint test format install uninstall

help:
	@printf '%s\n' 'Targets: setup check syntax lint test format install uninstall'

setup:
	@bash ./scripts/setup.sh

check: syntax lint test

syntax:
	@bash -n leroy.sh scripts/*.sh

lint:
	@if command -v shellcheck >/dev/null 2>&1; then shellcheck leroy.sh scripts/*.sh; else printf '%s\n' 'shellcheck not installed; skipping lint' >&2; fi

test:
	@if command -v bats >/dev/null 2>&1; then bats tests; else printf '%s\n' 'bats not installed; skipping tests' >&2; fi

format:
	@if command -v shfmt >/dev/null 2>&1; then shfmt -w -i 2 -ci leroy.sh scripts/*.sh tests/*.bash tests/*.bats; else printf '%s\n' 'shfmt is required for formatting' >&2; exit 3; fi

install:
	@install -d "$(DESTDIR)$(BINDIR)"
	@install -m 0755 leroy.sh "$(DESTDIR)$(BINDIR)/leroy"

uninstall:
	@rm -f "$(DESTDIR)$(BINDIR)/leroy"
