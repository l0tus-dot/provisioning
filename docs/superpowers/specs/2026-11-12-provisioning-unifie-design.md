# Provisioning unifié — document de conception

Date : 2026-11-12 · Statut : validé

## 1. Intention

Les scripts servent à préparer des machines Ubuntu/Debian fraîchement installées, dans deux contextes :

- **Machines personnelles** : lancement à la main, réponses saisies au fil de l'eau (usage actuel, à conserver).
- **Parc d'environ 10 machines** : l'opérateur se connecte en SSH à chaque machine et lance le script. Il veut un résultat **identique et reproductible** d'une machine à l'autre, **sans répondre aux questions**, et sans risque de perdre l'accès SSH.

Aujourd'hui, deux scripts quasi identiques (`ubuntu-setup.sh`, `debian-setup.sh`) ont divergé, contiennent des bugs bloquants et n'ont pas de mode automatique (`--non-interactive` est annoncé mais absent).

## 2. Objectifs, non-objectifs, anti-objectifs

**Objectifs**
1. Un point d'entrée unique `provision.sh` qui détecte Ubuntu ou Debian et applique les spécificités.
2. Deux modes : interactif (par défaut) et automatique via `--config FICHIER`.
3. Un même fichier de configuration donne le même résultat sur toutes les machines du parc.
4. Relancer le script ne casse rien et ne crée pas de doublons (idempotence).
5. Journal sur disque et code de sortie fiable pour savoir en un coup d'œil si une machine a échoué.
6. Corriger les bugs connus (section 6).

**Non-objectifs**
- Orchestrer plusieurs machines depuis un poste (pas de lanceur multi-hôtes, pas d'Ansible).
- Supporter d'autres distributions (Fedora, Arch…).
- Annuler automatiquement les changements (rollback).

**Anti-objectifs** (échec même si « ça marche »)
- Le script active UFW et coupe la session SSH en cours.
- Le script installe un paquet différent de celui demandé (nom approchant via snap/pip/npm).
- En mode automatique, le script reste bloqué en attente d'une saisie.
- Une mise à jour système échoue sans que le rapport le signale.

## 3. Contraintes

- 100 % Bash (≥ 5, présent sur toutes les versions ciblées), dépendances limitées à ce qui est installé de base.
- Versions supportées : Ubuntu 22.04 / 24.04 / 26.04, Debian 11 / 12 / 13. Toute autre distribution : refus en mode automatique, avertissement + confirmation en mode interactif.
- Exécution en root.
- Messages utilisateur en français (comme aujourd'hui).
- Distribution aux machines par `scp` : il doit exister une variante **fichier unique**.

## 4. Approches envisagées

| Approche | Résumé | Compromis |
|---|---|---|
| **A — Script unique + bibliothèque + fichier de config** *(choisie)* | `provision.sh` + `lib/*.sh`, mode `--config` | Une seule correction par bug, comportement identique partout ; demande une restructuration et une étape de « bundle » pour obtenir un fichier unique. |
| B — Garder deux scripts, ajouter `--config` à chacun | Changements minimes | Duplication doublée par le nouveau code, divergence déjà constatée entre les deux scripts. |
| C — Migrer vers Ansible | Outil fait pour les parcs | Nouvel outil à apprendre, perte de l'usage interactif et du « 100 % Shell », surdimensionné pour ~10 machines lancées une à une. |

**Choix de l'utilisateur : A.**

## 5. Conception

### 5.1 Arborescence

```
provision.sh              point d'entrée : options, détection OS, enchaînement des étapes
lib/
  ui.sh                   couleurs, info/ok/warn/error, confirm, ask (respecte le mode)
  config.sh               lecture/validation du fichier de config
  os.sh                   détection distribution/version, garde-fous
  update.sh               apt update/upgrade/autoremove
  repos_debian.sh         contrib/non-free/backports (sources.list ET deb822), snapd/flatpak optionnels
  tools.sh                installation des outils (apt, snap, flatpak, pip/pipx, npm, cargo)
  firewall.sh             UFW
  services.sh             gestion des services
  report.sh               rapport + code de sortie
examples/
  parc.conf               config d'exemple commentée (serveur type)
  poste.conf              config d'exemple (poste de travail)
scripts/bundle.sh         génère dist/provision.sh autonome (concatène lib/ dans provision.sh)
tests/                    tests bats + tests de fumée Docker
.github/workflows/ci.yml  shellcheck + bats + fumée
```

`ubuntu-setup.sh` et `debian-setup.sh` sont **supprimés** ; le README explique la correspondance (*décision de Claude : garder des wrappers n'apporte rien pour un projet personnel*).

### 5.2 Ligne de commande

```
sudo ./provision.sh                         # interactif
sudo ./provision.sh --config parc.conf      # automatique, aucune question
sudo ./provision.sh --config parc.conf --dry-run   # affiche ce qui serait fait, ne modifie rien
     --log FICHIER   (défaut : /var/log/provision/provision-AAAAMMJJ-HHMMSS.log)
     --help, --version
```

En mode `--config`, toute valeur absente prend sa valeur par défaut (prudente) ; **aucune lecture sur `/dev/tty`** n'a lieu. Si une décision n'est pas couverte par la config, le script prend l'option sûre et l'écrit dans le rapport.

`--config` signifie toujours automatique (pas de pré-remplissage du mode interactif) pour garder un comportement simple et prévisible (*décision de Claude*).

### 5.3 Fichier de configuration

Format `CLÉ=valeur` (une par ligne, `#` pour les commentaires, valeurs entre guillemets autorisées). Le fichier est **analysé, pas sourcé** : seules les clés connues sont acceptées, une clé inconnue ou une valeur invalide fait échouer le script avant toute modification (*décision de Claude : éviter l'exécution de code arbitraire et les fautes de frappe silencieuses*).

| Clé | Défaut | Rôle |
|---|---|---|
| `UPDATE_SYSTEM` | `yes` | apt update + upgrade + autoremove |
| `TOOLS` | vide | liste `gestionnaire:nom[@version]` séparée par des espaces, ex. `apt:git apt:curl snap:code pip:ansible@9.0 cargo:ripgrep` |
| `DEBIAN_COMPONENTS` | vide | Debian seulement, ex. `contrib non-free non-free-firmware` |
| `DEBIAN_BACKPORTS` | `no` | |
| `INSTALL_SNAPD` | `no` | Debian seulement |
| `INSTALL_FLATPAK` | `no` | ajoute Flathub |
| `UFW_ENABLE` | `yes` | |
| `UFW_SSH_PORT` | `auto` | `auto` = port lu dans la config sshd effective (`sshd -T`), sinon 22 ; ou un numéro ; ou `none` |
| `UFW_ALLOW` | vide | règles supplémentaires, ex. `80/tcp 443/tcp 5432/tcp` |
| `SERVICES_MASK` | vide | services à masquer |
| `SERVICES_DISABLE` | vide | services à désactiver au démarrage |
| `REBOOT` | `no` | `yes` / `no` / `if-needed` (présence de `/var/run/reboot-required`) |

En config, chaque outil **indique son gestionnaire** : pas de chaîne de repli, donc jamais de paquet « approchant » installé par erreur. Gestionnaire absent (ex. `snap:` sur Debian sans snapd) → échec explicite de cet outil.

**Emplacement des outils** (*décision de Claude*) : tout est installé **pour tout le système**, utilisable par n'importe quel utilisateur, pas dans le dossier de root :
- `pip:` = pipx uniquement, avec `PIPX_HOME=/opt/pipx` et `PIPX_BIN_DIR=/usr/local/bin` (pipx est installé via apt si absent). Plus de `pip3 --break-system-packages`.
- `cargo:` avec `CARGO_INSTALL_ROOT=/usr/local`.
- `npm:` en `-g` (déjà global).

**Sens de `@version`** (*décision de Claude*) :
- `apt` : préfixe de version, ex. `apt:nodejs@20` → la version disponible la plus récente commençant par `20` (une version Debian exacte ne correspondrait jamais d'une release à l'autre).
- `snap` : canal (`snap:node@20` → `--channel=20/stable`).
- `flatpak` : version non supportée → config refusée si `@` est utilisé.
- `pip`, `npm`, `cargo` : version exacte.
- Outil déjà présent dans une autre version : **aucune modification** (ni mise à niveau ni rétrogradation), avertissement dans le rapport, code de sortie inchangé.

### 5.4 Mode interactif

Mêmes étapes et mêmes questions qu'aujourd'hui, avec ces changements :
- Installation d'un outil sans gestionnaire précisé : on cherche dans apt ; si absent, on **affiche les gestionnaires où le nom exact existe** et on demande lequel utiliser (plus d'enchaînement silencieux apt → snap → pip → npm → cargo). L'utilisateur peut aussi saisir directement `snap:code`.
- UFW : l'option « Personnaliser les politiques » (lue mais ignorée aujourd'hui) est retirée (*décision de Claude*) ; politique fixe : refus entrant, autorisation sortant.
- À la fin, proposition d'**enregistrer les réponses** dans un fichier de config réutilisable (`/root/provision-AAAAMMJJ.conf`) : on configure une machine à la main, puis on rejoue sur le parc.

### 5.5 Garde-fous

- **SSH** : si la session courante est en SSH (`SSH_CONNECTION` non vide) et que UFW va être activé, le port SSH effectif est **toujours autorisé**, même si la config dit `none` (avertissement dans le rapport). Ports validés (1–65535, protocole tcp/udp).
- **Services** : la liste proposée est découpée en
  - *sûrs à désactiver* : avahi-daemon, cups, cups-browsed, bluetooth, ModemManager, whoopsie, apport, speech-dispatcher, saned, postfix, exim4, rpcbind, nfs-common (selon présence) ;
  - *sensibles* (proposés un par un uniquement, jamais dans « tout désactiver », avec avertissement) : unattended-upgrades, apt-daily(-upgrade).timer, rsyslog, wpa_supplicant, NetworkManager-wait-online, thermald, snapd.
  - En config, tout service peut être listé, mais un service sensible génère un avertissement dans le rapport. `snapd` est refusé si des outils `snap:` ont été installés dans la même exécution.
- **UFW en relance** (*choix de l'utilisateur*) : le script **ajoute** les règles de la config sans jamais en supprimer (pas de `ufw reset`). Les règles déjà présentes mais absentes de la config sont **listées dans le rapport** (avertissement, code de sortie inchangé), à retirer à la main si besoin. `UFW_ENABLE=no` laisse l'état du pare-feu tel quel (ne le désactive pas).
- Action sur les services (*décision de Claude*, identique à l'existant) : masquer = `stop` + `mask` ; désactiver = `disable --now`. Les unités `.timer` (apt-daily…) sont traitées avec leur service associé. `ssh`/`sshd` est refusé dans les deux listes.
- Existence d'un service : test exact sur l'unité (`systemctl list-unit-files "<nom>.service" "<nom>.timer"`), plus de `grep` par préfixe.
- **Connectivité** : remplacer le `ping 8.8.8.8` (ICMP souvent filtré) par un `apt-get update` réussi ou une requête HTTP vers le miroir configuré.

### 5.6 Dépôts Debian

- Détecter le format : `/etc/apt/sources.list.d/debian.sources` (deb822, Debian 13 et certaines 12) ou `/etc/apt/sources.list` (classique).
- Ajouter les composants en modifiant le champ `Components:` (deb822) ou les lignes `deb … main` correspondant au codename (classique), sans doublon.
- `non-free-firmware` uniquement à partir de Debian 12.
- Backports : fichier dédié `/etc/apt/sources.list.d/<codename>-backports.list` (ou `.sources`), idempotent.
- Sauvegarde du fichier modifié (`*.bak-AAAAMMJJ`) avant écriture.

### 5.6 bis Mise à jour système

`UPDATE_SYSTEM=yes` (*décision de Claude*) = `apt-get update` puis `apt-get full-upgrade` (installe aussi les nouveaux noyaux), `autoremove`, `autoclean`, avec `DEBIAN_FRONTEND=noninteractive` et `-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold` : les fichiers de config modifiés localement sont **conservés**, jamais de question bloquante. Échec d'apt = erreur bloquante (code 1).

### 5.7 Journal, rapport, code de sortie

- Tout ce qui s'affiche est aussi écrit dans le journal (sans couleurs), y compris la sortie complète d'apt.
- Rapport final : outils installés/échoués, dépôts, règles UFW, services, avertissements de garde-fous, redémarrage requis ou non. Copie dans `/var/log/provision/rapport-….txt`.
- Codes de sortie : `0` tout est OK ; `1` erreur bloquante (config invalide, pas root, OS non supporté, apt en échec) ; `2` terminé avec des échecs partiels (un outil ou un service).

### 5.8 Corrections de bugs incluses

1. `spinner` : `((i++))` stoppe le script sous `set -e` au premier tour → remplacer par `i=$((i+1))` ; récupérer le code de retour d'`apt-get upgrade` après le spinner.
2. `apt-get install … | grep -v "^$"` → faux échec quand apt n'affiche rien ; tester le code de retour d'apt directement.
3. `tput cols` sans `TERM` (session non interactive) → valeur par défaut 80.
4. Détection de services par préfixe (`cups` correspond à `cups-browsed`).
5. `NetworkManager-wait-online` et `apt-daily*` gérés avec le bon type d'unité.
6. `sed` sur `sources.list` inopérant/dangereux en deb822.
7. Choix UFW « personnaliser » ignoré ; activation UFW possible sans règle SSH.
8. Option `--non-interactive` annoncée mais inexistante (remplacée par `--config`).

### 5.9 Tests et intégration continue

- **shellcheck** sur tous les fichiers (bloquant en CI).
- **bats** pour les fonctions pures : analyse de config (clés inconnues, valeurs invalides), parsing `gestionnaire:nom@version`, validation des ports, modification des sources Debian sur des fichiers d'exemple (classique et deb822).
- **Fumée Docker** (CI) : `ubuntu:22.04/24.04/26.04`, `debian:11/12/13` ; lancement de `--config examples/parc.conf --dry-run`, puis un vrai lancement limité à `UPDATE_SYSTEM` + `TOOLS=apt:curl` (systemd et UFW ne tournent pas dans Docker : ces étapes sont détectées et sautées avec avertissement).
- **Validation manuelle** sur VM avant fusion (UFW en SSH, services) : liste de contrôle dans le README.

### 5.10 Distribution

`scripts/bundle.sh` produit `dist/provision.sh` autonome. Il est attaché aux *releases* GitHub et non commité (*décision de Claude*) : un workflow `.github/workflows/release.yml` déclenché par un tag `v*` lance le bundle et publie la release. Usage parc :

```
scp dist/provision.sh parc.conf admin@machine:
ssh -t admin@machine 'sudo bash provision.sh --config parc.conf'
```

## 6. Laissé au constructeur

- Découpage exact des fonctions dans `lib/`, nom des fonctions internes.
- Texte précis des messages et mise en forme du rapport.
- Choix des versions des actions GitHub et de bats.
- Ordre de mise en œuvre, à condition que les corrections de bugs (5.8) et les garde-fous (5.5) soient livrés avant ou avec le mode `--config`.
