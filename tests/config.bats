#!/usr/bin/env bats

setup() {
  load helpers
  load_lib config
  FIX="$REPO_ROOT/tests/fixtures/config"
}

@test "defaults when file is empty" {
  config_load "$FIX/empty.conf"
  [ "$CFG_UFW_SSH_PORT" = "auto" ]
  [ "$CFG_REBOOT" = "no" ]
  [ "$CFG_UPDATE_SYSTEM" = "yes" ]
  [ "$CFG_UFW_ENABLE" = "yes" ]
}

@test "config tolerates CRLF and quotes" {
  printf '# c\r\nTOOLS="apt:git snap:code"  \r\nREBOOT='"'"'if-needed'"'"'\r\n' > "$BATS_TEST_TMPDIR/crlf.conf"
  config_load "$BATS_TEST_TMPDIR/crlf.conf"
  [ "$CFG_TOOLS" = "apt:git snap:code" ]
  [ "$CFG_REBOOT" = "if-needed" ]
}

@test "unknown key fails with line number" {
  bats_run config_load "$FIX/unknown-key.conf"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ligne 4"* ]]
  [[ "$output" == *"UFW_ALOW"* ]]
}

@test "line without equals fails" {
  bats_run config_load "$FIX/no-equals.conf"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ligne 1"* ]]
}

@test "missing file fails" {
  bats_run config_load "$BATS_TEST_TMPDIR/absent.conf"
  [ "$status" -eq 1 ]
}

@test "invalid values fail" {
  local f
  for f in bad-reboot bad-ssh-port bad-ufw-allow bad-flatpak-version \
           bad-tool-nosrc bad-components bad-dollar; do
    bats_run config_load "$FIX/$f.conf"
    [ "$status" -eq 1 ] || { echo "$f: statut $status"; return 1; }
    [[ "$output" == *"ligne 1"* ]] || { echo "$f: $output"; return 1; }
  done
}

@test "config is not executed" {
  local pwned="$BATS_TEST_TMPDIR/pwned"
  printf 'TOOLS=$(touch %s)\n' "$pwned" > "$BATS_TEST_TMPDIR/exec.conf"
  bats_run config_load "$BATS_TEST_TMPDIR/exec.conf"
  [ "$status" -eq 1 ]
  [ ! -e "$pwned" ]
}

@test "validators" {
  local v
  for v in "is_yes_no yes" "is_yes_no no" "is_port 1" "is_port 65535" \
    "is_ufw_rule 80" "is_ufw_rule 80/tcp" "is_ufw_rule 6000:6010/udp" \
    "is_tool_spec apt:git" "is_tool_spec pip:black@24.1" \
    "is_tool_spec flatpak:org.gimp.GIMP"; do
    $v || { echo "devrait réussir : $v"; return 1; }
  done
  for v in "is_yes_no maybe" "is_port 0" "is_port 65536" "is_port abc" "is_port" \
    "is_ufw_rule 80/icmp" "is_ufw_rule 6010:6000/tcp" "is_ufw_rule 6000:6010" \
    "is_tool_spec flatpak:org.gimp.GIMP@2" "is_tool_spec git"; do
    if $v; then echo "devrait échouer : $v"; return 1; fi
  done
}

@test "write then load round-trips" {
  CFG_UPDATE_SYSTEM=no
  CFG_TOOLS="apt:git snap:code pip:black@24.1"
  CFG_DEBIAN_COMPONENTS="contrib non-free-firmware"
  CFG_DEBIAN_BACKPORTS=yes
  CFG_INSTALL_SNAPD=yes
  CFG_INSTALL_FLATPAK=yes
  CFG_UFW_ENABLE=no
  CFG_UFW_SSH_PORT=2222
  CFG_UFW_ALLOW="80/tcp 6000:6010/udp 443"
  CFG_SERVICES_MASK="avahi-daemon.service"
  CFG_SERVICES_DISABLE="cups bluetooth@1"
  CFG_REBOOT=if-needed
  local before after
  before=$(set | grep '^CFG_' | sort)
  config_write "$BATS_TEST_TMPDIR/out.conf"
  config_defaults
  config_load "$BATS_TEST_TMPDIR/out.conf"
  after=$(set | grep '^CFG_' | sort)
  [ "$before" = "$after" ]
  [ "$CFG_UFW_SSH_PORT" = "2222" ]
}
