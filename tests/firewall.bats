#!/usr/bin/env bats

load helpers

setup() {
  load_lib update
  # shellcheck source=/dev/null
  source "$REPO_ROOT/lib/config.sh"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/lib/firewall.sh"
  MODE=auto
  DRY_RUN=0
  LOG_FILE=""
  R_UFW_ADDED=()
  R_UFW_EXTRA=()
  R_WARNINGS=()
  HAS_PARTIAL_FAILURE=0
  unset SSH_CONNECTION SSH_CLIENT SUDO_USER PROC_ROOT UFW_ADDED_FILE UFW_FAIL
  CFG_UFW_ENABLE=yes
  CFG_UFW_SSH_PORT=auto
  CFG_UFW_ALLOW=""
  SSHD_CONFIG="$BATS_TEST_TMPDIR/sshd_config"
  UFW_STATUS_FILE="$REPO_ROOT/tests/fixtures/ufw-status-inactive.txt"
  CALLS="$BATS_TEST_TMPDIR/ufw.calls"
  : > "$CALLS"
  _stub_ufw
  stub sshd 'exit 1'
}

# Faux ufw : journalise les appels, `status` imprime $UFW_STATUS_FILE.
# $UFW_FAIL (motif sur "$1 $2") fait échouer l'appel correspondant.
_stub_ufw() {
  stub ufw "echo \"\$*\" >> \"$CALLS\"
[ -n \"\${UFW_FAIL:-}\" ] && [ \"\$1 \$2\" = \"\$UFW_FAIL\" ] && exit 1
[ \"\$1\" = status ] && cat \"\$UFW_STATUS_FILE\"
[ \"\$1 \$2\" = \"show added\" ] && [ -n \"\${UFW_ADDED_FILE:-}\" ] && cat \"\$UFW_ADDED_FILE\"
exit 0"
  export UFW_STATUS_FILE CALLS
}

_status() { UFW_STATUS_FILE="$REPO_ROOT/tests/fixtures/ufw-status-$1.txt"; export UFW_STATUS_FILE; }

# --- sshd_port ---

@test "sshd port from sshd -T" {
  stub sshd 'printf "port 2222\naddressfamily any\n"'
  [ "$(sshd_port)" = 2222 ]
}

@test "sshd port falls back to sshd_config, ignoring comments and case" {
  printf '#Port 22\n  # Port 99\nPORT 2200\n' > "$SSHD_CONFIG"
  [ "$(sshd_port)" = 2200 ]
}

@test "sshd port reads Include'd conf files" {
  mkdir -p "$BATS_TEST_TMPDIR/sshd_config.d"
  printf 'Include %s/sshd_config.d/*.conf\n#Port 22\n' "$BATS_TEST_TMPDIR" > "$SSHD_CONFIG"
  printf 'Port 2345\n' > "$BATS_TEST_TMPDIR/sshd_config.d/10-port.conf"
  [ "$(sshd_port)" = 2345 ]
}

@test "sshd port defaults to 22" {
  [ "$(sshd_port)" = 22 ]
}

@test "sshd port rejects invalid values" {
  stub sshd 'echo "port 99999"'
  printf 'Port abc\n' > "$SSHD_CONFIG"
  [ "$(sshd_port)" = 22 ]
}

# --- ufw_current_rules ---

@test "current rules empty when ufw inactive" {
  _status inactive
  [ -z "$(ufw_current_rules)" ]
}

@test "current rules parsed, v6 deduped, ranges kept" {
  _status active
  bats_run ufw_current_rules
  [ "$output" = $'22/tcp\n80/tcp\n3306/tcp\n443\n8000:8100/tcp' ]
}

@test "current rules: OpenSSH profile counts as 22/tcp, others ignored" {
  _status openssh
  [ "$(ufw_current_rules)" = "22/tcp" ]
}

@test "current rules: source-limited kept, DENY/OUT/profiles dropped" {
  _status source
  [ "$(ufw_current_rules)" = "22/tcp" ]
}

@test "current rules: verbose-style ALLOW IN" {
  _status verbose
  [ "$(ufw_current_rules)" = $'22/tcp\n80' ]
}

# --- ufw_plan ---

@test "ssh guard overrides none" {
  export SSH_CONNECTION="1.2.3.4 5 6.7.8.9 22"
  stub sshd 'echo "port 2222"'
  ufw_plan none 80/tcp > "$BATS_TEST_TMPDIR/plan" 2>/dev/null
  grep -qx '2222/tcp' "$BATS_TEST_TMPDIR/plan"
  grep -qx '80/tcp' "$BATS_TEST_TMPDIR/plan"
  [ "${#R_WARNINGS[@]}" -gt 0 ]
}

@test "no guard outside ssh" {
  stub sshd 'echo "port 2222"'
  ufw_plan none 80/tcp > "$BATS_TEST_TMPDIR/plan"
  if grep -q '2222' "$BATS_TEST_TMPDIR/plan"; then false; fi
  [ "$(cat "$BATS_TEST_TMPDIR/plan")" = "80/tcp" ]
  [ "${#R_WARNINGS[@]}" -eq 0 ]
}

@test "SSH_CLIENT alone triggers the guard" {
  export SSH_CLIENT="1.2.3.4 5 22"
  ufw_plan none > "$BATS_TEST_TMPDIR/plan" 2>/dev/null
  [ "$(cat "$BATS_TEST_TMPDIR/plan")" = "22/tcp" ]
}

@test "plan auto resolves sshd port, first, deduped" {
  stub sshd 'echo "port 2222"'
  bats_run ufw_plan auto 80/tcp 2222/tcp 80/tcp
  [ "$output" = $'2222/tcp\n80/tcp' ]
}

@test "ssh session with port differing from sshd adds both" {
  export SSH_CONNECTION="1.2.3.4 5 6.7.8.9 2222"
  stub sshd 'echo "port 2222"'
  ufw_plan 22 > "$BATS_TEST_TMPDIR/plan" 2>/dev/null
  [ "$(cat "$BATS_TEST_TMPDIR/plan")" = $'2222/tcp\n22/tcp' ]
  [ "${#R_WARNINGS[@]}" -gt 0 ]
}

@test "numeric ssh port outside ssh session is used as is" {
  stub sshd 'echo "port 2222"'
  bats_run ufw_plan 2200
  [ "$output" = "2200/tcp" ]
}

# --- ufw_apply ---

@test "order: ssh rule, then defaults, then other rules, then enable" {
  stub sshd 'echo "port 2222"'
  CFG_UFW_SSH_PORT=auto
  ufw_apply 80/tcp 2222/tcp
  local allow80 allow22 enable deny out
  allow22=$(grep -n '^allow 2222/tcp' "$CALLS" | cut -d: -f1)
  deny=$(grep -n '^default deny incoming' "$CALLS" | cut -d: -f1)
  out=$(grep -n '^default allow outgoing' "$CALLS" | cut -d: -f1)
  allow80=$(grep -n '^allow 80/tcp' "$CALLS" | cut -d: -f1)
  enable=$(grep -n -- '^--force enable' "$CALLS" | cut -d: -f1)
  [ "$allow22" -lt "$deny" ]
  [ "$deny" -lt "$out" ]
  [ "$out" -lt "$allow80" ]
  [ "$allow80" -lt "$enable" ]
  [ "${R_UFW_ADDED[*]}" = "2222/tcp 80/tcp" ]
}

@test "ssh rule is applied first even if listed last" {
  stub sshd 'echo "port 2222"'
  ufw_apply 80/tcp 2222/tcp
  [ "$(grep -n '^allow 2222/tcp' "$CALLS" | cut -d: -f1)" -lt "$(grep -n '^allow 80/tcp' "$CALLS" | cut -d: -f1)" ]
}

@test "ssh rule failure: ufw NOT enabled, returns 1" {
  stub sshd 'echo "port 2222"'
  export UFW_FAIL="allow 2222/tcp"
  bats_run ufw_apply 2222/tcp 80/tcp
  [ "$status" -eq 1 ]
  if grep -q -- '--force enable' "$CALLS"; then false; fi
  if grep -q '^allow 80/tcp' "$CALLS"; then false; fi
  if grep -q '^default' "$CALLS"; then false; fi
}

@test "non-ssh rule failure: partial failure, still enabled" {
  export UFW_FAIL="allow 80/tcp"
  ufw_apply 22/tcp 80/tcp
  [ "$HAS_PARTIAL_FAILURE" = 1 ]
  grep -q -- '--force enable' "$CALLS"
}

@test "existing rule not re-added" {
  _status active
  ufw_apply 22/tcp 80/tcp 9000/tcp
  if grep -q '^allow 80/tcp' "$CALLS"; then false; fi
  grep -q '^allow 22/tcp' "$CALLS"
  grep -q '^allow 9000/tcp' "$CALLS"
  [ "${R_UFW_ADDED[*]}" = "9000/tcp" ]
}

@test "bare port rule covers port/tcp" {
  _status active
  ufw_apply 443/tcp
  if grep -q '^allow 443/tcp' "$CALLS"; then false; fi
}

@test "OpenSSH profile covers 22/tcp" {
  _status openssh
  ufw_apply 22/tcp
  grep -q '^allow 22/tcp' "$CALLS"
  [ "${#R_UFW_ADDED[@]}" -eq 0 ]
  grep -q -- '--force enable' "$CALLS"
}

@test "extra rules reported not deleted" {
  _status active
  ufw_apply 22/tcp 80/tcp
  [[ " ${R_UFW_EXTRA[*]} " == *" 3306/tcp "* ]]
  [[ " ${R_UFW_EXTRA[*]} " != *" 22/tcp "* ]]
  if grep -q 'delete' "$CALLS"; then false; fi
}

@test "installs ufw via apt when missing" {
  _fw_have() { [[ -e "$BATS_TEST_TMPDIR/ufw.installed" ]]; }
  stub apt-get "echo \"\$*\" >> \"$BATS_TEST_TMPDIR/apt-get.calls\"; touch \"$BATS_TEST_TMPDIR/ufw.installed\""
  ufw_apply 22/tcp
  grep -q 'install ufw' "$BATS_TEST_TMPDIR/apt-get.calls"
  grep -q -- '--force enable' "$CALLS"
}

@test "ufw install failure returns 1" {
  _fw_have() { return 1; }
  stub apt-get 'exit 100'
  bats_run ufw_apply 22/tcp
  [ "$status" -eq 1 ]
}

@test "dry-run: no ufw changes" {
  DRY_RUN=1
  ufw_apply 22/tcp
  if grep -q -e '^allow' -e 'enable' -e '^default' "$CALLS"; then false; fi
  [ "${R_UFW_ADDED[*]}" = "22/tcp (dry-run)" ]
}

@test "--no-enable skips the enable step and warns when inactive" {
  ufw_apply --no-enable 22/tcp
  [ "${#R_WARNINGS[@]}" -gt 0 ]
  grep -q '^allow 22/tcp' "$CALLS"
  if grep -q -- '--force enable' "$CALLS"; then false; fi
}

# --- configure_firewall ---

@test "UFW_ENABLE=no leaves firewall alone" {
  CFG_UFW_ENABLE=no
  configure_firewall
  [ ! -s "$CALLS" ]
}

@test "configure_firewall auto mode: ssh + allow list then enable" {
  stub sshd 'echo "port 2222"'
  CFG_UFW_ALLOW="80/tcp 8000:8100/tcp"
  configure_firewall
  [ "$(grep '^allow' "$CALLS" | tr '\n' ',')" = "allow 2222/tcp,allow 80/tcp,allow 8000:8100/tcp," ]
  grep -q -- '--force enable' "$CALLS"
}

@test "configure_firewall: ssh rule failure returns 1 and flags partial failure" {
  stub sshd 'echo "port 2222"'
  export UFW_FAIL="allow 2222/tcp"
  bats_run configure_firewall
  [ "$status" -eq 1 ]
  if grep -q -- '--force enable' "$CALLS"; then false; fi
}

@test "configure_firewall: SSH session + none still opens sshd port" {
  export SSH_CONNECTION="1.2.3.4 5 6.7.8.9 22"
  CFG_UFW_SSH_PORT=none
  configure_firewall >/dev/null 2>&1
  grep -q '^allow 22/tcp' "$CALLS"
  [ "${#R_WARNINGS[@]}" -gt 0 ]
}

# --- interactif ---

# _script_confirm <réponses y/n…> et _script_ask <valeurs…> : remplacent confirm/ask_value
# (fichiers de position, car appelés en sous-shell).
_script_inputs() {
  printf '%s\n' "$1" > "$BATS_TEST_TMPDIR/conf.in"; : > "$BATS_TEST_TMPDIR/conf.pos"
  printf '%s\n' "$2" > "$BATS_TEST_TMPDIR/ask.in"; : > "$BATS_TEST_TMPDIR/ask.pos"
  confirm() {
    local n; echo x >> "$BATS_TEST_TMPDIR/conf.pos"; n=$(wc -l < "$BATS_TEST_TMPDIR/conf.pos")
    [[ "$(sed -n "${n}p" "$BATS_TEST_TMPDIR/conf.in")" == y ]]
  }
  ask_value() {
    local n; echo x >> "$BATS_TEST_TMPDIR/ask.pos"; n=$(wc -l < "$BATS_TEST_TMPDIR/ask.pos")
    sed -n "${n}p" "$BATS_TEST_TMPDIR/ask.in"
  }
}

@test "interactive: ssh port, http, custom rules, activate" {
  MODE=interactive
  # confirm: configurer, ssh, http, https, activer
  _script_inputs $'y\ny\ny\nn\ny' $'2200\n5432\n8080/tcp\nfin'
  configure_firewall >/dev/null 2>&1
  [ "$CFG_UFW_SSH_PORT" = 2200 ]
  [ "$CFG_UFW_ALLOW" = "80/tcp 5432 8080/tcp" ]
  [ "$(grep '^allow' "$CALLS" | tr '\n' ',')" = "allow 2200/tcp,allow 80/tcp,allow 5432,allow 8080/tcp," ]
  grep -q -- '--force enable' "$CALLS"
}

@test "interactive: invalid port re-asked at most 3 times then falls back to auto" {
  MODE=interactive
  _script_inputs $'y\ny\nn\nn\ny' $'abc\nabc\nabc\nfin'
  configure_firewall >/dev/null 2>&1
  [ "$CFG_UFW_SSH_PORT" = auto ]
  grep -q '^allow 22/tcp' "$CALLS"
}

@test "interactive: invalid custom rules stop after 3 in a row" {
  MODE=interactive
  _script_inputs $'y\nn\nn\nn\ny' $'bad\nbad\nbad\nbad\nbad'
  configure_firewall >/dev/null 2>&1
  [ "$(wc -l < "$BATS_TEST_TMPDIR/ask.pos")" -eq 3 ]
  [ -z "$CFG_UFW_ALLOW" ]
}

@test "interactive: ssh refused outside ssh session adds no ssh rule" {
  MODE=interactive
  _script_inputs $'y\nn\nn\nn\ny' $'fin'
  configure_firewall >/dev/null 2>&1
  [ "$CFG_UFW_SSH_PORT" = none ]
  if grep -q '^allow' "$CALLS"; then false; fi
}

@test "interactive: not activating applies rules without enable" {
  MODE=interactive
  _script_inputs $'y\ny\nn\nn\nn' $'22\nfin'
  configure_firewall >/dev/null 2>&1
  grep -q '^allow 22/tcp' "$CALLS"
  if grep -q -- '--force enable' "$CALLS"; then false; fi
}

@test "interactive: declining configuration touches nothing" {
  MODE=interactive
  _script_inputs $'n' ''
  configure_firewall >/dev/null 2>&1
  [ ! -s "$CALLS" ]
}

# --- invariants anti-lockout (revue 1) ---

@test "lockout: ipv4 source-limited + v6 open still calls allow 22/tcp before enable" {
  _status v4-limited
  ufw_apply 22/tcp
  [ "$(grep -n '^allow 22/tcp' "$CALLS" | cut -d: -f1)" -lt "$(grep -n -- '--force enable' "$CALLS" | cut -d: -f1)" ]
  [ "${R_UFW_ADDED[*]}" = "22/tcp" ]
}

@test "lockout: v6-only rule does not count for ipv4" {
  _status v6only
  ufw_apply 22/tcp 80/tcp
  grep -q '^allow 22/tcp' "$CALLS"
  grep -q '^allow 80/tcp' "$CALLS"
}

@test "lockout: non-ssh rule needs an ipv4 open rule to be skipped" {
  _status v4-limited
  ufw_apply 22/tcp
  UFW_STATUS_FILE="$REPO_ROOT/tests/fixtures/ufw-status-v6only.txt"
  : > "$CALLS"
  ufw_apply 22/tcp 22000/tcp
  grep -q '^allow 22000/tcp' "$CALLS"
}

@test "LIMIT rules are present (never converted to allow) and reported as extra" {
  _status limit
  stub sshd 'echo "port 22"'
  ufw_apply 22/tcp 25/tcp 80/tcp
  if grep -q '^allow 22/tcp' "$CALLS"; then false; fi
  if grep -q '^allow 25/tcp' "$CALLS"; then false; fi
  grep -q '^allow 80/tcp' "$CALLS"
  ufw_apply 80/tcp
  [[ " ${R_UFW_EXTRA[*]} " == *" 22/tcp "* ]]
  [[ " ${R_UFW_EXTRA[*]} " == *" 25/tcp "* ]]
}

@test "current rules include LIMIT" {
  _status limit
  [ "$(ufw_current_rules)" = $'22/tcp\n25/tcp' ]
}

@test "inactive: rules read from ufw show added" {
  _status inactive
  UFW_ADDED_FILE="$REPO_ROOT/tests/fixtures/ufw-added-inactive.txt"; export UFW_ADDED_FILE
  [ "$(ufw_current_rules)" = $'22/tcp\n2222/tcp\n3306/tcp\n8000:8100/tcp' ]
}

@test "inactive: extras reported and present rules skipped from show added" {
  _status inactive
  UFW_ADDED_FILE="$REPO_ROOT/tests/fixtures/ufw-added-inactive.txt"; export UFW_ADDED_FILE
  ufw_apply 22/tcp 8000:8100/tcp
  if grep -q '^allow 8000:8100/tcp' "$CALLS"; then false; fi
  [[ " ${R_UFW_EXTRA[*]} " == *" 3306/tcp "* ]]
  [[ " ${R_UFW_EXTRA[*]} " == *" 2222/tcp "* ]]
}

@test "--no-enable on an already active ufw does not warn" {
  _status active
  ufw_apply --no-enable 22/tcp
  [ "${#R_WARNINGS[@]}" -eq 0 ]
}

# --- détection de session SSH (sudo) ---

# _fake_proc <pid:comm:ppid…> : arbre /proc factice ; le premier élément doit être $$.
_fake_proc() {
  PROC_ROOT="$BATS_TEST_TMPDIR/proc"; export PROC_ROOT
  local e pid comm ppid
  for e in "$@"; do
    IFS=: read -r pid comm ppid <<< "$e"
    mkdir -p "$PROC_ROOT/$pid"
    printf '%s (%s) S %s 1 1 0\n' "$pid" "$comm" "$ppid" > "$PROC_ROOT/$pid/stat"
  done
}

@test "sudo without SSH_CONNECTION: sshd ancestor detected" {
  export SUDO_USER=bob
  _fake_proc "$$:bash:500" "500:sudo:400" "400:sshd-session:300" "300:sshd:1"
  _fw_in_ssh_session
}

@test "sshd as comm with spaces/parens is parsed" {
  export SUDO_USER=bob
  _fake_proc "$$:my (x) sh:500" "500:sshd:1"
  _fw_in_ssh_session
}

@test "sudo with no sshd ancestor: not an ssh session" {
  export SUDO_USER=bob
  _fake_proc "$$:bash:500" "500:login:1"
  if _fw_in_ssh_session; then false; fi
}

@test "no SUDO_USER (su -): sshd ancestor is still detected" {
  _fake_proc "$$:bash:500" "500:su:400" "400:sshd:1"
  _fw_in_ssh_session
}

@test "no /proc: not detected" {
  export SUDO_USER=bob PROC_ROOT="$BATS_TEST_TMPDIR/nope"
  if _fw_in_ssh_session; then false; fi
}

@test "ancestor walk is capped (cycle)" {
  export SUDO_USER=bob
  _fake_proc "$$:bash:500" "500:bash:600" "600:bash:500"
  if _fw_in_ssh_session; then false; fi
}

@test "sudo + sshd ancestor + none: sshd port forced" {
  export SUDO_USER=bob
  _fake_proc "$$:bash:500" "500:sshd:1"
  stub sshd 'echo "port 2222"'
  ufw_plan none > "$BATS_TEST_TMPDIR/plan" 2>/dev/null
  [ "$(cat "$BATS_TEST_TMPDIR/plan")" = "2222/tcp" ]
}

@test "connection port (4th field of SSH_CONNECTION) is allowed too" {
  export SSH_CONNECTION="1.2.3.4 5 6.7.8.9 2022"
  stub sshd 'echo "port 22"'
  ufw_plan auto > "$BATS_TEST_TMPDIR/plan" 2>/dev/null
  [ "$(cat "$BATS_TEST_TMPDIR/plan")" = $'22/tcp\n2022/tcp' ]
}

@test "connection port deduped with sshd port" {
  export SSH_CONNECTION="1.2.3.4 5 6.7.8.9 22"
  ufw_plan auto > "$BATS_TEST_TMPDIR/plan" 2>/dev/null
  [ "$(cat "$BATS_TEST_TMPDIR/plan")" = "22/tcp" ]
}

@test "interactive: declining SSH inside an ssh session still adds the sshd port" {
  MODE=interactive
  export SSH_CONNECTION="1.2.3.4 5 6.7.8.9 22"
  stub sshd 'echo "port 2222"'
  _script_inputs $'y\nn\nn\nn\ny' $'fin'
  configure_firewall >/dev/null 2>&1
  [ "$CFG_UFW_SSH_PORT" = none ]
  grep -q '^allow 2222/tcp' "$CALLS"
  grep -q '^allow 22/tcp' "$CALLS"
  [ "${#R_WARNINGS[@]}" -gt 0 ]
}

@test "defense in depth: ssh session forces ssh ports even if not requested" {
  export SSH_CONNECTION="1.2.3.4 5 6.7.8.9 2022"
  stub sshd 'echo "port 2222"'
  ufw_apply 80/tcp
  grep -q '^allow 2222/tcp' "$CALLS"
  grep -q '^allow 2022/tcp' "$CALLS"
  [ "$(grep -n '^allow 2222/tcp' "$CALLS" | cut -d: -f1)" -lt "$(grep -n -- '--force enable' "$CALLS" | cut -d: -f1)" ]
  [ "$(grep -n '^allow 2022/tcp' "$CALLS" | cut -d: -f1)" -lt "$(grep -n '^default deny' "$CALLS" | cut -d: -f1)" ]
  [[ " ${R_UFW_EXTRA[*]:-} " != *" 2222/tcp "* ]]
}

@test "defense in depth: ssh failure blocks enable on direct ufw_apply" {
  export SSH_CONNECTION="1.2.3.4 5 6.7.8.9 22"
  export UFW_FAIL="allow 22/tcp"
  bats_run ufw_apply 80/tcp
  [ "$status" -eq 1 ]
  if grep -q -- '--force enable' "$CALLS"; then false; fi
}

# --- ports sshd multiples et SSH_CONNECTION hérité d'un ancêtre ---

# _proc_environ <pid> <KEY=VAL…> : écrit <pid>/environ (séparateur NUL).
_proc_environ() {
  local pid="$1"
  shift
  printf '%s\0' "$@" > "$PROC_ROOT/$pid/environ"
}

@test "sshd_ports lists every port line, sshd_port keeps the first" {
  stub sshd 'printf "port 2222\nport 22\nport 2200\naddressfamily any\n"'
  [ "$(sshd_ports)" = $'2222\n22\n2200' ]
  [ "$(sshd_port)" = 2222 ]
}

@test "ufw_plan auto allows every sshd port" {
  stub sshd 'printf "port 2222\nport 22\n"'
  ufw_plan auto > "$BATS_TEST_TMPDIR/plan" 2>/dev/null
  [ "$(cat "$BATS_TEST_TMPDIR/plan")" = $'2222/tcp\n22/tcp' ]
}

@test "ufw_apply opens every sshd port before enabling" {
  stub sshd 'printf "port 2222\nport 22\n"'
  ufw_apply 2222/tcp 22/tcp
  grep -q '^allow 2222/tcp' "$CALLS"
  grep -q '^allow 22/tcp' "$CALLS"
}

@test "sudo stripped SSH_CONNECTION: port read from an ancestor environ" {
  _fake_proc "$$:bash:500" "500:sudo:400" "400:bash:300" "300:notsshd:1"
  _proc_environ 400 "HOME=/root" "SSH_CONNECTION=1.2.3.4 5 6.7.8.9 2022" "TERM=xterm"
  [ "$(_fw_conn_port)" = 2022 ]
  _fw_in_ssh_session
}

@test "ancestor environ: session detected without sshd in the chain and without SUDO_USER" {
  _fake_proc "$$:bash:500" "500:tmux:1"
  _proc_environ 500 "SSH_CONNECTION=1.2.3.4 5 6.7.8.9 22"
  _fw_in_ssh_session
}

@test "own SSH_CONNECTION wins over ancestors" {
  export SSH_CONNECTION="1.2.3.4 5 6.7.8.9 2200"
  _fake_proc "$$:bash:500" "500:bash:1"
  _proc_environ 500 "SSH_CONNECTION=1.2.3.4 5 6.7.8.9 2022"
  [ "$(_fw_conn_port)" = 2200 ]
}

@test "no ancestor environ and no SSH_CONNECTION: no conn port, no session" {
  _fake_proc "$$:bash:500" "500:bash:1"
  [ -z "$(_fw_conn_port)" ]
  if _fw_in_ssh_session; then false; fi
}

@test "ancestor environ port is opened by ufw_plan" {
  _fake_proc "$$:bash:500" "500:sudo:400" "400:bash:1"
  _proc_environ 400 "SSH_CONNECTION=1.2.3.4 5 6.7.8.9 2022"
  stub sshd 'echo "port 22"'
  ufw_plan auto > "$BATS_TEST_TMPDIR/plan" 2>/dev/null
  [ "$(cat "$BATS_TEST_TMPDIR/plan")" = $'22/tcp\n2022/tcp' ]
}
