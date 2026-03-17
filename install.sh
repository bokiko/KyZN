#!/usr/bin/env bash
# kyzn installer — curl -fsSL https://raw.githubusercontent.com/bokiko/kyzn/main/install.sh | bash
set -euo pipefail

REPO="bokiko/kyzn"
INSTALL_DIR="${KYZN_INSTALL_DIR:-$HOME/.kyzn-cli}"
BIN_DIR="${KYZN_BIN_DIR:-$HOME/.local/bin}"

echo "Installing kyzn..."

# Clone or update
if [[ -d "$INSTALL_DIR" ]]; then
    echo "Updating existing installation..."
    cd "$INSTALL_DIR" && git pull --quiet
else
    echo "Cloning repository..."
    git clone --quiet "https://github.com/$REPO.git" "$INSTALL_DIR"
fi

# Make executable
chmod +x "$INSTALL_DIR/kyzn"

# Create symlink
mkdir -p "$BIN_DIR"
ln -sf "$INSTALL_DIR/kyzn" "$BIN_DIR/kyzn"

# Check if BIN_DIR is in PATH
if ! echo "$PATH" | tr ':' '\n' | grep -q "^$BIN_DIR$"; then
    echo ""
    echo "Add this to your shell profile (~/.bashrc or ~/.zshrc):"
    echo "  export PATH=\"$BIN_DIR:\$PATH\""
    echo ""
fi

echo "✓ kyzn installed to $BIN_DIR/kyzn"
echo ""
echo "Next steps:"
echo "  kyzn doctor    # check prerequisites"
echo "  kyzn init      # set up a project"
echo "  kyzn improve   # start improving"
