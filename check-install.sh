#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# check-install.sh — Diagnostic post-install (Rev0li)
#
# Vérifie en LECTURE SEULE que le système est dans l'état attendu après
# install.sh : OS, Hyprland, NVIDIA, shell zsh, symlinks dotfiles, binaires.
#
# N'installe / ne modifie RIEN. Relançable autant de fois que voulu.
#
# Codes de sortie :
#   0  tout est OK (warnings tolérés)
#   1  au moins une vérification CRITIQUE a échoué
#
# Usage : ./check-install.sh
# ═══════════════════════════════════════════════════════════════════════════

set -uo pipefail   # pas de -e : on veut continuer même si un test échoue

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

PASS=0; WARN=0; FAIL=0

pass() { echo -e "  ${GREEN}✓${NC} $1"; PASS=$((PASS+1)); }
warn() { echo -e "  ${YELLOW}⚠${NC} $1"; WARN=$((WARN+1)); }
fail() { echo -e "  ${RED}✗${NC} $1"; FAIL=$((FAIL+1)); }
head() { echo -e "\n${BOLD}${CYAN}── $1 ──${NC}"; }

DOTFILES_DIR="$HOME/dotfiles"
EXPECTED_BRANCH="fedora_dotfile"

# ── Système ────────────────────────────────────────────────────────────────
head "Système"
if [ -r /etc/os-release ] && grep -q '^ID=fedora' /etc/os-release; then
  ver=$(. /etc/os-release && echo "${VERSION_ID:-?}")
  pass "Fedora détecté (version $ver)"
  [ "${ver%%.*}" -ge 40 ] 2>/dev/null && pass "Fedora >= 40 (DNF5)" || warn "Fedora < 40 — DNF5/akmod peuvent différer"
else
  fail "Ce n'est pas Fedora (scripts prévus pour Fedora 40+)"
fi
command -v dnf >/dev/null 2>&1 && pass "dnf disponible" || fail "dnf introuvable"

# ── Hyprland ───────────────────────────────────────────────────────────────
head "Hyprland"
if rpm -q hyprland &>/dev/null || rpm -q hyprland-git &>/dev/null; then
  pass "Hyprland installé ($(hyprctl version 2>/dev/null | head -1 | grep -oE 'v[0-9.]+' || echo 'version inconnue'))"
else
  fail "Hyprland non installé"
fi
command -v Hyprland >/dev/null 2>&1 || command -v hyprland >/dev/null 2>&1 \
  && pass "binaire Hyprland dans le PATH" || warn "binaire Hyprland non trouvé dans le PATH"

# ── NVIDIA (seulement si GPU NVIDIA présent) ───────────────────────────────
head "NVIDIA"
if lspci 2>/dev/null | grep -qi nvidia; then
  rpm -q akmod-nvidia &>/dev/null && pass "akmod-nvidia installé" || fail "akmod-nvidia manquant"
  if [ -r /sys/module/nvidia_drm/parameters/modeset ]; then
    [ "$(cat /sys/module/nvidia_drm/parameters/modeset)" = "Y" ] \
      && pass "nvidia_drm modeset actif (Y)" \
      || fail "nvidia_drm modeset != Y — as-tu rebooté ?"
  else
    fail "module nvidia_drm non chargé — reboot nécessaire ?"
  fi
  grep -q 'nvidia-drm.modeset=1' /etc/default/grub 2>/dev/null \
    && pass "nvidia-drm.modeset=1 présent dans GRUB" \
    || warn "nvidia-drm.modeset=1 absent de /etc/default/grub"
  command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L 2>/dev/null | head -1 | grep -q GPU \
    && pass "nvidia-smi voit le GPU" || warn "nvidia-smi ne répond pas (driver en cours de build ?)"
else
  warn "Aucun GPU NVIDIA détecté — section ignorée"
fi

# ── Shell zsh ──────────────────────────────────────────────────────────────
head "Shell"
command -v zsh >/dev/null 2>&1 && pass "zsh installé" || fail "zsh non installé"
if getent passwd "$USER" | grep -q '/zsh$'; then
  pass "zsh est le shell par défaut"
else
  warn "shell par défaut != zsh (chsh -s \$(command -v zsh))"
fi
# Pas d'oh-my-zsh attendu (config via dotfiles)
[ -d "$HOME/.oh-my-zsh" ] && warn "~/.oh-my-zsh présent (inattendu : config gérée par tes dotfiles)" \
                          || pass "pas d'oh-my-zsh (config via dotfiles, attendu)"

# ── Dotfiles : repo + branche ──────────────────────────────────────────────
head "Dotfiles (repo)"
if [ -d "$DOTFILES_DIR/.git" ]; then
  pass "$DOTFILES_DIR cloné"
  cur=$(git -C "$DOTFILES_DIR" branch --show-current 2>/dev/null)
  [ "$cur" = "$EXPECTED_BRANCH" ] \
    && pass "branche = $EXPECTED_BRANCH" \
    || warn "branche = '$cur' (attendu : $EXPECTED_BRANCH)"
else
  fail "$DOTFILES_DIR absent — dotfiles-main.sh n'a pas tourné ?"
fi

# ── Symlinks de configuration ──────────────────────────────────────────────
head "Symlinks dotfiles"
check_link() {
  local dst="$1"
  if [ -L "$dst" ]; then
    local target; target=$(readlink -f "$dst" 2>/dev/null)
    case "$target" in
      "$DOTFILES_DIR"/*) pass "$dst → $target" ;;
      *) warn "$dst est un symlink mais pointe hors dotfiles ($target)" ;;
    esac
  elif [ -e "$dst" ]; then
    fail "$dst existe mais n'est PAS un symlink (couche KooL non écrasée)"
  else
    fail "$dst absent"
  fi
}
check_link "$HOME/.zshrc"
check_link "$HOME/.config/wezterm/wezterm.lua"
check_link "$HOME/.config/helix"

# ── Binaires des dotfiles ──────────────────────────────────────────────────
head "Binaires (dotfiles/bin via ~/.local/bin)"
case ":$PATH:" in
  *":$HOME/.local/bin:"*) pass "~/.local/bin dans le PATH" ;;
  *) warn "~/.local/bin absent du PATH (recharge ton shell : exec zsh)" ;;
esac
for b in starship hx wezterm eza; do
  if command -v "$b" >/dev/null 2>&1; then
    pass "$b disponible ($(command -v "$b"))"
  else
    warn "$b introuvable dans le PATH"
  fi
done

# ── Snapshots de backup (info) ─────────────────────────────────────────────
head "Backups"
if [ -L "$(dirname "$0")/backups/latest" ] || [ -d "$(dirname "$0")/backups/latest" ]; then
  pass "snapshot de référence présent ($(basename "$(readlink -f "$(dirname "$0")/backups/latest")"))"
else
  warn "aucun snapshot — pense à lancer ./backup.sh une fois l'install validée"
fi

# ── Résumé ─────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}── Résumé ──${NC}"
echo -e "  ${GREEN}$PASS OK${NC}   ${YELLOW}$WARN warning(s)${NC}   ${RED}$FAIL erreur(s)${NC}"
if [ "$FAIL" -gt 0 ]; then
  echo -e "  ${RED}✗ Des vérifications critiques ont échoué — voir ci-dessus.${NC}"
  exit 1
else
  echo -e "  ${GREEN}✓ Système conforme.${NC}"
  exit 0
fi
