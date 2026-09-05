#!/usr/bin/env bash
# Host gate for kynalyzer (the Kyte Language Server). Builds against the sibling lang toolchain and runs its
# tests on THIS host OS, exiting non-zero on any failure. See ../CI-POLICY.md. Nothing merges red.
set -uo pipefail
cd "$(cd "$(dirname "$0")" && pwd)"
export PATH="$HOME/.kyte/bin:$PATH"
OS="$(uname -s)-$(uname -m)"
fail=0
step() { echo; echo ">>> $* [$OS]"; }

# kynalyzer compiles the Kyte compiler's src/root.zig as a module. In this monorepo the compiler folder is `lang`
# (not the standalone `../kyte` default), so point -Dkyte-src at it.
KYTE_SRC="../lang/src/root.zig"

step "zig build (LSP server)"
zig build -Dkyte-src="$KYTE_SRC" || fail=1

if [ $fail -eq 0 ]; then
  step "zig build test"
  zig build test -Dkyte-src="$KYTE_SRC" || fail=1
fi

echo
if [ $fail -eq 0 ]; then echo "GATE PASS  kynalyzer  [$OS]"; else echo "GATE FAIL  kynalyzer  [$OS]"; fi
exit $fail
