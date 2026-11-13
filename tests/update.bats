#!/usr/bin/env bats

load helpers

setup() {
  load_lib update
  MODE=auto
  DRY_RUN=0
  LOG_FILE=""
  R_WARNINGS=()
  CALLS="$BATS_TEST_TMPDIR/apt-get.calls"
}

@test "update runs full-upgrade with confold" {
  stub_log apt-get
  system_update
  mapfile -t lines < "$CALLS"
  [ "${lines[0]}" = "update" ]
  [[ "${lines[1]}" == *"full-upgrade"* ]]
  [[ "${lines[1]}" == *"--force-confold"* ]]
  [[ "${lines[1]}" == *"--force-confdef"* ]]
  [ "${lines[2]}" = "-y autoremove" ]
  [ "${lines[3]}" = "autoclean" ]
}

@test "DEBIAN_FRONTEND=noninteractive reaches apt-get" {
  stub apt-get 'echo "$DEBIAN_FRONTEND" >> "'"$BATS_TEST_TMPDIR"'/fe.calls"; exit 0'
  unset DEBIAN_FRONTEND
  system_update
  [ "$(sort -u "$BATS_TEST_TMPDIR/fe.calls")" = "noninteractive" ]
  [ "$(wc -l < "$BATS_TEST_TMPDIR/fe.calls")" -eq 4 ]
}

@test "upgrade failure returns 1" {
  stub apt-get 'case "$*" in *full-upgrade*) exit 100;; esac; exit 0'
  bats_run system_update
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERR"* ]]
}

@test "update failure returns 1" {
  stub apt-get 'case "$*" in update) exit 100;; esac; exit 0'
  bats_run system_update
  [ "$status" -eq 1 ]
}

@test "autoremove failure only warns" {
  stub apt-get 'case "$*" in *autoremove*) exit 100;; esac; exit 0'
  system_update
  [ "${#R_WARNINGS[@]}" -ge 1 ]
}

@test "autoclean failure only warns" {
  stub apt-get 'case "$*" in autoclean) exit 100;; esac; exit 0'
  system_update
  [ "${#R_WARNINGS[@]}" -ge 1 ]
}

@test "dry-run calls nothing" {
  stub_log apt-get
  DRY_RUN=1
  system_update
  [ ! -e "$CALLS" ]
}

@test "connectivity_check succeeds when apt-get update works" {
  stub_log apt-get
  connectivity_check
  [ "$(cat "$CALLS")" = "update" ]
}

@test "connectivity_check fails with message when apt-get update fails" {
  stub apt-get 'exit 100'
  bats_run connectivity_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"Impossible de joindre les dépôts apt"* ]]
}

@test "_apt install keeps existing config files (confdef + confold)" {
  stub_log apt-get
  _apt "x" install -y -- git
  grep -q -- '--force-confdef' "$CALLS"
  grep -q -- '--force-confold' "$CALLS"
  grep -q -- 'install -y -- git' "$CALLS"
}

@test "_apt in auto mode gives apt-get no stdin" {
  stub apt-get 'if [ -t 0 ]; then echo tty > "'"$BATS_TEST_TMPDIR"'/stdin"; else cat >> "'"$BATS_TEST_TMPDIR"'/stdin"; fi; exit 0'
  echo "données" | _apt "x" install -y git
  [ ! -s "$BATS_TEST_TMPDIR/stdin" ]
}
