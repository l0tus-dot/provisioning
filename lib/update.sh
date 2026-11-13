#!/usr/bin/env bash
# lib/update.sh : mise à jour du système (apt) et vérification de connexion.
# Bibliothèque : uniquement des définitions, rien ne s'exécute au source.
# Nécessite lib/ui.sh (run, run_with_spinner, info, ok, warn, error).

# _apt <message> <arguments apt-get…> : apt-get non interactif via run_with_spinner.
# Pour install / full-upgrade, les fichiers de configuration modifiés sont conservés
# (--force-confdef --force-confold) : jamais de question dpkg. En MODE=auto, stdin = /dev/null.
_apt() {
  local msg="$1"
  shift
  local -a opts=()
  case " $* " in
    *" install "* | *" full-upgrade "*)
      opts=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold) ;;
    *) ;;
  esac
  if [[ "${MODE:-interactive}" == "auto" ]]; then
    run_with_spinner "$msg" env DEBIAN_FRONTEND=noninteractive apt-get "${opts[@]}" "$@" < /dev/null
  else
    run_with_spinner "$msg" env DEBIAN_FRONTEND=noninteractive apt-get "${opts[@]}" "$@"
  fi
}
# connectivity_check : réussit si `apt-get update` réussit.
connectivity_check() {
  if ! _apt "Vérification des dépôts apt…" update; then
    error "Impossible de joindre les dépôts apt"
    return 1
  fi
}

# system_update : update, full-upgrade (bloquants), autoremove, autoclean (avertissements).
system_update() {
  info "Mise à jour du système…"
  if ! _apt "Actualisation de la liste des paquets…" update; then
    error "Échec de apt-get update"
    return 1
  fi
  if ! _apt "Mise à niveau des paquets…" -y full-upgrade; then
    error "Échec de apt-get full-upgrade"
    return 1
  fi
  _apt "Suppression des paquets inutiles…" -y autoremove \
    || warn "apt-get autoremove a échoué"
  _apt "Nettoyage du cache apt…" autoclean \
    || warn "apt-get autoclean a échoué"
  ok "Système à jour"
}
