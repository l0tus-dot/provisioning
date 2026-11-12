#!/usr/bin/env bats

load helpers

setup() {
  load_lib services
  MODE=auto
  DRY_RUN=0
  LOG_FILE=""
  R_TOOLS_OK=()
  R_SVC_MASKED=()
  R_SVC_DISABLED=()
  R_WARNINGS=()
  HAS_PARTIAL_FAILURE=0
  CFG_SERVICES_MASK=""
  CFG_SERVICES_DISABLE=""
  SYSTEMD_RUN_DIR="$BATS_TEST_TMPDIR/systemd"
  mkdir -p "$SYSTEMD_RUN_DIR"
  : > "$BATS_TEST_TMPDIR/units"
  _stub_systemctl 0
}

# _stub_systemctl <code mask> : list-unit-files lit le fichier "units" ; le reste est journalisé.
_stub_systemctl() {
  stub systemctl 'if [ "$1" = list-unit-files ]; then cat "'"$BATS_TEST_TMPDIR"'/units"; exit 0; fi
echo "$*" >> "'"$BATS_TEST_TMPDIR"'/systemctl.calls"
if [ "$1" = mask ]; then exit '"$1"'; fi
exit 0'
}

_units() { printf '%s enabled enabled\n' "$@" > "$BATS_TEST_TMPDIR/units"; }

# ask_value tourne en sous-shell : réponses lues dans un fichier.
_answers_from() {
  printf '%s\n' "$@" >"$BATS_TEST_TMPDIR/answers"
  : > "$BATS_TEST_TMPDIR/answers.pos"
  ask_value() {
    local n
    echo x >> "$BATS_TEST_TMPDIR/answers.pos"
    n=$(wc -l < "$BATS_TEST_TMPDIR/answers.pos")
    sed -n "${n}p" "$BATS_TEST_TMPDIR/answers"
  }
}

@test "exact unit match" {
  _units cups-browsed.service
  [ -z "$(service_units cups)" ]
  [ "$(service_units cups-browsed)" = cups-browsed.service ]
}

@test "timer handled" {
  _units apt-daily.service apt-daily.timer
  service_apply mask apt-daily
  grep -qx 'mask -- apt-daily.service apt-daily.timer' "$BATS_TEST_TMPDIR/systemctl.calls"
  grep -qx 'stop -- apt-daily.service apt-daily.timer' "$BATS_TEST_TMPDIR/systemctl.calls"
  [[ "${R_SVC_MASKED[*]}" == *apt-daily* ]]
}

@test "disable uses --now" {
  _units cups.service
  service_apply disable cups
  grep -qx 'disable --now -- cups.service' "$BATS_TEST_TMPDIR/systemctl.calls"
  [ "${R_SVC_DISABLED[0]}" = cups ]
}

@test "absent service is ignored" {
  service_apply mask cups
  [ ! -e "$BATS_TEST_TMPDIR/systemctl.calls" ]
  [ "${#R_SVC_MASKED[@]}" -eq 0 ]
}

@test "ssh is refused" {
  _units ssh.service sshd.service
  bats_run service_apply mask ssh
  [ "$status" -eq 1 ]
  service_apply mask sshd || true
  [ "$HAS_PARTIAL_FAILURE" -eq 1 ]
  [ ! -e "$BATS_TEST_TMPDIR/systemctl.calls" ]
}

@test "snapd refused after snap tool install" {
  _units snapd.service
  R_TOOLS_OK=("snap:code (dry-run)")
  bats_run service_apply mask snapd
  [ "$status" -eq 1 ]
  [ ! -e "$BATS_TEST_TMPDIR/systemctl.calls" ]
}

@test "snapd masked without snap tools, with sensitive warning" {
  _units snapd.service
  R_TOOLS_OK=("apt:git")
  service_apply mask snapd
  grep -qx 'mask -- snapd.service' "$BATS_TEST_TMPDIR/systemctl.calls"
  [[ "${R_WARNINGS[*]}" == *sensible* ]]
}

@test "failed mask sets partial failure" {
  _units cups.service
  _stub_systemctl 1
  service_apply mask cups || true
  [ "$HAS_PARTIAL_FAILURE" -eq 1 ]
  [ "${#R_SVC_MASKED[@]}" -eq 0 ]
}

@test "dry-run records suffix and runs nothing" {
  _units cups.service
  DRY_RUN=1
  service_apply mask cups
  [ "${R_SVC_MASKED[0]}" = "cups (dry-run)" ]
  [ ! -e "$BATS_TEST_TMPDIR/systemctl.calls" ]
}

@test "auto mode applies config lists" {
  _units cups.service rsyslog.service
  CFG_SERVICES_MASK="cups"
  CFG_SERVICES_DISABLE="rsyslog"
  manage_services
  grep -qx 'mask -- cups.service' "$BATS_TEST_TMPDIR/systemctl.calls"
  grep -qx 'disable --now -- rsyslog.service' "$BATS_TEST_TMPDIR/systemctl.calls"
}

@test "bulk option skips sensitive" {
  _units cups.service rsyslog.service
  MODE=interactive
  _answers_from B
  manage_services
  grep -qx 'mask -- cups.service' "$BATS_TEST_TMPDIR/systemctl.calls"
  if grep -q rsyslog "$BATS_TEST_TMPDIR/systemctl.calls"; then false; fi
  [ "$CFG_SERVICES_MASK" = cups ]
}

@test "option A offers sensitive one by one" {
  _units cups.service rsyslog.service
  MODE=interactive
  # A, puis cups (liste sûre) -> 3, rsyslog (sensible) -> 2
  _answers_from A 3 2
  manage_services
  grep -qx 'disable --now -- rsyslog.service' "$BATS_TEST_TMPDIR/systemctl.calls"
  if grep -q cups "$BATS_TEST_TMPDIR/systemctl.calls"; then false; fi
}

@test "option D ignores services" {
  _units cups.service
  MODE=interactive
  _answers_from D
  manage_services
  [ ! -e "$BATS_TEST_TMPDIR/systemctl.calls" ]
}

@test "no systemd skips with warning" {
  rmdir "$SYSTEMD_RUN_DIR"
  _units cups.service
  CFG_SERVICES_MASK="cups"
  manage_services
  [ ! -e "$BATS_TEST_TMPDIR/systemctl.calls" ]
  [[ "${R_WARNINGS[*]}" == *systemd* ]]
}
