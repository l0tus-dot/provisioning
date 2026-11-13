#!/usr/bin/env bash
# provision.sh : provisioning post-installation Ubuntu/Debian.
set -Eeuo pipefail

VERSION="2.0.0"
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"

# shellcheck source=lib/ui.sh
source "$LIB_DIR/ui.sh" # @bundle-source
# shellcheck source=lib/config.sh
source "$LIB_DIR/config.sh" # @bundle-source
# shellcheck source=lib/os.sh
source "$LIB_DIR/os.sh" # @bundle-source
# shellcheck source=lib/update.sh
source "$LIB_DIR/update.sh" # @bundle-source
# shellcheck source=lib/repos_debian.sh
source "$LIB_DIR/repos_debian.sh" # @bundle-source
# shellcheck source=lib/tools.sh
source "$LIB_DIR/tools.sh" # @bundle-source
# shellcheck source=lib/firewall.sh
source "$LIB_DIR/firewall.sh" # @bundle-source
# shellcheck source=lib/services.sh
source "$LIB_DIR/services.sh" # @bundle-source
# shellcheck source=lib/report.sh
source "$LIB_DIR/report.sh" # @bundle-source

CONFIG_FILE=""
REPORT_FILE=""

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

# _setup_logging : fixe LOG_FILE (si absent) et REPORT_FILE, crée le dossier.
# Hors root en dry-run, le journal va sous ${TMPDIR:-/tmp} (aucune écriture dans /var/log).
_setup_logging() {
  local ts dir
  ts="$(date +%Y%m%d-%H%M%S)"
  if [[ -z "$LOG_FILE" ]]; then
    if [[ "$DRY_RUN" == "1" && "$EUID" -ne 0 && "${PROVISION_ASSUME_ROOT:-}" != "1" ]]; then
      dir="${TMPDIR:-/tmp}/provision-logs"
    else
      dir="/var/log/provision"
    fi
    LOG_FILE="$dir/provision-$ts.log"
  fi
  dir="$(dirname "$LOG_FILE")"
  if ! mkdir -p "$dir" 2>/dev/null; then
    # Pas de droits (ex. non-root) : repli sous TMPDIR pour que le journal existe toujours.
    dir="${TMPDIR:-/tmp}/provision-logs"
    LOG_FILE="$dir/$(basename "$LOG_FILE")"
    mkdir -p "$dir" 2>/dev/null || true
  fi
  REPORT_FILE="$dir/rapport-$ts.txt"
  : >> "$LOG_FILE" 2>/dev/null || true
}

# _check_root : sortie 1 si non-root (avertissement seul en dry-run).
# PROVISION_ASSUME_ROOT=1 ne contourne que ce test : RÉSERVÉ AUX TESTS.
_check_root() {
  [[ "$EUID" -eq 0 || "${PROVISION_ASSUME_ROOT:-}" == "1" ]] && return 0
  if [[ "$DRY_RUN" == "1" ]]; then
    warn "Exécution sans droits root (dry-run) : aucune modification ne sera faite."
    return 0
  fi
  error "Ce script doit être exécuté en tant que root (sudo)."
  exit 1
}

_check_os() {
  if ! os_detect; then
    error "Impossible de détecter le système."
    exit 1
  fi
  if os_supported; then return 0; fi
  if [[ "$MODE" == "auto" ]]; then
    error "Système non supporté : ${OS_PRETTY:-inconnu} (Ubuntu 22.04/24.04/26.04, Debian 12/13)."
    exit 1
  fi
  warn "Système non supporté officiellement : ${OS_PRETTY:-inconnu}."
  confirm "Continuer quand même ?" n || exit 0
}

# _abort_with_report : rapport puis sortie 1 (erreur bloquante).
_abort_with_report() {
  report_print "$REPORT_FILE"
  exit 1
}

# _on_exit : à la sortie sur erreur inattendue (rapport pas encore affiché) : rapport, code 1.
_on_exit() {
  local rc=$?
  trap - EXIT
  if ((rc != 0)) && [[ "${REPORT_PRINTED:-0}" != "1" ]]; then
    error "Erreur inattendue (code $rc)"
    report_print "$REPORT_FILE"
    exit 1
  fi
  exit "$rc"
}

# _step_update : mise à jour du système.
_step_update() {
  if [[ "$MODE" == "interactive" ]]; then
    if confirm "Lancer la mise à jour complète du système (apt update && upgrade) ?" y; then
      CFG_UPDATE_SYSTEM=yes
    else
      CFG_UPDATE_SYSTEM=no
    fi
  fi
  [[ "$CFG_UPDATE_SYSTEM" == "yes" ]] || return 0
  step "Mise à jour du système"
  system_update || _abort_with_report
}

# _step_debian_repos : composants, backports, snapd (Debian seulement).
_step_debian_repos() {
  local sources_file
  step "Configuration des dépôts Debian"
  if [[ "$MODE" == "interactive" ]]; then
    local -a comps=()
    confirm "Activer le dépôt contrib ?" y && comps+=(contrib)
    confirm "Activer le dépôt non-free (firmware propriétaires, pilotes Wi-Fi…) ?" y \
      && comps+=(non-free non-free-firmware)
    CFG_DEBIAN_COMPONENTS="${comps[*]}"
    confirm "Activer les backports (versions plus récentes de certains paquets) ?" n \
      && CFG_DEBIAN_BACKPORTS=yes
    if ! command -v snap >/dev/null 2>&1; then
      confirm "Installer snapd (absent par défaut sur Debian) ?" n && CFG_INSTALL_SNAPD=yes
    fi
  fi
  sources_file="$(apt_sources_file)"
  if [[ -n "$CFG_DEBIAN_COMPONENTS" ]]; then
    local -a want
    read -r -a want <<< "$CFG_DEBIAN_COMPONENTS"
    debian_add_components "$sources_file" "$OS_CODENAME" "${want[@]}" || HAS_PARTIAL_FAILURE=1
  fi
  if [[ "$CFG_DEBIAN_BACKPORTS" == "yes" ]]; then
    local -a bp
    read -r -a bp <<< "$CFG_DEBIAN_COMPONENTS"
    debian_enable_backports "$OS_CODENAME" "${bp[@]}" || HAS_PARTIAL_FAILURE=1
  fi
  if [[ "$CFG_INSTALL_SNAPD" == "yes" ]]; then
    debian_install_snapd || HAS_PARTIAL_FAILURE=1
  fi
  # Les dépôts ajoutés ne sont visibles qu'après un nouvel apt-get update.
  if ((${#R_REPOS[@]} > 0)); then
    if ! _apt "Actualisation des listes de paquets…" update; then
      error "apt-get update a échoué après modification des dépôts"
      _abort_with_report
    fi
  fi
}

_step_flatpak() {
  if [[ "$MODE" == "interactive" ]] && ! command -v flatpak >/dev/null 2>&1; then
    confirm "Installer flatpak avec le dépôt Flathub ?" n && CFG_INSTALL_FLATPAK=yes
  fi
  [[ "$CFG_INSTALL_FLATPAK" == "yes" ]] || return 0
  debian_install_flatpak || HAS_PARTIAL_FAILURE=1
}

_step_tools() {
  local -a specs=() s
  step "Installation des outils"
  if [[ "$MODE" == "interactive" ]]; then
    tools_interactive
    specs=("${TOOLS_SELECTED[@]}")
    if ((${#specs[@]} > 0)); then
      confirm "Lancer l'installation ?" y || { warn "Installation annulée."; return 0; }
      CFG_TOOLS="${specs[*]}"
    fi
  else
    read -r -a specs <<< "$CFG_TOOLS"
  fi
  if ((${#specs[@]} == 0)); then
    info "Aucun outil à installer."
    return 0
  fi
  for s in "${specs[@]}"; do
    tool_install "$s" || true # l'échec est consigné par tool_install (HAS_PARTIAL_FAILURE)
  done
}

main() {
  parse_args "$@"
  _setup_logging
  report_init
  _check_root
  _check_os

  # Bannière unique
  printf '\n== provision %s : %s ==\n' "$VERSION" "$OS_PRETTY"
  _ui_log "provision $VERSION : $OS_PRETTY (mode $MODE)"

  if [[ "$MODE" == "auto" ]]; then
    # Échec = sortie 1 avant toute modification (et avant tout accès réseau).
    config_load "$CONFIG_FILE" || exit 1
  else
    config_defaults
  fi

  # Filet de sécurité : une erreur inattendue (set -e) produit tout de même un rapport.
  trap _on_exit EXIT
  connectivity_check || _abort_with_report
  _step_update
  if [[ "$(os_family)" == "debian" ]]; then _step_debian_repos; fi
  _step_flatpak
  _step_tools
  configure_firewall || HAS_PARTIAL_FAILURE=1
  manage_services || HAS_PARTIAL_FAILURE=1

  report_print "$REPORT_FILE"
  offer_save_config
  maybe_reboot
  exit "$(exit_code)"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
