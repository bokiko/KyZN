#!/usr/bin/env bash
# KyZN installer — curl -fsSL https://raw.githubusercontent.com/bokiko/KyZN/main/install.sh | bash
set -euo pipefail

REPO="bokiko/KyZN"
BIN_DIR="${KYZN_BIN_DIR:-$HOME/.local/bin}"

# Detect if running from inside a kyzn repo clone
# If so, use it directly — no second clone needed
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/kyzn" && -d "$SCRIPT_DIR/lib" && -f "$SCRIPT_DIR/lib/core.sh" ]]; then
    INSTALL_DIR="$SCRIPT_DIR"
    FROM_REPO=true
else
    INSTALL_DIR="${KYZN_INSTALL_DIR:-$HOME/.kyzn-cli}"
    FROM_REPO=false
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    DIM='\033[2m'
    RESET='\033[0m'
else
    RED='' GREEN='' YELLOW='' CYAN='' BOLD='' DIM='' RESET=''
fi

ok()   { echo -e "  ${GREEN}✓${RESET} $*"; }
warn() { echo -e "  ${YELLOW}⚠${RESET} $*"; }
err()  { echo -e "  ${RED}✗${RESET} $*"; }
info() { echo -e "  ${DIM}$*${RESET}"; }

has_cmd() { command -v "$1" &>/dev/null; }

detect_os() {
    if [[ -f /etc/os-release ]]; then
        local _id
        _id=$(grep '^ID=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
        echo "${_id:-linux}"
    elif [[ "$(uname)" == "Darwin" ]]; then
        echo "macos"
    else
        echo "linux"
    fi
}

detect_pkg_manager() {
    if has_cmd apt-get; then echo "apt"
    elif has_cmd brew; then echo "brew"
    elif has_cmd dnf; then echo "dnf"
    elif has_cmd yum; then echo "yum"
    elif has_cmd pacman; then echo "pacman"
    elif has_cmd apk; then echo "apk"
    else echo "unknown"
    fi
}

# ---------------------------------------------------------------------------
# Dependency installers
# ---------------------------------------------------------------------------
prompt_sudo() {
    local pkg_name="$1"
    warn "KyZN needs to install: $pkg_name"
    echo -en "  ${BOLD}Allow sudo to install dependencies?${RESET} [Y/n]: "
    local answer
    read -r answer
    answer="${answer:-y}"
    local lower_answer
    lower_answer=$(echo "$answer" | tr '[:upper:]' '[:lower:]')
    if [[ "$lower_answer" == "y" || "$lower_answer" == "yes" ]]; then
        return 0
    else
        info "Skipping. Install manually: sudo apt-get install $pkg_name (or equivalent)"
        return 1
    fi
}

install_jq() {
    local pkg_mgr="$1"
    echo -e "\n${BOLD}Installing jq...${RESET}"
    case "$pkg_mgr" in
        apt)
            prompt_sudo jq || return 0
            sudo apt-get install -y -qq jq
            ;;
        brew)   brew install jq ;;
        dnf)
            prompt_sudo jq || return 0
            sudo dnf install -y -q jq
            ;;
        yum)
            prompt_sudo jq || return 0
            sudo yum install -y -q jq
            ;;
        pacman)
            prompt_sudo jq || return 0
            sudo pacman -S --noconfirm jq
            ;;
        apk)
            prompt_sudo jq || return 0
            sudo apk add -q jq
            ;;
        *)
            # Fallback: download binary (no sudo needed)
            local arch
            arch=$(uname -m)
            case "$arch" in
                x86_64)       arch="amd64" ;;
                aarch64|arm64) arch="arm64" ;;
            esac
            local url="https://github.com/jqlang/jq/releases/latest/download/jq-linux-${arch}"
            if [[ "$(uname)" == "Darwin" ]]; then
                url="https://github.com/jqlang/jq/releases/latest/download/jq-macos-${arch}"
            fi
            mkdir -p "$BIN_DIR"
            if has_cmd curl; then
                curl -fsSL -o "$BIN_DIR/jq" "$url" && chmod +x "$BIN_DIR/jq"
            elif has_cmd wget; then
                wget -qO "$BIN_DIR/jq" "$url" && chmod +x "$BIN_DIR/jq"
            else
                err "Neither curl nor wget found — cannot download jq"
            fi
            ;;
    esac
    has_cmd jq && ok "jq installed" || err "jq install failed"
}

install_yq() {
    echo -e "\n${BOLD}Installing yq...${RESET}"

    # IMPORTANT: snap yq cannot access hidden directories (.kyzn/)
    # Always install as native binary
    if has_cmd yq && [[ "$(which yq)" == */snap/* ]]; then
        warn "Removing snap yq (incompatible with hidden directories)..."
        prompt_sudo "snap remove yq" && sudo snap remove yq 2>/dev/null || true
    fi

    # macOS: use brew if available (avoids bash 3.2 associative array issues)
    if [[ "$(uname)" == "Darwin" ]] && has_cmd brew; then
        brew install yq --quiet 2>/dev/null || brew upgrade yq --quiet 2>/dev/null || true
        has_cmd yq && ok "yq installed (brew)" || err "yq install failed"
        return
    fi

    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)  arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
    esac

    local os="linux"
    [[ "$(uname)" == "Darwin" ]] && os="darwin"

    # Pinned version + SHA256 checksums for supply chain safety
    local YQ_VERSION="v4.52.4"
    # checksums computed from https://github.com/mikefarah/yq/releases/tag/v4.52.4
    local expected_checksum=""
    case "${os}_${arch}" in
        linux_amd64)  expected_checksum="0c4d965ea944b64b8fddaf7f27779ee3034e5693263786506ccd1c120f184e8c" ;;
        linux_arm64)  expected_checksum="4c2cc022a129be5cc1187959bb4b09bebc7fb543c5837b93001c68f97ce39a5d" ;;
        darwin_amd64) expected_checksum="d72a75fe9953c707d395f653d90095b133675ddd61aa738e1ac9a73c6c05e8be" ;;
        darwin_arm64) expected_checksum="6bfa43a439936644d63c70308832390c8838290d064970eaada216219c218a13" ;;
    esac

    local platform_key="${os}_${arch}"

    mkdir -p "$BIN_DIR"
    local tmp
    tmp=$(mktemp)

    # Use curl on macOS, wget on Linux
    if has_cmd curl; then
        curl -fsSL -o "$tmp" "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_${platform_key}" || {
            err "Failed to download yq"
            rm -f "$tmp"
            return 1
        }
    elif has_cmd wget; then
        wget -qO "$tmp" "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_${platform_key}" || {
            err "Failed to download yq"
            rm -f "$tmp"
            return 1
        }
    else
        err "Neither curl nor wget found — cannot download yq"
        rm -f "$tmp"
        return 1
    fi

    # Verify checksum if available for this platform
    if [[ -n "$expected_checksum" ]]; then
        local actual_checksum
        if has_cmd sha256sum; then
            actual_checksum=$(sha256sum "$tmp" | awk '{print $1}')
        elif has_cmd shasum; then
            actual_checksum=$(shasum -a 256 "$tmp" | awk '{print $1}')
        else
            warn "No sha256 tool found — skipping checksum verification"
            actual_checksum=""
        fi
        if [[ -n "$actual_checksum" && "$actual_checksum" != "$expected_checksum" ]]; then
            err "yq checksum verification failed!"
            err "  Expected: $expected_checksum"
            err "  Got:      $actual_checksum"
            rm -f "$tmp"
            return 1
        fi
        [[ -n "$actual_checksum" ]] && ok "yq checksum verified"
    else
        warn "No checksum available for $platform_key — skipping verification"
    fi

    mv "$tmp" "$BIN_DIR/yq" && chmod +x "$BIN_DIR/yq"

    has_cmd yq && ok "yq installed (native binary, $YQ_VERSION)" || err "yq install failed"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${BOLD}  KyZN installer${RESET}"
echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""

OS=$(detect_os)
PKG=$(detect_pkg_manager)
info "Detected: $OS ($PKG)"
echo ""

# ---------------------------------------------------------------------------
# Step 1: Check required tools that need user setup
# ---------------------------------------------------------------------------
echo -e "${BOLD}Step 1: Checking prerequisites${RESET}"
echo ""

BLOCKERS=0

# git
if has_cmd git; then
    ok "git $(git --version | awk '{print $3}')"
else
    err "git — not found"
    case "$PKG" in
        apt)    info "Install: sudo apt install git" ;;
        brew)   info "Install: brew install git" ;;
        dnf)    info "Install: sudo dnf install git" ;;
        *)      info "Install: https://git-scm.com/downloads" ;;
    esac
    BLOCKERS=$((BLOCKERS + 1))
fi

# gh (GitHub CLI)
if has_cmd gh; then
    ok "gh $(gh --version | head -1 | awk '{print $3}')"
    if gh auth status &>/dev/null; then
        ok "gh authenticated"
    else
        warn "gh not authenticated — run: gh auth login"
    fi
else
    err "gh (GitHub CLI) — not found"
    case "$PKG" in
        apt)
            info "Install:"
            info "  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg"
            info "  echo \"deb [signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main\" | sudo tee /etc/apt/sources.list.d/github-cli.list"
            info "  sudo apt update && sudo apt install gh"
            ;;
        brew) info "Install: brew install gh" ;;
        *)    info "Install: https://cli.github.com" ;;
    esac
    BLOCKERS=$((BLOCKERS + 1))
fi

# claude CLI
if has_cmd claude; then
    ok "claude $(claude --version 2>/dev/null || echo '(version unknown)')"
else
    err "claude CLI — not found"
    info "Install: npm install -g @anthropic-ai/claude-code"
    info "  Then set ANTHROPIC_API_KEY in your shell profile"
    BLOCKERS=$((BLOCKERS + 1))
fi

# ANTHROPIC_API_KEY
if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    ok "ANTHROPIC_API_KEY is set"
else
    if has_cmd claude; then
        warn "ANTHROPIC_API_KEY not set (claude CLI may use its own auth)"
        info "If you get auth errors, add to ~/.bashrc or ~/.zshrc:"
        info "  export ANTHROPIC_API_KEY=\"sk-ant-...\""
    else
        warn "ANTHROPIC_API_KEY not set"
    fi
fi

echo ""

if (( BLOCKERS > 0 )); then
    err "${BLOCKERS} required tool(s) missing. Install them and re-run the installer."
    echo ""
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 2: Auto-install utility dependencies (jq, yq)
# ---------------------------------------------------------------------------
echo -e "${BOLD}Step 2: Installing dependencies${RESET}"
echo ""

# jq
if has_cmd jq; then
    ok "jq $(jq --version 2>/dev/null || echo '')"
else
    install_jq "$PKG"
fi

# yq — always prefer native binary over snap
if has_cmd yq; then
    if [[ "$(which yq)" == */snap/* ]]; then
        warn "snap yq detected — replacing with native binary"
        info "(snap yq cannot access hidden directories like .kyzn/)"
        install_yq
    else
        ok "yq $(yq --version 2>/dev/null | awk '{print $NF}')"
    fi
else
    install_yq
fi

echo ""

# ---------------------------------------------------------------------------
# Step 3: Install kyzn
# ---------------------------------------------------------------------------
echo -e "${BOLD}Step 3: Installing KyZN${RESET}"
echo ""

if $FROM_REPO; then
    # Running from inside a kyzn clone — use it directly
    ok "Using local repo: $INSTALL_DIR"
    info "Updates: just run ${CYAN}git pull${RESET} in this directory"

    # Clean up stale ~/.kyzn-cli clone if it exists and we're not in it
    if [[ -d "$HOME/.kyzn-cli/.git" && "$INSTALL_DIR" != "$HOME/.kyzn-cli" ]] \
       && [[ -f "$HOME/.kyzn-cli/kyzn" && -f "$HOME/.kyzn-cli/lib/core.sh" ]]; then
        info "Removing old clone at ~/.kyzn-cli (no longer needed)"
        rm -rf "$HOME/.kyzn-cli"
    fi
else
    # Remote install (curl | bash) — clone to ~/.kyzn-cli
    if [[ -d "$INSTALL_DIR/.git" ]]; then
        info "Updating existing installation..."
        git -C "$INSTALL_DIR" pull --quiet
        ok "Updated $INSTALL_DIR"
    elif [[ -d "$INSTALL_DIR" ]]; then
        # Directory exists but isn't a git repo — replace it
        warn "Replacing non-git installation at $INSTALL_DIR"
        rm -rf "$INSTALL_DIR"
        git clone --quiet "https://github.com/$REPO.git" "$INSTALL_DIR"
        ok "Cloned to $INSTALL_DIR"
    else
        info "Cloning repository..."
        git clone --quiet "https://github.com/$REPO.git" "$INSTALL_DIR"
        ok "Cloned to $INSTALL_DIR"
    fi
fi

# Make executable
chmod +x "$INSTALL_DIR/kyzn"

# Create symlink
mkdir -p "$BIN_DIR"
ln -sf "$INSTALL_DIR/kyzn" "$BIN_DIR/kyzn"
ok "Symlinked $BIN_DIR/kyzn → $INSTALL_DIR/kyzn"

# Check if BIN_DIR is in PATH
if ! echo "$PATH" | tr ':' '\n' | grep -q "^$BIN_DIR$"; then
    echo ""
    warn "$BIN_DIR is not in your PATH"
    info "Add this to your shell profile (~/.bashrc or ~/.zshrc):"
    echo -e "    ${CYAN}export PATH=\"$BIN_DIR:\$PATH\"${RESET}"
fi

# ---------------------------------------------------------------------------
# Step 4: Verify installation
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}Step 4: Verifying installation${RESET}"
echo ""

if has_cmd kyzn || [[ -x "$BIN_DIR/kyzn" ]]; then
    local_ver=$("$BIN_DIR/kyzn" version 2>/dev/null || echo "unknown")
    ok "KyZN installed ($local_ver)"
else
    err "KyZN not found in PATH after install"
    exit 1
fi

# Quick sanity: can kyzn load its libraries?
if "$BIN_DIR/kyzn" version &>/dev/null; then
    ok "Library loading OK (symlink resolution works)"
else
    err "KyZN cannot load its libraries — symlink may be broken"
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${GREEN}${BOLD}  KyZN installed successfully!${RESET}"
echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
echo -e "  ${BOLD}Typical workflow:${RESET}"
echo -e "    ${CYAN}kyzn init${RESET}  →  ${CYAN}kyzn measure${RESET}  →  ${CYAN}kyzn fix${RESET}  →  ${CYAN}kyzn approve${RESET}"
echo ""
echo -e "  ${BOLD}Commands:${RESET}"
echo -e "    ${CYAN}kyzn init${RESET}        Set up a project"
echo -e "    ${CYAN}kyzn measure${RESET}     Check project health"
echo -e "    ${CYAN}kyzn fix${RESET}         Deep analysis + auto-fix → PR"
echo -e "    ${CYAN}kyzn analyze${RESET}     Analysis report only (no changes)"
echo -e "    ${CYAN}kyzn quick${RESET}       Quick single-pass improvement"
echo -e "    ${CYAN}kyzn status${RESET}      Health score dashboard"
echo -e "    ${CYAN}kyzn approve${RESET}     Sign off on a completed run"
echo -e "    ${CYAN}kyzn schedule${RESET}    Set up recurring runs (cron)"
echo -e "    ${CYAN}kyzn history${RESET}     View past runs"
echo -e "    ${CYAN}kyzn doctor${RESET}      Verify environment"
echo -e "    ${CYAN}kyzn selftest${RESET}    Run test suite"
echo ""
echo -e "  ${BOLD}Update:${RESET}"
echo -e "    ${CYAN}cd $INSTALL_DIR && git pull${RESET}"
echo ""
