#!/usr/bin/env bash
# tests/smoke.sh [config] : test de fumée à lancer DANS un conteneur Docker, en root.
#   docker run --rm -v "$PWD:/src" -w /src ubuntu:24.04 bash tests/smoke.sh
# 1. dry-run avec la config d'exemple (défaut : examples/parc.conf) ;
# 2. vrai lancement minimal (curl via apt, sans UFW ni services : pas de systemd en conteneur).
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRY_CONFIG="${1:-$ROOT/examples/parc.conf}"
BUNDLE="$ROOT/dist/provision.sh"
export DEBIAN_FRONTEND=noninteractive

echo "== Préparation =="
apt-get update
apt-get install -y ca-certificates

if [[ ! -f "$BUNDLE" ]]; then
  echo "== Construction du bundle =="
  bash "$ROOT/scripts/bundle.sh"
fi

echo "== Passe 1 : dry-run ($DRY_CONFIG) =="
bash "$BUNDLE" --config "$DRY_CONFIG" --dry-run --log /tmp/smoke-dry.log

echo "== Passe 2 : lancement réel =="
REAL_CONFIG="$(mktemp /tmp/smoke-real.XXXXXX.conf)"
cat > "$REAL_CONFIG" <<'CONF'
UPDATE_SYSTEM="yes"
TOOLS="apt:curl"
DEBIAN_COMPONENTS=""
DEBIAN_BACKPORTS="no"
INSTALL_SNAPD="no"
INSTALL_FLATPAK="no"
UFW_ENABLE="no"
UFW_SSH_PORT="auto"
UFW_ALLOW=""
SERVICES_MASK=""
SERVICES_DISABLE=""
REBOOT="no"
CONF
rc=0
bash "$BUNDLE" --config "$REAL_CONFIG" --log /tmp/smoke-real.log || rc=$?
if [[ "$rc" -ne 0 ]]; then
  echo "ÉCHEC : code de sortie $rc (attendu 0)" >&2
  exit 1
fi
command -v curl >/dev/null || { echo "ÉCHEC : curl non installé" >&2; exit 1; }
echo "== Test de fumée OK =="
