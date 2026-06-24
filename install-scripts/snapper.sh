#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# snapper.sh — Configure snapper + grub-btrfs pour snapshots locaux (Rev0li)
#
# Installe :
#   • snapper                    — gestion des snapshots Btrfs
#   • python3-dnf-plugin-snapper — snapshot pre/post autour de chaque dnf
#   • grub-btrfs                 — snapshots dans le menu GRUB au boot
#
# Résultat :
#   • Snapshots automatiques : toutes les heures + avant/après chaque dnf
#   • Rollback depuis GRUB   : choisir un snapshot au boot → état restauré
#   • Rétention              : 5h / 7j / 4sem / 3m (root + home)
#
# Usage :
#   ./install-scripts/snapper.sh
#   ou via install.sh --preset preset.sh (option snapper="ON")
# ═══════════════════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$SCRIPT_DIR/.."
cd "$PARENT_DIR" || exit 1

if ! source "$SCRIPT_DIR/Global_functions.sh"; then
    echo "Failed to source Global_functions.sh" >&2
    exit 1
fi

mkdir -p Install-Logs
LOG="Install-Logs/install-$(date +%d-%H%M%S)_snapper.log"

echo "${NOTE} Configuration de snapper + grub-btrfs..." | tee -a "$LOG"

# ── Vérification Btrfs ──────────────────────────────────────────────────────
if ! findmnt -n -o FSTYPE / 2>/dev/null | grep -q btrfs; then
    echo "${ERROR} Root non Btrfs — snapper inapplicable." | tee -a "$LOG"
    exit 1
fi
echo "${OK} Root Btrfs détecté." | tee -a "$LOG"

# ── Packages ─────────────────────────────────────────────────────────────────
for pkg in snapper python3-dnf-plugin-snapper; do
    install_package "$pkg"
done

# grub-btrfs n'est pas dans les repos Fedora standard → COPR kylegospo/grub-btrfs
if rpm -q grub-btrfs &>/dev/null; then
    echo "${INFO} ${MAGENTA}grub-btrfs${RESET} is already installed. Skipping..."
else
    echo "${NOTE} grub-btrfs absent des repos standard — activation du COPR kylegospo/grub-btrfs..." | tee -a "$LOG"
    if sudo dnf copr enable -y kylegospo/grub-btrfs 2>&1 | tee -a "$LOG"; then
        install_package "grub-btrfs"
    else
        echo "${WARN} Impossible d'activer le COPR grub-btrfs — rollback GRUB non disponible." | tee -a "$LOG"
        echo "${NOTE} Pour l'installer manuellement :" | tee -a "$LOG"
        echo "   sudo dnf copr enable kylegospo/grub-btrfs && sudo dnf install -y grub-btrfs" | tee -a "$LOG"
    fi
fi

# ── Config snapper : root ────────────────────────────────────────────────────
if snapper list-configs 2>/dev/null | grep -q '^root '; then
    echo "${INFO} Config snapper 'root' déjà présente." | tee -a "$LOG"
else
    # Nettoyer /.snapshots si c'est un dossier simple (pas un subvolume btrfs)
    if [ -d "/.snapshots" ] && ! sudo btrfs subvolume show "/.snapshots" &>/dev/null; then
        sudo rm -rf "/.snapshots"
    fi
    sudo snapper -c root create-config / 2>&1 | tee -a "$LOG"
    echo "${OK} Config snapper 'root' créée." | tee -a "$LOG"
fi

# ── Config snapper : home ────────────────────────────────────────────────────
if snapper list-configs 2>/dev/null | grep -q '^home '; then
    echo "${INFO} Config snapper 'home' déjà présente." | tee -a "$LOG"
else
    if [ -d "/home/.snapshots" ] && ! sudo btrfs subvolume show "/home/.snapshots" &>/dev/null; then
        sudo rm -rf "/home/.snapshots"
    fi
    sudo snapper -c home create-config /home 2>&1 | tee -a "$LOG"
    echo "${OK} Config snapper 'home' créée." | tee -a "$LOG"
fi

# ── Rétention (root + home) ──────────────────────────────────────────────────
for cfg in root home; do
    sudo snapper -c "$cfg" set-config \
        NUMBER_LIMIT=10 \
        TIMELINE_LIMIT_HOURLY=5 \
        TIMELINE_LIMIT_DAILY=7 \
        TIMELINE_LIMIT_WEEKLY=4 \
        TIMELINE_LIMIT_MONTHLY=3 \
        TIMELINE_LIMIT_YEARLY=0 \
        2>&1 | tee -a "$LOG"
done
echo "${OK} Rétention configurée : 5h / 7j / 4sem / 3m (root + home)." | tee -a "$LOG"

# ── Timers systemd ───────────────────────────────────────────────────────────
for timer in snapper-timeline.timer snapper-cleanup.timer; do
    sudo systemctl enable --now "$timer" 2>&1 | tee -a "$LOG"
    echo "${OK} $timer activé." | tee -a "$LOG"
done

# ── grub-btrfs ───────────────────────────────────────────────────────────────
sudo grub2-mkconfig -o /boot/grub2/grub.cfg 2>&1 | tee -a "$LOG"
if systemctl list-unit-files grub-btrfs.path &>/dev/null 2>&1; then
    sudo systemctl enable --now grub-btrfs.path 2>&1 | tee -a "$LOG"
    echo "${OK} grub-btrfs.path actif — GRUB mis à jour à chaque nouveau snapshot." | tee -a "$LOG"
else
    echo "${WARN} grub-btrfs.path non disponible — relancer grub2-mkconfig manuellement si besoin." | tee -a "$LOG"
fi

printf "\n"
echo "${OK} snapper opérationnel." | tee -a "$LOG"
printf "${NOTE} Commandes utiles :\n"
printf "   snapper list                          — voir les snapshots\n"
printf "   snapper -c root create -d 'avant X'  — snapshot manuel\n"
printf "   snapper -c root diff N M              — diff entre snapshots\n"
printf "   snapper -c root undochange N..M       — annuler des changements\n"
