#!/usr/bin/env bats

setup() {
  load helpers
  load_lib config
  # shellcheck source=/dev/null
  source "$REPO_ROOT/lib/report.sh"
  MODE=auto
  report_init
  REBOOT_FLAG_FILE="$BATS_TEST_TMPDIR/reboot-required"
  PROVISION_SAVE_DIR="$BATS_TEST_TMPDIR/save"
  mkdir -p "$PROVISION_SAVE_DIR"
}

@test "report_init resets shared globals" {
  R_TOOLS_OK=(a); R_WARNINGS=(w); HAS_PARTIAL_FAILURE=1
  report_init
  [ "${#R_TOOLS_OK[@]}" -eq 0 ]
  [ "${#R_WARNINGS[@]}" -eq 0 ]
  [ "$HAS_PARTIAL_FAILURE" -eq 0 ]
  [[ "$START_TIME" =~ ^[0-9]+$ ]]
}

@test "exit code 2 on partial failure" {
  HAS_PARTIAL_FAILURE=1
  bats_run exit_code
  [ "$output" = "2" ]
  HAS_PARTIAL_FAILURE=0
  bats_run exit_code
  [ "$output" = "0" ]
}

@test "report lists extra ufw rules" {
  R_UFW_EXTRA=("8080/tcp ALLOW IN Anywhere")
  R_UFW_ADDED=("22/tcp")
  R_TOOLS_OK=("apt:git") R_TOOLS_FAIL=("snap:foo")
  bats_run report_print "$BATS_TEST_TMPDIR/out/rapport.txt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Règles UFW présentes hors configuration (à vérifier manuellement)"* ]]
  [[ "$output" == *"8080/tcp ALLOW IN Anywhere"* ]]
  [[ "$output" == *"apt:git"* ]]
  [[ "$output" == *"snap:foo"* ]]
  [[ "$output" == *"Aucun"* ]]
  [[ "$output" == *"Redémarrage requis : non"* ]]
  grep -q '8080/tcp' "$BATS_TEST_TMPDIR/out/rapport.txt"
}

@test "report shows reboot required when flag exists" {
  : > "$REBOOT_FLAG_FILE"
  bats_run report_print "$BATS_TEST_TMPDIR/rapport.txt"
  [[ "$output" == *"Redémarrage requis : oui"* ]]
}

@test "report file has no ANSI codes" {
  R_WARNINGS=("attention")
  report_print "$BATS_TEST_TMPDIR/rapport.txt" >/dev/null
  [ -s "$BATS_TEST_TMPDIR/rapport.txt" ]
  if grep -q $'\x1b' "$BATS_TEST_TMPDIR/rapport.txt"; then false; fi
  grep -q 'attention' "$BATS_TEST_TMPDIR/rapport.txt"
}

@test "if-needed reboots only with flag" {
  stub_log reboot
  CFG_REBOOT=if-needed
  maybe_reboot
  [ ! -e "$BATS_TEST_TMPDIR/reboot.calls" ]
  : > "$REBOOT_FLAG_FILE"
  maybe_reboot
  [ -e "$BATS_TEST_TMPDIR/reboot.calls" ]
}

@test "reboot yes reboots and no does not" {
  stub_log reboot
  CFG_REBOOT=no
  maybe_reboot
  [ ! -e "$BATS_TEST_TMPDIR/reboot.calls" ]
  CFG_REBOOT=yes
  maybe_reboot
  [ -e "$BATS_TEST_TMPDIR/reboot.calls" ]
}

@test "dry-run never reboots" {
  stub_log reboot
  CFG_REBOOT=yes DRY_RUN=1
  : > "$REBOOT_FLAG_FILE"
  maybe_reboot
  [ ! -e "$BATS_TEST_TMPDIR/reboot.calls" ]
}

@test "offer_save_config does nothing in auto mode" {
  MODE=auto
  offer_save_config
  [ -z "$(ls -A "$PROVISION_SAVE_DIR")" ]
}

@test "offer_save_config writes a 600 file in interactive mode" {
  MODE=interactive
  config_defaults
  confirm() { return 0; }
  bats_run offer_save_config
  [ "$status" -eq 0 ]
  local f
  f="$PROVISION_SAVE_DIR/provision-$(date +%Y%m%d).conf"
  [ -f "$f" ]
  [[ "$output" == *"$f"* ]]
  grep -q '^REBOOT=' "$f"
  if [[ "$(uname -s)" == Linux ]]; then
    [ "$(stat -c %a "$f")" = "600" ]
  fi
}

@test "offer_save_config declined writes nothing" {
  MODE=interactive
  config_defaults
  confirm() { return 1; }
  offer_save_config
  [ -z "$(ls -A "$PROVISION_SAVE_DIR")" ]
}

@test "error() records into R_ERRORS and the report has an Erreurs section" {
  error "apt-get full-upgrade a échoué" 2>/dev/null
  [ "${#R_ERRORS[@]}" -eq 1 ]
  bats_run report_print "$BATS_TEST_TMPDIR/rapport.txt"
  [[ "$output" == *"Erreurs"* ]]
  grep -q 'full-upgrade a échoué' "$BATS_TEST_TMPDIR/rapport.txt"
  report_init
  [ "${#R_ERRORS[@]}" -eq 0 ]
}

@test "reboot failure is only a warning" {
  CFG_REBOOT=yes
  stub reboot 'exit 1'
  maybe_reboot
  [ "${#R_WARNINGS[@]}" -eq 1 ]
}
