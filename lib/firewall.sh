#!/usr/bin/env bash
# lib/firewall.sh : pare-feu UFW additif, avec garde-fou SSH.
# Bibliothèque : uniquement des définitions, rien ne s'exécute au source.
# Nécessite lib/ui.sh (run, ok, warn, error, confirm, ask_value), lib/update.sh (_apt)
# et lib/config.sh (is_port, is_ufw_rule).
#
# Principe : on n'AJOUTE que des règles (jamais de suppression), et la règle SSH est
# toujours posée AVANT l'activation du pare-feu. Si elle échoue, on n'active rien.

: "${SSHD_CONFIG:=/etc/ssh/sshd_config}"

# _fw_have <commande> : la commande est-elle disponible ? (redéfinissable dans les tests)
_fw_have() { command -v "$1" >/dev/null 2>&1; }

# _fw_in_ssh_session : vrai si la session courante passe par SSH.
_fw_in_ssh_session() {
  [[ -n "${SSH_CONNECTION:-}" || -n "${SSH_CLIENT:-}" ]]
}

# _fw_sshd_t_port : premier « port N » de `sshd -T` (nécessite root et les clés d'hôte).
_fw_sshd_t_port() {
  local bin=""
  if _fw_have sshd; then bin=sshd
  elif [[ -x /usr/sbin/sshd ]]; then bin=/usr/sbin/sshd
  else return 1
  fi
  LC_ALL=C "$bin" -T 2>/dev/null | awk 'tolower($1) == "port" { print $2; exit }'
}

# _fw_config_port <fichier> <profondeur> : premier `Port` du fichier, en suivant les `Include`.
_fw_config_port() {
  local file="$1" depth="${2:-0}" line key val dir inc f p
  local -a words
  [[ -r "$file" ]] || return 1
  ((depth <= 3)) || return 1
  dir="$(dirname -- "$file")"
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    read -r -a words <<< "$line"
    ((${#words[@]} >= 2)) || continue
    key="${words[0]}"
    [[ "$key" == \#* ]] && continue
    val="${words[1]}"
    case "${key,,}" in
      port)
        if is_port "$val"; then printf '%s\n' "$val"; return 0; fi
        ;;
      include)
        for inc in "${words[@]:1}"; do
          [[ "$inc" == /* ]] || inc="$dir/$inc"
          # Motifs d'Include (ex. sshd_config.d/*.conf) : développés par compgen.
          while IFS= read -r f; do
            if p="$(_fw_config_port "$f" $((depth + 1)))" && [[ -n "$p" ]]; then
              printf '%s\n' "$p"
              return 0
            fi
          done < <(compgen -G "$inc" | LC_ALL=C sort)
        done
        ;;
    esac
  done < "$file"
  return 1
}

# sshd_port : port SSH effectif (sshd -T, sinon sshd_config, sinon 22). Toujours un port valide.
sshd_port() {
  local p=""
  p="$(_fw_sshd_t_port 2>/dev/null || true)"
  if is_port "$p"; then printf '%s\n' "$((10#$p))"; return 0; fi
  p="$(_fw_config_port "$SSHD_CONFIG" 0 2>/dev/null || true)"
  if is_port "$p"; then printf '%s\n' "$((10#$p))"; return 0; fi
  printf '22\n'
}

# _fw_status_rules <0|1> : règles ALLOW de `ufw status`, normalisées, sans doublons.
# Avec 1 : uniquement celles ouvertes à tous (From = Anywhere).
# Le profil d'application « OpenSSH » compte comme 22/tcp.
_fw_status_rules() {
  local open_only="${1:-0}" line to i rest
  local -a f
  local -A seen=()
  _fw_have ufw || return 0
  while IFS= read -r line; do
    read -r -a f <<< "$line"
    ((${#f[@]} >= 3)) || continue
    to="${f[0]}"
    i=1
    [[ "${f[i]}" == "(v6)" ]] && i=$((i + 1))
    [[ "${f[i]:-}" == "ALLOW" ]] || continue
    i=$((i + 1))
    case "${f[i]:-}" in
      IN) i=$((i + 1)) ;;
      OUT | FWD) continue ;;
    esac
    rest="${f[*]:i}"
    if ((open_only)) && [[ "$rest" != Anywhere* ]]; then continue; fi
    if [[ "$to" == OpenSSH ]]; then
      to="22/tcp"
    elif [[ ! "$to" =~ ^[0-9]+(:[0-9]+)?(/(tcp|udp))?$ ]]; then
      continue
    fi
    if [[ -z "${seen[$to]:-}" ]]; then
      seen[$to]=1
      printf '%s\n' "$to"
    fi
  done < <(LC_ALL=C ufw status 2>/dev/null)
}

# ufw_current_rules : règles ALLOW actuelles, une par ligne (vide si ufw inactif).
ufw_current_rules() { _fw_status_rules 0; }

# _fw_covers <règle actuelle> <règle voulue> : la première couvre-t-elle la seconde ?
# « 80 » (tcp+udp) couvre « 80/tcp ».
_fw_covers() {
  local cur="$1" want="$2"
  [[ "$cur" == "$want" ]] && return 0
  [[ "$cur" != */* && ( "$want" == "$cur/tcp" || "$want" == "$cur/udp" ) ]]
}

# ufw_plan <ssh_port|none|auto> <règles…> : liste finale, une par ligne (SSH en premier).
# Les avertissements vont sur stderr pour ne pas polluer la liste.
ufw_plan() {
  local ssh="${1:-auto}" real r
  shift || true
  local -a out=()
  local -A seen=()
  real="$(sshd_port)"

  if [[ "$ssh" != auto && "$ssh" != none ]] && ! is_port "$ssh"; then
    warn "Port SSH invalide « $ssh » : utilisation du port détecté ($real)" >&2
    ssh=auto
  fi

  case "$ssh" in
    none)
      if _fw_in_ssh_session; then
        warn "Session SSH détectée : port SSH forcé ($real/tcp) malgré UFW_SSH_PORT=none" >&2
        out+=("$real/tcp")
      fi
      ;;
    auto) out+=("$real/tcp") ;;
    *)
      ssh=$((10#$ssh))
      if _fw_in_ssh_session && [[ "$ssh" != "$real" ]]; then
        warn "Session SSH sur le port $real, différent de UFW_SSH_PORT=$ssh : les deux sont autorisés" >&2
        out+=("$real/tcp")
      fi
      out+=("$ssh/tcp")
      ;;
  esac

  for r in "$@"; do
    if ! is_ufw_rule "$r"; then
      warn "Règle UFW invalide ignorée : $r" >&2
      continue
    fi
    out+=("$r")
  done

  for r in "${out[@]}"; do
    if [[ -z "${seen[$r]:-}" ]]; then
      seen[$r]=1
      printf '%s\n' "$r"
    fi
  done
}

# ufw_apply <règles…> : installe ufw si besoin, politique par défaut, règles manquantes, activation.
# Si l'ajout d'une règle SSH échoue, UFW n'est PAS activé (retour 1).
# UFW_SKIP_ENABLE=1 : pose les règles sans activer.
ufw_apply() {
  local r c have sshr real
  local -a ssh_rules=() other_rules=() current=() wanted=("$@")
  local -A is_ssh=()

  if ! _fw_have ufw; then
    info "UFW non installé : installation…"
    if ! _apt "Installation de UFW…" -y install ufw; then
      error "Impossible d'installer ufw"
      return 1
    fi
  fi

  if ! run ufw default deny incoming; then
    error "ufw default deny incoming a échoué"
    return 1
  fi
  if ! run ufw default allow outgoing; then
    error "ufw default allow outgoing a échoué"
    return 1
  fi

  # Règles SSH = port détecté et port configuré : posées avant toutes les autres.
  real="$(sshd_port)"
  is_ssh["$real/tcp"]=1
  if [[ "${CFG_UFW_SSH_PORT:-}" =~ ^[0-9]+$ ]] && is_port "$CFG_UFW_SSH_PORT"; then
    is_ssh["$((10#$CFG_UFW_SSH_PORT))/tcp"]=1
  fi
  for r in "${wanted[@]}"; do
    if [[ -n "${is_ssh[$r]:-}" ]]; then ssh_rules+=("$r"); else other_rules+=("$r"); fi
  done

  mapfile -t current < <(_fw_status_rules 1)

  for r in "${ssh_rules[@]}" "${other_rules[@]}"; do
    have=0
    for c in "${current[@]}"; do
      if _fw_covers "$c" "$r"; then have=1; break; fi
    done
    if ((have)); then
      info "Règle UFW déjà présente : $r"
      continue
    fi
    sshr=0
    [[ -n "${is_ssh[$r]:-}" ]] && sshr=1
    if run ufw allow "$r"; then
      R_UFW_ADDED+=("$r")
      ok "Règle UFW ajoutée : $r"
    elif ((sshr)); then
      error "Impossible d'ajouter la règle SSH $r : UFW n'est pas activé (risque de perdre l'accès)"
      return 1
    else
      warn "Échec de l'ajout de la règle UFW : $r"
      HAS_PARTIAL_FAILURE=1
    fi
  done

  # Règles déjà présentes mais non demandées : signalées, jamais supprimées.
  mapfile -t current < <(_fw_status_rules 0)
  for c in "${current[@]}"; do
    have=0
    for r in "${wanted[@]}"; do
      if _fw_covers "$c" "$r"; then have=1; break; fi
    done
    ((have)) || R_UFW_EXTRA+=("$c")
  done

  if [[ "${UFW_SKIP_ENABLE:-0}" == "1" ]]; then
    warn "UFW configuré mais non activé. Activez-le avec : sudo ufw enable"
    return 0
  fi
  if ! run ufw --force enable; then
    error "Échec de l'activation de UFW"
    return 1
  fi
  ok "UFW activé"
}

# _fw_ask_port <question> <défaut> : demande un port valide (3 essais) ; statut 1 sinon.
_fw_ask_port() {
  local q="$1" def="$2" v n
  for n in 1 2 3; do
    v="$(ask_value "$q" "$def")"
    if is_port "$v"; then printf '%s\n' "$((10#$v))"; return 0; fi
    warn "Port invalide : « $v »" >&2
  done
  return 1
}

# _fw_ask_interactive : pose les questions et remplit CFG_UFW_ENABLE / CFG_UFW_SSH_PORT / CFG_UFW_ALLOW.
_fw_ask_interactive() {
  local p r bad=0 count=0
  local -a allow=()

  if ! confirm "Configurer UFW (pare-feu) ?" y; then
    CFG_UFW_ENABLE=no
    return 0
  fi
  CFG_UFW_ENABLE=yes

  if confirm "Autoriser SSH ?" y; then
    if p="$(_fw_ask_port "Port SSH" "$(sshd_port)")"; then
      CFG_UFW_SSH_PORT="$p"
    else
      warn "Port SSH non valide : utilisation du port détecté"
      CFG_UFW_SSH_PORT=auto
    fi
  else
    CFG_UFW_SSH_PORT=none
  fi

  confirm "Autoriser HTTP (port 80) ?" n && allow+=("80/tcp")
  confirm "Autoriser HTTPS (port 443) ?" n && allow+=("443/tcp")

  while ((count < 50)); do
    r="$(ask_value "Port/règle (ex: 8080/tcp, 5432, fin)" "fin")"
    [[ -z "$r" || "$r" == "fin" ]] && break
    count=$((count + 1))
    if is_ufw_rule "$r"; then
      allow+=("$r")
      bad=0
    else
      warn "Règle invalide : $r"
      bad=$((bad + 1))
      if ((bad >= 3)); then
        warn "Trop de règles invalides : fin de la saisie"
        break
      fi
    fi
  done

  CFG_UFW_ALLOW="${CFG_UFW_ALLOW:+$CFG_UFW_ALLOW }${allow[*]}"
  CFG_UFW_ALLOW="${CFG_UFW_ALLOW% }"

  confirm "Activer UFW maintenant ?" y || UFW_SKIP_ENABLE=1
  return 0
}

# configure_firewall : point d'entrée. CFG_UFW_ENABLE=no => ne touche à rien.
configure_firewall() {
  local plan_file
  local -a requested=() plan=()

  if [[ "${CFG_UFW_ENABLE:-yes}" == "no" ]]; then
    info "Pare-feu : UFW_ENABLE=no, aucune modification"
    return 0
  fi

  step "Configuration du pare-feu UFW"
  if [[ "$MODE" == "interactive" ]]; then _fw_ask_interactive; fi
  if [[ "${CFG_UFW_ENABLE:-yes}" == "no" ]]; then
    warn "UFW ignoré."
    return 0
  fi

  read -r -a requested <<< "${CFG_UFW_ALLOW:-}"
  # Sans sous-shell : les avertissements du plan doivent atteindre R_WARNINGS.
  plan_file="$(mktemp)" || { error "mktemp a échoué"; return 1; }
  ufw_plan "${CFG_UFW_SSH_PORT:-auto}" "${requested[@]}" > "$plan_file"
  mapfile -t plan < "$plan_file"
  rm -f -- "$plan_file"

  if ! ufw_apply "${plan[@]}"; then
    HAS_PARTIAL_FAILURE=1
    return 1
  fi
}
