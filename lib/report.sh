#!/usr/bin/env bash
# lib/report.sh : rapport final, code de sortie, redémarrage, sauvegarde des réponses.
# Bibliothèque : uniquement des définitions, rien ne s'exécute au source.
# Nécessite lib/ui.sh et lib/config.sh (config_write) ; lib/os.sh fournit OS_PRETTY.

: "${REBOOT_FLAG_FILE:=/var/run/reboot-required}"
: "${START_TIME:=0}"

# report_init : remet à zéro les globales partagées du rapport.
report_init() {
  R_TOOLS_OK=()
  R_TOOLS_FAIL=()
  R_REPOS=()
  R_UFW_ADDED=()
  R_UFW_EXTRA=()
  R_SVC_MASKED=()
  R_SVC_DISABLED=()
  R_WARNINGS=()
  HAS_PARTIAL_FAILURE=0
  START_TIME="$(date +%s)"
}

_report_reboot_needed() { [[ -e "$REBOOT_FLAG_FILE" ]]; }

# _report_section <titre> <élément…> : titre en gras, puis les éléments ou « Aucun ».
_report_section() {
  local title="$1"
  shift
  printf '\n\033[1m%s\033[0m\n' "$title"
  if (($# == 0)); then
    printf '  Aucun\n'
    return 0
  fi
  local item
  for item in "$@"; do
    printf '  - %s\n' "$item"
  done
}

# _report_text : le rapport complet (avec codes ANSI sur les titres).
_report_text() {
  local elapsed=0 mins secs
  if [[ "${START_TIME:-0}" =~ ^[0-9]+$ && "$START_TIME" -gt 0 ]]; then
    elapsed=$(($(date +%s) - START_TIME))
  fi
  mins=$((elapsed / 60))
  secs=$((elapsed % 60))
  printf '\033[1m%s\033[0m\n' "Rapport de provisionnement"
  printf '  Durée : %d min %02d s\n' "$mins" "$secs"
  printf '  Système : %s\n' "${OS_PRETTY:-inconnu}"
  _report_section "Outils installés" "${R_TOOLS_OK[@]}"
  _report_section "Outils en échec" "${R_TOOLS_FAIL[@]}"
  _report_section "Dépôts" "${R_REPOS[@]}"
  _report_section "Règles UFW ajoutées" "${R_UFW_ADDED[@]}"
  _report_section "Règles UFW présentes hors configuration (à vérifier manuellement)" "${R_UFW_EXTRA[@]}"
  _report_section "Services masqués" "${R_SVC_MASKED[@]}"
  _report_section "Services désactivés" "${R_SVC_DISABLED[@]}"
  _report_section "Avertissements" "${R_WARNINGS[@]}"
  printf '\n'
  if _report_reboot_needed; then
    printf '\033[1m%s\033[0m\n' "Redémarrage requis : oui"
  else
    printf '\033[1m%s\033[0m\n' "Redémarrage requis : non"
  fi
}

# report_print <fichier_rapport> : affiche le rapport et l'écrit sans couleurs.
report_print() {
  local file="${1:-}" text plain
  text="$(_report_text)"
  plain="$(printf '%s\n' "$text" | sed 's/\x1b\[[0-9;]*m//g')"
  if _ui_is_tty; then
    printf '%s\n' "$text"
  else
    printf '%s\n' "$plain"
  fi
  _ui_log "$plain"
  if [[ -n "$file" ]]; then
    if mkdir -p "$(dirname "$file")" 2>/dev/null && printf '%s\n' "$plain" > "$file" 2>/dev/null; then
      info "Rapport enregistré : $file"
    else
      warn "Impossible d'écrire le rapport : $file"
    fi
  fi
}

# exit_code : 2 si échecs partiels, sinon 0.
exit_code() {
  if [[ "${HAS_PARTIAL_FAILURE:-0}" == "1" ]]; then
    printf '2\n'
  else
    printf '0\n'
  fi
}

# maybe_reboot : redémarre selon CFG_REBOOT (ou la réponse en interactif). Jamais en dry-run.
maybe_reboot() {
  local do_reboot=0
  if [[ "$MODE" == "interactive" ]]; then
    confirm "Redémarrer maintenant ?" n && do_reboot=1
  else
    case "${CFG_REBOOT:-no}" in
      yes) do_reboot=1 ;;
      if-needed) _report_reboot_needed && do_reboot=1 ;;
    esac
  fi
  if ((do_reboot == 0)); then
    info "Pas de redémarrage automatique."
    _report_reboot_needed && info "Un redémarrage est nécessaire : pensez à redémarrer la machine."
    return 0
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    info "[dry-run] redémarrage non effectué."
    return 0
  fi
  info "Redémarrage en cours…"
  run reboot
}

# offer_save_config : propose d'enregistrer les réponses (interactif seulement).
offer_save_config() {
  [[ "$MODE" == "interactive" ]] || return 0
  confirm "Enregistrer vos réponses dans un fichier de configuration réutilisable ?" y || return 0
  local dir="${PROVISION_SAVE_DIR:-/root}" file
  file="$dir/provision-$(date +%Y%m%d).conf"
  if [[ "$DRY_RUN" == "1" ]]; then
    info "[dry-run] configuration non enregistrée ($file)."
    return 0
  fi
  if (umask 077 && config_write "$file") && chmod 600 "$file"; then
    ok "Configuration enregistrée : $file"
  else
    warn "Impossible d'enregistrer la configuration : $file"
  fi
}
