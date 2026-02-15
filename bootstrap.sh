#!/usr/bin/env bash

set -euo pipefail

export HOMEBREW_NO_INSTALL_CLEANUP=1
export HOMEBREW_NO_ENV_HINTS=1

# Stage 1: public, minimal bootstrap only.
FORMULAE=(
  git
  gh
  starship
)

CASKS=(
  1password
  1password-cli
  yubico-authenticator
)

PRIVATE_REPO="${PRIVATE_REPO:-ndng28/mbp_customize}"
PRIVATE_SCRIPT_PATH="${PRIVATE_SCRIPT_PATH:-customize.sh}"

SCRIPT_PATH="${BASH_SOURCE[0]:-}"
if [[ -n "$SCRIPT_PATH" && -f "$SCRIPT_PATH" ]]; then
  OUTPUT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
else
  OUTPUT_DIR="$PWD"
fi

STATUS_PATH="$OUTPUT_DIR/BOOTSTRAP_STATUS.md"
BOOTSTRAP_FAILED=0

now_ts() { date '+%Y-%m-%d %H:%M:%S'; }

screen_msg() {
  printf '==> %s\n' "$1"
}

escape_md() {
  local value="$1"
  value="${value//$'\n'/ }"
  value="${value//|/\\|}"
  printf '%s' "$value"
}

task_row() {
  local task="$1"
  local status="$2"
  local details="$3"
  printf '| %s | %s | %s | %s |\n' \
    "$(escape_md "$task")" \
    "$(escape_md "$status")" \
    "$(escape_md "$details")" \
    "$(now_ts)" >>"$STATUS_PATH"
}

item_row() {
  local type="$1"
  local name="$2"
  local before="$3"
  local after="$4"
  local status="$5"
  local details="$6"
  printf '| %s | %s | %s | %s | %s | %s | %s |\n' \
    "$(escape_md "$type")" \
    "$(escape_md "$name")" \
    "$(escape_md "$before")" \
    "$(escape_md "$after")" \
    "$(escape_md "$status")" \
    "$(escape_md "$details")" \
    "$(now_ts)" >>"$STATUS_PATH"
}

write_status_header() {
  local host_name
  local os_version

  host_name="$(scutil --get ComputerName 2>/dev/null || hostname)"
  os_version="$(sw_vers -productVersion 2>/dev/null || printf 'unknown')"

  cat >"$STATUS_PATH" <<EOF
# Bootstrap Run Status

- Run started: $(now_ts)
- Host: $host_name
- macOS: $os_version

## Task Status

| Task | Status | Details | Timestamp |
|---|---|---|---|

## Install Status

| Type | Name | Before | After | Status | Details | Timestamp |
|---|---|---|---|---|---|---|
EOF
}

require_macos() {
  if [[ "$(uname -s)" != 'Darwin' ]]; then
    task_row 'Verify macOS' 'FAILED' 'This script only supports macOS.'
    exit 1
  fi
  task_row 'Verify macOS' 'SUCCESS' 'Darwin detected.'
}

ensure_not_root() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    task_row 'Privilege check' 'FAILED' 'Run as your user, not root.'
    exit 1
  fi
  task_row 'Privilege check' 'SUCCESS' 'Running as non-root user.'
}

install_clt_if_missing() {
  screen_msg 'Checking Apple Command Line Tools...'
  if xcode-select -p >/dev/null 2>&1; then
    screen_msg 'Command Line Tools already installed.'
    task_row 'Install Command Line Tools' 'SKIPPED' 'Already installed.'
    return
  fi

  if ! xcode-select --install >/dev/null 2>&1; then
    screen_msg 'Could not launch Command Line Tools installer.'
    task_row 'Install Command Line Tools' 'FAILED' 'Could not launch installer.'
    BOOTSTRAP_FAILED=1
    return
  fi

  until xcode-select -p >/dev/null 2>&1; do
    screen_msg 'Waiting for Command Line Tools installation to finish...'
    sleep 10
  done
  screen_msg 'Command Line Tools installation complete.'
  task_row 'Install Command Line Tools' 'SUCCESS' 'Installed.'
}

init_brew_env() {
  if [[ -x /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [[ -x /usr/local/bin/brew ]]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi
}

install_homebrew_if_missing() {
  screen_msg 'Checking Homebrew...'
  init_brew_env
  if command -v brew >/dev/null 2>&1; then
    screen_msg 'Homebrew already installed.'
    task_row 'Install Homebrew' 'SKIPPED' 'Already installed.'
    return
  fi

  screen_msg 'Installing Homebrew...'
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || true
  init_brew_env

  if command -v brew >/dev/null 2>&1; then
    screen_msg 'Homebrew installation complete.'
    task_row 'Install Homebrew' 'SUCCESS' 'Installed.'
  else
    screen_msg 'Homebrew install failed.'
    task_row 'Install Homebrew' 'FAILED' 'brew unavailable after install attempt.'
    BOOTSTRAP_FAILED=1
  fi
}

update_macos_if_available() {
  local update_output

  if ! command -v softwareupdate >/dev/null 2>&1; then
    task_row 'Update macOS' 'SKIPPED' 'softwareupdate command unavailable.'
    return
  fi

  if ! update_output="$(/usr/sbin/softwareupdate --list 2>&1)"; then
    task_row 'Update macOS' 'FAILED' 'Could not check available software updates.'
    BOOTSTRAP_FAILED=1
    return
  fi

  if [[ "$update_output" == *"No new software available."* ]]; then
    task_row 'Update macOS' 'SKIPPED' 'System already up to date.'
    return
  fi

  if sudo /usr/sbin/softwareupdate --install --all; then
    task_row 'Update macOS' 'SUCCESS' 'Installed available updates. A reboot may still be required.'
  else
    task_row 'Update macOS' 'FAILED' 'softwareupdate install failed.'
    BOOTSTRAP_FAILED=1
  fi
}

run_task() {
  local name="$1"
  shift
  screen_msg "$name..."
  if "$@"; then
    screen_msg "$name complete."
    task_row "$name" 'SUCCESS' 'Completed.'
  else
    screen_msg "$name failed."
    task_row "$name" 'FAILED' 'Command failed.'
    BOOTSTRAP_FAILED=1
  fi
}

install_formulae() {
  local formula
  screen_msg 'Installing Homebrew formulae...'
  for formula in "${FORMULAE[@]}"; do
    screen_msg "Formula: $formula"
    if brew list --formula "$formula" >/dev/null 2>&1; then
      item_row 'brew' "$formula" 'yes' 'yes' 'ALREADY_INSTALLED' 'Formula already present.'
      continue
    fi

    if brew install "$formula"; then
      item_row 'brew' "$formula" 'no' 'yes' 'INSTALLED' 'Installed during bootstrap run.'
    else
      item_row 'brew' "$formula" 'no' 'no' 'FAILED' 'brew install failed.'
      BOOTSTRAP_FAILED=1
    fi
  done
}

install_casks() {
  local cask
  screen_msg 'Installing Homebrew casks...'
  for cask in "${CASKS[@]}"; do
    screen_msg "Cask: $cask"
    if brew list --cask "$cask" >/dev/null 2>&1; then
      item_row 'cask' "$cask" 'yes' 'yes' 'ALREADY_INSTALLED' 'Cask already present.'
      continue
    fi

    if brew install --cask "$cask"; then
      item_row 'cask' "$cask" 'no' 'yes' 'INSTALLED' 'Installed during bootstrap run.'
    else
      item_row 'cask' "$cask" 'no' 'no' 'FAILED' 'brew install --cask failed.'
      BOOTSTRAP_FAILED=1
    fi
  done
}

disable_natural_scrolling_if_enabled() {
  local trackpad_value
  local global_value

  trackpad_value="$(defaults read com.apple.AppleMultitouchTrackpad AppleEnableNaturalScrolling 2>/dev/null || true)"
  global_value="$(defaults read NSGlobalDomain com.apple.swipescrolldirection 2>/dev/null || true)"

  if [[ "$trackpad_value" == '1' || "$global_value" == '1' ]]; then
    defaults write NSGlobalDomain com.apple.swipescrolldirection -bool false
    defaults write com.apple.AppleMultitouchTrackpad AppleEnableNaturalScrolling -bool false
    defaults -currentHost write NSGlobalDomain com.apple.swipescrolldirection -bool false
    killall cfprefsd >/dev/null 2>&1 || true
    killall SystemUIServer >/dev/null 2>&1 || true
    task_row 'Disable natural scrolling' 'SUCCESS' 'Natural scrolling disabled.'
  else
    task_row 'Disable natural scrolling' 'SKIPPED' 'Already disabled.'
  fi
}

configure_zshrc() {
  local zshrc_path
  local managed_start
  local managed_end

  zshrc_path="$HOME/.zshrc"
  managed_start="# >>> mbp_bootstrap managed block >>>"
  managed_end="# <<< mbp_bootstrap managed block <<<"

  if [[ ! -f "$zshrc_path" ]]; then
    cat >"$zshrc_path" <<'EOF'
# Generated by mbp_bootstrap (stage 1)

# >>> mbp_bootstrap managed block >>>

# Homebrew environment
if [[ -x /opt/homebrew/bin/brew ]]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
elif [[ -x /usr/local/bin/brew ]]; then
  eval "$(/usr/local/bin/brew shellenv)"
fi

# Prompt
if command -v starship >/dev/null 2>&1; then
  eval "$(starship init zsh)"
fi

# 1Password SSH agent socket
export SSH_AUTH_SOCK="$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"

# 1Password shell plugins
if command -v op >/dev/null 2>&1; then
  eval "$(op plugin init zsh)"
fi

# <<< mbp_bootstrap managed block <<<
EOF
    task_row 'Configure zshrc' 'SUCCESS' 'Created default ~/.zshrc with Homebrew, starship, and 1Password settings.'
    return
  fi

  if /usr/bin/grep -Fq "$managed_start" "$zshrc_path"; then
    task_row 'Configure zshrc' 'SKIPPED' 'Managed zshrc block already present.'
    return
  fi

  cat >>"$zshrc_path" <<EOF

$managed_start
# Homebrew environment
if [[ -x /opt/homebrew/bin/brew ]]; then
  eval "\$(/opt/homebrew/bin/brew shellenv)"
elif [[ -x /usr/local/bin/brew ]]; then
  eval "\$(/usr/local/bin/brew shellenv)"
fi

# Prompt
if command -v starship >/dev/null 2>&1; then
  eval "\$(starship init zsh)"
fi

# 1Password SSH agent socket
export SSH_AUTH_SOCK="\$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"

# 1Password shell plugins
if command -v op >/dev/null 2>&1; then
  eval "\$(op plugin init zsh)"
fi
$managed_end
EOF

  task_row 'Configure zshrc' 'SUCCESS' 'Appended managed zshrc block with Homebrew, starship, and 1Password settings.'
}

print_handoff() {
  printf '\nStage 1 complete. Next steps:\n'
  printf '1) Reboot your Mac\n'
  printf '2) Sign in to 1Password desktop app\n'
  printf '3) Run stage 2 (private repo):\n\n'
  printf '   gh repo clone %s "$HOME/mbp_customize" && bash "$HOME/mbp_customize/%s"\n\n' "$PRIVATE_REPO" "$PRIVATE_SCRIPT_PATH"
}

main() {
  printf '\nWelcome to the macOS Stage 1 bootstrap.\n'
  printf 'This script checks system prerequisites, installs core tools, configures shell basics, and records a status report.\n\n'
  printf 'Estimated time: 10-30 minutes depending on updates and installs.\n'
  printf 'Note: some steps may ask for your macOS password (sudo).\n\n'

  write_status_header
  screen_msg "Writing status report to $STATUS_PATH"
  require_macos
  ensure_not_root
  install_clt_if_missing
  screen_msg 'Checking for macOS updates...'
  update_macos_if_available
  install_homebrew_if_missing

  if command -v brew >/dev/null 2>&1; then
    run_task 'Brew update' brew update
    install_formulae
    install_casks
    configure_zshrc
    run_task 'Brew cleanup' brew cleanup
  else
    task_row 'Brew operations' 'FAILED' 'brew unavailable; package installs skipped.'
    BOOTSTRAP_FAILED=1
  fi

  disable_natural_scrolling_if_enabled

  if [[ "$BOOTSTRAP_FAILED" -eq 0 ]]; then
    task_row 'Final result' 'SUCCESS' "Stage 1 complete. Report: $STATUS_PATH"
    print_handoff
    exit 0
  fi

  task_row 'Final result' 'FAILED' "One or more steps failed. Report: $STATUS_PATH"
  printf 'Bootstrap completed with failures. Review %s\n' "$STATUS_PATH"
  exit 1
}

main "$@"
