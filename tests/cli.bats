#!/usr/bin/env bats

setup() {
  load helpers
}

@test "--help prints usage and exits 0" {
  run bash "$REPO_ROOT/provision.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--config"* ]]
}

@test "--version prints version" {
  run bash "$REPO_ROOT/provision.sh" --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"provision 2.0.0"* ]]
}

@test "unknown option exits 1" {
  run bash "$REPO_ROOT/provision.sh" --bogus
  [ "$status" -eq 1 ]
}

@test "--config sets MODE=auto and CONFIG_FILE" {
  run bash -c 'source "$1/provision.sh"; parse_args --config /x.conf --dry-run --log /y.log; echo "$MODE $CONFIG_FILE $DRY_RUN $LOG_FILE"' _ "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "auto /x.conf 1 /y.log" ]
}

@test "bundle is standalone" {
  out="$BATS_TEST_TMPDIR/dist/provision.sh"
  run bash "$REPO_ROOT/scripts/bundle.sh" "$out"
  [ "$status" -eq 0 ]
  [ -f "$out" ]
  bash -n "$out"
  # Le bundle seul, dans un dossier vide, sans lib/.
  mkdir "$BATS_TEST_TMPDIR/alone"
  cp "$out" "$BATS_TEST_TMPDIR/alone/provision.sh"
  run bash "$BATS_TEST_TMPDIR/alone/provision.sh" --version
  [ "$status" -eq 0 ]
  [ "$output" = "provision 2.0.0" ]
  run grep -c 'source "\$LIB_DIR' "$out"
  [ "$output" = "0" ]
  run grep -c 'shellcheck source=' "$out"
  [ "$output" = "0" ]
  # Un seul shebang (celui de l'en-tête).
  run grep -c '^#!' "$out"
  [ "$output" = "1" ]
}
