#!/usr/bin/env bash
# Host gate for nls (the Nova Language Server). Builds against the sibling lang toolchain and runs its
# tests on THIS host OS, exiting non-zero on any failure. See ../CI-POLICY.md. Nothing merges red.
set -uo pipefail
cd "$(cd "$(dirname "$0")" && pwd)"
export PATH="$HOME/.nova/bin:$PATH"
OS="$(uname -s)-$(uname -m)"
fail=0
step() { echo; echo ">>> $* [$OS]"; }

# nls compiles the Nova compiler's src/root.zig as a module. In this monorepo the compiler folder is `lang`
# (not the standalone `../nova` default), so point -Dnova-src at it.
NOVA_SRC="../lang/src/root.zig"

step "zig build (LSP server)"
zig build -Dnova-src="$NOVA_SRC" || fail=1

if [ $fail -eq 0 ]; then
  step "zig build test"
  zig build test -Dnova-src="$NOVA_SRC" || fail=1
fi

echo
if [ $fail -eq 0 ]; then echo "GATE PASS  nls  [$OS]"; else echo "GATE FAIL  nls  [$OS]"; fi
exit $fail
