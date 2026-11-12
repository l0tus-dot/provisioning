#!/usr/bin/env bash
# scripts/bundle.sh [sortie] : assemble provision.sh et lib/*.sh en un fichier autonome.
# Sortie par défaut : dist/provision.sh
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/dist/provision.sh}"
LIBS=(ui config os update repos_debian tools firewall services report)

mkdir -p "$(dirname "$OUT")"
tmp="$(mktemp "${OUT}.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

held=""        # directive « shellcheck source= » en attente
inserted=0
{
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "# shellcheck source="* ]]; then
      [[ -z "$held" ]] || printf '%s\n' "$held"
      held="$line"
      continue
    fi
    if [[ "$line" == *"# @bundle-source"* ]]; then
      held=""   # la directive associée disparaît avec la ligne source
      if ((inserted == 0)); then
        for lib in "${LIBS[@]}"; do
          printf '\n# --- lib/%s.sh ---\n' "$lib"
          tail -n +2 "$ROOT/lib/$lib.sh"   # sans le shebang
        done
        printf '\n# --- fin des bibliothèques ---\n'
        inserted=1
      fi
      continue
    fi
    [[ -z "$held" ]] || { printf '%s\n' "$held"; held=""; }
    printf '%s\n' "$line"
  done < "$ROOT/provision.sh"
  [[ -z "$held" ]] || printf '%s\n' "$held"
} > "$tmp"

if ((inserted == 0)); then
  echo "bundle.sh : aucune ligne '# @bundle-source' dans provision.sh" >&2
  exit 1
fi
bash -n "$tmp"
chmod +x "$tmp"
mv -f "$tmp" "$OUT"
trap - EXIT
echo "Bundle écrit : $OUT"
