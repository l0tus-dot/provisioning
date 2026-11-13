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

# _fw_ancestors : « pid comm » du processus courant puis de ses ancêtres (64 niveaux au plus).
# Lit ${PROC_ROOT:-/proc}/<pid>/stat (comm, ppid) ; sans /proc : liste vide.
_fw_ancestors() {
  local root="${PROC_ROOT:-/proc}" pid=$$ n stat comm rest
  local -a r
  for ((n = 0; n < 64; n++)); do
    [[ -r "$root/$pid/stat" ]] || return 0
    stat="$(cat "$root/$pid/stat" 2>/dev/null)" || return 0
    comm="${stat#*(}"
    comm="${comm%)*}"
    printf '%s %s\n' "$pid" "$comm"
    rest="${stat##*) }"
    read -r -a r <<< "$rest"
    pid="${r[1]:-}"
    if [[ ! "$pid" =~ ^[0-9]+$ ]] || ((pid <= 1)); then return 0; fi
  done
  return 0
}

# _fw_ancestor_is_sshd : un ancêtre du processus courant est-il sshd / sshd-session ?
_fw_ancestor_is_sshd() {
  local pid comm
  while read -r pid comm; do
    if [[ "$comm" == sshd || "$comm" == sshd-session ]]; then return 0; fi
  done < <(_fw_ancestors)
  return 1
}

# _fw_ancestor_ssh_connection : SSH_CONNECTION lu dans l'environnement (NUL-séparé) du premier
# ancêtre qui le porte (sudo/su retirent la variable du processus courant, pas de ses parents).
_fw_ancestor_ssh_connection() {
  local root="${PROC_ROOT:-/proc}" pid comm kv
  while read -r pid comm; do
    [[ -r "$root/$pid/environ" ]] || continue
    while IFS= read -r -d '' kv || [[ -n "$kv" ]]; do
      if [[ "$kv" == SSH_CONNECTION=?* ]]; then
        printf '%s\n' "${kv#SSH_CONNECTION=}"
        return 0
      fi
    done < "$root/$pid/environ"
  done < <(_fw_ancestors)
  return 1
}

# _fw_ssh_connection : valeur de SSH_CONNECTION (environnement courant, sinon ancêtres).
_fw_ssh_connection() {
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    printf '%s\n' "$SSH_CONNECTION"
    return 0
  fi
  _fw_ancestor_ssh_connection
}

# _fw_in_ssh_session : vrai si la session courante passe par SSH.
# sudo (env_reset) et `su -` retirent SSH_CONNECTION : on cherche sshd parmi les ancêtres, ou
# SSH_CONNECTION dans l'environnement d'un ancêtre.
_fw_in_ssh_session() {
  [[ -n "${SSH_CONNECTION:-}" || -n "${SSH_CLIENT:-}" ]] && return 0
  _fw_ancestor_is_sshd && return 0
  _fw_ancestor_ssh_connection >/dev/null
}

# _fw_conn_port : port local de la connexion SSH courante (4e champ de SSH_CONNECTION), si valide.
_fw_conn_port() {
  local -a c
  local conn=""
  conn="$(_fw_ssh_connection || true)"
  read -r -a c <<< "$conn"
  if is_port "${c[3]:-}"; then printf '%s\n' "$((10#${c[3]}))"; fi
  return 0
}

# _fw_sshd_t_ports : tous les « port N » de `sshd -T` (nécessite root et les clés d'hôte).
_fw_sshd_t_ports() {
  local bin=""
  if _fw_have sshd; then bin=sshd
  elif [[ -x /usr/sbin/sshd ]]; then bin=/usr/sbin/sshd
  else return 1
  fi
  LC_ALL=C "$bin" -T 2>/dev/null | awk 'tolower($1) == "port" { print $2 }'
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

# sshd_ports : TOUS les ports SSH effectifs, un par ligne (sshd -T ; sinon premier Port de
# sshd_config ; sinon 22). Toujours au moins un port valide.
sshd_ports() {
  local p found=0
  while IFS= read -r p; do
    if is_port "$p"; then printf '%s\n' "$((10#$p))"; found=1; fi
  done < <(_fw_sshd_t_ports 2>/dev/null || true)
  ((found)) && return 0
  p="$(_fw_config_port "$SSHD_CONFIG" 0 2>/dev/null || true)"
  if is_port "$p"; then printf '%s\n' "$((10#$p))"; return 0; fi
  printf '22\n'
}

# sshd_port : premier port SSH effectif (affichage). Toujours un port valide.
sshd_port() {
  local p
  IFS= read -r p < <(sshd_ports)
  printf '%s\n' "$p"
}

# _fw_ufw_active : `ufw status` annonce-t-il « Status: active » ?
_fw_ufw_active() {
  local first=""
  _fw_have ufw || return 1
  IFS= read -r first < <(LC_ALL=C ufw status 2>/dev/null) || true
  [[ "$first" == "Status: active" ]]
}

# Les enregistrements ont la forme « <v4|v6> <allow|limit> <règle> <1|0> » (1 = ouverte à tous).
# Le profil d'application « OpenSSH » compte comme 22/tcp.
_fw_status_records() {
  local line to i rest fam act open
  local -a f
  while IFS= read -r line; do
    read -r -a f <<< "$line"
    ((${#f[@]} >= 3)) || continue
    to="${f[0]}"
    i=1
    fam=v4
    if [[ "${f[i]}" == "(v6)" ]]; then fam=v6; i=$((i + 1)); fi
    case "${f[i]:-}" in
      ALLOW) act=allow ;;
      LIMIT) act=limit ;;
      *) continue ;;
    esac
    i=$((i + 1))
    case "${f[i]:-}" in
      IN) i=$((i + 1)) ;;
      OUT | FWD) continue ;;
    esac
    rest="${f[*]:i}"
    open=0
    [[ "$rest" == Anywhere* ]] && open=1
    if [[ "$to" == OpenSSH ]]; then
      to="22/tcp"
    elif [[ ! "$to" =~ ^[0-9]+(:[0-9]+)?(/(tcp|udp))?$ ]]; then
      continue
    fi
    printf '%s %s %s %s\n' "$fam" "$act" "$to" "$open"
  done < <(LC_ALL=C ufw status 2>/dev/null)
}

# Pare-feu inactif : règles enregistrées, lues dans `ufw show added`.
_fw_added_records() {
  local line i act open src port proto rule
  local -a f
  while IFS= read -r line; do
    read -r -a f <<< "$line"
    [[ "${f[0]:-}" == ufw ]] || continue
    case "${f[1]:-}" in
      allow | limit) act="${f[1]}" ;;
      *) continue ;;
    esac
    i=2
    [[ "${f[i]:-}" == in ]] && i=$((i + 1))
    open=1
    if [[ "${f[i]:-}" == from ]]; then
      src="${f[i + 1]:-}"
      case "${src,,}" in any | anywhere | 0.0.0.0/0) ;; *) open=0 ;; esac
      port="" proto=""
      for ((i = i + 2; i < ${#f[@]}; i++)); do
        [[ "${f[i]}" == port ]] && port="${f[i + 1]:-}"
        [[ "${f[i]}" == proto ]] && proto="${f[i + 1]:-}"
      done
      rule="$port${proto:+/$proto}"
    else
      rule="${f[i]:-}"
      [[ "$rule" == OpenSSH ]] && rule="22/tcp"
    fi
    [[ "$rule" =~ ^[0-9]+(:[0-9]+)?(/(tcp|udp))?$ ]] || continue
    printf 'v4 %s %s %s\n' "$act" "$rule" "$open"
  done < <(LC_ALL=C ufw show added 2>/dev/null)
}

_fw_records() {
  _fw_have ufw || return 0
  if _fw_ufw_active; then _fw_status_records; else _fw_added_records; fi
}

# ufw_current_rules : règles ALLOW/LIMIT actuelles (ufw inactif : règles enregistrées), une par ligne.
ufw_current_rules() {
  local fam act rule open
  local -A seen=()
  while read -r fam act rule open; do
    [[ -z "$rule" || -n "${seen[$rule]:-}" ]] && continue
    seen[$rule]=1
    printf '%s\n' "$rule"
  done < <(_fw_records)
}

# _fw_find <tableau d'enregistrements> <règle> : affiche « limit » ou « allow » si une règle
# IPv4 ouverte à tous couvre <règle> (rien sinon). Une règle IPv6 ou limitée à une source
# ne compte jamais.
_fw_find() {
  local -n _fw_r="$1"
  local want="$2" rec fam act rule open found=""
  for rec in "${_fw_r[@]}"; do
    read -r fam act rule open <<< "$rec"
    [[ "$fam" == v4 && "$open" == 1 ]] || continue
    _fw_covers "$rule" "$want" || continue
    if [[ "$act" == limit ]]; then printf 'limit\n'; return 0; fi
    found=allow
  done
  if [[ -n "$found" ]]; then printf '%s\n' "$found"; fi
  return 0
}

# _fw_ssh_ports : ports SSH à ne jamais couper (sshd, port configuré, connexion courante).
_fw_ssh_ports() {
  sshd_ports
  if [[ "${CFG_UFW_SSH_PORT:-}" =~ ^[0-9]+$ ]] && is_port "$CFG_UFW_SSH_PORT"; then
    printf '%s\n' "$((10#$CFG_UFW_SSH_PORT))"
  fi
  _fw_conn_port
}

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
  local -a out=() allp=()
  local -A seen=()
  real="$(sshd_port)"
  mapfile -t allp < <(sshd_ports)

  if [[ "$ssh" != auto && "$ssh" != none ]] && ! is_port "$ssh"; then
    warn "Port SSH invalide « $ssh » : utilisation du port détecté ($real)" >&2
    ssh=auto
  fi

  case "$ssh" in
    none)
      if _fw_in_ssh_session; then
        warn "Session SSH détectée : port SSH forcé ($real/tcp) malgré UFW_SSH_PORT=none" >&2
        for r in "${allp[@]}"; do out+=("$r/tcp"); done
      fi
      ;;
    auto) for r in "${allp[@]}"; do out+=("$r/tcp"); done ;;
    *)
      ssh=$((10#$ssh))
      if _fw_in_ssh_session && [[ "$ssh" != "$real" ]]; then
        warn "Session SSH sur le port $real, différent de UFW_SSH_PORT=$ssh : les deux sont autorisés" >&2
        for r in "${allp[@]}"; do out+=("$r/tcp"); done
      fi
      out+=("$ssh/tcp")
      ;;
  esac

  r="$(_fw_conn_port)"
  if [[ -n "$r" ]]; then out+=("$r/tcp"); fi

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

# _fw_record_added <règle> : consigne une règle ajoutée (ou qui serait ajoutée en dry-run).
_fw_record_added() {
  if [[ "$DRY_RUN" == "1" ]]; then
    R_UFW_ADDED+=("$1 (dry-run)")
    ok "Règle UFW serait ajoutée : $1"
  else
    R_UFW_ADDED+=("$1")
    ok "Règle UFW ajoutée : $1"
  fi
}

# ufw_apply [--no-enable] <règles…> : installe ufw si besoin, règles SSH, politique par défaut,
# autres règles manquantes, activation (sauf --no-enable).
# Ordre : SSH d'abord, avant tout changement de politique. Une règle SSH est toujours
# soumise à `ufw allow` (idempotent), sauf si une règle LIMIT IPv4 ouverte la couvre déjà.
# Si l'ajout d'une règle SSH échoue : rien d'autre n'est modifié, UFW n'est PAS activé (retour 1).
ufw_apply() {
  local enable=1 r c p kind fam act rule open
  if [[ "${1:-}" == "--no-enable" ]]; then enable=0; shift; fi
  local -a ssh_rules=() other_rules=() recs=() wanted=("$@")
  local -A is_ssh=() seen=()

  if ! _fw_have ufw; then
    info "UFW non installé : installation…"
    if ! _apt "Installation de UFW…" -y install ufw; then
      error "Impossible d'installer ufw"
      return 1
    fi
  fi

  while IFS= read -r p; do
    if [[ -n "$p" ]]; then is_ssh["$p/tcp"]=1; fi
  done < <(_fw_ssh_ports)
  # Défense en profondeur : en session SSH, les ports SSH sont toujours posés, même non demandés.
  if _fw_in_ssh_session; then
    for r in "${!is_ssh[@]}"; do
      case " ${wanted[*]} " in *" $r "*) ;; *) wanted+=("$r") ;; esac
    done
  fi
  for r in "${wanted[@]}"; do
    if [[ -n "${is_ssh[$r]:-}" ]]; then ssh_rules+=("$r"); else other_rules+=("$r"); fi
  done

  mapfile -t recs < <(_fw_records)

  for r in "${ssh_rules[@]}"; do
    kind="$(_fw_find recs "$r")"
    if [[ "$kind" == limit ]]; then
      info "Règle UFW déjà présente (limit) : $r"
      continue
    fi
    if run ufw allow "$r"; then
      if [[ -z "$kind" ]]; then
        _fw_record_added "$r"
      else
        info "Règle UFW déjà présente : $r"
      fi
    else
      error "Impossible d'ajouter la règle SSH $r : politique par défaut inchangée et UFW non activé (risque de perdre l'accès)"
      return 1
    fi
  done

  if ! run ufw default deny incoming; then
    error "ufw default deny incoming a échoué"
    return 1
  fi
  if ! run ufw default allow outgoing; then
    error "ufw default allow outgoing a échoué"
    return 1
  fi

  for r in "${other_rules[@]}"; do
    kind="$(_fw_find recs "$r")"
    if [[ -n "$kind" ]]; then
      info "Règle UFW déjà présente : $r"
      continue
    fi
    if run ufw allow "$r"; then
      _fw_record_added "$r"
    else
      warn "Échec de l'ajout de la règle UFW : $r"
      HAS_PARTIAL_FAILURE=1
    fi
  done

  # Règles déjà présentes mais non demandées (allow, limit, toute source) : signalées, jamais supprimées.
  for c in "${recs[@]}"; do
    read -r fam act rule open <<< "$c"
    [[ -n "$rule" && -z "${seen[$rule]:-}" ]] || continue
    seen[$rule]=1
    kind=0
    for r in "${wanted[@]}"; do
      if _fw_covers "$rule" "$r"; then kind=1; break; fi
    done
    ((kind)) || R_UFW_EXTRA+=("$rule")
  done

  if ((!enable)); then
    if _fw_ufw_active; then
      info "UFW déjà actif : activation inchangée"
    else
      warn "UFW configuré mais non activé. Activez-le avec : sudo ufw enable"
    fi
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
# Affecte aussi la variable locale `no_enable` de configure_firewall (portée dynamique).
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

  confirm "Activer UFW maintenant ?" y || no_enable=1
  return 0
}

# configure_firewall : point d'entrée. CFG_UFW_ENABLE=no => ne touche à rien.
configure_firewall() {
  local plan_file no_enable=0
  local -a requested=() plan=() apply_opts=()

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

  if ((no_enable)); then apply_opts=(--no-enable); fi
  if ! ufw_apply "${apply_opts[@]}" "${plan[@]}"; then
    HAS_PARTIAL_FAILURE=1
    return 1
  fi
}
