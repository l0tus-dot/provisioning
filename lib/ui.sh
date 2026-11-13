#!/usr/bin/env bash
# lib/ui.sh : affichage, questions, exécution (journal, dry-run, spinner).
# Bibliothèque : uniquement des définitions, rien ne s'exécute au source.

# --- Globales partagées (non écrasées si le fichier est sourcé à nouveau) ---
: "${MODE:=interactive}"          # interactive | auto
: "${DRY_RUN:=0}"                 # 0 | 1
: "${LOG_FILE:=}"
: "${HAS_PARTIAL_FAILURE:=0}"     # 0 | 1
_ui_declare_array() {
  if ! declare -p "$1" 2>/dev/null | grep -q '^declare -a'; then
    declare -ga "$1=()"
  fi
}
for _ui_arr in R_TOOLS_OK R_TOOLS_FAIL R_REPOS R_UFW_ADDED R_UFW_EXTRA \
               R_SVC_MASKED R_SVC_DISABLED R_WARNINGS R_ERRORS; do
  _ui_declare_array "$_ui_arr"
done
unset _ui_arr

# --- Sortie ---
_ui_is_tty() { [[ -t 1 ]]; }

# _ui_print <couleur ANSI> <étiquette> <message…>
_ui_print() {
  local color="$1" label="$2"
  shift 2
  local msg="$*"
  if _ui_is_tty; then
    printf '\033[%sm%s\033[0m %s\n' "$color" "$label" "$msg"
  else
    printf '%s %s\n' "$label" "$msg"
  fi
  _ui_log "$label $msg"
}

# Ajoute une ligne (sans couleur) au journal si défini.
_ui_log() {
  [[ -n "${LOG_FILE:-}" ]] || return 0
  printf '%s\n' "$*" >> "$LOG_FILE" 2>/dev/null || true
}

info()  { _ui_print '1;34' '[INFO]' "$@"; }
ok()    { _ui_print '1;32' '[ OK ]' "$@"; }
warn()  { R_WARNINGS+=("$*"); _ui_print '1;33' '[WARN]' "$@"; }
error() { R_ERRORS+=("$*"); _ui_print '1;31' '[ERR ]' "$@" >&2; }
step()  { printf '\n' ; _ui_print '1;36' '==>' "$@"; }

# --- Questions ---
# confirm <question> <défaut y|n> : code 0 = oui. Jamais de lecture en MODE=auto.
confirm() {
  local question="$1" default="${2:-n}" reply prompt
  if [[ "$MODE" == "auto" ]]; then
    [[ "$default" == "y" ]]
    return
  fi
  if [[ "$default" == "y" ]]; then prompt="[O/n]"; else prompt="[o/N]"; fi
  read -r -p "$question $prompt " reply </dev/tty || reply=""
  case "${reply,,}" in
    o|y|oui|yes) return 0 ;;
    n|non|no) return 1 ;;
    *) [[ "$default" == "y" ]] ;;
  esac
}

# ask_value <question> <défaut> : écrit la réponse sur stdout.
ask_value() {
  local question="$1" default="${2:-}" reply=""
  if [[ "$MODE" == "auto" ]]; then
    printf '%s\n' "$default"
    return 0
  fi
  read -r -p "$question [$default] " reply </dev/tty || reply=""
  printf '%s\n' "${reply:-$default}"
}

# --- Exécution ---
# run <cmd…> : dry-run => affiche seulement ; sinon exécute, sortie vers le journal.
run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '[dry-run] %s\n' "$*"
    _ui_log "[dry-run] $*"
    return 0
  fi
  local rc=0
  if [[ -n "${LOG_FILE:-}" ]]; then
    "$@" >> "$LOG_FILE" 2>&1 || rc=$?
  else
    "$@" >/dev/null 2>&1 || rc=$?
  fi
  return "$rc"
}

# term_cols : largeur du terminal, 80 par défaut.
term_cols() {
  local cols=""
  if command -v tput >/dev/null 2>&1; then
    cols="$(tput cols 2>/dev/null || true)"
  fi
  [[ "$cols" =~ ^[0-9]+$ && "$cols" -gt 0 ]] || cols=80
  printf '%s\n' "$cols"
}

# run_with_spinner <message> <cmd…> : comme run, avec spinner sur un terminal.
run_with_spinner() {
  local msg="$1"
  shift
  if [[ "$DRY_RUN" == "1" ]] || ! _ui_is_tty; then
    run "$@"
    return
  fi
  local frames="|/-\\" i=0 pid rc=0
  run "$@" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r%s %s' "${frames:i%4:1}" "$msg"
    i=$((i + 1))
    sleep 0.1
  done
  wait "$pid" || rc=$?
  printf '\r\033[K'
  return "$rc"
}
