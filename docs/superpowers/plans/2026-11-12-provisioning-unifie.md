# Provisioning unifié — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remplacer `ubuntu-setup.sh` et `debian-setup.sh` par un `provision.sh` unique, interactif par défaut et automatique avec `--config`, sûr à relancer et sans risque de coupure SSH.

**Architecture:** `provision.sh` analyse les options, charge `lib/*.sh` et enchaîne les étapes. Chaque module expose des fonctions pures (testables avec des fichiers d'exemple) et des fonctions d'action qui passent toutes par `run` (respecte `--dry-run` et journalise). Les commandes système (`apt-get`, `systemctl`, `ufw`, `sshd`, `snap`…) sont appelées par leur nom : les tests les remplacent par des faux placés en tête de `PATH`.

**Tech Stack:** Bash ≥ 5, bats-core 1.11.1 (sous-module `tests/vendor/bats-core`), shellcheck, GitHub Actions, Docker (CI seulement).

**Spec:** `docs/superpowers/specs/2026-11-12-provisioning-unifie-design.md`

## Global Constraints

- Bash ≥ 5 ; aucune dépendance hors paquets de base Ubuntu/Debian (pipx installé via apt seulement si un outil `pip:` est demandé).
- Versions supportées : Ubuntu 22.04 / 24.04 / 26.04, Debian 11 / 12 / 13. Autre OS : refus en `--config`, avertissement + confirmation en interactif.
- Exécution en root (sauf `--help`, `--version`, et `--dry-run` qui avertit seulement).
- Messages utilisateur en français.
- Mode `--config` : **aucune lecture de `/dev/tty`**, jamais.
- Codes de sortie : `0` OK, `1` erreur bloquante, `2` échecs partiels.
- Journal par défaut : `/var/log/provision/provision-AAAAMMJJ-HHMMSS.log` ; rapport : `/var/log/provision/rapport-AAAAMMJJ-HHMMSS.txt`.
- Tous les `*.sh` en fins de ligne LF (`.gitattributes`), `set -Eeuo pipefail` dans `provision.sh`, shellcheck sans erreur.
- Les bibliothèques ne s'exécutent pas quand on les source (que des définitions) ; `provision.sh` n'exécute `main` que si `${BASH_SOURCE[0]} == $0`.

## Review Focus

1. **Session SSH + UFW avec `UFW_SSH_PORT=none` ou port sshd non standard** → le port réel de sshd est autorisé avant `ufw enable`. Test : Task 7 `ssh guard overrides none`.
2. **Valeur de config entre guillemets, avec espaces finaux ou CRLF** (fichier édité sous Windows) → lue correctement, pas d'erreur « valeur invalide ». Test : Task 2 `config tolerates CRLF and quotes`.
3. **`apt-get` silencieux mais en succès** (ancien bug du `grep -v`) → l'outil est compté installé. Test : Task 6 `apt install success with no output`.
4. **Relance sur une machine déjà provisionnée** → aucune ligne de dépôt ni règle UFW dupliquée, outils déjà présents ignorés. Tests : Task 5 `components idempotent`, Task 6 `already installed is skipped`, Task 7 `existing rule not re-added`.
5. **Exécution sans terminal** (`ssh machine 'sudo bash provision.sh --config …'` sans `-t`, `TERM` vide) → pas d'erreur `tput`, pas de blocage. Test : Task 1 `ui works without TERM`.

---

## File Structure

| Fichier | Responsabilité |
|---|---|
| `provision.sh` | options, chargement des libs, orchestration, `main` |
| `lib/ui.sh` | couleurs, `info/ok/warn/error/step`, `confirm`, `ask_value`, `run`, journalisation |
| `lib/config.sh` | `config_defaults`, `config_load`, `config_write`, validateurs |
| `lib/os.sh` | `os_detect`, `os_supported` |
| `lib/update.sh` | `system_update` |
| `lib/repos_debian.sh` | composants, backports, snapd/flatpak |
| `lib/tools.sh` | parsing `gestionnaire:nom@version`, installation par gestionnaire |
| `lib/firewall.sh` | validation des ports, port sshd, règles, garde-fou SSH |
| `lib/services.sh` | classification, existence, mask/disable |
| `lib/report.sh` | collecte des résultats, rapport, code de sortie |
| `examples/parc.conf`, `examples/poste.conf` | configs commentées |
| `scripts/bundle.sh` | génère `dist/provision.sh` autonome |
| `tests/*.bats`, `tests/helpers.bash`, `tests/fixtures/`, `tests/run.sh` | tests |
| `tests/smoke.sh` | test de fumée exécuté dans les conteneurs |
| `.github/workflows/ci.yml`, `.github/workflows/release.yml` | CI et releases |
| `.gitattributes`, `.gitignore` (`dist/`) | |

Variables globales partagées (définies dans `lib/ui.sh` / `lib/report.sh`) : `MODE` (`interactive`|`auto`), `DRY_RUN` (`0`|`1`), `LOG_FILE`, et les tableaux de rapport `R_TOOLS_OK R_TOOLS_FAIL R_REPOS R_UFW_ADDED R_UFW_EXTRA R_SVC_MASKED R_SVC_DISABLED R_WARNINGS`, plus `HAS_PARTIAL_FAILURE` (`0`|`1`).

---

### Task 1: Squelette, UI, outillage de test et CI de base

**Files:**
- Create: `provision.sh`, `lib/ui.sh`, `tests/helpers.bash`, `tests/run.sh`, `tests/ui.bats`, `tests/cli.bats`, `.gitattributes`, `.gitignore`, `.github/workflows/ci.yml`
- Submodule: `tests/vendor/bats-core` → `https://github.com/bats-core/bats-core` tag `v1.11.1`

**Interfaces:**
- Produces (`lib/ui.sh`):
  - `info|ok|warn|error|step <msg…>` — affichent (couleurs seulement si stdout est un terminal) et ajoutent la ligne sans couleur à `$LOG_FILE` si défini. `warn` ajoute aussi à `R_WARNINGS`.
  - `confirm <question> <défaut y|n>` → code 0 = oui. En `MODE=auto` : ne lit rien, renvoie le défaut.
  - `ask_value <question> <défaut>` → écrit la réponse sur stdout. En `MODE=auto` : renvoie le défaut.
  - `run <cmd…>` → si `DRY_RUN=1` affiche `[dry-run] cmd…` et renvoie 0 ; sinon exécute, envoie stdout/stderr dans le journal, renvoie le code de la commande.
  - `term_cols` → `tput cols` si possible, sinon `80`.
  - `run_with_spinner <msg> <cmd…>` → comme `run`, avec spinner si terminal ; renvoie le code de la commande (corrige le bug `((i++))`).
- Produces (`provision.sh`): `parse_args "$@"` remplit `MODE`, `CONFIG_FILE`, `DRY_RUN`, `LOG_FILE` ; `--help` affiche l'usage et sort 0 ; `--version` affiche `provision 2.0.0` ; option inconnue → message + sortie 1.
- `tests/helpers.bash` : `load_lib <nom>` (source `lib/<nom>.sh` + `lib/ui.sh`), `stub <cmd> <script>` (crée un exécutable dans `$BATS_TEST_TMPDIR/bin`, préfixé à `PATH`), `stub_log <cmd>` (faux qui écrit ses arguments dans `$BATS_TEST_TMPDIR/<cmd>.calls`).

- [ ] **Step 1:** Ajouter `.gitattributes` (`*.sh text eol=lf`, `*.bats text eol=lf`, `*.bash text eol=lf`, `*.conf text eol=lf`), `.gitignore` (`dist/`), le sous-module bats et `tests/run.sh` (utilise `bats` du PATH, sinon `tests/vendor/bats-core/bin/bats`, sur `tests/`).
- [ ] **Step 2: Tests qui échouent** — `tests/ui.bats` :
  - `confirm in auto mode returns default without reading tty` : `MODE=auto; confirm "x" y </dev/null` → 0 ; `confirm "x" n` → 1.
  - `ask_value in auto mode returns default` → sortie `22`.
  - `run in dry-run does not execute` : `DRY_RUN=1 run touch "$f"` → `$f` absent, sortie contient `[dry-run] touch`.
  - `run returns command exit code` : `run false` → statut 1.
  - `run_with_spinner returns failure code` : `run_with_spinner "x" bash -c 'exit 3'` → statut 3, et le script ne s'arrête pas avant (appelé sous `set -e` dans un sous-shell).
  - `ui works without TERM` : `env -u TERM bash -c 'source lib/ui.sh; term_cols; step titre'` → statut 0, sortie contient `80`.
  - `log file receives uncolored lines` : `LOG_FILE=$f; ok "bonjour"` → `$f` contient `bonjour`, pas de `\033`.
  `tests/cli.bats` : `--help` (statut 0, contient `--config`), `--version` (`provision 2.0.0`), `--bogus` (statut 1).
- [ ] **Step 3:** `tests/run.sh` → FAIL (fichiers absents).
- [ ] **Step 4:** Implémenter `lib/ui.sh` et le squelette `provision.sh` (`main` appelle pour l'instant seulement `parse_args`).
- [ ] **Step 5:** `tests/run.sh` → PASS.
- [ ] **Step 6:** `ci.yml` : job `lint` (`shellcheck -x provision.sh lib/*.sh scripts/*.sh tests/smoke.sh`) et job `unit` (`git submodule update --init` puis `tests/run.sh`) sur `ubuntu-latest`.
- [ ] **Step 7:** Commit `feat: squelette provision.sh, UI et outillage de test`.

### Task 2: Fichier de configuration

**Files:** Create `lib/config.sh`, `tests/config.bats`, `tests/fixtures/config/*.conf`

**Interfaces:**
- Consumes: `error` (Task 1).
- Produces:
  - `config_defaults` → définit `CFG_UPDATE_SYSTEM=yes CFG_TOOLS="" CFG_DEBIAN_COMPONENTS="" CFG_DEBIAN_BACKPORTS=no CFG_INSTALL_SNAPD=no CFG_INSTALL_FLATPAK=no CFG_UFW_ENABLE=yes CFG_UFW_SSH_PORT=auto CFG_UFW_ALLOW="" CFG_SERVICES_MASK="" CFG_SERVICES_DISABLE="" CFG_REBOOT=no`.
  - `config_load <fichier>` → appelle `config_defaults`, lit ligne par ligne (**jamais `source`**), retire `\r`, espaces de bord, commentaires `#` en début de ligne et guillemets `"…"`/`'…'` entourant la valeur. Erreur (statut 1, message avec numéro de ligne) si : clé inconnue, ligne sans `=`, valeur invalide.
  - `config_write <fichier>` → écrit toutes les clés `CFG_*` au format `CLÉ="valeur"` avec un en-tête commentaire ; `config_load` de ce fichier redonne les mêmes valeurs.
  - Validateurs réutilisés ailleurs : `is_yes_no <v>`, `is_port <v>` (entier 1–65535), `is_ufw_rule <v>` (`port` ou `port/tcp|udp`, ou plage `a:b/tcp|udp`), `is_tool_spec <v>` (voir Task 6 pour la grammaire : `^(apt|snap|flatpak|pip|npm|cargo):[A-Za-z0-9._+-]+(@[A-Za-z0-9._~+-]+)?$`, `@` interdit pour `flatpak`).
  - Valeurs : `UPDATE_SYSTEM/DEBIAN_BACKPORTS/INSTALL_SNAPD/INSTALL_FLATPAK/UFW_ENABLE` ∈ `yes|no` ; `UFW_SSH_PORT` ∈ `auto|none|<port>` ; `REBOOT` ∈ `yes|no|if-needed` ; `DEBIAN_COMPONENTS` ⊂ `{contrib, non-free, non-free-firmware}` ; chaque mot de `UFW_ALLOW` passe `is_ufw_rule`, chaque mot de `TOOLS` passe `is_tool_spec` ; noms de service `^[A-Za-z0-9@._-]+$`.

- [ ] **Step 1: Tests qui échouent** :
  - `defaults when file is empty` → `CFG_UFW_SSH_PORT == auto`, `CFG_REBOOT == no`.
  - `config tolerates CRLF and quotes` : fixture CRLF avec `TOOLS="apt:git snap:code"  ` → `CFG_TOOLS == "apt:git snap:code"`.
  - `unknown key fails with line number` : `UFW_ALOW=80` en ligne 3 → statut 1, sortie contient `ligne 3` et `UFW_ALOW`.
  - `invalid values fail` (une fixture par cas) : `REBOOT=maybe`, `UFW_SSH_PORT=70000`, `UFW_ALLOW="80/icmp"`, `TOOLS="flatpak:org.gimp.GIMP@2.10"`, `TOOLS="git"`, `DEBIAN_COMPONENTS="main"`.
  - `config is not executed` : fixture `TOOLS=$(touch /tmp/pwned)` → statut 1, fichier non créé.
  - `write then load round-trips` : valeurs non par défaut → identiques après rechargement.
- [ ] **Step 2:** Lancer → FAIL.
- [ ] **Step 3:** Implémenter `lib/config.sh`.
- [ ] **Step 4:** Lancer → PASS.
- [ ] **Step 5:** Commit `feat: lecture et validation du fichier de configuration`.

### Task 3: Détection de l'OS

**Files:** Create `lib/os.sh`, `tests/os.bats`, `tests/fixtures/os-release/{ubuntu-22.04,ubuntu-24.04,ubuntu-26.04,debian-11,debian-12,debian-13,fedora-41,linuxmint-22}`

**Interfaces:**
- Produces: `os_detect [fichier=${OS_RELEASE_FILE:-/etc/os-release}]` → définit `OS_ID` (`ubuntu`|`debian`|autre, via `ID` puis `ID_LIKE`), `OS_VERSION` (`VERSION_ID`), `OS_CODENAME` (`VERSION_CODENAME`, ou `UBUNTU_CODENAME` pour les dérivés), `OS_PRETTY`. Lecture par parsing, pas `source`.
- `os_supported` → 0 si (`ubuntu` et version ∈ 22.04/24.04/26.04) ou (`debian` et version ∈ 11/12/13).
- `os_family` → `ubuntu` ou `debian` (dérivé d'Ubuntu comme Mint → `ubuntu` via `ID_LIKE`, mais `os_supported` → 1 car `VERSION_ID` n'est pas une version Ubuntu ; utiliser alors `UBUNTU_CODENAME` seulement pour l'affichage).

- [ ] **Step 1: Tests qui échouent** : chaque fixture supportée → `os_supported` 0 avec `OS_ID`/`OS_CODENAME` attendus (`jammy noble` + codename 26.04 de la fixture, `bullseye bookworm trixie`) ; `fedora-41` → `os_supported` 1 ; `linuxmint-22` → `os_family == ubuntu`, `os_supported` 1.
- [ ] **Step 2:** FAIL. **Step 3:** Implémenter. **Step 4:** PASS.
- [ ] **Step 5:** Commit `feat: détection de la distribution`.

### Task 4: Mise à jour du système

**Files:** Create `lib/update.sh`, `tests/update.bats`

**Interfaces:**
- Consumes: `run_with_spinner`, `run`, `error`, `info`, `ok` (Task 1).
- Produces: `system_update` → statut 0 ou 1. Séquence exacte, avec `DEBIAN_FRONTEND=noninteractive` exporté :
  1. `apt-get update`
  2. `apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold full-upgrade`
  3. `apt-get -y autoremove`
  4. `apt-get autoclean`
  Échec d'une des deux premières → `error` + statut 1 (l'appelant sort en 1). Échec de 3 ou 4 → `warn` seulement.
- `connectivity_check` → remplace le ping : succès si `apt-get update` (étape 1) réussit ; utilisé par `provision.sh` comme vérification de connexion (message « Impossible de joindre les dépôts apt »).

- [ ] **Step 1: Tests qui échouent** (faux `apt-get` via `stub_log`) :
  - `update runs full-upgrade with confold` → `apt-get.calls` contient dans l'ordre `update`, la ligne `full-upgrade` avec `--force-confold`, `autoremove`, `autoclean`.
  - `upgrade failure returns 1` : faux `apt-get` qui échoue sur `full-upgrade` → statut 1.
  - `autoremove failure only warns` → statut 0, `R_WARNINGS` non vide.
  - `dry-run calls nothing` → `apt-get.calls` absent.
- [ ] **Step 2:** FAIL. **Step 3:** Implémenter. **Step 4:** PASS.
- [ ] **Step 5:** Commit `feat: mise à jour système non bloquante`.

### Task 5: Dépôts Debian

**Files:** Create `lib/repos_debian.sh`, `tests/repos_debian.bats`, `tests/fixtures/sources/{bookworm.list,bookworm-with-contrib.list,trixie.sources,bullseye.list}`

**Interfaces:**
- Consumes: `OS_VERSION`, `OS_CODENAME` (Task 3), `run`, `warn` (Task 1).
- Produces:
  - `apt_sources_file [racine=${APT_ROOT:-/}]` → chemin de `etc/apt/sources.list.d/debian.sources` s'il existe, sinon `etc/apt/sources.list`.
  - `debian_add_components <fichier> <codename> <composant…>` → classique : ajoute les composants manquants aux lignes `deb`/`deb-src` dont la suite est `<codename>`, `<codename>-updates` ou `<codename>-security` ; deb822 : ajoute au champ `Components:` des paragraphes dont `Suites:` contient le codename. Sans doublon. Sauvegarde `<fichier>.bak-AAAAMMJJ` avant la première modification (pas de sauvegarde si rien ne change). Ignore `non-free-firmware` (avec `warn`) si `OS_VERSION` < 12.
  - `debian_enable_backports <codename> <composants…>` → crée `etc/apt/sources.list.d/<codename>-backports.sources` (deb822 si le fichier principal est deb822) ou `.list` sinon ; ne fait rien s'il existe. URI `http://deb.debian.org/debian`, composants `main` + ceux de `CFG_DEBIAN_COMPONENTS`.
  - `debian_install_snapd`, `debian_install_flatpak` → `apt-get install -y snapd` + `systemctl enable --now snapd.socket` ; `apt-get install -y flatpak` + `flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo`. Ajoutent à `R_REPOS`.

- [ ] **Step 1: Tests qui échouent** (sur copies des fixtures dans `$BATS_TEST_TMPDIR`) :
  - `classic: adds contrib non-free non-free-firmware to bookworm lines only` → les lignes `bookworm`, `bookworm-updates`, `bookworm-security` finissent par `main contrib non-free non-free-firmware` ; une ligne pour un autre dépôt reste intacte.
  - `deb822: adds to Components` → `Components: main contrib non-free non-free-firmware` dans chaque paragraphe trixie.
  - `components idempotent` : deux appels → fichier identique au premier résultat, une seule sauvegarde.
  - `bullseye skips non-free-firmware with warning`.
  - `backports file created once, deb822 when main file is deb822`.
- [ ] **Step 2:** FAIL. **Step 3:** Implémenter (awk pour les deux formats). **Step 4:** PASS.
- [ ] **Step 5:** Commit `feat: dépôts Debian (sources.list et deb822)`.

### Task 6: Installation des outils

**Files:** Create `lib/tools.sh`, `tests/tools.bats`, `tests/fixtures/apt-cache-policy-nodejs.txt`

**Interfaces:**
- Consumes: `run`, `ok`, `error`, `warn`, `confirm`, `ask_value`, `MODE` (Task 1) ; `is_tool_spec` (Task 2).
- Produces:
  - `tool_parse <spec>` → définit `T_MGR`, `T_NAME`, `T_VER` (vide si pas de `@`).
  - `apt_resolve_version <paquet> <préfixe>` → version la plus récente de `apt-cache policy` dont la valeur commence par `<préfixe>` (en ignorant un éventuel `epoch:`) ; statut 1 si aucune.
  - `tool_is_installed <mgr> <nom>` → `dpkg-query -W -f='${Status}'` pour apt, `snap list <nom>`, `flatpak info <nom>`, `pipx list --short` (avec `PIPX_HOME=/opt/pipx`), `npm ls -g --depth=0 <nom>`, présence dans `/usr/local/.crates.toml` pour cargo.
  - `tool_install <spec>` → 0 si installé ou déjà présent, 1 sinon ; met à jour `R_TOOLS_OK` / `R_TOOLS_FAIL` / `HAS_PARTIAL_FAILURE`. Déjà présent → `ok "… déjà installé"`, jamais de mise à niveau/rétrogradation ; si une version est demandée et diffère → `warn`. Commandes par gestionnaire :
    - apt : `apt-get install -y <nom>[=<version résolue>]` ; succès = code de retour d'apt-get (aucun `grep`). Nom inconnu (`apt-cache show` échoue) → échec.
    - snap : `snap install <nom> [--channel=<ver>/stable]` ; si échec avec message contenant `classic`, réessaye avec `--classic`.
    - flatpak : `flatpak install -y --noninteractive flathub <nom>`.
    - pip : installe `pipx` via apt si absent ; `PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin pipx install <nom>[==ver]`.
    - npm : `npm install -g <nom>[@ver]`.
    - cargo : `CARGO_INSTALL_ROOT=/usr/local cargo install [--version <ver>] <nom>` (`--locked`).
    - Gestionnaire absent (`command -v` échoue) → échec avec message « gestionnaire <mgr> indisponible ».
  - `tool_alias <nom>` → `node→nodejs golang→golang-go pip→python3-pip docker→docker.io postgres→postgresql fd→fd-find`, sinon le nom (apt seulement).
  - `tools_interactive` (mode interactif) → boucle de saisie comme aujourd'hui ; accepte `mgr:nom@ver` tel quel ; sinon nom seul → `apt:<alias>` si `apt-cache show` connaît le paquet, sinon liste les gestionnaires où le **nom exact** existe (`snap info <nom>`, `flatpak remote-info flathub <nom>`, `pip index versions <nom>`, `npm view <nom> name`, `cargo search --limit 1 <nom>` avec nom identique) et demande lequel avec `ask_value` ; aucun → l'outil n'est pas ajouté. Renvoie la liste finale des specs dans le tableau `TOOLS_SELECTED` (réutilisé par `config_write` via `CFG_TOOLS`).

- [ ] **Step 1: Tests qui échouent** :
  - `parse spec with version` : `pip:ansible@9.0` → `pip ansible 9.0` ; sans version → `T_VER` vide.
  - `apt resolves version prefix` : fixture policy nodejs (`20.19.2+dfsg-1`, `18.19.1+dfsg-6`) ; préfixe `20` → `20.19.2+dfsg-1` ; préfixe `22` → statut 1.
  - `apt install success with no output` : faux `apt-cache show` OK, faux `apt-get` muet qui renvoie 0 → statut 0, `R_TOOLS_OK` contient `apt:git`.
  - `apt unknown package fails without fallback` : `apt-cache show` échoue → statut 1, aucun appel à `snap`/`pipx`/`npm`/`cargo` (fichiers `.calls` absents).
  - `already installed is skipped` : faux `dpkg-query` → `install ok installed` → aucun appel `apt-get install`.
  - `pip installs system-wide via pipx` : `pipx.calls` contient `install ansible==9.0` et l'environnement capturé contient `PIPX_HOME=/opt/pipx`.
  - `cargo uses /usr/local` : `CARGO_INSTALL_ROOT=/usr/local` et `--version 14.1.0`.
  - `snap retries with classic` : premier appel échoue avec « requires classic confinement » → deuxième appel contient `--classic`.
  - `missing manager fails clearly` : pas de `snap` dans PATH → statut 1, sortie contient `indisponible`.
- [ ] **Step 2:** FAIL. **Step 3:** Implémenter. **Step 4:** PASS.
- [ ] **Step 5:** Commit `feat: installation des outils par gestionnaire explicite`.

### Task 7: Pare-feu UFW

**Files:** Create `lib/firewall.sh`, `tests/firewall.bats`, `tests/fixtures/ufw-status-*.txt`

**Interfaces:**
- Consumes: `run`, `ok`, `warn`, `confirm`, `ask_value` (Task 1) ; `is_port`, `is_ufw_rule` (Task 2).
- Produces:
  - `sshd_port` → premier `port N` de `sshd -T` (en root) ; si indisponible, `Port` de `/etc/ssh/sshd_config` ; sinon `22`.
  - `ufw_current_rules` → règles `ALLOW IN` actuelles normalisées (`22/tcp`, `80`, `8000:8100/tcp`), une par ligne, sans doublons IPv6, depuis `ufw status`.
  - `ufw_plan <ssh_port|none|auto> <règles…>` → liste finale (une par ligne) : port SSH résolu en `<port>/tcp` + règles. **Garde-fou** : si `SSH_CONNECTION` est non vide et que le port SSH est `none`, ajoute quand même `$(sshd_port)/tcp` et `warn "… port SSH forcé …"`.
  - `ufw_apply <règles…>` → installe ufw via apt si absent ; `ufw default deny incoming`, `ufw default allow outgoing` ; pour chaque règle absente de `ufw_current_rules` → `ufw allow <règle>` + `R_UFW_ADDED` ; règles présentes non demandées → `R_UFW_EXTRA` (jamais supprimées) ; puis `ufw --force enable`. Le SSH est toujours ajouté **avant** `enable`.
  - `configure_firewall` → si `CFG_UFW_ENABLE=no` : ne touche à rien (ni activation ni désactivation). Sinon `ufw_plan` + `ufw_apply`. En interactif, les questions SSH/HTTP/HTTPS/règles perso remplissent `CFG_UFW_SSH_PORT` et `CFG_UFW_ALLOW` avant le même chemin (ports validés, re-question si invalide).

- [ ] **Step 1: Tests qui échouent** :
  - `sshd port from sshd -T` : faux `sshd` → `port 2222` → `2222`.
  - `ssh guard overrides none` : `SSH_CONNECTION="1.2.3.4 5 6.7.8.9 22"`, faux sshd port 2222 → plan contient `2222/tcp`, `R_WARNINGS` non vide.
  - `no guard outside ssh` : `SSH_CONNECTION` vide, `none` → pas de règle SSH.
  - `ssh rule applied before enable` : ordre dans `ufw.calls` : `allow 2222/tcp` avant `--force enable`.
  - `existing rule not re-added` : fixture status avec `80/tcp` → pas d'appel `allow 80/tcp`.
  - `extra rules reported not deleted` : fixture avec `3306/tcp` non demandé → `R_UFW_EXTRA` contient `3306/tcp`, aucun `ufw delete`.
  - `UFW_ENABLE=no leaves firewall alone` → aucun appel à `ufw`.
- [ ] **Step 2:** FAIL. **Step 3:** Implémenter. **Step 4:** PASS.
- [ ] **Step 5:** Commit `feat: UFW additif avec garde-fou SSH`.

### Task 8: Gestion des services

**Files:** Create `lib/services.sh`, `tests/services.bats`

**Interfaces:**
- Consumes: `run`, `ok`, `warn`, `confirm`, `ask_value` (Task 1) ; `R_TOOLS_OK` (Task 6).
- Produces:
  - Tableaux `SERVICES_SAFE` (avahi-daemon cups cups-browsed bluetooth ModemManager whoopsie apport speech-dispatcher saned postfix exim4 rpcbind nfs-common), `SERVICES_SENSITIVE` (unattended-upgrades apt-daily apt-daily-upgrade rsyslog wpa_supplicant NetworkManager-wait-online thermald snapd), `SERVICES_FORBIDDEN` (ssh sshd), et `SERVICE_DESC[nom]` (descriptions reprises des anciens scripts).
  - `service_units <nom>` → unités existantes exactement nommées parmi `<nom>.service`, `<nom>.socket`, `<nom>.timer` (via `systemctl list-unit-files --no-legend <unités…>`), une par ligne ; vide si absent.
  - `service_apply <mask|disable> <nom>` → refuse `SERVICES_FORBIDDEN` (erreur, partiel) ; refuse `snapd` si `R_TOOLS_OK` contient une entrée `snap:` ; service absent → `info` et ignoré ; sensible → `warn` ; mask = `systemctl stop <unités>` puis `systemctl mask <unités>` ; disable = `systemctl disable --now <unités>`. Met à jour `R_SVC_MASKED`/`R_SVC_DISABLED` ; échec → `HAS_PARTIAL_FAILURE=1`.
  - `manage_services` → auto : applique `CFG_SERVICES_MASK` puis `CFG_SERVICES_DISABLE`. Interactif : options globales A/B/C/D comme aujourd'hui, mais B/C ne portent que sur `SERVICES_SAFE` ; A propose aussi les sensibles un par un avec avertissement. Les choix remplissent `CFG_SERVICES_MASK`/`CFG_SERVICES_DISABLE`.
  - Si `systemctl` est indisponible ou que systemd ne tourne pas (`/run/systemd/system` absent) → étape sautée avec `warn` (cas Docker).

- [ ] **Step 1: Tests qui échouent** (faux `systemctl`) :
  - `exact unit match` : `list-unit-files` ne connaît que `cups-browsed.service` → `service_units cups` vide.
  - `timer handled` : `apt-daily.service` + `apt-daily.timer` → les deux masqués.
  - `ssh is refused` → statut 1, aucun `mask`.
  - `snapd refused after snap tool install` : `R_TOOLS_OK=(snap:code)` → aucun `mask snapd`.
  - `bulk option skips sensitive` : choix B en interactif simulé (`ask_value` remplacé dans le test) → `rsyslog` non masqué, `cups` masqué.
  - `no systemd skips with warning`.
- [ ] **Step 2:** FAIL. **Step 3:** Implémenter. **Step 4:** PASS.
- [ ] **Step 5:** Commit `feat: gestion des services avec liste sensible`.

### Task 9: Rapport, code de sortie et enregistrement des réponses

**Files:** Create `lib/report.sh`, `tests/report.bats`

**Interfaces:**
- Consumes: tableaux `R_*`, `HAS_PARTIAL_FAILURE` ; `config_write` (Task 2).
- Produces:
  - `report_init` → initialise les tableaux, `START_TIME`.
  - `report_print <fichier_rapport>` → affiche et écrit (sans couleurs) : durée, OS, outils OK/échecs, dépôts, règles UFW ajoutées, **règles UFW présentes hors config**, services masqués/désactivés, avertissements, `Redémarrage requis : oui/non` (`/var/run/reboot-required`, chemin surchargeable par `REBOOT_FLAG_FILE`).
  - `exit_code` → `2` si `HAS_PARTIAL_FAILURE=1`, sinon `0`.
  - `maybe_reboot` → `CFG_REBOOT=yes` → `reboot` ; `if-needed` → `reboot` seulement si le drapeau existe ; `no` → message. En interactif : `confirm "Redémarrer maintenant ?" n`. Jamais en `--dry-run`.
  - `offer_save_config` (interactif seulement) → `confirm` puis `config_write /root/provision-AAAAMMJJ.conf`, chemin affiché.

- [ ] **Step 1: Tests qui échouent** : `exit code 2 on partial failure` ; `report lists extra ufw rules` ; `report file has no ANSI codes` ; `if-needed reboots only with flag` (faux `reboot`) ; `dry-run never reboots`.
- [ ] **Step 2:** FAIL. **Step 3:** Implémenter. **Step 4:** PASS.
- [ ] **Step 5:** Commit `feat: rapport, code de sortie et sauvegarde des réponses`.

### Task 10: Orchestration, exemples, README, suppression des anciens scripts

**Files:** Modify `provision.sh` ; Create `examples/parc.conf`, `examples/poste.conf`, `tests/main.bats` ; Modify `README.md` ; Delete `ubuntu-setup.sh`, `debian-setup.sh`

**Interfaces:**
- Consumes: tout ce qui précède.
- Produces: `main` exécute dans l'ordre : `parse_args` → création du dossier de journal (sauf dry-run hors root : journal dans `$TMPDIR`) → `report_init` → vérif root (`EUID`, sortie 1) → `os_detect` + `os_supported` (auto : refus sortie 1 ; interactif : `confirm` défaut `n`) → si `--config` : `config_load` (échec → sortie 1 avant toute modification) → `connectivity_check` → `system_update` si `CFG_UPDATE_SYSTEM=yes` (échec → rapport + sortie 1) → si Debian : composants/backports/snapd → si `CFG_INSTALL_FLATPAK=yes` (Ubuntu **et** Debian) : `debian_install_flatpak` (la fonction n'a rien de propre à Debian malgré son fichier) → outils (`CFG_TOOLS` ou `tools_interactive`) → `configure_firewall` → `manage_services` → `report_print` → `offer_save_config` (interactif) → `maybe_reboot` → `exit $(exit_code)`. Bannière unique avec `OS_PRETTY`. En interactif, chaque étape commence par la même question qu'aujourd'hui et remplit les `CFG_*` correspondants.

- [ ] **Step 1: Tests qui échouent** (`tests/main.bats`, tous les binaires système remplacés, `OS_RELEASE_FILE` sur fixture, `EUID` simulé via `PROVISION_ASSUME_ROOT=1` réservé aux tests) :
  - `invalid config exits 1 before any change` → aucun fichier `.calls` créé.
  - `unsupported os refused in auto mode` (fedora) → statut 1.
  - `full auto run on debian-12 fixture` avec `examples/parc.conf` → statut 0, `apt-get.calls` contient `full-upgrade`, `ufw.calls` contient `--force enable`.
  - `tool failure gives exit 2`.
  - `auto mode never reads tty` : lancé avec `setsid … </dev/null` → se termine (timeout 30 s), statut 0.
- [ ] **Step 2:** FAIL. **Step 3:** Implémenter `main` ; écrire `examples/parc.conf` (serveur : update, `apt:git apt:curl apt:htop apt:fail2ban`, SSH auto, UFW actif, mask `cups cups-browsed avahi-daemon bluetooth ModemManager`, `REBOOT=if-needed`) et `examples/poste.conf` (poste : outils de dev, flatpak, pas de mask, `REBOOT=no`), chaque clé commentée en français.
- [ ] **Step 4:** PASS.
- [ ] **Step 5:** Supprimer les anciens scripts ; réécrire le README (français) : utilisation interactive, mode parc (`scp` + `ssh -t … --config`), `--dry-run`, référence des clés (tableau de la spec §5.3), garde-fous, codes de sortie, emplacement des journaux, correspondance ancien → nouveau, **liste de contrôle de validation sur VM** (UFW via SSH avec port non standard, relance idempotente, services sensibles, Debian 13 deb822). Conserver les sections « commandes utiles » systemd/UFW existantes.
- [ ] **Step 6:** `tests/run.sh` → tout PASS.
- [ ] **Step 7:** Commit `feat: provision.sh unifié remplace les scripts Ubuntu/Debian`.

### Task 11: Bundle, tests de fumée Docker, release

**Files:** Create `scripts/bundle.sh`, `tests/smoke.sh`, `.github/workflows/release.yml` ; Modify `.github/workflows/ci.yml`, `tests/cli.bats`

**Interfaces:**
- Consumes: `provision.sh`, `lib/*.sh`.
- Produces:
  - `scripts/bundle.sh` → `dist/provision.sh` : en-tête de `provision.sh`, puis le contenu de chaque `lib/*.sh` dans l'ordre `ui config os update repos_debian tools firewall services report` (sans shebang), puis le reste de `provision.sh` avec les lignes `source "$LIB_DIR/…"` retirées (repérées par le marqueur `# @bundle-source`). Exécutable.
  - `tests/smoke.sh <config>` → dans un conteneur : `apt-get update && apt-get install -y ca-certificates` puis `bash dist/provision.sh --config <config> --dry-run`, puis un vrai lancement avec une config `UPDATE_SYSTEM=yes TOOLS="apt:curl" UFW_ENABLE=no` ; vérifie `command -v curl` et code 0. Les étapes systemd/UFW sont sautées avec avertissement (Task 8).
  - `ci.yml` : job `smoke`, matrice `ubuntu:22.04 ubuntu:24.04 ubuntu:26.04 debian:11 debian:12 debian:13`, `docker run --rm -v "$PWD:/src" -w /src <image> bash tests/smoke.sh`.
  - `release.yml` : sur tag `v*` → `scripts/bundle.sh`, puis `gh release create "$GITHUB_REF_NAME" dist/provision.sh examples/*.conf --generate-notes`.

- [ ] **Step 1: Test qui échoue** : `tests/cli.bats` → `bundle is standalone` : lance `scripts/bundle.sh`, copie `dist/provision.sh` seul dans un dossier vide, `--version` → `provision 2.0.0` ; `grep -c 'source "\$LIB_DIR' dist/provision.sh` → 0.
- [ ] **Step 2:** FAIL. **Step 3:** Implémenter bundle, smoke, workflows. **Step 4:** `tests/run.sh` → PASS ; `bash -n dist/provision.sh` OK.
- [ ] **Step 5:** Commit `ci: bundle autonome, tests de fumée Docker et release`.
- [ ] **Step 6:** Après push de la branche : vérifier que les jobs `lint`, `unit` et les 6 `smoke` passent sur GitHub Actions (si l'image `ubuntu:26.04` n'existe pas encore sur Docker Hub, la marquer `continue-on-error` et le signaler).
