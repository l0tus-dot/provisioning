#!/usr/bin/env bash
# lib/tools.sh : installation des outils par gestionnaire explicite (apt, snap, flatpak, pip, npm, cargo).
# Bibliothèque : uniquement des définitions, rien ne s'exécute au source.
# Nécessite lib/ui.sh (run, ok, warn, error, ask_value…), lib/update.sh (_apt)
# et lib/config.sh (is_tool_spec).

: "${CRATES_TOML:=/usr/local/.crates.toml}"
declare -ga TOOLS_SELECTED=()

# _tools_have <commande> : la commande est-elle disponible ? (redéfinissable dans les tests)
_tools_have() { command -v "$1" >/dev/null 2>&1; }

# tool_parse <spec> : définit T_MGR, T_NAME, T_VER (vide sans @).
tool_parse() {
  local spec="$1" rest
  T_MGR="${spec%%:*}"
  rest="${spec#*:}"
  T_NAME="${rest%%@*}"
  if [[ "$rest" == *@* ]]; then T_VER="${rest#*@}"; else T_VER=""; fi
}

# tool_alias <nom> : nom du paquet apt pour un nom courant (saisie interactive uniquement :
# un fichier de configuration nomme toujours le paquet exact).
tool_alias() {
  case "$1" in
    node) echo nodejs ;;
    golang) echo golang-go ;;
    pip) echo python3-pip ;;
    docker) echo docker.io ;;
    postgres) echo postgresql ;;
    fd) echo fd-find ;;
    *) echo "$1" ;;
  esac
}

# apt_resolve_version <paquet> <préfixe> : version la plus récente (selon apt-cache policy)
# dont la valeur, sans `epoch:`, commence par <préfixe> (suivi d'une fin de champ ou d'un
# caractère non numérique). Statut 1 si aucune.
apt_resolve_version() {
  local pkg="$1" prefix="$2" line in_table=0 v bare
  local -a f
  while IFS= read -r line; do
    if [[ "$line" == *"Version table:"* ]]; then in_table=1; continue; fi
    ((in_table)) || continue
    read -r -a f <<< "$line"
    [[ "${f[0]:-}" == '***' ]] && f=("${f[@]:1}")
    # Ligne de version : « <version> <priorité> » ; les lignes de source commencent par la priorité.
    [[ "${#f[@]}" -eq 2 && "${f[1]}" =~ ^[0-9]+$ && ! "${f[0]}" =~ ^[0-9]+$ ]] || continue
    v="${f[0]}"
    if [[ "$v" =~ ^[0-9]+:(.*)$ ]]; then bare="${BASH_REMATCH[1]}"; else bare="$v"; fi
    if [[ "$bare" == "$prefix" ]] || { [[ "$bare" == "$prefix"* ]] && [[ ! "${bare:${#prefix}:1}" =~ [0-9] ]]; }; then
      printf '%s\n' "$v"
      return 0
    fi
  done < <(LC_ALL=C apt-cache policy -- "$pkg" 2>/dev/null)
  return 1
}

# _apt_has_package <nom> : `apt-cache show` doit renvoyer exactement « Package: <nom> »
# (jamais un autre paquet que celui demandé).
_apt_has_package() {
  LC_ALL=C apt-cache show -- "$1" 2>/dev/null \
    | awk -v n="$1" '$0 == "Package: " n { f = 1 } END { exit !f }'
}

# tool_is_installed <gestionnaire> <nom>
tool_is_installed() {
  local mgr="$1" name="$2"
  case "$mgr" in
    apt) [[ "$(LC_ALL=C dpkg-query -W -f='${Status}' -- "$name" 2>/dev/null)" == *"install ok installed"* ]] ;;
    snap) snap list "$name" >/dev/null 2>&1 ;;
    flatpak) flatpak info "$name" >/dev/null 2>&1 ;;
    pip) PIPX_HOME=/opt/pipx LC_ALL=C pipx list --short 2>/dev/null | awk -v n="$name" '$1 == n { f = 1 } END { exit !f }' ;;
    npm) npm ls -g --depth=0 -- "$name" >/dev/null 2>&1 ;;
    cargo) [[ -f "$CRATES_TOML" ]] && grep -Fq -- "\"$name " "$CRATES_TOML" ;;
    *) return 1 ;;
  esac
}

# _tool_installed_version <gestionnaire> <nom> : version installée (vide si inconnue).
_tool_installed_version() {
  local mgr="$1" name="$2"
  case "$mgr" in
    apt) LC_ALL=C dpkg-query -W -f='${Version}' -- "$name" 2>/dev/null ;;
    snap) LC_ALL=C snap list "$name" 2>/dev/null | awk 'NR == 2 { print $2 }' ;;
    flatpak) LC_ALL=C flatpak info "$name" 2>/dev/null | awk '$1 == "Version:" { print $2 }' ;;
    pip) PIPX_HOME=/opt/pipx LC_ALL=C pipx list --short 2>/dev/null | awk -v n="$name" '$1 == n { print $2 }' ;;
    npm) LC_ALL=C npm ls -g --depth=0 -- "$name" 2>/dev/null | sed -n "s/.*[ ]${name}@//p" | head -n 1 ;;
    cargo) [[ -f "$CRATES_TOML" ]] && sed -n "s/^\"${name} \([^ ]*\) .*/\1/p" "$CRATES_TOML" | head -n 1 ;;
  esac
  return 0
}

# _tools_capture <cmd…> : comme run, mais conserve la sortie dans _TOOLS_OUT (et dans le journal).
_tools_capture() {
  if [[ "$DRY_RUN" == "1" ]]; then run "$@"; return; fi
  local tmp rc=0
  tmp="$(mktemp)"
  "$@" > "$tmp" 2>&1 || rc=$?
  _TOOLS_OUT="$(cat "$tmp")"
  if [[ -n "${LOG_FILE:-}" ]]; then cat "$tmp" >> "$LOG_FILE" 2>/dev/null || true; fi
  rm -f "$tmp"
  return "$rc"
}

_tool_record_ok() {
  if [[ "$DRY_RUN" == "1" ]]; then R_TOOLS_OK+=("$1 (dry-run)"); else R_TOOLS_OK+=("$1"); fi
}

_tool_record_fail() {
  error "$2"
  R_TOOLS_FAIL+=("$1")
  HAS_PARTIAL_FAILURE=1
  return 1
}

# tool_install <spec> : 0 si installé ou déjà présent, 1 sinon. Aucune mise à niveau.
tool_install() {
  local spec="$1" mgr name ver pkg full rc=0
  if ! is_tool_spec "$spec"; then
    _tool_record_fail "$spec" "Spécification d'outil invalide : $spec"
    return 1
  fi
  tool_parse "$spec"
  mgr="$T_MGR"; name="$T_NAME"; ver="$T_VER"

  if [[ "$mgr" == flatpak && ! "$name" =~ ^[^.]+(\.[^.]+){2,}$ ]]; then
    _tool_record_fail "$spec" "$spec : flatpak exige l'identifiant complet de l'application (ex. org.gimp.GIMP)"
    return 1
  fi

  if [[ "$DRY_RUN" != "1" ]]; then
    local need="$mgr"
    case "$mgr" in
      apt) need=apt-get ;;
      pip) if _tools_have pipx; then need=pipx; else need=apt-get; fi ;;
    esac
    if ! _tools_have "$need"; then
      _tool_record_fail "$spec" "$spec : gestionnaire $mgr indisponible"
      return 1
    fi
  fi

  if tool_is_installed "$mgr" "$name"; then
    ok "$spec déjà installé"
    if [[ -n "$ver" ]]; then
      local cur
      cur="$(_tool_installed_version "$mgr" "$name")"
      if [[ -n "$cur" && "${cur#*:}" != "$ver"* ]]; then
        warn "$spec : version $cur déjà installée (demandée : $ver), laissée telle quelle"
      fi
    fi
    _tool_record_ok "$spec"
    return 0
  fi

  info "Installation de $spec…"
  case "$mgr" in
    apt)
      if ! _apt_has_package "$name"; then
        _tool_record_fail "$spec" "$spec : paquet apt introuvable"
        return 1
      fi
      pkg="$name"
      if [[ -n "$ver" ]]; then
        if ! full="$(apt_resolve_version "$name" "$ver")"; then
          _tool_record_fail "$spec" "$spec : aucune version apt ne commence par $ver"
          return 1
        fi
        pkg="$name=$full"
      fi
      _apt "Installation de $spec…" install -y -- "$pkg" || rc=$?
      ;;
    snap)
      local -a args=(env LC_ALL=C snap install)
      [[ -n "$ver" ]] && args+=("--channel=$ver/stable")
      args+=("$name")
      _TOOLS_OUT=""
      _tools_capture "${args[@]}" || rc=$?
      if ((rc != 0)) && [[ "$_TOOLS_OUT" == *classic* ]]; then
        info "$spec nécessite le confinement classic, nouvel essai…"
        rc=0
        _tools_capture "${args[@]}" --classic || rc=$?
      fi
      ;;
    flatpak)
      run flatpak install -y --noninteractive flathub "$name" || rc=$?
      ;;
    pip)
      if ! _tools_have pipx && [[ "$DRY_RUN" != "1" ]]; then
        _apt "Installation de pipx…" install -y -- pipx || rc=$?
      fi
      if ((rc == 0)); then
        pkg="$name"
        [[ -n "$ver" ]] && pkg="$name==$ver"
        run env PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin pipx install -- "$pkg" || rc=$?
      fi
      ;;
    npm)
      pkg="$name"
      [[ -n "$ver" ]] && pkg="$name@$ver"
      run npm install -g -- "$pkg" || rc=$?
      ;;
    cargo)
      local -a cargs=(env CARGO_INSTALL_ROOT=/usr/local cargo install --locked)
      [[ -n "$ver" ]] && cargs+=(--version "$ver")
      run "${cargs[@]}" -- "$name" || rc=$?
      ;;
  esac

  if ((rc != 0)); then
    _tool_record_fail "$spec" "Échec de l'installation de $spec"
    return 1
  fi
  ok "$spec installé"
  _tool_record_ok "$spec"
  return 0
}

# _tools_candidates <nom> : gestionnaires (hors apt) où le nom exact existe, un par ligne.
_tools_candidates() {
  local n="$1"
  if _tools_have snap && snap info "$n" >/dev/null 2>&1; then echo snap; fi
  if _tools_have flatpak && flatpak remote-info flathub "$n" >/dev/null 2>&1; then echo flatpak; fi
  if _tools_have pip && pip index versions "$n" >/dev/null 2>&1; then echo pip; fi
  if _tools_have npm && npm view "$n" name >/dev/null 2>&1; then echo npm; fi
  if _tools_have cargo && LC_ALL=C cargo search --limit 1 "$n" 2>/dev/null | grep -Fq "$n = "; then echo cargo; fi
  return 0
}

# tools_interactive : saisie des outils (mode interactif uniquement) ; résultat dans TOOLS_SELECTED.
tools_interactive() {
  if [[ "$MODE" == "auto" ]]; then
    error "tools_interactive ne doit pas être appelé en mode automatique"
    return 1
  fi
  TOOLS_SELECTED=()
  local entry name ver spec alias choice s dup
  local -a cands
  while true; do
    entry="$(ask_value "Outil à installer (nom ou gestionnaire:nom[@version], vide pour terminer)" "")"
    [[ -n "$entry" ]] || break
    spec=""
    if is_tool_spec "$entry"; then
      spec="$entry"
    elif [[ "$entry" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*(@[A-Za-z0-9][A-Za-z0-9._~+-]*)?$ ]]; then
      name="${entry%%@*}"
      ver=""
      [[ "$entry" == *@* ]] && ver="@${entry#*@}"
      alias="$(tool_alias "$name")"
      if _apt_has_package "$alias"; then
        spec="apt:$alias$ver"
      else
        mapfile -t cands < <(_tools_candidates "$name")
        if ((${#cands[@]} == 0)); then
          warn "Aucun gestionnaire ne connaît « $name » : ignoré"
          continue
        fi
        choice="$(ask_value "« $name » trouvé dans : ${cands[*]}. Lequel utiliser ?" "${cands[0]}")"
        dup=0
        for s in "${cands[@]}"; do [[ "$s" == "$choice" ]] && dup=1; done
        if ((dup == 0)); then
          warn "Choix « $choice » invalide : « $name » ignoré"
          continue
        fi
        spec="$choice:$name$ver"
      fi
    fi
    if ! is_tool_spec "$spec"; then
      warn "Entrée invalide : « $entry » ignorée"
      continue
    fi
    dup=0
    for s in "${TOOLS_SELECTED[@]}"; do [[ "$s" == "$spec" ]] && dup=1; done
    ((dup)) || TOOLS_SELECTED+=("$spec")
  done
  return 0
}
