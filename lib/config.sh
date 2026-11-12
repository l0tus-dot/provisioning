#!/usr/bin/env bash
# lib/config.sh : lecture, validation et écriture du fichier de configuration.
# Bibliothèque : uniquement des définitions, rien ne s'exécute au source.
# Le fichier est lu ligne par ligne, jamais exécuté ni sourcé.

# Clés reconnues (sans le préfixe CFG_).
CONFIG_KEYS=(UPDATE_SYSTEM TOOLS DEBIAN_COMPONENTS DEBIAN_BACKPORTS INSTALL_SNAPD
  INSTALL_FLATPAK UFW_ENABLE UFW_SSH_PORT UFW_ALLOW SERVICES_MASK SERVICES_DISABLE REBOOT)

config_defaults() {
  CFG_UPDATE_SYSTEM=yes
  CFG_TOOLS=""
  CFG_DEBIAN_COMPONENTS=""
  CFG_DEBIAN_BACKPORTS=no
  CFG_INSTALL_SNAPD=no
  CFG_INSTALL_FLATPAK=no
  CFG_UFW_ENABLE=yes
  CFG_UFW_SSH_PORT=auto
  CFG_UFW_ALLOW=""
  CFG_SERVICES_MASK=""
  CFG_SERVICES_DISABLE=""
  CFG_REBOOT=no
}

# --- Validateurs ---
is_yes_no() { [[ "${1:-}" == yes || "${1:-}" == no ]]; }

is_port() {
  [[ "${1:-}" =~ ^[0-9]{1,5}$ ]] || return 1
  local n=$((10#$1))
  ((n >= 1 && n <= 65535))
}

# port, port/tcp|udp, ou plage a:b/tcp|udp
is_ufw_rule() {
  local v="${1:-}" a b
  if [[ "$v" =~ ^([0-9]+):([0-9]+)/(tcp|udp)$ ]]; then
    a="${BASH_REMATCH[1]}" b="${BASH_REMATCH[2]}"
    is_port "$a" && is_port "$b" && ((10#$a <= 10#$b))
  elif [[ "$v" =~ ^([0-9]+)(/(tcp|udp))?$ ]]; then
    a="${BASH_REMATCH[1]}"
    is_port "$a"
  else
    return 1
  fi
}

is_tool_spec() {
  local v="${1:-}"
  [[ "$v" =~ ^(apt|snap|flatpak|pip|npm|cargo):[A-Za-z0-9._+-]+(@[A-Za-z0-9._~+-]+)?$ ]] || return 1
  [[ "$v" == flatpak:*@* ]] && return 1
  return 0
}

is_service_name() { [[ "${1:-}" =~ ^[A-Za-z0-9@._-]+$ ]]; }

# _config_all_words <validateur> <liste> : chaque mot doit être valide.
_config_all_words() {
  local fn="$1" w
  # shellcheck disable=SC2086
  for w in $2; do
    "$fn" "$w" || return 1
  done
}

_config_is_component() {
  [[ "$1" == contrib || "$1" == non-free || "$1" == non-free-firmware ]]
}

# _config_valid <clé> <valeur> : 0 si la valeur est valide pour la clé.
_config_valid() {
  local key="$1" val="$2"
  case "$key" in
    UPDATE_SYSTEM | DEBIAN_BACKPORTS | INSTALL_SNAPD | INSTALL_FLATPAK | UFW_ENABLE)
      is_yes_no "$val" ;;
    UFW_SSH_PORT) [[ "$val" == auto || "$val" == none ]] || is_port "$val" ;;
    REBOOT) [[ "$val" == yes || "$val" == no || "$val" == if-needed ]] ;;
    DEBIAN_COMPONENTS) _config_all_words _config_is_component "$val" ;;
    UFW_ALLOW) _config_all_words is_ufw_rule "$val" ;;
    TOOLS) _config_all_words is_tool_spec "$val" ;;
    SERVICES_MASK | SERVICES_DISABLE) _config_all_words is_service_name "$val" ;;
    *) return 1 ;;
  esac
}

_config_known_key() {
  local k
  for k in "${CONFIG_KEYS[@]}"; do
    [[ "$k" == "$1" ]] && return 0
  done
  return 1
}

# config_load <fichier> : charge la configuration (défauts + fichier).
config_load() {
  local file="${1:-}" line key val n=0
  if [[ ! -f "$file" || ! -r "$file" ]]; then
    error "Fichier de configuration introuvable ou illisible : $file"
    return 1
  fi
  config_defaults
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    line="${line//$'\r'/}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    if [[ "$line" != *=* ]]; then
      error "Configuration, ligne $n : « = » manquant"
      return 1
    fi
    key="${line%%=*}"
    val="${line#*=}"
    key="${key%"${key##*[![:space:]]}"}"
    val="${val#"${val%%[![:space:]]*}"}"
    if [[ "$val" =~ ^\"(.*)\"$ || "$val" =~ ^\'(.*)\'$ ]]; then
      val="${BASH_REMATCH[1]}"
    fi
    val="${val#"${val%%[![:space:]]*}"}"
    val="${val%"${val##*[![:space:]]}"}"
    if ! _config_known_key "$key"; then
      error "Configuration, ligne $n : clé inconnue « $key »"
      return 1
    fi
    if [[ "$val" == *[\"\$\`]* ]] || ! _config_valid "$key" "$val"; then
      error "Configuration, ligne $n : valeur invalide pour $key"
      return 1
    fi
    printf -v "CFG_$key" '%s' "$val"
  done < "$file"
}

# config_write <fichier> : écrit toutes les clés CFG_* (valeurs sans « " »).
config_write() {
  local file="${1:-}" k var
  {
    printf '# Configuration de provision.sh\n'
    printf '# Utilisation : provision.sh --config <ce fichier>\n'
    for k in "${CONFIG_KEYS[@]}"; do
      var="CFG_$k"
      printf '%s="%s"\n' "$k" "${!var}"
    done
  } > "$file"
}
