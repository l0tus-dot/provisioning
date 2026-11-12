# Provisioning Ubuntu / Debian

`provision.sh` prépare une machine **Ubuntu** ou **Debian** fraîchement installée : mise à jour, dépôts, outils, pare-feu UFW, services inutiles. Il remplace `ubuntu-setup.sh` et `debian-setup.sh`.

- Ubuntu 22.04 / 24.04 / 26.04, Debian 11 / 12 / 13 (Bash 5 ou plus, exécution en root).
- Deux modes : **interactif** (questions au fil de l'eau) et **automatique** (`--config`, aucune question, résultat identique sur toutes les machines).
- Relançable sans danger : rien n'est dupliqué, aucune règle UFW n'est supprimée.

```
provision.sh              point d'entrée
lib/*.sh                  bibliothèques (config, os, update, repos_debian, tools, firewall, services, report)
examples/parc.conf        configuration d'exemple : serveur du parc
examples/poste.conf       configuration d'exemple : poste de travail
```

Les releases GitHub fournissent aussi une version **fichier unique** (`dist/provision.sh`, générée par le script de bundle, Task 11) à copier telle quelle sur les machines.

---

## Utilisation

### Interactif

```bash
sudo ./provision.sh
```

Les étapes sont enchaînées dans cet ordre, chacune commence par sa question : mise à jour du système, dépôts Debian (contrib, non-free, backports, snapd), flatpak, outils, pare-feu UFW, services, rapport. À la fin, le script propose d'enregistrer vos réponses dans `/root/provision-AAAAMMJJ.conf`, rejouable ensuite sur le parc.

Pour un outil saisi sans gestionnaire, apt est interrogé d'abord ; s'il ne le connaît pas, le script liste les gestionnaires où le nom **exact** existe et demande lequel utiliser. On peut aussi saisir directement `snap:code`.

### Mode parc (automatique)

```bash
scp provision.sh parc.conf admin@machine:
ssh -t admin@machine 'sudo bash provision.sh --config parc.conf'
```

`--config` signifie toujours « automatique » : aucune lecture du clavier ni de `/dev/tty`. Si la configuration ne couvre pas une décision, le script prend l'option sûre et l'indique dans le rapport. Un fichier invalide fait échouer le script (code 1) **avant toute modification**.

### Simulation

```bash
sudo ./provision.sh --config parc.conf --dry-run
```

Affiche ce qui serait fait (`[dry-run] …`) sans rien modifier. Sans root, le dry-run fonctionne avec un simple avertissement.

### Options

| Option | Rôle |
|---|---|
| `--config <fichier>` | mode automatique à partir d'un fichier de configuration |
| `--dry-run` | affiche les actions sans les exécuter |
| `--log <fichier>` | fichier journal (défaut : `/var/log/provision/provision-AAAAMMJJ-HHMMSS.log`) |
| `--version`, `--help` | version, aide |

---

## Fichier de configuration

Format `CLÉ=valeur`, une par ligne, `#` pour les commentaires, guillemets autorisés. Le fichier est **analysé, jamais exécuté** : une clé inconnue ou une valeur invalide (y compris `$`, `` ` `` ou `"` dans une valeur) fait échouer le script. Toute clé absente prend sa valeur par défaut. Voir `examples/parc.conf` et `examples/poste.conf`.

| Clé | Défaut | Rôle |
|---|---|---|
| `UPDATE_SYSTEM` | `yes` | `apt update` + `full-upgrade` + `autoremove` |
| `TOOLS` | vide | liste `gestionnaire:nom[@version]` séparée par des espaces, ex. `apt:git apt:curl snap:code pip:ansible@9.0 cargo:ripgrep` |
| `DEBIAN_COMPONENTS` | vide | Debian seulement, ex. `contrib non-free non-free-firmware` |
| `DEBIAN_BACKPORTS` | `no` | Debian seulement |
| `INSTALL_SNAPD` | `no` | Debian seulement |
| `INSTALL_FLATPAK` | `no` | installe flatpak et ajoute Flathub (Ubuntu et Debian) |
| `UFW_ENABLE` | `yes` | `no` laisse le pare-feu tel quel (ne le désactive pas) |
| `UFW_SSH_PORT` | `auto` | `auto` = port lu dans la configuration sshd effective (`sshd -T`), sinon 22 ; ou un numéro ; ou `none` |
| `UFW_ALLOW` | vide | règles supplémentaires, ex. `80/tcp 443/tcp 5432/tcp` |
| `SERVICES_MASK` | vide | services à masquer |
| `SERVICES_DISABLE` | vide | services à désactiver au démarrage |
| `REBOOT` | `no` | `yes` / `no` / `if-needed` (présence de `/var/run/reboot-required`) |

### Outils : gestionnaires et versions

Chaque outil indique son gestionnaire (`apt`, `snap`, `flatpak`, `pip`, `npm`, `cargo`) : pas de chaîne de repli, donc jamais de paquet « approchant ». Gestionnaire absent (ex. `snap:` sans snapd) : échec explicite de cet outil.

| Gestionnaire | Sens de `@version` | Emplacement |
|---|---|---|
| `apt` | préfixe de version (`apt:nodejs@20`) | système |
| `snap` | canal (`snap:node@20` = `20/stable`) | système |
| `flatpak` | non supporté (config refusée) ; identifiant complet requis (`org.gimp.GIMP`) | système |
| `pip` | version exacte ; pipx uniquement (`PIPX_HOME=/opt/pipx`, binaires dans `/usr/local/bin`) | système |
| `npm` | version exacte | global (`-g`) |
| `cargo` | version exacte | `/usr/local` |

Un outil déjà présent dans une autre version n'est **ni mis à niveau ni rétrogradé** : un avertissement apparaît dans le rapport.

---

## Garde-fous

- **SSH** : en session SSH, le port SSH effectif est toujours autorisé dans UFW avant l'activation, même avec `UFW_SSH_PORT=none` (avertissement dans le rapport).
- **UFW en relance** : les règles de la configuration sont **ajoutées**, jamais supprimées (pas de `ufw reset`). Les règles déjà présentes mais absentes de la configuration sont listées dans le rapport, à retirer à la main si besoin.
- **Services** : la liste « sûrs » (avahi-daemon, cups, cups-browsed, bluetooth, ModemManager, whoopsie, apport, speech-dispatcher, saned, postfix, exim4, rpcbind, nfs-common) peut être traitée en lot. Les services « sensibles » (unattended-upgrades, apt-daily, apt-daily-upgrade, rsyslog, wpa_supplicant, NetworkManager-wait-online, thermald, snapd) ne sont proposés qu'un par un, ou avertissent en mode config. `ssh`/`sshd` sont toujours refusés. Masquer = `stop` + `mask` ; désactiver = `disable --now`.
- **Mise à jour** : `DEBIAN_FRONTEND=noninteractive`, fichiers de configuration modifiés localement conservés. Un échec d'apt est une erreur bloquante (code 1).
- **Connectivité** : vérifiée par un `apt-get update` réussi (pas de ping).
- **Système non supporté** : refusé en mode `--config` ; avertissement et confirmation en interactif.

---

## Codes de sortie, journaux, rapport

| Code | Signification |
|---|---|
| `0` | tout est OK |
| `1` | erreur bloquante : configuration invalide, pas root, système non supporté, apt en échec |
| `2` | terminé avec des échecs partiels (un outil ou un service) |

- Journal complet (sortie d'apt incluse, sans couleurs) : `/var/log/provision/provision-AAAAMMJJ-HHMMSS.log` (ou `--log`).
- Rapport final : affiché et copié dans `/var/log/provision/rapport-AAAAMMJJ-HHMMSS.txt` (outils installés/échoués, dépôts, règles UFW, services, avertissements, redémarrage requis).
- En dry-run sans root, le journal est écrit sous `$TMPDIR` (ou `/tmp`).

---

## Ancien → nouveau

| Avant | Maintenant |
|---|---|
| `sudo bash ubuntu-setup.sh` | `sudo ./provision.sh` |
| `sudo bash debian-setup.sh` | `sudo ./provision.sh` (Debian détecté automatiquement) |
| `--non-interactive` (annoncé, jamais implémenté) | `--config fichier.conf` |
| UFW « personnaliser les politiques » | retiré : refus entrant, autorisation sortant |

---

## Liste de contrôle de validation sur VM

À dérouler sur des VM (Ubuntu 24.04 et Debian 12/13 au minimum) avant de déployer sur le parc :

- [ ] `--config examples/parc.conf --dry-run` : rien n'est modifié, les actions prévues sont affichées.
- [ ] **UFW via SSH, port non standard** : sshd sur le port 2222, connexion SSH sur ce port, lancement avec `UFW_SSH_PORT=auto` puis `none` : la session reste ouverte, `ufw status` montre `2222/tcp` autorisé.
- [ ] **Relance idempotente** : deuxième exécution identique, aucune règle UFW dupliquée, aucun dépôt dupliqué, outils « déjà installés », code de sortie `0`.
- [ ] **Règle UFW manuelle** ajoutée entre deux exécutions : conservée, listée dans le rapport.
- [ ] **Services sensibles** : en interactif, absents de l'option « tout désactiver » ; en config, avertissement dans le rapport ; `snapd` refusé si des outils `snap:` sont installés.
- [ ] **Debian 13 (deb822)** : `DEBIAN_COMPONENTS` modifie `debian.sources` (champ `Components:`), sauvegarde `*.bak-AAAAMMJJ`, backports dans un fichier `.sources` dédié.
- [ ] Outil en échec volontaire (`apt:inexistant`) : code de sortie `2`, outil listé dans le rapport.
- [ ] Fichier de configuration invalide : code `1`, aucune modification.
- [ ] `ssh -t machine 'sudo bash provision.sh --config parc.conf </dev/null'` se termine sans rester bloqué.
- [ ] `REBOOT=if-needed` : redémarrage seulement si `/var/run/reboot-required` existe.

---

## Commandes utiles : services (systemd)

### 🔍 Commandes pour vérifier et gérer les services (Systemd)

```bash
# 1. Vérifier si un service est actuellement actif (en cours d'exécution)
systemctl is-active <nom_service>
# Retourne : active, inactive ou failed

# 2. Vérifier si un service démarre au boot (enabled, disabled, masked)
systemctl is-enabled <nom_service>
# Retourne : enabled, disabled ou masked

# 3. Afficher le statut détaillé et les logs récents d'un service
sudo systemctl status <nom_service>

# 4. Lister tous les services actifs en cours d'exécution
systemctl list-units --type=service --state=running

# 5. Lister tous les services masqués (désactivation totale)
systemctl list-unit-files --state=masked

# 6. Rétablir un service masqué ou désactivé si besoin
sudo systemctl unmask <nom_service>
sudo systemctl enable --now <nom_service>
```


---

## Commandes utiles : pare-feu UFW

### 🔍 Commandes pour vérifier et gérer UFW

```bash
# 1. Vérifier le statut complet et les règles actives (recommandé)
sudo ufw status verbose

# 2. Afficher les règles numérotées (idéal pour identifier une règle à supprimer)
sudo ufw status numbered

# 3. Vérifier les politiques par défaut (default incoming / outgoing)
sudo ufw status verbose | grep "Default:"

# 4. Activer ou désactiver le pare-feu
sudo ufw enable
sudo ufw disable

# 5. Recharger la configuration après modification
sudo ufw reload

# 6. Supprimer une règle existante
# Méthode A : par son numéro (obtenu via 'sudo ufw status numbered')
sudo ufw delete <numéro>

# Méthode B : par la règle exacte
sudo ufw delete allow 80/tcp

# 7. Consulter les logs du pare-feu en temps réel
sudo journalctl -u ufw -f
# ou dans le fichier de log UFW :
sudo tail -f /var/log/ufw.log
```


---

> Le script requiert les droits **root**. Testez-le sur une VM avant tout usage en production.
