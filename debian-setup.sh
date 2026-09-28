#!/usr/bin/env bash
# =============================================================================
#  debian-setup.sh — Script de post-installation Debian
#  Version : 1.0
#  Compatibilité : Debian 11 (Bullseye) / 12 (Bookworm) et ultérieur
#  Auteur  : Généré avec Network Mapper Suite
#
#  Usage :
#    sudo bash debian-setup.sh
# =============================================================================
#
#  Ce script effectue dans l'ordre :
#   1. Vérification des prérequis (root, connexion Internet)
#   2. Configuration des dépôts (contrib, non-free, backports)
#   3. Mise à jour complète du système
#   4. Installation interactive des outils souhaités
#      → Tout type d'outil (apt, flatpak, pip, npm, cargo…)
#      → Choix de la version ou "dernière disponible"
#   5. Configuration du pare-feu UFW
#   6. Gestion des services inutiles (désactivation totale / partielle / aucune)
#   7. Rapport de synthèse
#
#  Différences clés avec Ubuntu :
#   - Pas de snap par défaut (installation optionnelle proposée)
#   - Dépôts contrib/non-free/backports à activer manuellement
#   - Liste de services différente (pas de whoopsie, apport…)
#   - Supports de flatpak proposé si non installé
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Couleurs ANSI
# ---------------------------------------------------------------------------
RED='\033[0;31m';    LRED='\033[1;31m'
GREEN='\033[0;32m';  LGREEN='\033[1;32m'
YELLOW='\033[1;33m'; BLUE='\033[0;34m'
CYAN='\033[0;36m';   MAGENTA='\033[0;35m'
WHITE='\033[1;37m';  GRAY='\033[0;37m'
BOLD='\033[1m';      NC='\033[0m'

# ---------------------------------------------------------------------------
# Variables globales — rapport de synthèse
# ---------------------------------------------------------------------------
REPORT_TOOLS_INSTALLED=()
REPORT_TOOLS_FAILED=()
REPORT_SERVICES_MASKED=()
REPORT_SERVICES_DISABLED=()
REPORT_SERVICES_SKIPPED=()
UFW_RULES_ADDED=()
REPOS_ADDED=()
START_TIME=$(date +%s)

DEBIAN_VERSION=""
DEBIAN_CODENAME=""

# ---------------------------------------------------------------------------
# Helpers d'affichage
# ---------------------------------------------------------------------------
hr()      { printf "${GRAY}%$(tput cols)s${NC}\n" | tr ' ' '-'; }
hr_bold() { printf "${CYAN}%$(tput cols)s${NC}\n" | tr ' ' '='; }

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()      { echo -e "${LGREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${LRED}[ERR]${NC}   $*"; }
step()    { echo -e "\n${BOLD}${BLUE}▶ $*${NC}"; hr; }
ask()     { echo -e "${MAGENTA}[?]${NC}    $*"; }

spinner() {
    local pid=$1 msg=$2
    local spin='|/-\'
    local i=0
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r${CYAN}%s${NC} %s " "${spin:$((i % 4)):1}" "$msg"
        sleep 0.1
        ((i++))
    done
    printf "\r%-60s\r" " "
}

confirm() {
    local prompt="$1" default="${2:-n}"
    local yn_hint
    [[ "$default" == "y" ]] && yn_hint="${LGREEN}O${NC}/n" || yn_hint="o/${LGREEN}N${NC}"
    ask "$prompt [$yn_hint] : "
    read -r reply
    [[ -z "$reply" ]] && reply="$default"
    [[ "$reply" =~ ^[oOyY]$ ]]
}

# ---------------------------------------------------------------------------
# 0. Bannière
# ---------------------------------------------------------------------------
print_banner() {
    clear
    hr_bold
    echo -e "${BOLD}${WHITE}"
    echo "    ____       _     _               ____       _               "
    echo "   |  _ \  ___| |__ (_) __ _ _ __  / ___|  ___| |_ _   _ _ __ "
    echo "   | | | |/ _ \ '_ \| |/ _\` | '_ \ \___ \ / _ \ __| | | | '_ \\"
    echo "   | |_| |  __/ |_) | | (_| | | | | ___) |  __/ |_| |_| | |_) |"
    echo "   |____/ \___|_.__/|_|\__,_|_| |_||____/ \___|\__|\__,_| .__/ "
    echo "                                                           |_|    "
    echo -e "${NC}"
    echo -e "  ${CYAN}Script de post-installation Debian${NC}  |  v1.0"

    # Détection de la version Debian
    if [[ -f /etc/debian_version ]]; then
        DEBIAN_VERSION=$(cat /etc/debian_version)
        DEBIAN_CODENAME=$(grep VERSION_CODENAME /etc/os-release 2>/dev/null | cut -d= -f2 || echo "unknown")
        echo -e "  Système : ${WHITE}Debian $DEBIAN_VERSION ($DEBIAN_CODENAME)${NC}"
    fi

    echo -e "  Date    : ${WHITE}$(date '+%d/%m/%Y %H:%M:%S')${NC}"
    hr_bold
    echo ""
}

# ---------------------------------------------------------------------------
# 1. Vérifications préliminaires
# ---------------------------------------------------------------------------
check_requirements() {
    step "Vérification des prérequis"

    if [[ $EUID -ne 0 ]]; then
        error "Ce script doit être exécuté en tant que root."
        echo -e "  Relancez avec : ${BOLD}sudo bash $0${NC}"
        exit 1
    fi
    ok "Droits root confirmés"

    if ! ping -c 1 -W 3 8.8.8.8 &>/dev/null; then
        error "Aucune connexion Internet détectée."
        exit 1
    fi
    ok "Connexion Internet disponible"

    if ! grep -qi debian /etc/os-release 2>/dev/null; then
        warn "Ce script est optimisé pour Debian. Continuer quand même ?"
        confirm "Continuer ?" "n" || exit 0
    fi

    if ! command -v apt &>/dev/null; then
        error "apt non trouvé."
        exit 1
    fi
    ok "Gestionnaire de paquets apt disponible"
    echo ""
}

# ---------------------------------------------------------------------------
# 2. Configuration des dépôts Debian
# ---------------------------------------------------------------------------
configure_repos() {
    step "Configuration des dépôts Debian"

    local sources_file="/etc/apt/sources.list"
    local codename="$DEBIAN_CODENAME"
    [[ -z "$codename" || "$codename" == "unknown" ]] && codename="bookworm"

    echo -e "  Codename détecté : ${CYAN}$codename${NC}"
    echo ""

    # Vérifier et proposer contrib
    if ! grep -q "contrib" "$sources_file" 2>/dev/null; then
        if confirm "Activer le dépôt ${BOLD}contrib${NC} (logiciels libres nécessitant des composants non-libres) ?" "y"; then
            sed -i "s/${codename} main$/${codename} main contrib/" "$sources_file" 2>/dev/null || true
            ok "Dépôt contrib activé"
            REPOS_ADDED+=("contrib")
        fi
    else
        info "Dépôt contrib déjà activé"
    fi

    # non-free
    if ! grep -q "non-free" "$sources_file" 2>/dev/null; then
        if confirm "Activer le dépôt ${BOLD}non-free${NC} (firmware propriétaires, drivers Wi-Fi, etc.) ?" "y"; then
            sed -i "s/${codename} main/${codename} main non-free non-free-firmware/" "$sources_file" 2>/dev/null || true
            ok "Dépôt non-free activé"
            REPOS_ADDED+=("non-free")
        fi
    else
        info "Dépôt non-free déjà activé"
    fi

    # backports
    local backports_entry="deb http://deb.debian.org/debian ${codename}-backports main contrib non-free"
    if ! grep -q "${codename}-backports" "$sources_file" 2>/dev/null; then
        if confirm "Activer les ${BOLD}backports${NC} (versions plus récentes de certains paquets) ?" "n"; then
            echo "$backports_entry" >> "$sources_file"
            ok "Backports activés : $codename-backports"
            REPOS_ADDED+=("backports")
        fi
    else
        info "Backports déjà activés"
    fi

    # Snap sur Debian (optionnel)
    if ! command -v snap &>/dev/null; then
        echo ""
        if confirm "Installer ${BOLD}snapd${NC} (gestionnaire de paquets snap, absent par défaut sur Debian) ?" "n"; then
            apt install -y snapd -qq
            systemctl enable --now snapd.socket &>/dev/null
            ok "snapd installé"
            REPORT_TOOLS_INSTALLED+=("snapd")
        fi
    else
        info "snapd déjà installé"
    fi

    # Flatpak sur Debian
    if ! command -v flatpak &>/dev/null; then
        if confirm "Installer ${BOLD}flatpak${NC} (gestionnaire de paquets flatpak) avec le dépôt Flathub ?" "n"; then
            apt install -y flatpak -qq
            flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo 2>/dev/null || true
            ok "flatpak installé avec Flathub"
            REPORT_TOOLS_INSTALLED+=("flatpak")
        fi
    else
        info "flatpak déjà installé"
    fi

    echo ""
}

# ---------------------------------------------------------------------------
# 3. Mise à jour du système
# ---------------------------------------------------------------------------
system_update() {
    step "Mise à jour du système"

    confirm "Lancer la mise à jour complète (apt update && upgrade) ?" "y" || {
        warn "Mise à jour ignorée."
        return 0
    }

    info "Mise à jour de la liste des paquets..."
    apt update -qq 2>&1 | tail -3
    ok "Liste des paquets mise à jour"

    info "Mise à niveau des paquets..."
    (apt upgrade -y -qq 2>&1) &
    spinner $! "Mise à niveau en cours..."
    ok "Paquets mis à niveau"

    info "Nettoyage..."
    apt autoremove -y -qq
    apt autoclean -qq
    ok "Nettoyage terminé"
    echo ""
}

# ---------------------------------------------------------------------------
# 4. Installation d'outils — moteur universel
# ---------------------------------------------------------------------------

search_apt_versions() {
    local pkg="$1"
    apt-cache policy "$pkg" 2>/dev/null | grep -E '^\s+[0-9]' | awk '{print $1}' | head -10
}

try_apt_install() {
    local pkg="$1" version="$2"
    local install_target

    if ! apt-cache show "$pkg" &>/dev/null; then
        # Essayer depuis les backports si activés
        if grep -q "backports" /etc/apt/sources.list 2>/dev/null; then
            if apt-cache show -t "${DEBIAN_CODENAME}-backports" "$pkg" &>/dev/null 2>&1; then
                warn "Paquet '$pkg' trouvé dans les backports."
                if confirm "  Installer depuis les backports ?" "y"; then
                    apt install -y -t "${DEBIAN_CODENAME}-backports" "$pkg" -qq 2>&1 | grep -v "^$" || true
                    return 0
                fi
            fi
        fi
        return 1
    fi

    if [[ -n "$version" ]]; then
        if apt-cache show "${pkg}=${version}" &>/dev/null 2>&1; then
            install_target="${pkg}=${version}"
        else
            warn "Version '${version}' introuvable dans apt pour '${pkg}'."
            echo -e "  Versions disponibles :"
            search_apt_versions "$pkg" | while read -r v; do
                echo -e "    ${GRAY}→ $v${NC}"
            done
            confirm "  Installer la dernière version ?" "y" || return 1
            install_target="$pkg"
        fi
    else
        install_target="$pkg"
    fi

    apt install -y "$install_target" -qq 2>&1 | grep -v "^$" || true
    return 0
}

try_snap_install() {
    local pkg="$1" version="$2"

    if ! command -v snap &>/dev/null; then
        return 1
    fi

    if ! snap find "$pkg" &>/dev/null 2>&1; then
        return 1
    fi

    if [[ -n "$version" ]]; then
        snap install "$pkg" --channel="${version}/stable" 2>/dev/null || \
        snap install "$pkg" 2>/dev/null || return 1
    else
        snap install "$pkg" 2>/dev/null || return 1
    fi
    return 0
}

try_flatpak_install() {
    local pkg="$1"

    if ! command -v flatpak &>/dev/null; then
        return 1
    fi

    flatpak install -y flathub "$pkg" &>/dev/null && return 0 || return 1
}

# Installe via pip / pipx (Python) — compatible PEP 668 (Debian 12 / 13)
try_pip_install() {
    local pkg="$1" version="$2"
    local target
    [[ -n "$version" ]] && target="${pkg}==${version}" || target="$pkg"

    if command -v pipx &>/dev/null; then
        pipx install --quiet "$target" &>/dev/null && return 0
    fi

    if command -v pip3 &>/dev/null; then
        pip3 install --quiet "$target" &>/dev/null && return 0
        pip3 install --quiet --break-system-packages "$target" &>/dev/null && return 0
    fi
    return 1
}

try_npm_install() {
    local pkg="$1" version="$2"
    local target
    [[ -n "$version" ]] && target="${pkg}@${version}" || target="$pkg"

    if command -v npm &>/dev/null; then
        npm install -g --silent "$target" &>/dev/null && return 0
    fi
    return 1
}

try_cargo_install() {
    local pkg="$1" version="$2"

    if command -v cargo &>/dev/null; then
        if [[ -n "$version" ]]; then
            cargo install --quiet --version "$version" "$pkg" &>/dev/null && return 0
        else
            cargo install --quiet "$pkg" &>/dev/null && return 0
        fi
    fi
    return 1
}

install_tool() {
    local tool="$1" version="${2:-}"
    local installed=false

    echo -e "\n  ${BOLD}${WHITE}→ $tool${NC}${version:+ (version: ${CYAN}$version${NC})}"

    if try_apt_install "$tool" "$version"; then
        ok "  $tool installé via apt"
        installed=true

    elif try_snap_install "$tool" "$version"; then
        ok "  $tool installé via snap"
        installed=true

    elif try_flatpak_install "$tool"; then
        ok "  $tool installé via flatpak"
        installed=true

    elif try_pip_install "$tool" "$version"; then
        ok "  $tool installé via pip"
        installed=true

    elif try_npm_install "$tool" "$version"; then
        ok "  $tool installé via npm"
        installed=true

    elif try_cargo_install "$tool" "$version"; then
        ok "  $tool installé via cargo"
        installed=true
    fi

    if $installed; then
        REPORT_TOOLS_INSTALLED+=("$tool${version:+ v$version}")
    else
        error "  Impossible d'installer '$tool'. Vérifiez le nom ou ajoutez manuellement."
        REPORT_TOOLS_FAILED+=("$tool${version:+ (v$version demandée)}")
    fi
}

install_tools() {
    step "Installation des outils"

    echo -e "  Entrez les outils à installer, ${BOLD}un par un${NC}."
    echo -e "  Tout type d'outil accepté : paquet apt, snap, pip, npm, cargo, flatpak…"
    echo -e "  Tapez ${BOLD}fin${NC} ou laissez vide pour terminer."
    echo ""

    local tools_list=()

    while true; do
        ask "Nom de l'outil (ou 'fin') : "
        read -r tool_name
        tool_name="${tool_name// /}"

        [[ -z "$tool_name" || "$tool_name" == "fin" || "$tool_name" == "done" ]] && break

        ask "Version de ${BOLD}$tool_name${NC} ? ${GRAY}(laisser vide = dernière)${NC} : "
        read -r tool_version

        tools_list+=("${tool_name}::${tool_version}")
        ok "Ajouté : $tool_name${tool_version:+ v$tool_version}"
    done

    if [[ ${#tools_list[@]} -eq 0 ]]; then
        warn "Aucun outil sélectionné."
        return 0
    fi

    echo ""
    echo -e "  ${BOLD}Récapitulatif :${NC}"
    for entry in "${tools_list[@]}"; do
        local name="${entry%%::*}"
        local ver="${entry##*::}"
        echo -e "    ${CYAN}•${NC} $name${ver:+  ${GRAY}(v$ver)${NC}}"
    done
    echo ""

    confirm "Lancer l'installation ?" "y" || { warn "Installation annulée."; return 0; }

    echo ""
    for entry in "${tools_list[@]}"; do
        local name="${entry%%::*}"
        local ver="${entry##*::}"
        install_tool "$name" "$ver"
    done
    echo ""
}

# ---------------------------------------------------------------------------
# 5. Configuration du pare-feu UFW
# ---------------------------------------------------------------------------
configure_ufw() {
    step "Configuration du pare-feu UFW"

    if ! command -v ufw &>/dev/null; then
        info "UFW non installé. Installation..."
        apt install -y ufw -qq
        ok "UFW installé"
    fi

    confirm "Configurer UFW ?" "y" || { warn "UFW ignoré."; return 0; }

    ufw default deny incoming  &>/dev/null
    ufw default allow outgoing &>/dev/null
    ok "Politique par défaut : bloquer entrant, autoriser sortant"

    echo ""
    echo -e "  ${BOLD}Règles standard :${NC}"

    if confirm "Autoriser SSH (port 22) ?" "y"; then
        ask "  Port SSH ${GRAY}[défaut: 22]${NC} : "
        read -r ssh_port
        [[ -z "$ssh_port" ]] && ssh_port="22"
        ufw allow "$ssh_port/tcp" &>/dev/null
        UFW_RULES_ADDED+=("SSH ($ssh_port/tcp)")
        ok "SSH autorisé sur le port $ssh_port"
    fi

    confirm "Autoriser HTTP (80) ?" "n" && {
        ufw allow 80/tcp &>/dev/null
        UFW_RULES_ADDED+=("HTTP (80/tcp)")
        ok "HTTP autorisé"
    }

    confirm "Autoriser HTTPS (443) ?" "n" && {
        ufw allow 443/tcp &>/dev/null
        UFW_RULES_ADDED+=("HTTPS (443/tcp)")
        ok "HTTPS autorisé"
    }

    echo ""
    echo -e "  ${BOLD}Règles personnalisées${NC} (tapez ${BOLD}fin${NC} pour arrêter) :"
    while true; do
        ask "Port/règle (ex: 8080/tcp, 5432) : "
        read -r custom_rule
        [[ -z "$custom_rule" || "$custom_rule" == "fin" ]] && break
        ufw allow "$custom_rule" &>/dev/null && {
            UFW_RULES_ADDED+=("$custom_rule")
            ok "Règle ajoutée : $custom_rule"
        } || warn "Règle invalide : $custom_rule"
    done

    echo ""
    if confirm "Activer UFW maintenant ?" "y"; then
        ufw --force enable &>/dev/null
        ok "UFW activé"
        ufw status verbose
    else
        warn "UFW configuré mais non activé. Activez avec : sudo ufw enable"
    fi
    echo ""
}

# ---------------------------------------------------------------------------
# 6. Gestion des services inutiles
# ---------------------------------------------------------------------------

# Liste spécifique à Debian (différente d'Ubuntu)
declare -A DEBIAN_SERVICES=(
    ["avahi-daemon"]="mDNS/Bonjour — découverte de services réseau locaux"
    ["cups"]="Service d'impression CUPS"
    ["cups-browsed"]="Découverte automatique d'imprimantes réseau"
    ["bluetooth"]="Service Bluetooth"
    ["ModemManager"]="Gestion des modems mobiles (4G/GSM)"
    ["rsyslog"]="Service de journalisation système (remplacé par journald)"
    ["postfix"]="Serveur de messagerie SMTP local"
    ["exim4"]="Agent de transport de mail (MTA) Exim"
    ["saned"]="Service de scan réseau (scanners)"
    ["speech-dispatcher"]="Synthèse vocale (text-to-speech)"
    ["wpa_supplicant"]="Gestion Wi-Fi (inutile sur serveurs câblés)"
    ["NetworkManager-wait-online"]="Attente réseau au démarrage (ralentit le boot)"
    ["apt-daily"]="Maintenance apt quotidienne automatique"
    ["apt-daily-upgrade"]="Mises à jour apt automatiques"
    ["rpcbind"]="Port mapper RPC (inutile si NFS non utilisé)"
    ["nfs-common"]="Support NFS client (si non nécessaire)"
)

ask_service_action() {
    local svc="$1" desc="$2"

    # Vérifier présence du service
    if ! systemctl list-unit-files 2>/dev/null | grep -q "^${svc}"; then
        return  # Non installé
    fi

    local status enabled
    status=$(systemctl is-active "$svc" 2>/dev/null || echo "inactive")
    enabled=$(systemctl is-enabled "$svc" 2>/dev/null || echo "disabled")

    echo ""
    echo -e "  ${BOLD}${WHITE}$svc${NC}"
    echo -e "  ${GRAY}$desc${NC}"
    echo -e "  Actuel : ${status}  |  Au démarrage : ${enabled}"
    echo ""
    echo -e "   ${RED}1${NC}. ${BOLD}Désactiver totalement${NC}  (mask) — impossible à démarrer même manuellement"
    echo -e "   ${YELLOW}2${NC}. ${BOLD}Désactiver partiellement${NC} (disable) — ne démarre plus au boot"
    echo -e "   ${GREEN}3${NC}. ${BOLD}Laisser tel quel${NC}"
    ask "Choix [1/2/3, défaut: 3] : "
    read -r choice
    [[ -z "$choice" ]] && choice="3"

    case "$choice" in
        1)
            systemctl stop "$svc"    2>/dev/null || true
            systemctl mask "$svc"    2>/dev/null && {
                ok "  $svc masqué (désactivation totale)"
                REPORT_SERVICES_MASKED+=("$svc")
            } || warn "  Impossible de masquer $svc"
            ;;
        2)
            systemctl stop "$svc"    2>/dev/null || true
            systemctl disable "$svc" 2>/dev/null && {
                ok "  $svc désactivé au démarrage"
                REPORT_SERVICES_DISABLED+=("$svc")
            } || warn "  Impossible de désactiver $svc"
            ;;
        3|*)
            info "  $svc conservé"
            REPORT_SERVICES_SKIPPED+=("$svc")
            ;;
    esac
}

manage_services() {
    step "Gestion des services inutiles"

    echo -e "  Liste des services potentiellement inutiles sur Debian."
    echo -e "  Pour chaque service présent sur votre système, choisissez :"
    echo -e "   ${RED}• Désactivation totale${NC}  (mask)    → impossible à démarrer"
    echo -e "   ${YELLOW}• Désactivation partielle${NC} (disable) → ne démarre plus au boot"
    echo -e "   ${GREEN}• Aucun changement${NC}               → conservé"
    echo ""

    echo -e "  ${BOLD}Option globale :${NC}"
    echo -e "   ${CYAN}A${NC}. Gérer les services ${BOLD}un par un${NC} (recommandé)"
    echo -e "   ${CYAN}B${NC}. Désactiver ${BOLD}totalement${NC} tous les services de la liste"
    echo -e "   ${CYAN}C${NC}. Désactiver ${BOLD}partiellement${NC} tous les services"
    echo -e "   ${CYAN}D${NC}. ${BOLD}Ignorer${NC} la gestion des services"
    ask "Choix [A/B/C/D, défaut: A] : "
    read -r global_choice
    [[ -z "$global_choice" ]] && global_choice="A"

    case "${global_choice^^}" in
        B)
            warn "Désactivation totale (mask) de tous les services..."
            for svc in "${!DEBIAN_SERVICES[@]}"; do
                if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}"; then
                    systemctl stop "$svc"    2>/dev/null || true
                    systemctl mask "$svc"    2>/dev/null && {
                        ok "  $svc masqué"
                        REPORT_SERVICES_MASKED+=("$svc")
                    } || true
                fi
            done
            ;;
        C)
            warn "Désactivation partielle (disable) de tous les services..."
            for svc in "${!DEBIAN_SERVICES[@]}"; do
                if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}"; then
                    systemctl stop "$svc"    2>/dev/null || true
                    systemctl disable "$svc" 2>/dev/null && {
                        ok "  $svc désactivé"
                        REPORT_SERVICES_DISABLED+=("$svc")
                    } || true
                fi
            done
            ;;
        D)
            warn "Gestion des services ignorée."
            ;;
        A|*)
            for svc in "${!DEBIAN_SERVICES[@]}"; do
                ask_service_action "$svc" "${DEBIAN_SERVICES[$svc]}"
            done
            ;;
    esac
    echo ""
}

# ---------------------------------------------------------------------------
# 7. Rapport de synthèse
# ---------------------------------------------------------------------------
print_report() {
    local end_time elapsed
    end_time=$(date +%s)
    elapsed=$((end_time - START_TIME))

    hr_bold
    echo -e "\n  ${BOLD}${WHITE}RAPPORT DE POST-INSTALLATION DEBIAN${NC}"
    echo -e "  Durée totale : ${CYAN}${elapsed}s${NC}  |  $(date '+%d/%m/%Y %H:%M:%S')"
    hr_bold
    echo ""

    # Dépôts activés
    if [[ ${#REPOS_ADDED[@]} -gt 0 ]]; then
        echo -e "  ${CYAN}📦 Dépôts activés (${#REPOS_ADDED[@]})${NC}"
        for r in "${REPOS_ADDED[@]}"; do
            echo -e "    ${CYAN}•${NC} $r"
        done
        echo ""
    fi

    # Outils installés
    echo -e "  ${LGREEN}✔ Outils installés (${#REPORT_TOOLS_INSTALLED[@]})${NC}"
    if [[ ${#REPORT_TOOLS_INSTALLED[@]} -gt 0 ]]; then
        for t in "${REPORT_TOOLS_INSTALLED[@]}"; do
            echo -e "    ${GREEN}•${NC} $t"
        done
    else
        echo -e "    ${GRAY}Aucun${NC}"
    fi
    echo ""

    # Échecs
    if [[ ${#REPORT_TOOLS_FAILED[@]} -gt 0 ]]; then
        echo -e "  ${LRED}✘ Outils non installés (${#REPORT_TOOLS_FAILED[@]})${NC}"
        for t in "${REPORT_TOOLS_FAILED[@]}"; do
            echo -e "    ${RED}•${NC} $t"
        done
        echo ""
    fi

    # UFW
    echo -e "  ${CYAN}🔒 Règles UFW ajoutées (${#UFW_RULES_ADDED[@]})${NC}"
    if [[ ${#UFW_RULES_ADDED[@]} -gt 0 ]]; then
        for r in "${UFW_RULES_ADDED[@]}"; do
            echo -e "    ${CYAN}•${NC} $r"
        done
    else
        echo -e "    ${GRAY}Aucune${NC}"
    fi
    echo ""

    # Services masqués
    echo -e "  ${RED}🔴 Services masqués / désactivation totale (${#REPORT_SERVICES_MASKED[@]})${NC}"
    if [[ ${#REPORT_SERVICES_MASKED[@]} -gt 0 ]]; then
        for s in "${REPORT_SERVICES_MASKED[@]}"; do
            echo -e "    ${RED}•${NC} $s"
        done
    else
        echo -e "    ${GRAY}Aucun${NC}"
    fi
    echo ""

    # Services désactivés
    echo -e "  ${YELLOW}🟡 Services désactivés au démarrage (${#REPORT_SERVICES_DISABLED[@]})${NC}"
    if [[ ${#REPORT_SERVICES_DISABLED[@]} -gt 0 ]]; then
        for s in "${REPORT_SERVICES_DISABLED[@]}"; do
            echo -e "    ${YELLOW}•${NC} $s"
        done
    else
        echo -e "    ${GRAY}Aucun${NC}"
    fi
    echo ""

    hr
    echo -e "  ${BOLD}${LGREEN}Post-installation Debian terminée !${NC}"
    echo -e "  ${GRAY}Un redémarrage est recommandé pour appliquer tous les changements.${NC}"
    echo ""
    confirm "Redémarrer maintenant ?" "n" && reboot || echo -e "  Redémarrez avec : ${BOLD}sudo reboot${NC}"
    echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    print_banner
    check_requirements
    configure_repos
    system_update
    install_tools
    configure_ufw
    manage_services
    print_report
}

main "$@"
