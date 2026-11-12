#!/usr/bin/env bats

load helpers

setup() {
  export PROVISION_ASSUME_ROOT=1
  export OS_RELEASE_FILE="$REPO_ROOT/tests/fixtures/os-release/debian-12"
  export APT_ROOT="$BATS_TEST_TMPDIR/root"
  export REBOOT_FLAG_FILE="$BATS_TEST_TMPDIR/no-reboot"
  export PROVISION_SAVE_DIR="$BATS_TEST_TMPDIR"
  export SYSTEMD_RUN_DIR="$BATS_TEST_TMPDIR/no-systemd"
  export TMPDIR="$BATS_TEST_TMPDIR"
  unset SSH_CONNECTION SSH_CLIENT SSH_TTY
  mkdir -p "$APT_ROOT/etc/apt"
  printf 'deb http://deb.debian.org/debian bookworm main\n' > "$APT_ROOT/etc/apt/sources.list"
  LOGF="$BATS_TEST_TMPDIR/logs/provision.log"
  stub_log apt-get
  stub_log ufw
  stub dpkg-query 'exit 1'
  stub apt-cache 'for a; do n="$a"; done; echo "Package: $n"; exit 0'
}

prov() { bash "$REPO_ROOT/provision.sh" --log "$LOGF" "$@"; }

@test "invalid config exits 1 before any change" {
  run prov --config "$REPO_ROOT/tests/fixtures/config/unknown-key.conf"
  [ "$status" -eq 1 ]
  [ ! -e "$BATS_TEST_TMPDIR/apt-get.calls" ]
  [ ! -e "$BATS_TEST_TMPDIR/ufw.calls" ]
}

@test "missing config file exits 1 before any change" {
  run prov --config "$BATS_TEST_TMPDIR/absent.conf"
  [ "$status" -eq 1 ]
  [ ! -e "$BATS_TEST_TMPDIR/apt-get.calls" ]
}

@test "unsupported os refused in auto mode" {
  export OS_RELEASE_FILE="$REPO_ROOT/tests/fixtures/os-release/fedora-41"
  run prov --config "$REPO_ROOT/examples/parc.conf"
  [ "$status" -eq 1 ]
  [ ! -e "$BATS_TEST_TMPDIR/apt-get.calls" ]
}

@test "non-root without dry-run exits 1" {
  unset PROVISION_ASSUME_ROOT
  if [ "$(id -u)" -eq 0 ]; then skip "exécuté en root"; fi
  run prov --config "$REPO_ROOT/examples/parc.conf"
  [ "$status" -eq 1 ]
  [ ! -e "$BATS_TEST_TMPDIR/apt-get.calls" ]
}

@test "full auto run on debian-12 fixture" {
  run prov --config "$REPO_ROOT/examples/parc.conf"
  echo "$output"
  [ "$status" -eq 0 ]
  grep -q 'full-upgrade' "$BATS_TEST_TMPDIR/apt-get.calls"
  grep -q 'install -y -- git' "$BATS_TEST_TMPDIR/apt-get.calls"
  grep -q -- '--force enable' "$BATS_TEST_TMPDIR/ufw.calls"
  [ -s "$LOGF" ]
  ls "$BATS_TEST_TMPDIR"/logs/rapport-*.txt
}

@test "dry-run changes nothing" {
  run prov --config "$REPO_ROOT/examples/parc.conf" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run]"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/apt-get.calls" ]
  if [ -e "$BATS_TEST_TMPDIR/ufw.calls" ]; then
    # lectures seules autoris�es (ufw status), jamais de modification
    if grep -Eq 'allow|enable|default' "$BATS_TEST_TMPDIR/ufw.calls"; then false; fi
  fi
}

@test "debian components, backports and flatpak are applied" {
  cat > "$BATS_TEST_TMPDIR/d.conf" <<'CONF'
UPDATE_SYSTEM="no"
DEBIAN_COMPONENTS="contrib non-free non-free-firmware"
DEBIAN_BACKPORTS="yes"
INSTALL_FLATPAK="yes"
UFW_ENABLE="no"
CONF
  stub_log flatpak
  run prov --config "$BATS_TEST_TMPDIR/d.conf"
  echo "$output"
  [ "$status" -eq 0 ]
  grep -q 'contrib' "$APT_ROOT/etc/apt/sources.list"
  ls "$APT_ROOT"/etc/apt/sources.list.d/bookworm-backports.list
  grep -q 'install -y flatpak' "$BATS_TEST_TMPDIR/apt-get.calls"
  grep -q 'remote-add' "$BATS_TEST_TMPDIR/flatpak.calls"
}

@test "flatpak is installed on ubuntu too" {
  export OS_RELEASE_FILE="$REPO_ROOT/tests/fixtures/os-release/ubuntu-24.04"
  printf 'UPDATE_SYSTEM="no"\nINSTALL_FLATPAK="yes"\nUFW_ENABLE="no"\n' > "$BATS_TEST_TMPDIR/u.conf"
  stub_log flatpak
  run prov --config "$BATS_TEST_TMPDIR/u.conf"
  [ "$status" -eq 0 ]
  grep -q 'install -y flatpak' "$BATS_TEST_TMPDIR/apt-get.calls"
}

@test "tool failure gives exit 2" {
  printf 'UPDATE_SYSTEM="no"\nTOOLS="apt:git"\nUFW_ENABLE="no"\n' > "$BATS_TEST_TMPDIR/t.conf"
  stub apt-get 'echo "$*" >> "'"$BATS_TEST_TMPDIR"'/apt-get.calls"; case "$*" in *install*) exit 100;; esac; exit 0'
  run prov --config "$BATS_TEST_TMPDIR/t.conf"
  [ "$status" -eq 2 ]
  [[ "$output" == *"git"* ]]
}

@test "system update failure prints report and exits 1" {
  stub apt-get 'case "$*" in *full-upgrade*) exit 100;; esac; exit 0'
  run prov --config "$REPO_ROOT/examples/parc.conf"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Rapport de provisionnement"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/ufw.calls" ]
}

@test "connectivity failure exits 1" {
  stub apt-get 'exit 100'
  run prov --config "$REPO_ROOT/examples/parc.conf"
  [ "$status" -eq 1 ]
}

@test "auto mode never reads tty" {
  command -v setsid >/dev/null || skip "setsid indisponible"
  command -v timeout >/dev/null || skip "timeout indisponible"
  run timeout 30 setsid -w bash "$REPO_ROOT/provision.sh" --log "$LOGF" \
    --config "$REPO_ROOT/examples/parc.conf" </dev/null
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "example configs pass config_load" {
  source "$REPO_ROOT/lib/ui.sh"
  source "$REPO_ROOT/lib/config.sh"
  config_load "$REPO_ROOT/examples/parc.conf"
  [ "$CFG_REBOOT" = "if-needed" ]
  [ "$CFG_UFW_ENABLE" = "yes" ]
  config_load "$REPO_ROOT/examples/poste.conf"
  [ "$CFG_INSTALL_FLATPAK" = "yes" ]
  [ "$CFG_REBOOT" = "no" ]
}
