#!/usr/bin/env bats

setup() {
  load helpers
  load_lib os
  FIX="$REPO_ROOT/tests/fixtures/os-release"
}

@test "supported distributions are detected" {
  local f id codename
  for spec in ubuntu-22.04:ubuntu:jammy ubuntu-24.04:ubuntu:noble ubuntu-26.04:ubuntu:resolute \
              debian-11:debian:bullseye debian-12:debian:bookworm debian-13:debian:trixie; do
    IFS=: read -r f id codename <<< "$spec"
    os_detect "$FIX/$f"
    [ "$OS_ID" = "$id" ]
    [ "$OS_CODENAME" = "$codename" ]
    os_supported
    [ "$(os_family)" = "$id" ]
  done
}

@test "version and pretty name are filled" {
  os_detect "$FIX/ubuntu-24.04"
  [ "$OS_VERSION" = "24.04" ]
  [[ "$OS_PRETTY" == *"Ubuntu 24.04"* ]]
}

@test "fedora is not supported" {
  os_detect "$FIX/fedora-41"
  [ "$OS_ID" = "fedora" ]
  [ "$OS_VERSION" = "41" ]
  run_status=0; os_supported || run_status=$?
  [ "$run_status" -eq 1 ]
  run_status=0; os_family >/dev/null || run_status=$?
  [ "$run_status" -eq 1 ]
}

@test "linux mint is ubuntu family but unsupported" {
  os_detect "$FIX/linuxmint-22"
  [ "$(os_family)" = "ubuntu" ]
  [ "$OS_CODENAME" = "noble" ]
  run_status=0; os_supported || run_status=$?
  [ "$run_status" -eq 1 ]
}

@test "os-release with CRLF and single quotes" {
  printf "ID='debian'\r\nVERSION_ID='12'\r\nVERSION_CODENAME=bookworm\r\nPRETTY_NAME='Debian 12'\r\n" > "$BATS_TEST_TMPDIR/os"
  os_detect "$BATS_TEST_TMPDIR/os"
  [ "$OS_ID" = "debian" ]
  [ "$OS_VERSION" = "12" ]
  [ "$OS_PRETTY" = "Debian 12" ]
  os_supported
}

@test "os-release is never sourced" {
  printf 'ID=debian\nVERSION_ID="12"\nPRETTY_NAME="x $(touch %s/pwned)"\n' "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/os"
  os_detect "$BATS_TEST_TMPDIR/os"
  [ ! -e "$BATS_TEST_TMPDIR/pwned" ]
}

@test "OS_RELEASE_FILE overrides the default path" {
  OS_RELEASE_FILE="$FIX/debian-13" os_detect
  [ "$OS_CODENAME" = "trixie" ]
}

@test "missing file fails" {
  run_status=0; os_detect "$BATS_TEST_TMPDIR/absent" 2>/dev/null || run_status=$?
  [ "$run_status" -eq 1 ]
}
