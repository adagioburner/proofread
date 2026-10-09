#!/bin/bash
# Installs Proofread on this Mac: Hammerspoon (if needed), the Proofread
# Spoon, an Anthropic API key (kept in the Keychain) and the ⌃⌥P hotkey.
#
# Run it from Terminal:
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/adagioburner/proofread/main/install.sh)"
#
# Safe to run again later: it updates Proofread and keeps your own prompt edits.

set -euo pipefail

REPO="adagioburner/proofread"
BRANCH="main"
HAMMERSPOON_FALLBACK_VERSION="1.1.1"
KEYCHAIN_SERVICE="proofread-anthropic-api-key"

HS_DIR="$HOME/.hammerspoon"
SPOON_DIR="$HS_DIR/Spoons/Proofread.spoon"
CONFIG="$HS_DIR/init.lua"
ACCOUNT="${USER:-$(id -un)}"

say()  { printf '%s\n' "$*"; }
step() { printf '\n\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
fail() { printf '\n\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

# Questions are read from the terminal even when this script arrives on stdin.
exec 3<"${PROOFREAD_TTY:-/dev/tty}" || fail "Please run this in Terminal."
ask() { local reply=""; printf '%s' "$1" >&2; IFS= read -r -u 3 reply || true; printf '%s' "$reply"; }

[ "$(uname -s)" = "Darwin" ] || fail "Proofread works on macOS only."
macos_major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$macos_major" -ge 13 ] || fail "Hammerspoon needs macOS 13 (Ventura) or newer."

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

say "This sets up Proofread: select text in any app, press ⌃⌥P, and review"
say "Claude's suggestions before they replace your text."

# ---------------------------------------------------------------------------
step "1/4  Hammerspoon"

find_app() {
  local dir
  for dir in /Applications "$HOME/Applications"; do
    if [ -d "$dir/Hammerspoon.app" ]; then printf '%s' "$dir/Hammerspoon.app"; return 0; fi
  done
  return 1
}

if APP="$(find_app)"; then
  ok "already installed"
else
  version="$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
    https://github.com/Hammerspoon/hammerspoon/releases/latest 2>/dev/null | sed 's#.*/##' || true)"
  case "$version" in [0-9]*) ;; *) version="$HAMMERSPOON_FALLBACK_VERSION" ;; esac
  say "  Downloading Hammerspoon $version…"
  curl -fsSL "https://github.com/Hammerspoon/hammerspoon/releases/download/$version/Hammerspoon-$version.zip" \
    -o "$TMP/hammerspoon.zip" \
    || fail "Couldn't download Hammerspoon. Install it from https://www.hammerspoon.org, then run this again."
  ditto -x -k "$TMP/hammerspoon.zip" "$TMP/hammerspoon"
  [ -d "$TMP/hammerspoon/Hammerspoon.app" ] || fail "The Hammerspoon download looks incomplete."
  dest="/Applications"
  if [ ! -w "$dest" ]; then dest="$HOME/Applications"; mkdir -p "$dest"; fi
  ditto "$TMP/hammerspoon/Hammerspoon.app" "$dest/Hammerspoon.app"
  APP="$dest/Hammerspoon.app"
  ok "installed in $dest"
fi

# ---------------------------------------------------------------------------
step "2/4  Proofread"

if [ -d "$SPOON_DIR/.git" ]; then
  ok "already installed as a git checkout; update it with: git -C \"$SPOON_DIR\" pull"
else
  curl -fsSL "https://github.com/$REPO/archive/refs/heads/$BRANCH.zip" -o "$TMP/proofread.zip" \
    || fail "Couldn't download Proofread from GitHub."
  ditto -x -k "$TMP/proofread.zip" "$TMP/proofread"
  new="$TMP/proofread/proofread-$BRANCH"
  [ -f "$new/init.lua" ] || fail "The Proofread download looks incomplete."

  # Keep the user's own prompt: .prompt.installed.md remembers the version we
  # installed last time, so an edited prompt.md is easy to spot.
  mine=""
  if [ -f "$SPOON_DIR/prompt.md" ] && ! cmp -s "$SPOON_DIR/prompt.md" "$SPOON_DIR/.prompt.installed.md"; then
    mine="$TMP/prompt.mine.md"
    cp "$SPOON_DIR/prompt.md" "$mine"
  fi

  mkdir -p "$HS_DIR/Spoons"
  rm -rf "$SPOON_DIR"
  ditto "$new" "$SPOON_DIR"
  cp "$SPOON_DIR/prompt.md" "$SPOON_DIR/.prompt.installed.md"
  if [ -n "$mine" ]; then
    cp "$SPOON_DIR/prompt.md" "$SPOON_DIR/prompt.default.md"
    cp "$mine" "$SPOON_DIR/prompt.md"
    ok "installed the latest version (kept your edited prompt; the new default is in prompt.default.md)"
  else
    ok "installed the latest version"
  fi
fi

# ---------------------------------------------------------------------------
step "3/4  Anthropic API key"

need_key=1
if security find-generic-password -s "$KEYCHAIN_SERVICE" >/dev/null 2>&1; then
  ok "a key is already stored in the Keychain"
  case "$(ask "  Replace it with a new key? [y/N] ")" in
    [yY]*) ;;
    *) need_key="" ;;
  esac
fi

if [ -n "$need_key" ]; then
  say "  Create a key at https://platform.claude.com/settings/keys"
  key=""
  for attempt in 1 2 3; do
    printf '  Paste the key (it stays hidden) and press Return: '
    key=""
    IFS= read -rs -u 3 key || true
    printf '\n'
    key="$(printf '%s' "$key" | tr -d '[:space:]')"
    case "$key" in
      sk-ant-*) ;;
      *) say "  That doesn't look like an Anthropic API key (they start with sk-ant-)."; key=""; continue ;;
    esac
    # Check the key against the API (listing models is free). The key goes to
    # curl on stdin so it never shows up in the process list.
    status="$(printf 'header = "x-api-key: %s"\n' "$key" \
      | curl -s -o /dev/null -w '%{http_code}' -K - -H "anthropic-version: 2023-06-01" \
        https://api.anthropic.com/v1/models || true)"
    if [ "$status" = "200" ]; then ok "key works"; break; fi
    if [ "$status" = "401" ]; then say "  Anthropic rejected that key."; key=""; continue; fi
    say "  Couldn't check the key right now (HTTP ${status:-none}); saving it anyway."
    break
  done
  [ -n "$key" ] || fail "No valid key entered. Run the installer again when you have one."
  security add-generic-password -U -a "$ACCOUNT" -s "$KEYCHAIN_SERVICE" -w "$key"
  ok "stored in the Keychain"
fi

# ---------------------------------------------------------------------------
step "4/4  Hotkey and permission"

mkdir -p "$HS_DIR"
touch "$CONFIG"
if grep -q 'loadSpoon("Proofread")' "$CONFIG"; then
  ok "hotkey already set up"
else
  cat >> "$CONFIG" <<'EOF'

-- Proofread: select text in any app and press Ctrl-Option-P.
-- https://github.com/adagioburner/proofread
hs.autoLaunch(true) -- start Hammerspoon when you log in
hs.loadSpoon("Proofread")
spoon.Proofread:bindHotkeys({ proofread = { { "ctrl", "alt" }, "p" } })
EOF
  ok "hotkey ⌃⌥P added"
fi

# Start Hammerspoon fresh so it loads the new setup and asks for access.
killall Hammerspoon >/dev/null 2>&1 || true
sleep 1
open "$APP"
sleep 3
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" || true

say ""
say "  Proofread needs permission to copy and paste for you:"
say "  in System Settings → Privacy & Security → Accessibility, switch on Hammerspoon."
say "  (Not in the list? Click +, then pick Hammerspoon in Applications.)"
ask "  Press Return once it's on (or if it already was)… " >/dev/null

# macOS often applies the permission only after the app restarts.
killall Hammerspoon >/dev/null 2>&1 || true
sleep 1
open "$APP"

step "All set!"
say "Select some text in any app and press ⌃⌥P (Control-Option-P)."
say "Run this installer again any time to update Proofread."
