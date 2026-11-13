#!/usr/bin/env bats

load helpers

setup() {
  load_lib update
  # shellcheck source=/dev/null
  source "$REPO_ROOT/lib/config.sh"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/lib/tools.sh"
  MODE=auto
  DRY_RUN=0
  LOG_FILE=""
  R_TOOLS_OK=()
  R_TOOLS_FAIL=()
  R_WARNINGS=()
  HAS_PARTIAL_FAILURE=0
  CRATES_TOML="$BATS_TEST_TMPDIR/crates.toml"
  # dpkg-query : paquet absent par défaut
  stub dpkg-query 'exit 1'
}

# _answers_from <réponses…> : ask_value lit ses réponses dans un fichier (il tourne en sous-shell).
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

@test "parse spec with version" {
  tool_parse pip:ansible@9.0
  [ "$T_MGR" = pip ]
  [ "$T_NAME" = ansible ]
  [ "$T_VER" = 9.0 ]
  tool_parse apt:git
  [ "$T_NAME" = git ]
  [ -z "$T_VER" ]
}

@test "alias maps common names" {
  [ "$(tool_alias node)" = nodejs ]
  [ "$(tool_alias fd)" = fd-find ]
  [ "$(tool_alias git)" = git ]
}

@test "apt resolves version prefix" {
  stub apt-cache 'cat "'"$REPO_ROOT"'/tests/fixtures/apt-cache-policy-nodejs.txt"'
  [ "$(apt_resolve_version nodejs 20)" = "20.19.2+dfsg-1" ]
  [ "$(apt_resolve_version nodejs 18)" = "18.19.1+dfsg-6ubuntu5" ]
  run_status=0
  apt_resolve_version nodejs 22 || run_status=$?
  [ "$run_status" -eq 1 ]
  # le préfixe 2 ne doit pas correspondre à 20.x (frontière numérique)
  run_status=0
  apt_resolve_version nodejs 2 || run_status=$?
  [ "$run_status" -eq 1 ]
}

@test "apt version with epoch is installed as full string" {
  stub apt-cache 'if [ "$1" = policy ]; then cat "'"$REPO_ROOT"'/tests/fixtures/apt-cache-policy-nodejs.txt"; else echo "Package: nodejs"; fi'
  stub_log apt-get
  tool_install apt:nodejs@18.19.0
  grep -q 'install -y -- nodejs=2:18.19.0+dfsg-1$' "$BATS_TEST_TMPDIR/apt-get.calls"
}

@test "apt install success with no output" {
  stub apt-cache 'for a; do :; done; echo "Package: $a"'
  stub apt-get 'exit 0'
  tool_install apt:git
  [ "${R_TOOLS_OK[0]}" = "apt:git" ]
  [ "${#R_TOOLS_FAIL[@]}" -eq 0 ]
}

@test "apt unknown package fails without fallback" {
  stub apt-cache 'exit 100'
  stub apt-get 'exit 0'
  stub_log snap
  stub_log pipx
  stub_log npm
  stub_log cargo
  status=0
  tool_install apt:inconnu || status=$?
  [ "$status" -eq 1 ]
  [ "${R_TOOLS_FAIL[0]}" = "apt:inconnu" ]
  [ "$HAS_PARTIAL_FAILURE" -eq 1 ]
  for t in snap pipx npm cargo; do [ ! -e "$BATS_TEST_TMPDIR/$t.calls" ]; done
}

@test "apt install failure is reported" {
  stub apt-cache 'for a; do :; done; echo "Package: $a"'
  stub apt-get 'exit 100'
  status=0
  tool_install apt:git || status=$?
  [ "$status" -eq 1 ]
  [ "${R_TOOLS_FAIL[0]}" = "apt:git" ]
}

@test "already installed is skipped" {
  stub dpkg-query 'case "$*" in *Version*) echo 2.0;; *) echo "install ok installed";; esac'
  stub apt-cache 'for a; do :; done; echo "Package: $a"'
  stub_log apt-get
  tool_install apt:git
  [ ! -e "$BATS_TEST_TMPDIR/apt-get.calls" ]
  [ "${R_TOOLS_OK[0]}" = "apt:git" ]
}

@test "already installed with different version only warns" {
  stub dpkg-query 'case "$*" in *Version*) echo 1:2.0-1;; *) echo "install ok installed";; esac'
  stub_log apt-get
  tool_install apt:git@3.0
  [ ! -e "$BATS_TEST_TMPDIR/apt-get.calls" ]
  [ "${#R_WARNINGS[@]}" -eq 1 ]
}

@test "invalid spec fails the tool, not the script" {
  status=0
  tool_install '--evil' || status=$?
  [ "$status" -eq 1 ]
  [ "${R_TOOLS_FAIL[0]}" = "--evil" ]
}

@test "pip installs system-wide via pipx" {
  stub pipx 'echo "$*" >> "'"$BATS_TEST_TMPDIR"'/pipx.calls"; env | grep ^PIPX_ >> "'"$BATS_TEST_TMPDIR"'/pipx.calls"; [ "$1" = list ] && exit 1; exit 0'
  tool_install pip:ansible@9.0
  grep -qx 'install -- ansible==9.0' "$BATS_TEST_TMPDIR/pipx.calls"
  grep -qx 'PIPX_HOME=/opt/pipx' "$BATS_TEST_TMPDIR/pipx.calls"
  grep -qx 'PIPX_BIN_DIR=/usr/local/bin' "$BATS_TEST_TMPDIR/pipx.calls"
}

@test "cargo uses /usr/local" {
  stub cargo 'echo "$CARGO_INSTALL_ROOT $*" >> "'"$BATS_TEST_TMPDIR"'/cargo.calls"; exit 0'
  tool_install cargo:ripgrep@14.1.0
  grep -q '^/usr/local ' "$BATS_TEST_TMPDIR/cargo.calls"
  grep -q -- '--version 14.1.0' "$BATS_TEST_TMPDIR/cargo.calls"
  grep -q -- '-- ripgrep' "$BATS_TEST_TMPDIR/cargo.calls"
}

@test "cargo detects an installed crate" {
  printf '"ripgrep 14.1.0 (registry+https://github.com/rust-lang/crates.io-index)" = ["rg"]\n' > "$CRATES_TOML"
  stub_log cargo
  tool_install cargo:ripgrep
  [ ! -e "$BATS_TEST_TMPDIR/cargo.calls" ]
}

@test "npm installs globally" {
  stub_log npm
  stub npm 'echo "$*" >> "'"$BATS_TEST_TMPDIR"'/npm.calls"; [ "$1" = ls ] && exit 1; exit 0'
  tool_install npm:typescript@5.4
  grep -qx 'install -g -- typescript@5.4' "$BATS_TEST_TMPDIR/npm.calls"
}

@test "snap retries with classic" {
  stub snap 'echo "$*" >> "'"$BATS_TEST_TMPDIR"'/snap.calls"
case "$1" in list) exit 1;; esac
case "$*" in *--classic*) exit 0;; esac
echo "error: This revision of snap requires classic confinement" >&2; exit 1'
  tool_install snap:code
  grep -qx 'install code' "$BATS_TEST_TMPDIR/snap.calls"
  grep -qx 'install code --classic' "$BATS_TEST_TMPDIR/snap.calls"
  [ "${R_TOOLS_OK[0]}" = "snap:code" ]
}

@test "snap failure without classic is not retried" {
  stub snap 'echo "$*" >> "'"$BATS_TEST_TMPDIR"'/snap.calls"
case "$1" in list) exit 1;; esac
echo "error: boom" >&2; exit 1'
  status=0
  tool_install snap:code || status=$?
  [ "$status" -eq 1 ]
  [ "$(grep -c '^install' "$BATS_TEST_TMPDIR/snap.calls")" -eq 1 ]
}

@test "snap output reaches the log" {
  LOG_FILE="$BATS_TEST_TMPDIR/log"
  stub snap 'case "$1" in list) exit 1;; esac; echo "sortie-snap"; exit 0'
  tool_install snap:code
  grep -q sortie-snap "$LOG_FILE"
}

@test "missing manager fails clearly" {
  _tools_have() { [[ "$1" != snap ]]; }
  status=0
  out="$(tool_install snap:code 2>&1)" || status=$?
  [ "$status" -eq 1 ]
  [[ "$out" == *indisponible* ]]
  tool_install snap:code 2>/dev/null || true
  [ "${R_TOOLS_FAIL[0]}" = "snap:code" ]
}

@test "dry-run installs nothing" {
  DRY_RUN=1
  stub_log apt-get
  stub apt-cache 'for a; do :; done; echo "Package: $a"'
  out="$(tool_install apt:git)"
  [[ "$out" == *"[dry-run]"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/apt-get.calls" ]
  tool_install apt:git >/dev/null
  [ "${R_TOOLS_OK[0]}" = "apt:git (dry-run)" ]
}

@test "tools_interactive refuses auto mode" {
  MODE=auto
  status=0
  tools_interactive 2>/dev/null || status=$?
  [ "$status" -eq 1 ]
}

@test "tools_interactive resolves names and specs" {
  MODE=interactive
  ANSWERS=("npm:typescript@5" "git" "node" "zzz" "git" "")
  _answers_from "${ANSWERS[@]}"
  stub apt-cache 'for a; do :; done; case "$a" in zzz) exit 100;; esac; echo "Package: $a"'
  _tools_candidates() { :; }
  tools_interactive 2>/dev/null
  [ "${TOOLS_SELECTED[*]}" = "npm:typescript@5 apt:git apt:nodejs" ]
}

@test "tools_interactive asks which manager for non-apt names" {
  MODE=interactive
  ANSWERS=("lazydocker" "snap" "")
  _answers_from "${ANSWERS[@]}"
  stub apt-cache 'exit 100'
  _tools_candidates() { printf 'snap\nnpm\n'; }
  tools_interactive 2>/dev/null
  [ "${TOOLS_SELECTED[*]}" = "snap:lazydocker" ]
}

@test "tools_interactive drops names unknown everywhere" {
  MODE=interactive
  ANSWERS=("zzz" "")
  _answers_from "${ANSWERS[@]}"
  stub apt-cache 'exit 100'
  _tools_candidates() { :; }
  tools_interactive 2>/dev/null
  [ "${#TOOLS_SELECTED[@]}" -eq 0 ]
}

@test "apt policy is parsed under a French locale" {
  stub apt-cache 'F="'"$REPO_ROOT"'/tests/fixtures/apt-cache-policy-nodejs.txt"
if [ "$LC_ALL" = C ]; then cat "$F"; else sed "s/Version table/Table de versions/" "$F"; fi'
  LC_ALL=fr_FR.UTF-8
  [ "$(apt_resolve_version nodejs 20)" = "20.19.2+dfsg-1" ]
}

@test "apt refuses a package whose name differs from the request" {
  stub apt-cache 'echo "Package: git"'
  stub_log apt-get
  status=0
  tool_install apt:g.t || status=$?
  [ "$status" -eq 1 ]
  [ "${R_TOOLS_FAIL[0]}" = "apt:g.t" ]
  [ ! -e "$BATS_TEST_TMPDIR/apt-get.calls" ]
}

@test "flatpak requires a full reverse-DNS app id" {
  stub_log flatpak
  status=0
  out="$(tool_install flatpak:gimp 2>&1)" || status=$?
  [ "$status" -eq 1 ]
  [[ "$out" == *org.gimp.GIMP* ]]
  [ ! -e "$BATS_TEST_TMPDIR/flatpak.calls" ]
}

@test "flatpak installs with a full app id" {
  stub flatpak 'echo "$*" >> "'"$BATS_TEST_TMPDIR"'/flatpak.calls"; [ "$1" = info ] && exit 1; exit 0'
  tool_install flatpak:org.gimp.GIMP
  grep -qx 'install -y --noninteractive flathub org.gimp.GIMP' "$BATS_TEST_TMPDIR/flatpak.calls"
}

@test "tool_install does not apply aliases to config specs" {
  stub apt-cache 'for a; do :; done; echo "Package: $a"'
  stub_log apt-get
  tool_install apt:node
  grep -q ' install -y -- node$' "$BATS_TEST_TMPDIR/apt-get.calls"
}
