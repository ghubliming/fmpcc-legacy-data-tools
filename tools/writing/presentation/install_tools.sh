#!/usr/bin/env bash
# Install the deck toolchain into this container (idempotent; re-run after a container rebuild).
#   Quarto   -> ~/.local/opt/quarto-<ver>, linked as ~/.local/bin/quarto   (user-local, no root, not in git)
#   Chromium -> apt (sudo), used by decktape for the PDF backup and slide screenshots
#   fonts    -> fonts-liberation (metric clone of Arial/Helvetica, so local renders match the room laptop)
#   decktape -> npm global (reveal.js -> PDF); told to use the apt Chromium, no bundled browser download
#   MathJax  -> tools/node_modules (pinned in tools/package.json); renders maths to SVG at build time
# Versions are pinned so a rebuild renders the same deck; bump them on purpose and note it in CHANGELOG.md.
set -euo pipefail
QUARTO_VERSION="${QUARTO_VERSION:-1.10.18}"
DECKTAPE_VERSION="${DECKTAPE_VERSION:-3.16.1}"

# --- Quarto -----------------------------------------------------------------------------------
if command -v quarto >/dev/null 2>&1 && [ "$(quarto --version)" = "$QUARTO_VERSION" ]; then
  echo "quarto   $(quarto --version)  (already installed)"
else
  dest="$HOME/.local/opt/quarto-$QUARTO_VERSION"
  tmp="$(mktemp -d)"
  echo "quarto   downloading $QUARTO_VERSION ..."
  curl -fsSL -o "$tmp/q.tgz" \
    "https://github.com/quarto-dev/quarto-cli/releases/download/v$QUARTO_VERSION/quarto-$QUARTO_VERSION-linux-amd64.tar.gz"
  mkdir -p "$dest" "$HOME/.local/bin"
  tar -xzf "$tmp/q.tgz" -C "$dest" --strip-components=1
  ln -sf "$dest/bin/quarto" "$HOME/.local/bin/quarto"
  rm -rf "$tmp"
  echo "quarto   $("$HOME/.local/bin/quarto" --version)  -> $HOME/.local/bin/quarto"
fi

# --- Chromium + fonts (apt) -------------------------------------------------------------------
need=()
command -v chromium >/dev/null 2>&1 || need+=(chromium)
dpkg -s fonts-liberation >/dev/null 2>&1 || need+=(fonts-liberation)
if [ ${#need[@]} -gt 0 ]; then
  echo "apt      installing ${need[*]} ..."
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "${need[@]}" >/dev/null
fi
echo "chromium $(chromium --version 2>/dev/null | head -1)"

# --- decktape (npm) ---------------------------------------------------------------------------
if command -v decktape >/dev/null 2>&1 && decktape version 2>/dev/null | grep -q "$DECKTAPE_VERSION"; then
  echo "decktape $DECKTAPE_VERSION  (already installed)"
else
  echo "decktape installing $DECKTAPE_VERSION ..."
  PUPPETEER_SKIP_DOWNLOAD=true npm install -g --silent "decktape@$DECKTAPE_VERSION" >/dev/null
  echo "decktape $(decktape version 2>/dev/null | head -1)"
fi

# --- MathJax (npm, local to tools/) -----------------------------------------------------------
here="$(cd "$(dirname "$0")" && pwd)"
if [ -d "$here/node_modules/mathjax-full" ]; then
  echo "mathjax  $(node -p "require('$here/node_modules/mathjax-full/package.json').version")  (already installed)"
else
  echo "mathjax  installing from tools/package-lock.json ..."
  npm ci --prefix "$here" --silent --no-audit --no-fund >/dev/null
  echo "mathjax  $(node -p "require('$here/node_modules/mathjax-full/package.json').version")"
fi
