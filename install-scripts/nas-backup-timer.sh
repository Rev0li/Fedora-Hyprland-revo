#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# nas-backup-timer.sh — Installe l'automatisation systemd de nas-backup.sh (Rev0li)
#
# Met en place :
#   • /etc/sudoers.d/nas-backup            — NOPASSWD ciblé (voir le fichier source)
#   • nas-backup.timer       (quotidien)   — envoi incrémental à 02:00
#   • nas-backup-full.timer  (mensuel)     — envoi complet --full le 1er à 03:00
#
# Idempotent : réinstalle/écrase les fichiers et réactive les timers sans casser.
#
# ⚠️ Lis d'abord systemd/nas-backup.sudoers : le NOPASSWD accordé équivaut en
#    pratique à root sans mot de passe pour rev0li. Acceptable sur poste perso.
#
# Usage :
#   ./install-scripts/nas-backup-timer.sh
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
LOG="Install-Logs/install-$(date +%d-%H%M%S)_nas-backup-timer.log"

SYSTEMD_SRC="$PARENT_DIR/systemd"
NAS_SCRIPT="$PARENT_DIR/nas-backup.sh"

echo "${NOTE} Installation de l'automatisation systemd nas-backup..." | tee -a "$LOG"

# ── Pré-vérifications ────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] && { echo "${ERROR} Ne pas lancer en root (sudo est appelé au besoin)." | tee -a "$LOG"; exit 1; }

[ -x "$NAS_SCRIPT" ] || { echo "${ERROR} $NAS_SCRIPT introuvable ou non exécutable." | tee -a "$LOG"; exit 1; }
command -v flock >/dev/null 2>&1 || { echo "${ERROR} flock manquant (dnf install util-linux)." | tee -a "$LOG"; exit 1; }
for f in nas-backup.service nas-backup.timer nas-backup-full.service nas-backup-full.timer nas-backup.sudoers; do
    [ -f "$SYSTEMD_SRC/$f" ] || { echo "${ERROR} Fichier source manquant : systemd/$f" | tee -a "$LOG"; exit 1; }
done
echo "${OK} Pré-vérifications passées." | tee -a "$LOG"

# ── 1. Drop-in sudoers (validé avant activation) ─────────────────────────────
# On installe dans un fichier temporaire root, on valide avec visudo -cf, et on
# ne le met en place que s'il est syntaxiquement correct (sinon on abandonne).
echo "${NOTE} Installation du drop-in sudoers..." | tee -a "$LOG"
sudo install -m 0440 -o root -g root "$SYSTEMD_SRC/nas-backup.sudoers" /etc/sudoers.d/nas-backup.tmp
if sudo visudo -cf /etc/sudoers.d/nas-backup.tmp >>"$LOG" 2>&1; then
    sudo mv /etc/sudoers.d/nas-backup.tmp /etc/sudoers.d/nas-backup
    echo "${OK} /etc/sudoers.d/nas-backup installé et validé." | tee -a "$LOG"
else
    sudo rm -f /etc/sudoers.d/nas-backup.tmp
    echo "${ERROR} Le drop-in sudoers est invalide — abandon (rien n'a été activé)." | tee -a "$LOG"
    exit 1
fi

# ── 2. Unités systemd ────────────────────────────────────────────────────────
echo "${NOTE} Installation des unités systemd..." | tee -a "$LOG"
sudo install -m 0644 -o root -g root \
    "$SYSTEMD_SRC/nas-backup.service" \
    "$SYSTEMD_SRC/nas-backup.timer" \
    "$SYSTEMD_SRC/nas-backup-full.service" \
    "$SYSTEMD_SRC/nas-backup-full.timer" \
    /etc/systemd/system/
sudo systemctl daemon-reload
echo "${OK} Unités copiées + daemon-reload." | tee -a "$LOG"

# ── 3. Activation des timers ─────────────────────────────────────────────────
sudo systemctl enable --now nas-backup.timer nas-backup-full.timer 2>&1 | tee -a "$LOG"
echo "${OK} Timers activés (quotidien + mensuel --full)." | tee -a "$LOG"

printf "\n"
echo "${OK} Automatisation nas-backup opérationnelle." | tee -a "$LOG"
printf "${NOTE} Vérifs & commandes utiles :\n"
printf "   systemctl list-timers 'nas-backup*'        — prochaines exécutions\n"
printf "   systemctl start nas-backup.service         — lancer un backup maintenant (test)\n"
printf "   journalctl -u nas-backup.service -f         — suivre les logs en direct\n"
printf "   systemctl status nas-backup.timer           — état du timer quotidien\n"
