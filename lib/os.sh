#!/usr/bin/env bash
# Détection de la distribution (lecture de /etc/os-release par parsing, jamais `source`).
# Bibliothèque : ne contient que des définitions.

OS_ID=""
OS_VERSION=""
OS_CODENAME=""
OS_PRETTY=""
OS_DERIVED=0   # 1 si OS_ID provient de ID_LIKE (dérivé : Mint, Raspbian…)

# os_detect [fichier] : renseigne OS_ID, OS_VERSION, OS_CODENAME, OS_PRETTY.
os_detect() {
  local file="${1:-${OS_RELEASE_FILE:-/etc/os-release}}"
  local line key val id="" id_like="" version="" codename="" ubuntu_codename="" pretty=""

  if [[ ! -r "$file" ]]; then
    echo "Fichier de description du système illisible : $file" >&2
    return 1
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*([A-Z_]+)=(.*)$ ]] || continue
    key="${BASH_REMATCH[1]}"
    val="${BASH_REMATCH[2]}"
    if [[ "$val" =~ ^\"(.*)\"[[:space:]]*$ ]] || [[ "$val" =~ ^\'(.*)\'[[:space:]]*$ ]]; then
      val="${BASH_REMATCH[1]}"
    fi
    case "$key" in
      ID) id="${val,,}" ;;
      ID_LIKE) id_like="${val,,}" ;;
      VERSION_ID) version="$val" ;;
      VERSION_CODENAME) codename="$val" ;;
      UBUNTU_CODENAME) ubuntu_codename="$val" ;;
      PRETTY_NAME) pretty="$val" ;;
      *) ;;
    esac
  done < "$file"

  OS_DERIVED=0
  if [[ "$id" != "ubuntu" && "$id" != "debian" && -n "$id_like" ]]; then
    local -a like=()
    local w
    read -r -a like <<< "$id_like"
    for w in "${like[@]}"; do
      if [[ "$w" == "ubuntu" ]]; then id="ubuntu"; OS_DERIVED=1; break; fi
    done
    if [[ "$OS_DERIVED" -eq 0 ]]; then
      for w in "${like[@]}"; do
        if [[ "$w" == "debian" ]]; then id="debian"; OS_DERIVED=1; break; fi
      done
    fi
  fi

  # Dérivés d'Ubuntu : le nom de code Ubuntu sert à l'affichage.
  if [[ "$OS_DERIVED" -eq 1 && "$id" == "ubuntu" && -n "$ubuntu_codename" ]]; then
    codename="$ubuntu_codename"
  fi

  OS_ID="$id"
  OS_VERSION="$version"
  OS_CODENAME="$codename"
  OS_PRETTY="$pretty"
}

# os_supported : 0 si Ubuntu 22.04/24.04/26.04 ou Debian 11/12/13 (hors dérivés).
os_supported() {
  [[ "$OS_DERIVED" -eq 0 ]] || return 1
  case "$OS_ID:$OS_VERSION" in
    ubuntu:22.04 | ubuntu:24.04 | ubuntu:26.04) return 0 ;;
    debian:11 | debian:12 | debian:13) return 0 ;;
    *) return 1 ;;
  esac
}

# os_family : affiche « ubuntu » ou « debian » (dérivés inclus) ; 1 sinon.
os_family() {
  case "$OS_ID" in
    ubuntu | debian) echo "$OS_ID" ;;
    *) return 1 ;;
  esac
}
