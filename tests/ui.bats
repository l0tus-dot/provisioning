#!/usr/bin/env bats

setup() {
  load helpers
  load_lib ui
}

@test "confirm in auto mode returns default without reading tty" {
  MODE=auto
  bats_run confirm "x" y </dev/null
  [ "$status" -eq 0 ]
  bats_run confirm "x" n </dev/null
  [ "$status" -eq 1 ]
}

@test "ask_value in auto mode returns default" {
  MODE=auto
  bats_run ask_value "Port SSH ?" 22 </dev/null
  [ "$status" -eq 0 ]
  [ "$output" = "22" ]
}

@test "run in dry-run does not execute" {
  local f="$BATS_TEST_TMPDIR/touched"
  DRY_RUN=1
  bats_run run touch "$f"
  [ "$status" -eq 0 ]
  [ ! -e "$f" ]
  [[ "$output" == *"[dry-run] touch"* ]]
}

@test "run returns command exit code" {
  bats_run run false
  [ "$status" -eq 1 ]
}

@test "run_with_spinner returns failure code" {
  # Appelé sous set -e dans un sous-shell : doit renvoyer 3, sans mourir avant.
  bats_run bash -c '
    set -e
    source "$1/lib/ui.sh"
    rc=0
    run_with_spinner "x" bash -c "exit 3" || rc=$?
    echo "rc=$rc"
    exit "$rc"
  ' _ "$REPO_ROOT"
  [ "$status" -eq 3 ]
  [[ "$output" == *"rc=3"* ]]
}

@test "run_with_spinner returns success code" {
  bats_run run_with_spinner "x" true
  [ "$status" -eq 0 ]
}

@test "ui works without TERM" {
  bats_run env -u TERM bash -c 'source "$1/lib/ui.sh"; term_cols; step titre' _ "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"80"* ]]
}

@test "log file receives uncolored lines" {
  local f="$BATS_TEST_TMPDIR/log.txt"
  LOG_FILE="$f"
  ok "bonjour" >/dev/null
  grep -q "bonjour" "$f"
  ! grep -q $'\033' "$f"
}

@test "warn appends to R_WARNINGS" {
  warn "attention" >/dev/null
  [ "${#R_WARNINGS[@]}" -eq 1 ]
  [[ "${R_WARNINGS[0]}" == *"attention"* ]]
}

@test "re-sourcing ui.sh keeps existing globals" {
  MODE=auto
  R_WARNINGS=("a")
  source "$REPO_ROOT/lib/ui.sh"
  [ "$MODE" = "auto" ]
  [ "${#R_WARNINGS[@]}" -eq 1 ]
}

@test "run_with_spinner spinner path (tty forced) returns failure code under set -e" {
  bats_run bash -c '
    set -e
    source "$1/lib/ui.sh"
    _ui_is_tty() { return 0; }
    rc=0
    run_with_spinner "x" bash -c "sleep 0.3; exit 3" || rc=$?
    echo "rc=$rc"
    exit "$rc"
  ' _ "$REPO_ROOT"
  [ "$status" -eq 3 ]
  [[ "$output" == *"rc=3"* ]]
}
