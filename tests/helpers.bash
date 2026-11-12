# Aides communes aux tests bats.
# Les tests n'écrivent que dans $BATS_TEST_TMPDIR.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

# load_lib <nom> : source lib/ui.sh puis lib/<nom>.sh
# NB : lib/ui.sh définit sa propre fonction `run`, qui masque celle de bats.
# On conserve donc celle de bats sous le nom `bats_run` (à utiliser dans les tests).
load_lib() {
  if ! declare -F bats_run >/dev/null && declare -F run >/dev/null; then
    eval "bats_run() $(declare -f run | tail -n +2)"
  fi
  # shellcheck source=/dev/null
  source "$REPO_ROOT/lib/ui.sh"
  if [[ "$1" != "ui" ]]; then
    # shellcheck source=/dev/null
    source "$REPO_ROOT/lib/$1.sh"
  fi
}

# stub <cmd> <script> : crée un exécutable factice dans $BATS_TEST_TMPDIR/bin
stub() {
  local cmd="$1" script="$2"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/usr/bin/env bash\n%s\n' "$script" > "$BATS_TEST_TMPDIR/bin/$cmd"
  chmod +x "$BATS_TEST_TMPDIR/bin/$cmd"
  case ":$PATH:" in
    *":$BATS_TEST_TMPDIR/bin:"*) ;;
    *) PATH="$BATS_TEST_TMPDIR/bin:$PATH" ;;
  esac
}

# stub_log <cmd> : faux qui journalise ses arguments (une ligne par appel)
stub_log() {
  local cmd="$1"
  stub "$cmd" "echo \"\$*\" >> \"$BATS_TEST_TMPDIR/$cmd.calls\"; exit 0"
}
