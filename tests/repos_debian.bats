#!/usr/bin/env bats

setup() {
  load helpers
  load_lib repos_debian
  FIX="$REPO_ROOT/tests/fixtures/sources"
  APT_ROOT="$BATS_TEST_TMPDIR/root"
  export APT_ROOT
  mkdir -p "$APT_ROOT/etc/apt/sources.list.d"
  DRY_RUN=0
  R_REPOS=()
  R_WARNINGS=()
  OS_VERSION=12
  OS_CODENAME=bookworm
  BK="$APT_ROOT/var/backups/provision"
}

@test "apt_sources_file prefers debian.sources then sources.list" {
  [ "$(apt_sources_file)" = "$APT_ROOT/etc/apt/sources.list" ]
  touch "$APT_ROOT/etc/apt/sources.list.d/debian.sources"
  [ "$(apt_sources_file)" = "$APT_ROOT/etc/apt/sources.list.d/debian.sources" ]
  [ "$(apt_sources_file "$BATS_TEST_TMPDIR/autre")" = "$BATS_TEST_TMPDIR/autre/etc/apt/sources.list" ]
}

@test "classic: adds contrib non-free non-free-firmware to bookworm lines only" {
  local f="$APT_ROOT/etc/apt/sources.list"
  cp "$FIX/bookworm.list" "$f"
  debian_add_components "$f" bookworm contrib non-free non-free-firmware
  grep -qx 'deb http://deb.debian.org/debian/ bookworm main contrib non-free non-free-firmware' "$f"
  grep -qx 'deb-src http://deb.debian.org/debian/ bookworm main contrib non-free non-free-firmware' "$f"
  grep -qx 'deb http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware' "$f"
  grep -qx 'deb http://deb.debian.org/debian/ bookworm-updates main contrib non-free non-free-firmware' "$f"
  # dépôt tiers, cdrom et commentaires intacts
  grep -qx 'deb \[arch=amd64 signed-by=/usr/share/keyrings/docker.gpg\] https://download.docker.com/linux/debian bookworm stable' "$f"
  grep -qx 'deb cdrom:\[Debian GNU/Linux 12.0.0 _Bookworm_ - Official amd64 DVD Binary-1\]/ bookworm main' "$f"
  grep -qx '# deb cdrom:\[Debian GNU/Linux 12.0.0 _Bookworm_ - Official amd64 DVD Binary-1 with firmware 20230610-10:19\]/ bookworm contrib main non-free-firmware' "$f"
  grep -qx '# bookworm-updates, to get updates before a point release is made;' "$f"
}

@test "classic: option brackets and partial components are handled without duplicates" {
  local f="$APT_ROOT/etc/apt/sources.list"
  cp "$FIX/bookworm-with-contrib.list" "$f"
  debian_add_components "$f" bookworm contrib non-free non-free-firmware
  grep -qx 'deb \[arch=amd64 signed-by=/usr/share/keyrings/x.gpg\] http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware' "$f"
  grep -qx 'deb-src http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware' "$f"
  grep -qx 'deb http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware' "$f"
  grep -qx '# deb http://deb.debian.org/debian bookworm-updates main' "$f"
  grep -qx 'deb http://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware' "$f"
}

@test "classic: file permissions are preserved" {
  local f="$APT_ROOT/etc/apt/sources.list"
  cp "$FIX/bookworm.list" "$f"
  chmod 640 "$f"
  [ "$(stat -c %a "$f")" = "640" ] || skip "permissions POSIX non gérées ici"
  debian_add_components "$f" bookworm contrib
  [ "$(stat -c %a "$f")" = "640" ]
}

@test "deb822: adds to Components" {
  OS_VERSION=13; OS_CODENAME=trixie
  local f="$APT_ROOT/etc/apt/sources.list.d/debian.sources"
  cp "$FIX/trixie.sources" "$f"
  debian_add_components "$f" trixie contrib non-free non-free-firmware
  [ "$(grep -cx 'Components: main contrib non-free non-free-firmware' "$f")" -eq 2 ]
  [ "$(grep -cx 'Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg' "$f")" -eq 2 ]
  grep -qx 'Suites: trixie trixie-updates' "$f"
  grep -qx 'Suites: trixie-security' "$f"
  grep -qx '# Modernized from /etc/apt/sources.list' "$f"
}

@test "deb822: paragraph for another suite is untouched" {
  local f="$APT_ROOT/etc/apt/sources.list.d/debian.sources"
  cp "$FIX/trixie.sources" "$f"
  debian_add_components "$f" bookworm contrib
  cmp "$f" "$FIX/trixie.sources"
  [ ! -e "$BK/$(basename "$f").bak-$(date +%Y%m%d)" ]
}

@test "components idempotent: second call changes nothing and keeps a single backup" {
  local f="$APT_ROOT/etc/apt/sources.list"
  cp "$FIX/bookworm.list" "$f"
  debian_add_components "$f" bookworm contrib non-free non-free-firmware
  cp "$f" "$BATS_TEST_TMPDIR/first"
  debian_add_components "$f" bookworm contrib non-free non-free-firmware
  cmp "$f" "$BATS_TEST_TMPDIR/first"
  cmp "$BK/sources.list.bak-$(date +%Y%m%d)" "$FIX/bookworm.list"
  [ "$(ls "$BK" | grep -c '^sources.list.bak-')" -eq 1 ]
  [ "$(ls "$APT_ROOT/etc/apt" | grep -c 'bak-')" -eq 0 ]
  [ "${#R_REPOS[@]}" -eq 1 ]
}

@test "bullseye skips non-free-firmware with warning" {
  OS_VERSION=11; OS_CODENAME=bullseye
  local f="$APT_ROOT/etc/apt/sources.list"
  cp "$FIX/bullseye.list" "$f"
  debian_add_components "$f" bullseye contrib non-free non-free-firmware
  grep -qx 'deb http://deb.debian.org/debian/ bullseye main contrib non-free' "$f"
  if grep -q 'non-free-firmware' "$f"; then false; fi
  [ "${#R_WARNINGS[@]}" -eq 1 ]
  [[ "${R_WARNINGS[0]}" == *non-free-firmware* ]]
}

@test "dry-run: no file is modified or backed up" {
  DRY_RUN=1
  local f="$APT_ROOT/etc/apt/sources.list"
  cp "$FIX/bookworm.list" "$f"
  bats_run debian_add_components "$f" bookworm contrib
  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run]"* ]]
  cmp "$f" "$FIX/bookworm.list"
  [ ! -e "$BK/$(basename "$f").bak-$(date +%Y%m%d)" ]
}

@test "backports file created once, classic when main file is classic" {
  cp "$FIX/bookworm.list" "$APT_ROOT/etc/apt/sources.list"
  debian_enable_backports bookworm contrib non-free
  local b="$APT_ROOT/etc/apt/sources.list.d/bookworm-backports.list"
  [ -f "$b" ]
  grep -qx 'deb http://deb.debian.org/debian bookworm-backports main contrib non-free' "$b"
  echo "marqueur" >> "$b"
  debian_enable_backports bookworm contrib non-free
  grep -qx marqueur "$b"
  [ "${#R_REPOS[@]}" -eq 1 ]
}

@test "backports file is deb822 when main file is deb822" {
  OS_VERSION=13; OS_CODENAME=trixie
  cp "$FIX/trixie.sources" "$APT_ROOT/etc/apt/sources.list.d/debian.sources"
  debian_enable_backports trixie contrib non-free non-free-firmware
  local b="$APT_ROOT/etc/apt/sources.list.d/trixie-backports.sources"
  [ -f "$b" ]
  grep -qx 'Types: deb' "$b"
  grep -qx 'URIs: http://deb.debian.org/debian' "$b"
  grep -qx 'Suites: trixie-backports' "$b"
  grep -qx 'Components: main contrib non-free non-free-firmware' "$b"
  grep -qx 'Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg' "$b"
}

@test "backports: dry-run creates nothing" {
  DRY_RUN=1
  cp "$FIX/bookworm.list" "$APT_ROOT/etc/apt/sources.list"
  bats_run debian_enable_backports bookworm contrib
  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run]"* ]]
  [ ! -e "$APT_ROOT/etc/apt/sources.list.d/bookworm-backports.list" ]
}

@test "debian_install_snapd installs and enables the socket" {
  stub_log apt-get
  stub_log systemctl
  debian_install_snapd
  grep -qx 'install -y snapd' "$BATS_TEST_TMPDIR/apt-get.calls"
  grep -qx 'enable --now snapd.socket' "$BATS_TEST_TMPDIR/systemctl.calls"
  [ "${#R_REPOS[@]}" -eq 1 ]
}

@test "debian_install_flatpak installs and adds flathub" {
  stub_log apt-get
  stub_log flatpak
  debian_install_flatpak
  grep -qx 'install -y flatpak' "$BATS_TEST_TMPDIR/apt-get.calls"
  grep -qx 'remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo' "$BATS_TEST_TMPDIR/flatpak.calls"
  [ "${#R_REPOS[@]}" -eq 1 ]
}

@test "debian_install_flatpak fails when apt-get fails" {
  stub apt-get 'exit 100'
  stub_log flatpak
  run_status=0; debian_install_flatpak || run_status=$?
  [ "$run_status" -ne 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/flatpak.calls" ]
  [ "${#R_REPOS[@]}" -eq 0 ]
}

@test "file without trailing newline and nothing to change is neither rewritten nor backed up" {
  local f="$APT_ROOT/etc/apt/sources.list"
  printf 'deb http://deb.debian.org/debian bookworm main contrib' > "$f"
  debian_add_components "$f" bookworm contrib
  [ "$(cat "$f")" = 'deb http://deb.debian.org/debian bookworm main contrib' ]
  [ ! -e "$BK/$(basename "$f").bak-$(date +%Y%m%d)" ]
}

@test "look-alike host notdebian.org is untouched" {
  local f="$APT_ROOT/etc/apt/sources.list"
  printf '%s\n' 'deb http://notdebian.org/x bookworm main' 'deb http://deb.debian.org/debian bookworm main' > "$f"
  debian_add_components "$f" bookworm contrib
  grep -qx 'deb http://notdebian.org/x bookworm main' "$f"
  grep -qx 'deb http://deb.debian.org/debian bookworm main contrib' "$f"
}

@test "classic: third-party mirror ending in /debian is edited, docker repo is not" {
  local f="$APT_ROOT/etc/apt/sources.list"
  printf '%s\n' \
    'deb http://mirror.ovh.net/debian/ bookworm main' \
    'deb [arch=amd64] https://download.docker.com/linux/debian bookworm stable' > "$f"
  debian_add_components "$f" bookworm contrib
  grep -qx 'deb http://mirror.ovh.net/debian/ bookworm main contrib' "$f"
  grep -qx 'deb \[arch=amd64\] https://download.docker.com/linux/debian bookworm stable' "$f"
}

@test "deb822: mirror edited, docker paragraph untouched" {
  local f="$APT_ROOT/etc/apt/sources.list.d/debian.sources"
  printf '%s\n' \
    'Types: deb' 'URIs: http://mirror.ovh.net/debian/' 'Suites: bookworm' 'Components: main' '' \
    'Types: deb' 'URIs: https://download.docker.com/linux/debian' 'Suites: bookworm' 'Components: stable' > "$f"
  debian_add_components "$f" bookworm contrib
  [ "$(grep -cx 'Components: main contrib' "$f")" -eq 1 ]
  grep -qx 'Components: stable' "$f"
}

@test "mktemp 0600 mode is not left behind when chmod --reference fails" {
  local f="$APT_ROOT/etc/apt/sources.list"
  cp "$FIX/bookworm.list" "$f"
  chmod 644 "$f"
  [ "$(stat -c %a "$f")" = "644" ] || skip "permissions POSIX non gérées ici"
  local real
  real="$(command -v chmod)"
  stub chmod "[[ \"\$1\" == --reference* ]] && exit 1; exec \"$real\" \"\$@\""
  debian_add_components "$f" bookworm contrib
  grep -q 'bookworm main contrib' "$f"
  [ "$(stat -c %a "$f")" = "644" ]
}

@test "components: R_REPOS records the change, only when the file changed" {
  local f="$APT_ROOT/etc/apt/sources.list"
  cp "$FIX/bookworm.list" "$f"
  debian_add_components "$f" bookworm contrib
  [ "${#R_REPOS[@]}" -eq 1 ]
  [[ "${R_REPOS[0]}" == "composants contrib ($f)" ]]
  debian_add_components "$f" bookworm contrib
  [ "${#R_REPOS[@]}" -eq 1 ]
}

@test "components: dry-run records a (dry-run) repo entry" {
  DRY_RUN=1
  local f="$APT_ROOT/etc/apt/sources.list"
  cp "$FIX/bookworm.list" "$f"
  bats_run debian_add_components "$f" bookworm contrib
  [ "${#R_REPOS[@]}" -eq 1 ]
  [[ "${R_REPOS[0]}" == *"(dry-run)" ]]
}

@test "snapd: waits for seeding after enabling the socket" {
  stub_log apt-get
  stub_log systemctl
  stub_log snap
  debian_install_snapd
  grep -qx 'wait system seed.loaded' "$BATS_TEST_TMPDIR/snap.calls"
}

@test "snapd: snap wait failure is only a warning" {
  stub_log apt-get
  stub_log systemctl
  stub snap 'exit 1'
  debian_install_snapd
  [ "${#R_WARNINGS[@]}" -eq 1 ]
  [ "${#R_REPOS[@]}" -eq 1 ]
}
