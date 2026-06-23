#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# backup.sh — Snapshot horodaté d'une install Fedora + Hyprland (Rev0li)
#
# Capture, dans un dossier daté :
#   1. Les paquets DNF explicitement installés par l'utilisateur
#   2. Les applications Flatpak
#   3. Les dépôts COPR activés
#   4. Une archive des configs ~/.config gérées par KooL (hors mes dotfiles)
#
# Idempotent : chaque exécution crée un NOUVEAU snapshot daté, ne touche pas
# aux précédents, et met à jour le lien `latest`. Tout est loggé avec timestamp.
#
# Usage :
#   ./backup.sh                 # snapshot dans ./backups/<timestamp>/
#   BACKUP_ROOT=/mnt/nas ./backup.sh   # change la destination
# ═══════════════════════════════════════════════════════════════════════════

set -euo pipefail

# ── Couleurs ───────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'

# ── Chemins ────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_ROOT="${BACKUP_ROOT:-$SCRIPT_DIR/backups}"
STAMP="$(date +%Y%m%d_%H%M%S)"
SNAP_DIR="$BACKUP_ROOT/$STAMP"
LOG="$SNAP_DIR/backup.log"

# Configs ~/.config à sauvegarder (couche desktop KooL).
# On EXCLUT helix & wezterm : ils sont gérés par mes dotfiles (versionnés).
CONFIG_DIRS=(
  hypr waybar rofi swaync wlogout kitty fastfetch
  Kvantum qt5ct qt6ct gtk-3.0 gtk-4.0 cava
)

# ── Helpers de log (timestamp systématique) ────────────────────────────────
log()  { echo -e "$(date '+%H:%M:%S') ${CYAN}→${NC} $1" | tee -a "$LOG"; }
ok()   { echo -e "$(date '+%H:%M:%S') ${GREEN}✓${NC} $1" | tee -a "$LOG"; }
warn() { echo -e "$(date '+%H:%M:%S') ${YELLOW}⚠${NC} $1" | tee -a "$LOG"; }

mkdir -p "$SNAP_DIR"
log "Snapshot démarré → $SNAP_DIR"

# ── 1. Paquets DNF explicitement installés ─────────────────────────────────
# DNF5 : `dnf repoquery --userinstalled` ; fallback `dnf history userinstalled`.
log "Capture des paquets DNF user-installed..."
if dnf repoquery --userinstalled --qf '%{name}\n' >"$SNAP_DIR/dnf-userinstalled.txt" 2>/dev/null; then
  sort -u -o "$SNAP_DIR/dnf-userinstalled.txt" "$SNAP_DIR/dnf-userinstalled.txt"
  ok "DNF : $(wc -l <"$SNAP_DIR/dnf-userinstalled.txt") paquets → dnf-userinstalled.txt"
elif dnf history userinstalled >"$SNAP_DIR/dnf-userinstalled.txt" 2>/dev/null; then
  ok "DNF (history) → dnf-userinstalled.txt"
else
  warn "Impossible de lister les paquets DNF user-installed."
fi

# ── 2. Applications Flatpak ────────────────────────────────────────────────
log "Capture des applications Flatpak..."
if command -v flatpak >/dev/null 2>&1; then
  flatpak list --app --columns=application >"$SNAP_DIR/flatpak-apps.txt" 2>/dev/null || true
  ok "Flatpak : $(wc -l <"$SNAP_DIR/flatpak-apps.txt") app(s) → flatpak-apps.txt"
else
  warn "flatpak non installé — ignoré."
  : >"$SNAP_DIR/flatpak-apps.txt"
fi

# ── 3. Dépôts COPR activés ─────────────────────────────────────────────────
log "Capture des dépôts COPR activés..."
# `dnf copr list` n'est pas toujours dispo / fiable → on parse les .repo files.
if grep -rhoE 'copr\.fedorainfracloud\.org/[^/]+/[^/]+' /etc/yum.repos.d/ 2>/dev/null \
     | sed -E 's#copr\.fedorainfracloud\.org/##' | sort -u >"$SNAP_DIR/copr-repos.txt"; then
  ok "COPR : $(wc -l <"$SNAP_DIR/copr-repos.txt") dépôt(s) → copr-repos.txt"
else
  warn "Aucun dépôt COPR détecté."
  : >"$SNAP_DIR/copr-repos.txt"
fi

# ── 4. Archive des configs hors-dotfiles ───────────────────────────────────
log "Archivage des configs ~/.config (hors dotfiles)..."
present=()
for d in "${CONFIG_DIRS[@]}"; do
  [ -e "$HOME/.config/$d" ] && present+=("$d")
done
if [ ${#present[@]} -gt 0 ]; then
  # On suit les symlinks (-h désactivé) pour archiver le contenu réel.
  tar -czf "$SNAP_DIR/config-backup.tar.gz" -C "$HOME/.config" "${present[@]}" 2>>"$LOG"
  printf '%s\n' "${present[@]}" >"$SNAP_DIR/config-dirs.txt"
  ok "Configs : ${#present[@]} dossier(s) → config-backup.tar.gz"
else
  warn "Aucun des dossiers de config listés n'est présent."
fi

# ── Métadonnées + lien latest ──────────────────────────────────────────────
{
  echo "date=$STAMP"
  echo "host=$(hostname)"
  echo "fedora=$(. /etc/os-release 2>/dev/null && echo "${VERSION_ID:-?}")"
  echo "kernel=$(uname -r)"
} >"$SNAP_DIR/manifest.txt"

ln -sfn "$SNAP_DIR" "$BACKUP_ROOT/latest"
ok "Snapshot terminé. 'latest' → $STAMP"

# ── (Optionnel) push de mes dotfiles vers git ──────────────────────────────
# Volontairement désactivé : décommenter pour committer ~/dotfiles à chaque backup.
# Pousse sur la branche dédiée Fedora utilisée par dotfiles-main.sh.
# DOTFILES_BRANCH="fedora_dotfile"
# if [ -d "$HOME/dotfiles/.git" ]; then
#   git -C "$HOME/dotfiles" add -A
#   git -C "$HOME/dotfiles" commit -m "backup: snapshot $STAMP" && \
#   git -C "$HOME/dotfiles" push origin "$DOTFILES_BRANCH" && ok "dotfiles poussés vers git ($DOTFILES_BRANCH)."
# fi

echo ""
log "Pour restaurer : ./restore.sh            (dernier snapshot)"
log "             ou : ./restore.sh $STAMP"
