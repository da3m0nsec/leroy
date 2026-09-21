SHELL := bash
PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin

.PHONY: help setup check syntax lint test format install uninstall web web-manifests

help:
	@printf '%s\n' 'Targets: setup check syntax lint test format install uninstall web web-manifests'

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

web:
	@printf '%s\n' 'Constructor de demos en http://localhost:8765/ (Ctrl+C para salir)'
	@python3 -m http.server 8765 --directory web

web-manifests:
	@command -v node >/dev/null 2>&1 || { printf '%s\n' 'node is required to emit builder manifests' >&2; exit 3; }
	@for scenario in $$(node web/tools/emit-manifests.mjs); do \
		printf '%s: ' "$$scenario"; \
		node web/tools/emit-manifests.mjs "$$scenario" | jq -c '{schemaVersion, id: .metadata.id, personas: (.personas | length)}'; \
	done

install:
	@install -d "$(DESTDIR)$(BINDIR)"
	@install -m 0755 leroy.sh "$(DESTDIR)$(BINDIR)/leroy"

uninstall:
	@rm -f "$(DESTDIR)$(BINDIR)/leroy"
