#!/bin/bash
# 💫 https://github.com/JaKooLit 💫 #
# Hyprland-Dots — version Rev0li #
#
# DEUX COUCHES de dotfiles, dans cet ordre :
#   1. KooL Hyprland-Dots  → la couche "desktop" (hypr, waybar, rofi, ...).
#   2. Rev0li/dotfiles     → ma couche "shell/terminal/éditeur" (zsh, wezterm,
#                            helix, starship). Posée APRÈS pour que mes symlinks
#                            écrasent ceux de KooL (~/.zshrc, ~/.config/wezterm...).

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

# Dépôt de mes dotfiles personnels, branche dédiée Fedora, et emplacement cible
REVO_DOTFILES_REPO="https://github.com/Rev0li/dotfiles"
REVO_DOTFILES_BRANCH="fedora_dotfile"
REVO_DOTFILES_DIR="$HOME/dotfiles"

# ──────────────────────────────────────────────────────────────────────────
# COUCHE 1 — KooL Hyprland-Dots (desktop)
# ──────────────────────────────────────────────────────────────────────────
printf "${NOTE} Cloning and Installing ${SKY_BLUE}KooL's Hyprland Dots${RESET} (desktop layer)....\n"
if [ -d Hyprland-Dots ]; then
  cd Hyprland-Dots
  git stash && git pull
  chmod +x copy.sh
  ./copy.sh
  cd "$PARENT_DIR" || exit 1
else
  if git clone --depth=1 https://github.com/JaKooLit/Hyprland-Dots; then
    cd Hyprland-Dots || exit 1
    chmod +x copy.sh
    ./copy.sh
    cd "$PARENT_DIR" || exit 1
  else
    echo -e "$ERROR Can't download ${YELLOW}KooL's Hyprland-Dots${RESET} . Check your internet connection"
  fi
fi

printf "\n%.0s" {1..1}

# ──────────────────────────────────────────────────────────────────────────
# COUCHE 2 — Rev0li/dotfiles (shell / terminal / éditeur)
# ──────────────────────────────────────────────────────────────────────────
printf "${NOTE} Cloning and Installing ${SKY_BLUE}Rev0li dotfiles${RESET} (shell layer)....\n"

if [ -d "$REVO_DOTFILES_DIR/.git" ]; then
  printf "${INFO} ${REVO_DOTFILES_DIR} already exists — updating branch ${SKY_BLUE}${REVO_DOTFILES_BRANCH}${RESET}...\n"
  git -C "$REVO_DOTFILES_DIR" stash --include-untracked 2>/dev/null || true
  git -C "$REVO_DOTFILES_DIR" fetch origin "$REVO_DOTFILES_BRANCH" || true
  git -C "$REVO_DOTFILES_DIR" checkout "$REVO_DOTFILES_BRANCH" 2>/dev/null || \
    git -C "$REVO_DOTFILES_DIR" checkout -b "$REVO_DOTFILES_BRANCH" --track "origin/$REVO_DOTFILES_BRANCH"
  git -C "$REVO_DOTFILES_DIR" pull --ff-only origin "$REVO_DOTFILES_BRANCH" || \
    echo "${WARN} git pull failed for dotfiles — continuing with local copy."
else
  if ! git clone --depth=1 --branch "$REVO_DOTFILES_BRANCH" "$REVO_DOTFILES_REPO" "$REVO_DOTFILES_DIR"; then
    echo -e "${ERROR} Can't clone ${YELLOW}Rev0li/dotfiles${RESET} (branch ${REVO_DOTFILES_BRANCH}). Check your internet connection / branch name."
    printf "\n%.0s" {1..2}
    exit 1
  fi
fi

# Lancer l'installeur des dotfiles (idempotent : symlinks + binaires + polices).
# Il pose ~/.zshrc, ~/.config/helix, ~/.config/wezterm en écrasant ceux de KooL.
if [ -x "$REVO_DOTFILES_DIR/install.sh" ]; then
  ( cd "$REVO_DOTFILES_DIR" && ./install.sh )
else
  chmod +x "$REVO_DOTFILES_DIR/install.sh" 2>/dev/null && \
    ( cd "$REVO_DOTFILES_DIR" && ./install.sh ) || \
    echo "${ERROR} ${REVO_DOTFILES_DIR}/install.sh introuvable ou non exécutable."
fi

printf "\n%.0s" {1..2}
