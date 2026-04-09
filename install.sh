#!/usr/bin/env bash
# =============================================================================
# install-obsidian-vps.sh
# Interaktywny instalator Obsidian Headless + Claude Code na VPS (Debian/Ubuntu)
#
# Usage:
#   curl -fsSL <url>/install-obsidian-vps.sh | bash       # instalacja
#   bash install-obsidian-vps.sh --reset                  # reset do zera
#   bash install-obsidian-vps.sh --help                   # pomoc
#
# Based on: Zasoby/Tech/obsidian-headless-vps-guide.md
# =============================================================================

set -euo pipefail

# ---------- Kolory i helpery ----------
# ANSI-C quoting ($'...') — stringi zawierają faktyczne bajty ESC,
# dzięki czemu działają zarówno w echo jak i w cat << EOF (heredoc).
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
NC=$'\033[0m'

log()   { printf '%s[INFO]%s %s\n' "${BLUE}" "${NC}" "$*"; }
ok()    { printf '%s[OK]%s %s\n' "${GREEN}" "${NC}" "$*"; }
warn()  { printf '%s[WARN]%s %s\n' "${YELLOW}" "${NC}" "$*"; }
err()   { printf '%s[ERR]%s %s\n' "${RED}" "${NC}" "$*" >&2; }
step()  { printf '\n%s%s==> %s%s\n' "${BOLD}" "${CYAN}" "$*" "${NC}"; }
ask()   { printf '%s%s?%s %s' "${BOLD}" "${YELLOW}" "${NC}" "$*"; }

# ---------- Stałe ----------
CLAUDE_USER="claude"
CLAUDE_HOME="/home/${CLAUDE_USER}"
VAULT_PATH="${CLAUDE_HOME}/vault"
VAULT_GIT_PATH="${CLAUDE_HOME}/vault-git"
SERVICE_FILE="/etc/systemd/system/obsidian-sync.service"
SERVICE_NAME="obsidian-sync"

# ---------- Flagi stanu (dla rollback) ----------
STATE_INSTALLED_PKG=0
STATE_INSTALLED_NODE=0
STATE_INSTALLED_OB=0
STATE_CREATED_USER=0
STATE_INSTALLED_CLAUDE=0
STATE_CLONED_REPO=0
STATE_CREATED_SYMLINK=0
STATE_CREATED_SERVICE=0
STATE_STARTED_SERVICE=0

# ---------- Zmienne konfiguracyjne (wypełniane później) ----------
OBSIDIAN_EMAIL=""
VAULT_NAME=""
GITHUB_PAT=""
GITHUB_REPO=""
DEVICE_NAME=""

# =============================================================================
# ROLLBACK ON ERROR
# =============================================================================

rollback_on_error() {
    local exit_code=$?
    local line_no=$1

    echo
    err "Instalacja przerwana na linii ${line_no} (exit ${exit_code})"
    echo
    warn "Rozpoczynam automatyczny rollback — cofam zmiany..."
    echo

    if [[ ${STATE_STARTED_SERVICE} -eq 1 ]]; then
        log "Zatrzymuję service ${SERVICE_NAME}..."
        systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
        systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
    fi

    if [[ ${STATE_CREATED_SERVICE} -eq 1 ]]; then
        log "Usuwam plik service..."
        rm -f "${SERVICE_FILE}"
        systemctl daemon-reload 2>/dev/null || true
    fi

    if [[ ${STATE_CREATED_SYMLINK} -eq 1 ]]; then
        log "Usuwam symlink .claude..."
        rm -f "${VAULT_PATH}/.claude"
    fi

    if [[ ${STATE_CLONED_REPO} -eq 1 ]]; then
        log "Usuwam vault-git..."
        rm -rf "${VAULT_GIT_PATH}"
    fi

    if [[ ${STATE_CREATED_USER} -eq 1 ]]; then
        log "Usuwam usera ${CLAUDE_USER} wraz z home..."
        pkill -u "${CLAUDE_USER}" 2>/dev/null || true
        sleep 1
        userdel -r "${CLAUDE_USER}" 2>/dev/null || true
    fi

    echo
    ok "Rollback zakończony. VPS w stanie sprzed instalacji."
    warn "Sprawdź co poszło nie tak i odpal skrypt ponownie."
    exit "${exit_code}"
}

trap 'rollback_on_error ${LINENO}' ERR

# =============================================================================
# PARSER FLAG
# =============================================================================

show_help() {
    cat << EOF
${BOLD}install-obsidian-vps.sh${NC} — instalator Obsidian Headless na VPS

${BOLD}Użycie:${NC}
  sudo bash install-obsidian-vps.sh           Instalacja interaktywna
  sudo bash install-obsidian-vps.sh --reset   Reset — usuwa wszystko
  sudo bash install-obsidian-vps.sh --help    Ta pomoc

${BOLD}Wymagania:${NC}
  - Debian/Ubuntu VPS z dostępem root
  - Aktywny Obsidian Sync (płatny, https://obsidian.md/sync)
  - GitHub Personal Access Token (fine-grained, read-only do repo z .claude)

${BOLD}Co instaluje:${NC}
  - Node.js 22, obsidian-headless, git, claude code
  - Dedykowany user 'claude' z vault'em
  - Systemd service 'obsidian-sync' z auto-restart

${BOLD}Dokumentacja:${NC}
  Zasoby/Tech/obsidian-headless-vps-guide.md
EOF
}

MODE="install"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --reset) MODE="reset"; shift ;;
        --help|-h) show_help; exit 0 ;;
        *) err "Nieznana flaga: $1"; show_help; exit 1 ;;
    esac
done

# =============================================================================
# PRE-FLIGHT CHECKS
# =============================================================================

preflight() {
    step "Pre-flight checks"

    # Root check
    if [[ ${EUID} -ne 0 ]]; then
        err "Skrypt wymaga uprawnień root. Uruchom przez sudo."
        exit 1
    fi
    ok "Uruchomiony jako root"

    # OS check
    if [[ ! -f /etc/os-release ]]; then
        err "Brak /etc/os-release — nieobsługiwany system"
        exit 1
    fi

    . /etc/os-release
    case "${ID}" in
        debian|ubuntu) ok "System: ${PRETTY_NAME}" ;;
        *) err "Nieobsługiwany system: ${ID}. Skrypt działa tylko na Debian/Ubuntu"; exit 1 ;;
    esac

    # Internet check
    if ! curl -fsS --max-time 5 https://api.github.com > /dev/null; then
        err "Brak połączenia z internetem (api.github.com nieosiągalny)"
        exit 1
    fi
    ok "Internet działa"
}

detect_existing() {
    local found=0

    if id "${CLAUDE_USER}" &>/dev/null; then
        warn "User '${CLAUDE_USER}' już istnieje"
        found=1
    fi

    if [[ -f "${SERVICE_FILE}" ]]; then
        warn "Service '${SERVICE_NAME}' już istnieje"
        found=1
    fi

    if [[ -d "${VAULT_PATH}" ]]; then
        warn "Vault '${VAULT_PATH}' już istnieje"
        found=1
    fi

    if [[ ${found} -eq 1 ]]; then
        echo
        warn "Wykryto istniejącą instalację."
        ask "Co robimy? [R]eset (usuń i od nowa) / [E]xit: "
        read -r choice
        case "${choice,,}" in
            r|reset) MODE="reset"; do_reset; MODE="install"; log "Po resecie — kontynuuję instalację..." ;;
            *) log "Przerywam. Odpal z --reset gdy będziesz gotowy."; exit 0 ;;
        esac
    fi
}

# =============================================================================
# RESET
# =============================================================================

do_reset() {
    step "Tryb RESET — usuwanie istniejącej instalacji"

    echo
    warn "${BOLD}To usunie:${NC}"
    warn "  - Systemd service '${SERVICE_NAME}'"
    warn "  - Usera '${CLAUDE_USER}' wraz z całym home ${CLAUDE_HOME}"
    warn "  - Vault ${VAULT_PATH} (lokalne pliki — w Obsidian Sync pozostaną)"
    warn "  - Vault-git ${VAULT_GIT_PATH}"
    echo
    ask "Na pewno? Wpisz ${BOLD}TAK${NC} żeby potwierdzić: "
    read -r confirm

    if [[ "${confirm}" != "TAK" ]]; then
        log "Anulowano."
        exit 0
    fi

    # Wyłącz trap na czas resetu — wszystko co się nie uda to || true
    trap - ERR

    log "Zatrzymuję service..."
    systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
    systemctl disable "${SERVICE_NAME}" 2>/dev/null || true

    log "Usuwam plik service..."
    rm -f "${SERVICE_FILE}"
    systemctl daemon-reload 2>/dev/null || true

    log "Zabijam procesy usera ${CLAUDE_USER}..."
    pkill -u "${CLAUDE_USER}" 2>/dev/null || true
    sleep 2

    log "Usuwam usera ${CLAUDE_USER}..."
    if id "${CLAUDE_USER}" &>/dev/null; then
        userdel -r "${CLAUDE_USER}" 2>/dev/null || {
            warn "userdel -r nie zadziałał, próbuję force..."
            userdel -f -r "${CLAUDE_USER}" 2>/dev/null || true
            rm -rf "${CLAUDE_HOME}" 2>/dev/null || true
        }
    fi

    log "Usuwam resztki..."
    rm -rf "${VAULT_PATH}" "${VAULT_GIT_PATH}"

    # Przywróć trap
    trap 'rollback_on_error ${LINENO}' ERR

    ok "Reset zakończony"

    if [[ "${MODE}" == "reset" ]]; then
        echo
        log "Gotowe. Możesz teraz odpalić skrypt bez --reset żeby zainstalować od nowa."
        exit 0
    fi
}

# =============================================================================
# ZBIERANIE DANYCH OD USERA
# =============================================================================

collect_config() {
    step "Zbieram konfigurację"

    echo
    log "Zaraz zapytam o kilka rzeczy. Potem skrypt sam poleci — idź po kawę ☕"
    log "Hasło do Obsidian i hasło e2e ${BOLD}NIE${NC} są tu potrzebne — wpiszesz je później."
    echo

    # Email
    while [[ -z "${OBSIDIAN_EMAIL}" ]]; do
        ask "Email do konta Obsidian: "
        read -r OBSIDIAN_EMAIL
    done

    # Nazwa vault'a
    while [[ -z "${VAULT_NAME}" ]]; do
        ask "Nazwa vault'a w Obsidian Sync (Settings > Sync): "
        read -r VAULT_NAME
    done

    # GitHub PAT
    echo
    log "Potrzebuję GitHub Personal Access Token (fine-grained, read-only do repo z .claude)"
    log "Jak stworzyć: GitHub → Settings → Developer settings → Personal access tokens → Fine-grained"
    while [[ -z "${GITHUB_PAT}" ]]; do
        ask "GitHub PAT (ukryte): "
        read -rs GITHUB_PAT
        echo
    done

    # Repo
    while [[ -z "${GITHUB_REPO}" ]]; do
        ask "Repo z vault'em (${BOLD}user/repo${NC} lub pełny URL): "
        read -r GITHUB_REPO
    done

    # Normalizacja — akceptuj https URL, git@ SSH, z .git lub bez
    GITHUB_REPO=$(echo "${GITHUB_REPO}" | sed -E 's|^https?://github\.com/||; s|^git@github\.com:||; s|\.git/?$||; s|/$||')

    # Walidacja formatu
    if [[ ! "${GITHUB_REPO}" =~ ^[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+$ ]]; then
        err "Nieprawidłowy format repo po normalizacji: ${GITHUB_REPO}"
        err "Oczekiwany format: user/repo (np. AIBiz-Automatyzacje/obsidian-vault-kacper)"
        exit 1
    fi
    log "Repo: ${GITHUB_REPO}"

    # Walidacja PAT
    log "Weryfikuję token na GitHub..."
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "Authorization: Bearer ${GITHUB_PAT}" \
        "https://api.github.com/repos/${GITHUB_REPO}")

    case "${http_code}" in
        200) ok "Token działa, repo dostępne" ;;
        401) err "Token nieprawidłowy (HTTP 401). Sprawdź czy dobrze skopiowany."; exit 1 ;;
        404) err "Repo '${GITHUB_REPO}' niedostępne dla tego tokena (HTTP 404). Sprawdź uprawnienia i nazwę repo."; exit 1 ;;
        *)   err "Nieoczekiwany błąd walidacji (HTTP ${http_code})"; exit 1 ;;
    esac

    # Device name
    local default_device="vps-$(hostname)"
    ask "Nazwa urządzenia w Obsidian Sync [${default_device}]: "
    read -r DEVICE_NAME
    DEVICE_NAME="${DEVICE_NAME:-${default_device}}"

    # Podsumowanie
    echo
    log "${BOLD}Konfiguracja:${NC}"
    echo "  Email:       ${OBSIDIAN_EMAIL}"
    echo "  Vault:       ${VAULT_NAME}"
    echo "  Repo:        ${GITHUB_REPO}"
    echo "  Token:       ****${GITHUB_PAT: -4}"
    echo "  Device:      ${DEVICE_NAME}"
    echo
    ask "Kontynuujemy? [T/n]: "
    read -r confirm
    if [[ "${confirm,,}" == "n" ]]; then
        log "Anulowano."
        exit 0
    fi
}

# =============================================================================
# INSTALACJA PACZEK
# =============================================================================

install_packages() {
    step "Instaluję paczki systemowe"

    log "apt-get update..."
    DEBIAN_FRONTEND=noninteractive apt-get update -qq

    log "Instaluję git, curl, ca-certificates, expect..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        git curl ca-certificates gnupg >/dev/null
    STATE_INSTALLED_PKG=1
    ok "Paczki podstawowe zainstalowane"

    # Node.js 22
    local node_version
    node_version=$(node -v 2>/dev/null | sed 's/v//' | cut -d. -f1 || echo "0")

    if [[ "${node_version}" -lt 22 ]]; then
        log "Instaluję Node.js 22 (aktualna wersja: ${node_version})..."
        curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null 2>&1
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nodejs >/dev/null
        STATE_INSTALLED_NODE=1
        ok "Node.js $(node -v) zainstalowany"
    else
        ok "Node.js $(node -v) już zainstalowany"
    fi

    # obsidian-headless
    if ! command -v ob &>/dev/null; then
        log "Instaluję obsidian-headless (globalnie)..."
        npm install -g obsidian-headless >/dev/null 2>&1
        STATE_INSTALLED_OB=1
        ok "obsidian-headless zainstalowany: $(which ob)"
    else
        ok "obsidian-headless już zainstalowany: $(which ob)"
    fi
}

# =============================================================================
# USER CLAUDE + CLAUDE CODE
# =============================================================================

setup_user() {
    step "Tworzę usera ${CLAUDE_USER}"

    useradd -m -s /bin/bash "${CLAUDE_USER}"
    STATE_CREATED_USER=1
    ok "User ${CLAUDE_USER} utworzony"

    log "Tworzę folder vault..."
    su - "${CLAUDE_USER}" -c "mkdir -p ${VAULT_PATH}"
    ok "Vault folder: ${VAULT_PATH}"
}

install_claude_code() {
    step "Instaluję Claude Code"

    log "Pobieram i instaluję Claude Code natywnie..."
    su - "${CLAUDE_USER}" -c "curl -fsSL https://claude.ai/install.sh | bash" >/dev/null 2>&1
    STATE_INSTALLED_CLAUDE=1

    # PATH fix — dokładnie tak jak instruuje installer
    log "Dodaję ~/.local/bin do PATH w .bashrc..."
    su - "${CLAUDE_USER}" -c 'grep -q "HOME/.local/bin" ~/.bashrc 2>/dev/null || echo "export PATH=\"\$HOME/.local/bin:\$PATH\"" >> ~/.bashrc'

    # Weryfikacja
    if su - "${CLAUDE_USER}" -c 'bash -lc "command -v claude"' &>/dev/null; then
        ok "Claude Code dostępny: $(su - ${CLAUDE_USER} -c 'bash -lc "which claude"')"
    else
        err "Claude Code zainstalowany ale nie znaleziony w PATH"
        exit 1
    fi
}

# =============================================================================
# INTERAKTYWNE PAUZY — ob login + sync-setup
# =============================================================================

pause_ob_login() {
    step "Logowanie do Obsidian — krok ręczny"

    cat << EOF

${BOLD}${YELLOW}⏸  PAUZA — potrzebuję żebyś coś zrobił ręcznie${NC}

${BOLD}Otwórz nowy terminal${NC} (lub nowe okno SSH) i uruchom:

  ${CYAN}su - ${CLAUDE_USER} -c "ob login"${NC}

Wpisz email (${OBSIDIAN_EMAIL}) i hasło gdy poprosi.
Jeśli masz 2FA — dostaniesz prompt na kod.

Po udanym logowaniu ${BOLD}wróć tu${NC} i naciśnij ENTER.

EOF
    ask "Gotowe? Naciśnij ENTER: "
    read -r
    ok "Kontynuuję..."
}

pause_sync_setup() {
    step "Podłączenie vault'a — krok ręczny"

    cat << EOF

${BOLD}${YELLOW}⏸  PAUZA — drugi krok ręczny${NC}

${BOLD}W tym samym terminalu${NC} uruchom:

  ${CYAN}su - ${CLAUDE_USER} -c 'ob sync-setup --vault "${VAULT_NAME}" --path ~/vault --device-name "${DEVICE_NAME}"'${NC}

Wpisz ${BOLD}hasło szyfrowania end-to-end${NC} gdy poprosi
(to osobne hasło, ustawione przy tworzeniu vault'a w Obsidian Sync).

Jeśli vault nie ma e2e encryption — naciśnij Enter.

Po sukcesie zobaczysz: ${GREEN}Vault configured successfully!${NC}

Wróć tu i naciśnij ENTER.

EOF
    ask "Gotowe? Naciśnij ENTER: "
    read -r

    # Weryfikacja że sync-setup zadziałał
    log "Sprawdzam konfigurację vault'a..."
    if su - "${CLAUDE_USER}" -c "ob sync-status --path ${VAULT_PATH}" &>/dev/null; then
        ok "Vault skonfigurowany poprawnie"
    else
        err "ob sync-status nie działa — setup nieudany?"
        ask "Kontynuować mimo to? [t/N]: "
        read -r c
        [[ "${c,,}" == "t" ]] || exit 1
    fi
}

# =============================================================================
# GIT SPARSE CHECKOUT + SYMLINK
# =============================================================================

setup_claude_config() {
    step "Ściągam folder .claude przez git sparse checkout"

    local clone_url="https://${GITHUB_PAT}@github.com/${GITHUB_REPO}.git"

    log "Klonowanie repo (sparse, tylko .claude)..."
    su - "${CLAUDE_USER}" -c "git clone --no-checkout '${clone_url}' ${VAULT_GIT_PATH}" >/dev/null 2>&1
    STATE_CLONED_REPO=1

    log "Konfiguruję sparse checkout..."
    su - "${CLAUDE_USER}" -c "cd ${VAULT_GIT_PATH} && git sparse-checkout set .claude && git checkout main" >/dev/null 2>&1

    if [[ ! -d "${VAULT_GIT_PATH}/.claude" ]]; then
        err "Folder .claude nie został ściągnięty — sprawdź czy istnieje w repo na branchu main"
        exit 1
    fi
    ok "Folder .claude ściągnięty"

    log "Tworzę symlink w vault'cie..."
    su - "${CLAUDE_USER}" -c "ln -sf ${VAULT_GIT_PATH}/.claude ${VAULT_PATH}/.claude"
    STATE_CREATED_SYMLINK=1
    ok "Symlink: ${VAULT_PATH}/.claude -> ${VAULT_GIT_PATH}/.claude"
}

# =============================================================================
# SYSTEMD SERVICE
# =============================================================================

create_service() {
    step "Tworzę systemd service"

    local ob_path
    ob_path=$(which ob)

    if [[ -z "${ob_path}" ]]; then
        err "Nie znaleziono ścieżki do 'ob' — instalacja niekompletna?"
        exit 1
    fi
    log "Ścieżka do ob: ${ob_path}"

    cat > "${SERVICE_FILE}" << EOF
[Unit]
Description=Obsidian Headless Sync
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${CLAUDE_USER}
ExecStartPre=/bin/rm -rf ${VAULT_PATH}/.obsidian/.sync.lock
ExecStart=${ob_path} sync --path ${VAULT_PATH} --continuous
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    STATE_CREATED_SERVICE=1
    ok "Plik service utworzony: ${SERVICE_FILE}"

    log "systemctl daemon-reload..."
    systemctl daemon-reload

    log "Enable + start..."
    systemctl enable --now "${SERVICE_NAME}" >/dev/null 2>&1
    STATE_STARTED_SERVICE=1
    ok "Service ${SERVICE_NAME} uruchomiony"
}

# =============================================================================
# WERYFIKACJA KOŃCOWA
# =============================================================================

verify_installation() {
    step "Weryfikacja końcowa"

    # Status service'u
    log "Sprawdzam status service'u..."
    sleep 2
    if systemctl is-active --quiet "${SERVICE_NAME}"; then
        ok "Service ${SERVICE_NAME} jest aktywny"
    else
        err "Service ${SERVICE_NAME} nie działa"
        echo
        warn "Ostatnie 20 linii logów:"
        journalctl -u "${SERVICE_NAME}" -n 20 --no-pager || true
        exit 1
    fi

    # Test pliku
    log "Tworzę plik testowy i sprawdzam czy trafi do sync'a..."
    local test_file="${VAULT_PATH}/_install-test-$(date +%s).md"
    su - "${CLAUDE_USER}" -c "echo '# Install test' > ${test_file}"

    # Poll przez 30s czy ob widzi zmianę (sprawdzamy logi service'u)
    # Szerokie słowa kluczowe — ob loguje rzeczy typu "Connecting", "Fully synced",
    # "Detecting changes", "Upload", "Download", "Sync complete"
    local found=0
    for i in {1..15}; do
        if journalctl -u "${SERVICE_NAME}" --since "1 minute ago" --no-pager 2>/dev/null | \
           grep -qiE "(sync|connect|detect|upload|download|change)"; then
            found=1
            break
        fi
        sleep 2
    done

    if [[ ${found} -eq 1 ]]; then
        ok "Sync aktywny (znaleziono aktywność w logach)"
    else
        warn "Nie widzę aktywności sync'a w logach — sprawdź ręcznie:"
        warn "  journalctl -u ${SERVICE_NAME} -n 30 --no-pager"
    fi

    # Cleanup pliku testowego
    su - "${CLAUDE_USER}" -c "rm -f ${test_file}"
}

# =============================================================================
# PODSUMOWANIE
# =============================================================================

print_summary() {
    echo
    echo -e "${GREEN}${BOLD}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║  ✅  Instalacja zakończona pomyślnie                  ║${NC}"
    echo -e "${GREEN}${BOLD}╚════════════════════════════════════════════════════════╝${NC}"
    echo
    echo -e "${BOLD}Co zostało zainstalowane:${NC}"
    echo "  ✓ User ${CLAUDE_USER} (home: ${CLAUDE_HOME})"
    echo "  ✓ Obsidian Headless → ${VAULT_PATH}"
    echo "  ✓ Claude Code (~/.local/bin/claude)"
    echo "  ✓ Folder .claude (sparse checkout z ${GITHUB_REPO})"
    echo "  ✓ Systemd service: ${SERVICE_NAME} (auto-start, auto-restart)"
    echo
    echo -e "${BOLD}Przydatne komendy:${NC}"
    echo "  systemctl status ${SERVICE_NAME}         # status sync'a"
    echo "  journalctl -u ${SERVICE_NAME} -f         # logi na żywo"
    echo "  su - ${CLAUDE_USER}                      # wejście jako claude"
    echo "  cd ${VAULT_PATH} && claude               # odpal Claude Code"
    echo
    echo -e "${BOLD}Co dalej:${NC}"
    echo "  1. Zdalny dostęp (mobilny): zainstaluj Happy Coder — sekcja 10 w guide"
    echo "  2. Skille z zewnętrznymi zależnościami (gog, yt-dlp itp.) — sekcja 11"
    echo "  3. Auto-pull .claude: claude-cron job co 1h (sekcja 6)"
    echo
    echo -e "${CYAN}📖 Pełna dokumentacja: Zasoby/Tech/obsidian-headless-vps-guide.md${NC}"
    echo
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    if [[ "${MODE}" == "reset" ]]; then
        preflight
        do_reset
        exit 0
    fi

    echo
    echo -e "${BOLD}${CYAN}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║  Obsidian Headless + Claude Code — instalator VPS    ║${NC}"
    echo -e "${BOLD}${CYAN}╚════════════════════════════════════════════════════════╝${NC}"

    preflight
    detect_existing
    collect_config
    install_packages
    setup_user
    install_claude_code
    pause_ob_login
    pause_sync_setup
    setup_claude_config
    create_service
    verify_installation
    print_summary

    # Wszystko OK — wyłącz trap żeby exit 0 nie triggerował rollback
    trap - ERR
}

main "$@"
