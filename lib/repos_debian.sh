#!/usr/bin/env bash
# lib/repos_debian.sh : dépôts Debian (sources.list classique et deb822), snapd, flatpak.
# Bibliothèque : uniquement des définitions, rien ne s'exécute au source.
# Nécessite lib/ui.sh (run, info, warn, error) et lib/os.sh (OS_VERSION, OS_CODENAME).
# APT_ROOT (défaut /) préfixe tous les chemins touchés (utile pour les tests).

# apt_sources_file [racine] : fichier de sources principal (deb822 s'il existe, sinon classique).
# shellcheck disable=SC2120  # l'argument est optionnel : la plupart des appels n'en passent pas
apt_sources_file() {
  local root="${1:-${APT_ROOT:-/}}"
  root="${root%/}"
  if [[ -f "$root/etc/apt/sources.list.d/debian.sources" ]]; then
    printf '%s\n' "$root/etc/apt/sources.list.d/debian.sources"
  else
    printf '%s\n' "$root/etc/apt/sources.list"
  fi
}

# _repos_dry <message> : affiche et journalise une action simulée.
_repos_dry() {
  printf '[dry-run] %s\n' "$*"
  _ui_log "[dry-run] $*"
}

# _repos_filter_components <tableau-résultat> <composant…> : remplit le tableau (nameref).
# Ignore non-free-firmware (avec avertissement) avant Debian 12 ; sans doublon.
_repos_filter_components() {
  local -n _out="$1"
  shift
  local c d dup major="${OS_VERSION%%.*}"
  _out=()
  for c in "$@"; do
    if [[ "$c" == "non-free-firmware" && "$major" =~ ^[0-9]+$ && "$major" -lt 12 ]]; then
      warn "Le composant non-free-firmware n'existe pas avant Debian 12 : ignoré"
      continue
    fi
    dup=0
    for d in "${_out[@]}"; do [[ "$d" == "$c" ]] && dup=1; done
    [[ $dup -eq 1 ]] || _out+=("$c")
  done
}

# Fonctions awk communes : isdeb(uri) vrai pour un hôte debian.org (ou sous-domaine) ou un
# miroir dont le chemin finit par /debian ou /debian-security.
# shellcheck disable=SC2016
_REPOS_AWK_COMMON='
function isdeb(u,   p, host, path) {
  if (u !~ /^https?:[/][/]/) return 0
  sub(/^https?:[/][/]/, "", u)
  p = index(u, "/")
  host = (p ? substr(u, 1, p - 1) : u)
  path = (p ? substr(u, p) : "")
  sub(/:[0-9]+$/, "", host)
  return (host ~ /(^|[.])debian[.]org$/ || path ~ /[/]debian(-security)?[/]?$/)
}
'

# Programme awk : format classique (sources.list). Seuls les dépôts Debian (voir isdeb) ayant
# déjà le composant main sont modifiés (tiers et cdrom: intacts). Variables : suites, comps.
# shellcheck disable=SC2016  # le programme awk contient des $ littéraux
_REPOS_AWK_CLASSIC='
BEGIN { ns = split(suites, S, " "); nc = split(comps, C, " ") }
/^[ \t]*deb(-src)?[ \t]/ {
  i = 2
  if ($i ~ /^\[/) { while (i <= NF && $i !~ /\]$/) i++; i++ }
  if (i + 1 > NF || !isdeb($i)) { print; next }
  suite = $(i + 1); hit = 0
  for (k = 1; k <= ns; k++) if (suite == S[k]) hit = 1
  if (!hit) { print; next }
  last = i + 1
  delete have
  for (j = i + 2; j <= NF && $j !~ /^#/; j++) { have[$j] = 1; last = j }
  if (!("main" in have)) { print; next }
  add = ""
  for (k = 1; k <= nc; k++) if (!(C[k] in have)) { add = add " " C[k]; have[C[k]] = 1 }
  if (add == "") { print; next }
  out = $1
  for (j = 2; j <= last; j++) out = out " " $j
  out = out add
  for (j = last + 1; j <= NF; j++) out = out " " $j
  print out
  next
}
{ print }
'

# Programme awk : format deb822 (paragraphes séparés par des lignes vides).
# shellcheck disable=SC2016
_REPOS_AWK_DEB822='
BEGIN { ns = split(suites, S, " "); nc = split(comps, C, " ") }
function flush(   k, k2, m, w, deb, hit, ci, add, have, cw, nw) {
  if (n == 0) return
  hit = 0; ci = 0; deb = 0
  for (k = 1; k <= n; k++) if (L[k] ~ /^[Uu][Rr][Ii][Ss]:/) {
    nw = split(L[k], w, /[ \t]+/)
    for (m = 2; m <= nw; m++) if (isdeb(w[m])) deb = 1
  }
  for (k = 1; k <= n; k++) {
    if (L[k] ~ /^[Ss]uites:/) {
      nw = split(L[k], w, /[ \t]+/)
      for (m = 2; m <= nw; m++) for (k2 = 1; k2 <= ns; k2++) if (w[m] == S[k2]) hit = 1
    }
    if (L[k] ~ /^[Cc]omponents:/) ci = k
  }
  if (deb && hit && ci) {
    nw = split(L[ci], cw, /[ \t]+/)
    for (m = 2; m <= nw; m++) have[cw[m]] = 1
    add = ""
    if ("main" in have) {
      for (k = 1; k <= nc; k++) if (!(C[k] in have)) { add = add " " C[k]; have[C[k]] = 1 }
      sub(/[ \t]+$/, "", L[ci])
      L[ci] = L[ci] add
    }
  }
  for (k = 1; k <= n; k++) print L[k]
  n = 0
}
/^[ \t]*$/ { flush(); print; next }
{ L[++n] = $0 }
END { flush() }
'

# debian_add_components <fichier> <codename> <composant…>
debian_add_components() {
  local file="$1" codename="$2"
  shift 2
  local -a wanted=()
  _repos_filter_components wanted "$@"
  [[ ${#wanted[@]} -gt 0 ]] || return 0
  if [[ ! -f "$file" ]]; then
    warn "Fichier de sources introuvable : $file"
    return 1
  fi

  local prog
  if [[ "$file" == *.sources ]]; then prog="$_REPOS_AWK_DEB822"; else prog="$_REPOS_AWK_CLASSIC"; fi
  local suites="$codename $codename-updates $codename-security"
  local new
  # Le "x" final protège les retours à la ligne terminaux de la substitution de commande.
  new="$(awk -v suites="$suites" -v comps="${wanted[*]}" "$_REPOS_AWK_COMMON$prog" "$file" || exit 1; printf x)" || {
    error "Échec de la modification de $file"
    return 1
  }
  new="${new%x}"
  local old
  old="$(cat "$file"; printf x)"
  old="${old%x}"
  # awk termine toujours la dernière ligne par un saut de ligne : normaliser avant de comparer.
  [[ -z "$old" || "$old" == *$'\n' ]] || old+=$'\n'
  if [[ "$new" == "$old" ]]; then
    return 0
  fi

  # Sauvegarde hors de sources.list.d (apt avertit sur les fichiers inconnus de ce dossier).
  local backup bdir="${APT_ROOT:-/}"
  bdir="${bdir%/}/var/backups/provision"
  backup="$bdir/$(basename -- "$file").bak-$(date +%Y%m%d)"
  if [[ "$DRY_RUN" == "1" ]]; then
    _repos_dry "ajouter les composants ${wanted[*]} à $file (sauvegarde : $backup)"
    R_REPOS+=("composants ${wanted[*]} ($file) (dry-run)")
    return 0
  fi
  mkdir -p "$bdir" || { error "Création du dossier de sauvegarde impossible : $bdir"; return 1; }
  [[ -e "$backup" ]] || cp -p "$file" "$backup" || { error "Sauvegarde impossible : $backup"; return 1; }
  local tmp
  tmp="$(mktemp "$file.XXXXXX")" || { error "Création du fichier temporaire impossible"; return 1; }
  # Même mode/propriétaire que l'original, puis contenu remplacé de façon atomique.
  # mktemp crée en 0600 : repli sur 644 root:root pour que l'utilisateur _apt puisse lire.
  chmod --reference="$file" "$tmp" 2>/dev/null || chmod 644 "$tmp" || { rm -f "$tmp"; error "chmod impossible sur $tmp"; return 1; }
  if ! chown --reference="$file" "$tmp" 2>/dev/null; then
    chown root:root "$tmp" 2>/dev/null || [[ "$(id -u)" -ne 0 ]] || { rm -f "$tmp"; error "chown impossible sur $tmp"; return 1; }
  fi
  if ! { printf '%s' "$new" > "$tmp" && mv -f "$tmp" "$file"; }; then
    rm -f "$tmp"
    error "Échec de l'écriture de $file"
    return 1
  fi
  R_REPOS+=("composants ${wanted[*]} ($file)")
  info "Composants ajoutés dans $file : ${wanted[*]}"
}

# debian_enable_backports <codename> <composant…>
debian_enable_backports() {
  local codename="$1"
  shift
  local root="${APT_ROOT:-/}"
  root="${root%/}"
  local main_file ext
  main_file="$(apt_sources_file)"
  if [[ "$main_file" == *.sources ]]; then ext=sources; else ext=list; fi
  local dir="$root/etc/apt/sources.list.d"
  local target="$dir/$codename-backports.$ext"
  if [[ -e "$target" || -e "$dir/$codename-backports.sources" || -e "$dir/$codename-backports.list" ]]; then
    info "Dépôt backports déjà configuré pour $codename"
    return 0
  fi

  local -a comps=()
  _repos_filter_components comps main "$@"
  local content
  if [[ "$ext" == sources ]]; then
    content="Types: deb
URIs: http://deb.debian.org/debian
Suites: $codename-backports
Components: ${comps[*]}
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
"
  else
    content="deb http://deb.debian.org/debian $codename-backports ${comps[*]}
"
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    _repos_dry "créer $target (backports $codename : ${comps[*]})"
  else
    if ! { mkdir -p "$dir" && printf '%s' "$content" > "$target"; }; then
      error "Impossible de créer $target"
      return 1
    fi
    chmod 644 "$target"
    info "Dépôt backports créé : $target"
  fi
  R_REPOS+=("backports $codename")
}

# debian_install_snapd : snapd + activation du socket.
debian_install_snapd() {
  info "Installation de snapd…"
  if ! run env DEBIAN_FRONTEND=noninteractive apt-get install -y snapd; then
    error "Échec de l'installation de snapd"
    return 1
  fi
  if ! run systemctl enable --now snapd.socket; then
    error "Impossible d'activer snapd.socket"
    return 1
  fi
  # Sans cela, un `snap install` immédiat peut échouer (« too early for operation »).
  run snap wait system seed.loaded || warn "snapd n'a pas fini son initialisation (snap wait a échoué)"
  R_REPOS+=("snapd")
}

# debian_install_flatpak : flatpak + dépôt Flathub (utilisable aussi sur Ubuntu).
debian_install_flatpak() {
  info "Installation de flatpak…"
  if ! run env DEBIAN_FRONTEND=noninteractive apt-get install -y flatpak; then
    error "Échec de l'installation de flatpak"
    return 1
  fi
  if ! run flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo; then
    error "Impossible d'ajouter le dépôt Flathub"
    return 1
  fi
  R_REPOS+=("flathub")
}
