#!/usr/bin/env bash
# lib/services.sh : gestion des services inutiles, avec liste « sensible ».
# Bibliothèque : uniquement des définitions, rien ne s'exécute au source.
# Nécessite lib/ui.sh (run, info, ok, warn, error, step, ask_value).
#
# SERVICES_SAFE      : proposés en lot (options B/C).
# SERVICES_SENSITIVE : jamais en lot ; proposés un par un avec avertissement.
# SERVICES_FORBIDDEN : toujours refusés (risque de perdre l'accès à distance).

SERVICES_SAFE=(avahi-daemon cups cups-browsed bluetooth ModemManager whoopsie apport
  speech-dispatcher saned postfix exim4 rpcbind nfs-common)
SERVICES_SENSITIVE=(unattended-upgrades apt-daily apt-daily-upgrade rsyslog wpa_supplicant
  NetworkManager-wait-online thermald snapd)
SERVICES_FORBIDDEN=(ssh sshd)

declare -gA SERVICE_DESC=(
  [snapd]="Daemon Snap (gestionnaire de paquets snap)"
  [avahi-daemon]="mDNS/Bonjour (découverte réseau locale)"
  [cups]="Service d'impression (CUPS)"
  [cups-browsed]="Découverte automatique d'imprimantes"
  [bluetooth]="Service Bluetooth"
  [ModemManager]="Gestion des modems GSM/CDMA"
  [whoopsie]="Envoi de rapports de crash Ubuntu"
  [apport]="Collecte de rapports d'erreurs"
  [thermald]="Démon de gestion thermique"
  [unattended-upgrades]="Mises à jour automatiques non supervisées"
  [rsyslog]="Service de journalisation système"
  [postfix]="Serveur de messagerie (SMTP local)"
  [exim4]="Agent de transport de mail (MTA) Exim"
  [speech-dispatcher]="Synthèse vocale (text-to-speech)"
  [saned]="Daemon réseau pour scanners"
  [wpa_supplicant]="Gestion Wi-Fi (inutile si câble uniquement)"
  [NetworkManager-wait-online]="Attente de connexion réseau au démarrage"
  [apt-daily]="Maintenance apt quotidienne automatique"
  [apt-daily-upgrade]="Mises à jour apt automatiques"
  [rpcbind]="Port mapper RPC (inutile si NFS non utilisé)"
  [nfs-common]="Support NFS client (si non nécessaire)"
)

# _svc_in_list <nom> <éléments…> : le nom figure-t-il dans la liste ?
_svc_in_list() {
  local n="$1" x
  shift
  for x in "$@"; do
    [[ "$x" == "$n" ]] && return 0
  done
  return 1
}

# _svc_systemd_running : systemctl présent et systemd en cours d'exécution.
_svc_systemd_running() {
  command -v systemctl >/dev/null 2>&1 && [[ -d "${SYSTEMD_RUN_DIR:-/run/systemd/system}" ]]
}

# service_units <nom> : unités existantes exactement nommées (.service/.socket/.timer), une par ligne.
service_units() {
  local name="$1" line unit
  local -a cand=("$name.service" "$name.socket" "$name.timer")
  while read -r line; do
    unit="${line%% *}"
    if _svc_in_list "$unit" "${cand[@]}"; then printf '%s\n' "$unit"; fi
  done < <(LC_ALL=C systemctl list-unit-files --no-legend -- "${cand[@]}" 2>/dev/null)
  return 0
}

# service_apply <mask|disable> <nom> : 0 si appliqué ou ignoré, 1 si refusé ou en échec.
service_apply() {
  local action="$1" name="$2" suffix="" t
  local -a units
  if [[ "$action" != mask && "$action" != disable ]]; then
    error "Action de service inconnue : $action"
    return 1
  fi
  if _svc_in_list "$name" "${SERVICES_FORBIDDEN[@]}"; then
    error "Service $name refusé : il garantit l'accès SSH."
    HAS_PARTIAL_FAILURE=1
    return 1
  fi
  if [[ "$name" == snapd ]]; then
    for t in "${R_TOOLS_OK[@]}"; do
      if [[ "$t" == snap:* ]]; then
        warn "snapd conservé : l'outil $t a été installé via snap."
        return 1
      fi
    done
  fi
  mapfile -t units < <(service_units "$name")
  if ((${#units[@]} == 0)); then
    info "Service $name absent, ignoré."
    return 0
  fi
  if _svc_in_list "$name" "${SERVICES_SENSITIVE[@]}"; then
    warn "Service sensible : $name (${SERVICE_DESC[$name]:-sans description})."
  fi
  [[ "$DRY_RUN" == "1" ]] && suffix=" (dry-run)"
  if [[ "$action" == mask ]]; then
    run systemctl stop -- "${units[@]}" || true
    if run systemctl mask -- "${units[@]}"; then
      ok "$name masqué."
      R_SVC_MASKED+=("$name$suffix")
    else
      warn "Impossible de masquer $name."
      HAS_PARTIAL_FAILURE=1
      return 1
    fi
  else
    if run systemctl disable --now -- "${units[@]}"; then
      ok "$name désactivé au démarrage."
      R_SVC_DISABLED+=("$name$suffix")
    else
      warn "Impossible de désactiver $name."
      HAS_PARTIAL_FAILURE=1
      return 1
    fi
  fi
  return 0
}

# _svc_apply_config : applique CFG_SERVICES_MASK puis CFG_SERVICES_DISABLE.
_svc_apply_config() {
  local s
  local -a list
  read -r -a list <<< "${CFG_SERVICES_MASK:-}"
  for s in "${list[@]}"; do
    service_apply mask "$s" || true
  done
  list=()
  read -r -a list <<< "${CFG_SERVICES_DISABLE:-}"
  for s in "${list[@]}"; do
    service_apply disable "$s" || true
  done
}

# _svc_add <MASK|DISABLE> <nom> : ajoute le service à CFG_SERVICES_<clé>.
_svc_add() {
  local var="CFG_SERVICES_$1"
  printf -v "$var" '%s' "${!var:+${!var} }$2"
}

# _svc_choose_one <nom> : demande l'action pour un service présent.
_svc_choose_one() {
  local name="$1" choice
  [[ -n "$(service_units "$name")" ]] || return 0
  printf '\n  %s\n  %s\n' "$name" "${SERVICE_DESC[$name]:-}"
  if _svc_in_list "$name" "${SERVICES_SENSITIVE[@]}"; then
    printf '  ATTENTION : service sensible, à désactiver en connaissance de cause.\n'
  fi
  printf '   1. Désactiver totalement (mask)\n   2. Désactiver au démarrage (disable)\n   3. Laisser tel quel\n'
  choice="$(ask_value "Choix pour $name [1/2/3]" 3)"
  case "$choice" in
    1) _svc_add MASK "$name" ;;
    2) _svc_add DISABLE "$name" ;;
    *) info "$name conservé tel quel." ;;
  esac
}

manage_services() {
  step "Gestion des services inutiles"
  if ! _svc_systemd_running; then
    warn "systemd n'est pas actif (conteneur ?) : gestion des services ignorée."
    return 0
  fi
  local s choice
  if [[ "$MODE" != "auto" ]]; then
    printf '  Options globales :\n'
    printf '   A. Gérer les services un par un (recommandé, sensibles inclus)\n'
    printf '   B. Désactiver totalement (mask) les services de la liste sûre\n'
    printf '   C. Désactiver au démarrage (disable) les services de la liste sûre\n'
    printf '   D. Ignorer la gestion des services\n'
    choice="$(ask_value "Choix [A/B/C/D]" A)"
    case "${choice^^}" in
      B | C)
        for s in "${SERVICES_SAFE[@]}"; do
          [[ -n "$(service_units "$s")" ]] || continue
          if [[ "${choice^^}" == B ]]; then _svc_add MASK "$s"; else _svc_add DISABLE "$s"; fi
        done
        ;;
      D)
        info "Gestion des services ignorée."
        return 0
        ;;
      *)
        for s in "${SERVICES_SAFE[@]}" "${SERVICES_SENSITIVE[@]}"; do
          _svc_choose_one "$s"
        done
        ;;
    esac
  fi
  _svc_apply_config
}
