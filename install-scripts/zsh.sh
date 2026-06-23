#!/bin/bash
# 💫 https://github.com/JaKooLit 💫 #
# ZSH — version Rev0li #
#
# DIFFÉRENCE avec l'upstream JaKooLit :
#   - PAS d'oh-my-zsh : la configuration Zsh est fournie par mes dotfiles
#     (https://github.com/Rev0li/dotfiles), posés par dotfiles-main.sh.
#   - On NE copie PAS assets/.zshrc / assets/.zprofile (ils seraient écrasés
#     par les symlinks de mes dotfiles de toute façon).
#   - Ce script se limite à : installer zsh + outils CLI, définir zsh comme
#     shell par défaut. La config (symlink ~/.zshrc) est faite plus tard.

# Paquets CLI requis par mes dotfiles (eza/lsd, fzf, etc.) + zsh lui-même.
zsh=(
  fzf
  git
  curl
  tar
  unzip
  fontconfig
  zsh
  util-linux
)

## WARNING: DO NOT EDIT BEYOND THIS LINE IF YOU DON'T KNOW WHAT YOU ARE DOING! ##
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Change the working directory to the parent directory of the script
PARENT_DIR="$SCRIPT_DIR/.."
cd "$PARENT_DIR" || { echo "${ERROR} Failed to change directory to $PARENT_DIR"; exit 1; }

# Source the global functions script
if ! source "$(dirname "$(readlink -f "$0")")/Global_functions.sh"; then
  echo "Failed to source Global_functions.sh"
  exit 1
fi

# Set the name of the log file to include the current date and time
LOG="Install-Logs/install-$(date +%d-%H%M%S)_zsh.log"

# Check if the log file already exists, if yes, append a counter to make it unique
COUNTER=1
while [ -f "$LOG" ]; do
  LOG="Install-Logs/install-$(date +%d-%H%M%S)_${COUNTER}_zsh.log"
  ((COUNTER++))
done

# Installing zsh packages
printf "${NOTE} Installing core zsh packages (Rev0li flavor)...${RESET}\n"
for ZSHP in "${zsh[@]}"; do
  install_package "$ZSHP"
done

printf "\n%.0s" {1..1}

# Set zsh as the default shell (the actual config comes from my dotfiles)
if command -v zsh >/dev/null; then
  current_shell=$(basename "$SHELL")
  if [ "$current_shell" != "zsh" ]; then
    printf "${NOTE} Changing default shell to ${MAGENTA}zsh${RESET}..."
    printf "\n%.0s" {1..2}

    # Loop to ensure the chsh command succeeds
    while ! chsh -s "$(command -v zsh)"; do
      echo "${ERROR} Authentication failed. Please enter the correct password." 2>&1 | tee -a "$LOG"
      sleep 1
    done

    printf "${INFO} Shell changed successfully to ${MAGENTA}zsh${RESET}" 2>&1 | tee -a "$LOG"
  else
    echo "${NOTE} Your shell is already set to ${MAGENTA}zsh${RESET}."
  fi
else
  echo "${ERROR} zsh not found after install. Check $LOG." 2>&1 | tee -a "$LOG"
fi

echo "${INFO} Zsh config (~/.zshrc) is provided by my dotfiles — see dotfiles-main.sh" 2>&1 | tee -a "$LOG"

printf "\n%.0s" {1..2}
