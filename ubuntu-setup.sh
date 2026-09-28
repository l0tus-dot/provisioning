#!/usr/bin/env bash
# =============================================================================
#  ubuntu-setup.sh — Script de post-installation Ubuntu
#  Version : 1.1
#  Compatibilité : Ubuntu 22.04 LTS / 24.04 LTS / 26.04 LTS (et dérivés)
#  Auteur  : Généré avec Network Mapper Suite
#
#  Usage :
#    sudo bash ubuntu-setup.sh
#    sudo bash ubuntu-setup.sh --non-interactive   (utilise les valeurs par défaut)
# =============================================================================
#
#  Ce script effectue dans l'ordre :
#   1. Vérification des prérequis (root, connexion Internet)
#   2. Mise à jour complète du système
#   3. Installation interactive des outils souhaités
#      → Tout type d'outil (apt, snap, flatpak, pip, npm, cargo…)
#      → Choix de la version ou "dernière disponible"
#   4. Configuration du pare-feu UFW
#   5. Gestion des services inutiles (désactivation totale / partielle / aucune)
#   6. Rapport de synthèse
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
START_TIME=$(date +%s)

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

# Spinner pour les opérations longues
spinner() {
    local pid=$1 msg=$2
    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r${CYAN}%s${NC} %s " "${spin:$((i % ${#spin})):1}" "$msg"
        sleep 0.1
        ((i++))
    done
    printf "\r%-60s\r" " "
}

# Lecture sécurisée avec valeur par défaut
read_default() {
    local prompt="$1" default="$2" var_name="$3"
    ask "$prompt ${GRAY}[défaut: $default]${NC} : "
    read -r input
    if [[ -z "$input" ]]; then
        printf -v "$var_name" '%s' "$default"
    else
        printf -v "$var_name" '%s' "$input"
    fi
}

# Confirmation oui/non
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
    echo "   _   _ _                 _          ____       _               "
    echo "  | | | | |__  _   _ _ __ | |_ _   _ / ___|  ___| |_ _   _ _ __ "
    echo "  | | | | '_ \| | | | '_ \| __| | | \___ \ / _ \ __| | | | '_ \\"
    echo "  | |_| | |_) | |_| | | | | |_| |_| |___) |  __/ |_| |_| | |_) |"
    echo "   \___/|_.__/ \__,_|_| |_|\__|\__,_|____/ \___|\__|\__,_| .__/ "
    echo "                                                            |_|    "
    echo -e "${NC}"
    echo -e "  ${CYAN}Script de post-installation Ubuntu${NC}  |  v1.1"
    local os_pretty
    os_pretty="$(grep -oP 'PRETTY_NAME="\K[^"]+' /etc/os-release 2>/dev/null || lsb_release -ds 2>/dev/null || echo Ubuntu)"
    echo -e "  Système : ${WHITE}${os_pretty}${NC}"
    echo -e "  Date    : ${WHITE}$(date '+%d/%m/%Y %H:%M:%S')${NC}"
    hr_bold
    echo ""
}

# ---------------------------------------------------------------------------
# 1. Vérifications préliminaires
# ---------------------------------------------------------------------------
check_requirements() {
    step "Vérification des prérequis"

    # Root
    if [[ $EUID -ne 0 ]]; then
        error "Ce script doit être exécuté en tant que root."
        echo -e "  Relancez avec : ${BOLD}sudo bash $0${NC}"
        exit 1
    fi
    ok "Droits root confirmés"

    # Connexion Internet
    if ! ping -c 1 -W 3 8.8.8.8 &>/dev/null; then
        error "Aucune connexion Internet détectée. Le script nécessite Internet."
        exit 1
    fi
    ok "Connexion Internet disponible"

    # Ubuntu
    if ! grep -qi ubuntu /etc/os-release 2>/dev/null; then
        warn "Ce script est optimisé pour Ubuntu. Continuer quand même ?"
        confirm "Continuer ?" "n" || exit 0
    fi

    # apt
    if ! command -v apt &>/dev/null; then
        error "apt non trouvé. Ce script requiert un système basé sur Debian/Ubuntu."
        exit 1
    fi
    ok "Gestionnaire de paquets apt disponible"
    echo ""
}

# ---------------------------------------------------------------------------
# 2. Mise à jour du système
# ---------------------------------------------------------------------------
system_update() {
    step "Mise à jour du système"

    confirm "Lancer la mise à jour complète du système (apt update && upgrade) ?" "y" || {
        warn "Mise à jour ignorée."
        return 0
    }

    info "Mise à jour de la liste des paquets..."
    apt update -qq 2>&1 | tail -3
    ok "Liste des paquets mise à jour"

    info "Mise à niveau des paquets installés..."
    (apt upgrade -y -qq 2>&1) &
    spinner $! "Mise à niveau en cours..."
    ok "Paquets mis à niveau"

    info "Nettoyage des paquets obsolètes..."
    apt autoremove -y -qq
    apt autoclean -qq
    ok "Nettoyage terminé"
    echo ""
}

# ---------------------------------------------------------------------------
# 3. Installation d'outils — moteur de recherche et d'installation
# ---------------------------------------------------------------------------

# Recherche un paquet dans apt et retourne les versions disponibles
search_apt_versions() {
    local pkg="$1"
    apt-cache policy "$pkg" 2>/dev/null | grep -E '^\s+[0-9]' | awk '{print $1}' | head -10
}

# Installe via apt (avec version optionnelle)
try_apt_install() {
    local pkg="$1" version="$2"
    local install_target

    if ! apt-cache show "$pkg" &>/dev/null; then
        return 1   # Paquet inconnu de apt
    fi

    if [[ -n "$version" ]]; then
        # Vérifier si la version existe
        if apt-cache show "${pkg}=${version}" &>/dev/null 2>&1; then
            install_target="${pkg}=${version}"
        else
            warn "Version '${version}' introuvable dans apt pour '${pkg}'."
            echo -e "  Versions disponibles :"
            search_apt_versions "$pkg" | while read -r v; do
                echo -e "    ${GRAY}→ $v${NC}"
            done
            confirm "  Installer la dernière version disponible à la place ?" "y" || return 1
            install_target="$pkg"
        fi
    else
        install_target="$pkg"
    fi

    apt install -y "$install_target" -qq 2>&1 | grep -v "^$" || true
    return 0
}

# Installe via snap (avec canal/version optionnel)
try_snap_install() {
    local pkg="$1" version="$2"

    if ! command -v snap &>/dev/null; then
        return 1
    fi

    if ! snap find "$pkg" &>/dev/null 2>&1; then
        return 1
    fi

    if [[ -n "$version" ]]; then
        # Essayer le canal version/stable, puis latest/stable
        snap install "$pkg" --channel="${version}/stable" 2>/dev/null || \
        snap install "$pkg" 2>/dev/null || return 1
    else
        snap install "$pkg" 2>/dev/null || return 1
    fi
    return 0
}

# Installe via flatpak
try_flatpak_install() {
    local pkg="$1"

    if ! command -v flatpak &>/dev/null; then
        return 1
    fi

    flatpak install -y flathub "$pkg" &>/dev/null && return 0 || return 1
}

# Installe via pip / pipx (Python) — compatible PEP 668 (Ubuntu 24.04 / 26.04)
try_pip_install() {
    local pkg="$1" version="$2"
    local target
    [[ -n "$version" ]] && target="${pkg}==${version}" || target="$pkg"

    # En premier : pipx (méthode officielle isolée recommandée sur Ubuntu 24.04 / 26.04)
    if command -v pipx &>/dev/null; then
        pipx install --quiet "$target" &>/dev/null && return 0
    fi

    # En second : pip3 standard, puis fallback --break-system-packages si PEP 668 actif
    if command -v pip3 &>/dev/null; then
        pip3 install --quiet "$target" &>/dev/null && return 0
        pip3 install --quiet --break-system-packages "$target" &>/dev/null && return 0
    fi
    return 1
}

# Installe via npm (Node.js)
try_npm_install() {
    local pkg="$1" version="$2"
    local target
    [[ -n "$version" ]] && target="${pkg}@${version}" || target="$pkg"

    if command -v npm &>/dev/null; then
        npm install -g --silent "$target" &>/dev/null && return 0
    fi
    return 1
}

# Installe via cargo (Rust)
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

# Orchestrateur principal : essaie tous les gestionnaires dans l'ordre
install_tool() {
    local tool="$1" version="${2:-}"
    local installed=false

    echo -e "\n  ${BOLD}${WHITE}→ $tool${NC}${version:+ (version: ${CYAN}$version${NC})}"

    # Ordre de priorité : apt → snap → flatpak → pip → npm → cargo
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

# Demande interactive des outils
install_tools() {
    step "Installation des outils"

    echo -e "  Entrez les outils à installer, ${BOLD}un par un${NC}."
    echo -e "  Vous pouvez indiquer n'importe quel outil : paquet apt, snap, pip, npm, cargo…"
    echo -e "  Tapez ${BOLD}fin${NC} ou laissez vide pour terminer la saisie."
    echo ""

    local tools_list=()

    while true; do
        ask "Nom de l'outil (ou 'fin' pour terminer) : "
        read -r tool_name
        tool_name="${tool_name// /}"   # Supprimer les espaces

        [[ -z "$tool_name" || "$tool_name" == "fin" || "$tool_name" == "done" ]] && break

        # Demander la version
        ask "Version de ${BOLD}$tool_name${NC} ? ${GRAY}(laisser vide = dernière version)${NC} : "
        read -r tool_version

        tools_list+=("${tool_name}::${tool_version}")
        ok "Ajouté : $tool_name${tool_version:+ v$tool_version}"
    done

    if [[ ${#tools_list[@]} -eq 0 ]]; then
        warn "Aucun outil sélectionné."
        return 0
    fi

    echo ""
    echo -e "  ${BOLD}Récapitulatif des outils à installer :${NC}"
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
# 4. Configuration du pare-feu UFW
# ---------------------------------------------------------------------------
configure_ufw() {
    step "Configuration du pare-feu UFW"

    if ! command -v ufw &>/dev/null; then
        info "UFW non installé. Installation..."
        apt install -y ufw -qq
        ok "UFW installé"
    fi

    confirm "Configurer UFW (pare-feu) ?" "y" || { warn "UFW ignoré."; return 0; }

    # Politique par défaut
    echo ""
    echo -e "  ${BOLD}Politique par défaut :${NC}"
    echo -e "   ${CYAN}1${NC}. Bloquer tout le trafic entrant, autoriser tout le trafic sortant ${GRAY}(recommandé)${NC}"
    echo -e "   ${CYAN}2${NC}. Personnaliser les politiques manuellement"
    ask "Choix [1/2, défaut: 1] : "
    read -r ufw_policy
    [[ -z "$ufw_policy" ]] && ufw_policy="1"

    ufw default deny incoming  &>/dev/null
    ufw default allow outgoing &>/dev/null
    ok "Politique par défaut : bloquer entrant, autoriser sortant"

    # Règles de base
    echo ""
    echo -e "  ${BOLD}Règles standard :${NC}"

    # SSH
    if confirm "Autoriser SSH (port 22) ?" "y"; then
        ask "  Port SSH ${GRAY}[défaut: 22]${NC} : "
        read -r ssh_port
        [[ -z "$ssh_port" ]] && ssh_port="22"
        ufw allow "$ssh_port/tcp" &>/dev/null
        UFW_RULES_ADDED+=("SSH ($ssh_port/tcp)")
        ok "SSH autorisé sur le port $ssh_port"
    fi

    confirm "Autoriser HTTP (port 80) ?" "n" && {
        ufw allow 80/tcp &>/dev/null
        UFW_RULES_ADDED+=("HTTP (80/tcp)")
        ok "HTTP autorisé"
    }

    confirm "Autoriser HTTPS (port 443) ?" "n" && {
        ufw allow 443/tcp &>/dev/null
        UFW_RULES_ADDED+=("HTTPS (443/tcp)")
        ok "HTTPS autorisé"
    }

    # Règles personnalisées
    echo ""
    echo -e "  ${BOLD}Règles personnalisées :${NC}"
    echo -e "  Ajoutez des ports/protocoles supplémentaires. Tapez ${BOLD}fin${NC} pour terminer."
    while true; do
        ask "Port/règle (ex: 8080/tcp, 5432, fin) : "
        read -r custom_rule
        [[ -z "$custom_rule" || "$custom_rule" == "fin" ]] && break
        ufw allow "$custom_rule" &>/dev/null && {
            UFW_RULES_ADDED+=("$custom_rule")
            ok "Règle ajoutée : $custom_rule"
        } || warn "Règle invalide : $custom_rule"
    done

    # Activer UFW
    echo ""
    if confirm "Activer UFW maintenant ?" "y"; then
        ufw --force enable &>/dev/null
        ok "UFW activé"
        ufw status verbose
    else
        warn "UFW configuré mais non activé. Activez-le avec : sudo ufw enable"
    fi
    echo ""
}

# ---------------------------------------------------------------------------
# 5. Gestion des services inutiles
# ---------------------------------------------------------------------------

# Liste des services potentiellement inutiles sur Ubuntu (avec description)
declare -A UBUNTU_SERVICES=(
    ["snapd"]="Daemon Snap (gestionnaire de paquets snap)"
    ["avahi-daemon"]="mDNS/Bonjour (découverte réseau locale)"
    ["cups"]="Service d'impression (CUPS)"
    ["cups-browsed"]="Découverte automatique d'imprimantes"
    ["bluetooth"]="Service Bluetooth"
    ["ModemManager"]="Gestion des modems GSM/CDMA"
    ["whoopsie"]="Envoi de rapports de crash Ubuntu"
    ["apport"]="Collecte de rapports d'erreurs"
    ["thermald"]="Démon de gestion thermique"
    ["unattended-upgrades"]="Mises à jour automatiques non supervisées"
    ["rsyslog"]="Service de journalisation système"
    ["postfix"]="Serveur de messagerie (SMTP local)"
    ["speech-dispatcher"]="Synthèse vocale (text-to-speech)"
    ["saned"]="Daemon réseau pour scanners"
    ["wpa_supplicant"]="Gestion Wi-Fi (inutile si câble uniquement)"
    ["NetworkManager-wait-online"]="Attente de connexion réseau au démarrage"
)

# Demande l'action pour un service
ask_service_action() {
    local svc="$1" desc="$2"

    # Vérifier si le service existe
    if ! systemctl list-units --all | grep -q "^.*${svc}"; then
        if ! systemctl list-unit-files | grep -q "^${svc}"; then
            return  # Service non présent sur ce système
        fi
    fi

    local status
    status=$(systemctl is-active "$svc" 2>/dev/null || echo "inactive")
    local enabled
    enabled=$(systemctl is-enabled "$svc" 2>/dev/null || echo "disabled")

    echo ""
    echo -e "  ${BOLD}${WHITE}$svc${NC}"
    echo -e "  ${GRAY}$desc${NC}"
    echo -e "  État actuel : ${status}  |  Au démarrage : ${enabled}"
    echo ""
    echo -e "  Comment gérer ce service ?"
    echo -e "   ${RED}1${NC}. ${BOLD}Désactiver totalement${NC}  (mask) — ne peut plus être démarré même manuellement"
    echo -e "   ${YELLOW}2${NC}. ${BOLD}Désactiver partiellement${NC} (disable) — ne démarre plus au boot, mais démarrable manuellement"
    echo -e "   ${GREEN}3${NC}. ${BOLD}Laisser tel quel${NC} — aucun changement"
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
            info "  $svc conservé tel quel"
            REPORT_SERVICES_SKIPPED+=("$svc")
            ;;
    esac
}

manage_services() {
    step "Gestion des services inutiles"

    echo -e "  Voici une liste de services souvent inutiles sur une installation fraîche."
    echo -e "  Pour chaque service, vous pouvez choisir :"
    echo -e "   ${RED}• Désactivation totale${NC}  (mask)    → impossible à démarrer"
    echo -e "   ${YELLOW}• Désactivation partielle${NC} (disable) → ne démarre plus au boot"
    echo -e "   ${GREEN}• Aucun changement${NC}               → conservé tel quel"
    echo ""

    # Option globale
    echo -e "  ${BOLD}Option globale :${NC}"
    echo -e "   ${CYAN}A${NC}. Gérer les services ${BOLD}un par un${NC} (recommandé)"
    echo -e "   ${CYAN}B${NC}. Désactiver ${BOLD}totalement${NC} tous les services de la liste"
    echo -e "   ${CYAN}C${NC}. Désactiver ${BOLD}partiellement${NC} tous les services de la liste"
    echo -e "   ${CYAN}D${NC}. ${BOLD}Ignorer${NC} la gestion des services"
    ask "Choix [A/B/C/D, défaut: A] : "
    read -r global_choice
    [[ -z "$global_choice" ]] && global_choice="A"

    case "${global_choice^^}" in
        B)
            warn "Désactivation totale (mask) de tous les services de la liste..."
            for svc in "${!UBUNTU_SERVICES[@]}"; do
                if systemctl list-unit-files | grep -q "^${svc}"; then
                    systemctl stop "$svc" 2>/dev/null || true
                    systemctl mask "$svc" 2>/dev/null && {
                        ok "  $svc masqué"
                        REPORT_SERVICES_MASKED+=("$svc")
                    } || true
                fi
            done
            ;;
        C)
            warn "Désactivation partielle (disable) de tous les services de la liste..."
            for svc in "${!UBUNTU_SERVICES[@]}"; do
                if systemctl list-unit-files | grep -q "^${svc}"; then
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
            for svc in "${!UBUNTU_SERVICES[@]}"; do
                ask_service_action "$svc" "${UBUNTU_SERVICES[$svc]}"
            done
            ;;
    esac
    echo ""
}

# ---------------------------------------------------------------------------
# 6. Rapport de synthèse
# ---------------------------------------------------------------------------
print_report() {
    local end_time elapsed
    end_time=$(date +%s)
    elapsed=$((end_time - START_TIME))

    hr_bold
    echo -e "\n  ${BOLD}${WHITE}RAPPORT DE POST-INSTALLATION UBUNTU${NC}"
    echo -e "  Durée totale : ${CYAN}${elapsed}s${NC}  |  $(date '+%d/%m/%Y %H:%M:%S')"
    hr_bold
    echo ""

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

    # Outils en échec
    if [[ ${#REPORT_TOOLS_FAILED[@]} -gt 0 ]]; then
        echo -e "  ${LRED}✘ Outils non installés (${#REPORT_TOOLS_FAILED[@]})${NC}"
        for t in "${REPORT_TOOLS_FAILED[@]}"; do
            echo -e "    ${RED}•${NC} $t"
        done
        echo ""
    fi

    # Règles UFW
    echo -e "  ${CYAN}🔒 Règles UFW ajoutées (${#UFW_RULES_ADDED[@]})${NC}"
    if [[ ${#UFW_RULES_ADDED[@]} -gt 0 ]]; then
        for r in "${UFW_RULES_ADDED[@]}"; do
            echo -e "    ${CYAN}•${NC} $r"
        done
    else
        echo -e "    ${GRAY}Aucune${NC}"
    fi
    echo ""

    # Services masqués (totalement)
    echo -e "  ${RED}🔴 Services masqués / désactivation totale (${#REPORT_SERVICES_MASKED[@]})${NC}"
    if [[ ${#REPORT_SERVICES_MASKED[@]} -gt 0 ]]; then
        for s in "${REPORT_SERVICES_MASKED[@]}"; do
            echo -e "    ${RED}•${NC} $s"
        done
    else
        echo -e "    ${GRAY}Aucun${NC}"
    fi
    echo ""

    # Services désactivés (partiellement)
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
    echo -e "  ${BOLD}${LGREEN}Post-installation Ubuntu terminée avec succès !${NC}"
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
    system_update
    install_tools
    configure_ufw
    manage_services
    print_report
}

main "$@"
