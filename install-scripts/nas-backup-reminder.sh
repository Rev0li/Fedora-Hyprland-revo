#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# nas-backup-reminder.sh — Installe le rappel INTERACTIF de sauvegarde NAS (Rev0li)
#
# Met en place des timers systemd --user (aucun sudo, aucun NOPASSWD) :
#   • nas-backup-reminder.timer       — rappel quotidien 20:00 (incrémental)
#   • nas-backup-reminder-full.timer  — rappel hebdo dimanche 20:30 (--full)
#
# Chaque rappel affiche une notification swaync avec un bouton « Lancer » ;
# au clic, un terminal kitty ouvre nas-backup.sh et sudo demande, de façon
# interactive, ton mot de passe + touch YubiKey. Rien ne part vers le NAS sans
# ton action.
#
# Idempotent : réinstalle/écrase les unités et réactive les timers.
#
# Usage :
#   ./install-scripts/nas-backup-reminder.sh
# ═══════════════════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PARENT_DIR" || exit 1

if ! source "$SCRIPT_DIR/Global_functions.sh"; then
    echo "Failed to source Global_functions.sh" >&2
    exit 1
fi

mkdir -p Install-Logs
LOG="Install-Logs/install-$(date +%d-%H%M%S)_nas-backup-reminder.log"

SRC="$PARENT_DIR/systemd/user"
USER_UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

echo "${NOTE} Installation du rappel interactif nas-backup (systemd --user)..." | tee -a "$LOG"

# ── Pré-vérifications ────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] && { echo "${ERROR} Ne pas lancer en root (unités --user de ton compte)." | tee -a "$LOG"; exit 1; }
[ -x "$PARENT_DIR/nas-backup.sh" ]        || { echo "${ERROR} nas-backup.sh introuvable/non exécutable." | tee -a "$LOG"; exit 1; }
[ -x "$PARENT_DIR/nas-backup-notify.sh" ] || { echo "${ERROR} nas-backup-notify.sh introuvable/non exécutable." | tee -a "$LOG"; exit 1; }
for c in notify-send kitty setsid; do
    command -v "$c" >/dev/null 2>&1 || { echo "${ERROR} '$c' manquant." | tee -a "$LOG"; exit 1; }
done
command -v swaync >/dev/null 2>&1 || echo "${WARN} swaync introuvable — les notifications risquent de ne pas s'afficher." | tee -a "$LOG"
for f in nas-backup-reminder.service nas-backup-reminder.timer \
         nas-backup-reminder-full.service nas-backup-reminder-full.timer; do
    [ -f "$SRC/$f" ] || { echo "${ERROR} Unité source manquante : systemd/user/$f" | tee -a "$LOG"; exit 1; }
done
echo "${OK} Pré-vérifications passées." | tee -a "$LOG"

# ── Installation des unités user ─────────────────────────────────────────────
mkdir -p "$USER_UNIT_DIR"
install -m 0644 \
    "$SRC/nas-backup-reminder.service" \
    "$SRC/nas-backup-reminder.timer" \
    "$SRC/nas-backup-reminder-full.service" \
    "$SRC/nas-backup-reminder-full.timer" \
    "$USER_UNIT_DIR/"
systemctl --user daemon-reload
echo "${OK} Unités copiées dans $USER_UNIT_DIR + daemon-reload." | tee -a "$LOG"

# ── Activation des timers ────────────────────────────────────────────────────
systemctl --user enable --now nas-backup-reminder.timer nas-backup-reminder-full.timer 2>&1 | tee -a "$LOG"
echo "${OK} Timers activés (rappel quotidien + hebdo --full)." | tee -a "$LOG"

printf "\n"
echo "${OK} Rappel interactif nas-backup opérationnel." | tee -a "$LOG"
printf "${NOTE} Vérifs & commandes utiles :\n"
printf "   systemctl --user list-timers 'nas-backup*'                    — prochains rappels\n"
printf "   systemctl --user start --no-block nas-backup-reminder-full.service   — tester la notif maintenant\n"
printf "   ./nas-backup.sh                                                — lancer un backup à la main\n"
