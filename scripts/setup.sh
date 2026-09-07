#!/usr/bin/env bash
set -Eeuo pipefail

SETUP_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly SETUP_ROOT
missing=()

for command_name in bash curl jq; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    missing+=("$command_name")
  fi
done

printf 'Leroy development setup\n'
printf 'Repository: %s\n' "$SETUP_ROOT"

if ((${#missing[@]} > 0)); then
  printf 'Missing required tools: %s\n' "${missing[*]}" >&2
  printf 'Install them with your operating system package manager, then rerun this script.\n' >&2
  exit 3
fi

chmod +x "$SETUP_ROOT/leroy.sh" "$SETUP_ROOT/scripts/setup.sh"

config_home="${XDG_CONFIG_HOME:-${HOME}/.config}/leroy"
mkdir -p "$config_home"

printf 'Required tools are available.\n'
for optional_tool in shellcheck shfmt bats; do
  if command -v "$optional_tool" >/dev/null 2>&1; then
    printf 'Optional tool found: %s\n' "$optional_tool"
  else
    printf 'Optional tool not found: %s\n' "$optional_tool"
  fi
done

printf 'Run ./leroy.sh --help or make check to continue.\n'
