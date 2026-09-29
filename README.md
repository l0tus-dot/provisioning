# 🛠️ Scripts de Post-Installation

Scripts interactifs de configuration d'une machine vierge **Ubuntu** ou **Debian**.

---

## 📂 Fichiers

| Script | Cible |
|---|---|
| `ubuntu-setup.sh` | Ubuntu 22.04 / 24.04 / 26.04 LTS (et dérivés) |
| `debian-setup.sh` | Debian 11 (Bullseye) / 12 (Bookworm) / 13 |

---

## 🚀 Utilisation

```bash
# Ubuntu
sudo bash ubuntu-setup.sh

# Debian
sudo bash debian-setup.sh
```

---

## 🔄 Déroulement interactif

### Ubuntu (`ubuntu-setup.sh`)

| Étape | Description |
|---|---|
| 1 | Vérification des prérequis (root, Internet) |
| 2 | Mise à jour du système (`apt update && upgrade`) |
| 3 | **Installation des outils** (interactive) |
| 4 | Configuration du pare-feu UFW |
| 5 | **Gestion des services inutiles** (interactive) |
| 6 | Rapport de synthèse + redémarrage optionnel |

### Debian (`debian-setup.sh`) — étapes supplémentaires

| Étape | Description |
|---|---|
| 1 | Vérification des prérequis |
| **2** | **Configuration des dépôts** (contrib, non-free, backports, snap, flatpak) |
| 3 | Mise à jour du système |
| 4 | Installation des outils |
| 5 | Configuration UFW |
| 6 | Gestion des services |
| 7 | Rapport de synthèse |

---

## 🔧 Installation des outils (étape clé)

Le script vous demande les outils **un par un** :

```
[?] Nom de l'outil (ou 'fin') : git
[?] Version de git ? (laisser vide = dernière) :
[OK] Ajouté : git

[?] Nom de l'outil (ou 'fin') : node
[?] Version de node ? (laisser vide = dernière) : 20.0.0
[OK] Ajouté : node v20.0.0

[?] Nom de l'outil (ou 'fin') : fin
```

### Gestionnaires supportés (ordre de priorité)

| Ordre | Gestionnaire | Exemples d'outils |
|---|---|---|
| 1 | **apt** | git, curl, vim, wireshark, nmap… |
| 2 | **snap** | code, discord, spotify, postman… |
| 3 | **flatpak** | org.gimp.GIMP, com.obsproject.Studio… |
| 4 | **pip** | httpie, ansible, black, requests… |
| 5 | **npm** | typescript, eslint, nodemon… |
| 6 | **cargo** | ripgrep, bat, fd-find, exa… |

Si aucun gestionnaire ne trouve l'outil, une erreur claire est affichée dans le rapport final.

### Sélection de version

- Laisser vide → **dernière version** disponible
- Entrer une version → le script vérifie si elle existe et propose un fallback si introuvable

---

## ⚙️ Gestion des services inutiles

Trois niveaux de désactivation proposés **pour chaque service** :

| Choix | Méthode | Effet |
|---|---|---|
| **1 — Totalement** | `systemctl mask` | Le service ne peut plus démarrer, même manuellement |
| **2 — Partiellement** | `systemctl disable --now` | Ne démarre plus au boot, mais démarrable manuellement |
| **3 — Aucun changement** | — | Le service reste tel quel |

### Option globale (gain de temps)

Au lieu de répondre service par service, vous pouvez choisir :
- **A** — Gérer un par un *(recommandé)*
- **B** — Masquer tout (désactivation totale de toute la liste)
- **C** — Désactiver tout partiellement
- **D** — Ignorer complètement

### Services de la liste Ubuntu

| Service | Description |
|---|---|
| `snapd` | Daemon Snap |
| `avahi-daemon` | mDNS/Bonjour |
| `cups` / `cups-browsed` | Impression |
| `bluetooth` | Bluetooth |
| `ModemManager` | Modems GSM/CDMA |
| `whoopsie` | Rapports de crash Ubuntu |
| `apport` | Collecte d'erreurs |
| `thermald` | Gestion thermique |
| `unattended-upgrades` | Mises à jour automatiques |
| `rsyslog` | Journalisation système |
| `postfix` | Serveur SMTP local |
| `speech-dispatcher` | Synthèse vocale |

### Services supplémentaires (Debian uniquement)

| Service | Description |
|---|---|
| `exim4` | Agent mail Exim |
| `apt-daily` / `apt-daily-upgrade` | Maintenance apt automatique |
| `rpcbind` | Port mapper RPC (si NFS inutilisé) |
| `nfs-common` | Support NFS client |

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

## 🔒 Pare-feu UFW

Configuration interactive :
- Politique par défaut : **bloquer entrant, autoriser sortant**
- SSH (port personnalisable)
- HTTP / HTTPS (optionnels)
- Règles personnalisées supplémentaires

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

## 📊 Rapport de synthèse

En fin de script, un rapport récapitule :
- ✅ Outils installés (avec version et gestionnaire)
- ❌ Outils en échec
- 🔒 Règles UFW ajoutées
- 🔴 Services masqués (totalement)
- 🟡 Services désactivés (au démarrage)

---

## ⚠️ Notes

> Ces scripts requièrent les droits **root** (`sudo bash`).
> Testez-les sur une VM ou un environnement de test avant une production.
