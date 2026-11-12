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
