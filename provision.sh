#!/usr/bin/env bash
# provision.sh : provisioning post-installation Ubuntu/Debian.
set -Eeuo pipefail

VERSION="2.0.0"
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"

# shellcheck source=lib/ui.sh
source "$LIB_DIR/ui.sh" # @bundle-source

# Lu par les tâches suivantes (chargement de la configuration).
# shellcheck disable=SC2034
CONFIG_FILE=""

usage() {
  cat <<USAGE
Usage : provision.sh [options]

Options :
  --config <fichier>   Mode automatique à partir d'un fichier de configuration
  --dry-run            Affiche les actions sans les exécuter
  --log <fichier>      Fichier journal (défaut : /var/log/provision/provision-AAAAMMJJ-HHMMSS.log)
  --version            Affiche la version
  --help               Affiche cette aide

Codes de sortie : 0 succès, 1 erreur bloquante, 2 échecs partiels.
USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config)
        [[ $# -ge 2 ]] || { echo "Option --config : fichier manquant" >&2; exit 1; }
        CONFIG_FILE="$2"; MODE=auto; shift 2 ;;
      --dry-run) DRY_RUN=1; shift ;;
      --log)
        [[ $# -ge 2 ]] || { echo "Option --log : fichier manquant" >&2; exit 1; }
        LOG_FILE="$2"; shift 2 ;;
      --version) echo "provision $VERSION"; exit 0 ;;
      --help|-h) usage; exit 0 ;;
      *) echo "Option inconnue : $1" >&2; usage >&2; exit 1 ;;
    esac
  done
}

main() {
  parse_args "$@"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
