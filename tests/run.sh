#!/usr/bin/env bash
# Lance la suite de tests bats (bats du PATH, sinon celui du sous-module).
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v bats >/dev/null 2>&1; then
  BATS=bats
else
  BATS="$ROOT/tests/vendor/bats-core/bin/bats"
fi
exec "$BATS" "${@:-$ROOT/tests}"
