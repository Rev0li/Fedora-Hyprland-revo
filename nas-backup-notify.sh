#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# nas-backup-notify.sh — Rappel INTERACTIF de sauvegarde NAS (Rev0li)
#
# Déclenché par un timer systemd --user (voir systemd/user/). N'exécute PAS le
# backup lui-même : il envoie une notification swaync avec un bouton
# « Lancer ». Au clic, ouvre un terminal kitty qui lance nas-backup.sh — donc
# sudo y demande mot de passe + touch YubiKey de façon interactive.
# → Aucun NOPASSWD, rien ne part vers le NAS sans une action consciente.
#
# Usage :
#   nas-backup-notify.sh          # rappel incrémental (se tait si backup < 20h)
#   nas-backup-notify.sh --full   # rappel du full hebdomadaire (toujours notifié)
# ═══════════════════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAS_SCRIPT="$SCRIPT_DIR/nas-backup.sh"
STATE_FILE="$SCRIPT_DIR/backups/nas-backup-state/root.parent"

FULL=0
[ "${1:-}" = "--full" ] && FULL=1

# ── Âge du dernier backup réussi (mtime de root.parent) ──────────────────────
if [ -f "$STATE_FILE" ]; then
    last=$(stat -c %Y "$STATE_FILE"); now=$(date +%s)
    age_h=$(( (now - last) / 3600 )); age_d=$(( (now - last) / 86400 ))
    if   [ "$age_d" -eq 0 ]; then age_txt="aujourd'hui (il y a ${age_h} h)"
    elif [ "$age_d" -eq 1 ]; then age_txt="hier"
    else                          age_txt="il y a ${age_d} jours"; fi
else
    age_h=999999; age_txt="jamais"
fi

# Rappel incrémental : ne pas déranger si une sauvegarde est très récente.
if [ "$FULL" -eq 0 ] && [ "$age_h" -lt 20 ]; then
    exit 0
fi

if [ "$FULL" -eq 1 ]; then
    TITLE="Sauvegarde NAS hebdomadaire (complète)"
    BODY="Dernier backup : ${age_txt}. Lancer un envoi COMPLET (--full) ?"
    RUN_CMD="$NAS_SCRIPT --full"
else
    TITLE="Sauvegarde NAS due"
    BODY="Dernier backup : ${age_txt}. Lancer une sauvegarde incrémentale ?"
    RUN_CMD="$NAS_SCRIPT"
fi

# ── Notification persistante avec bouton ─────────────────────────────────────
# -A attend l'action ; -t 0 = ne s'efface pas seule. timeout dur de 4h pour que
# le service ne reste pas bloqué si l'on ne clique jamais.
action="$(timeout 4h notify-send --app-name='Backup NAS' --icon=drive-harddisk \
    --urgency=normal -t 0 \
    -A 'run=Lancer maintenant' \
    "$TITLE" "$BODY" 2>/dev/null || true)"

if [ "$action" = "run" ]; then
    # Terminal détaché : le backup s'y déroule, sudo y réclame password + YubiKey.
    inner="$RUN_CMD; echo; read -rp 'Sauvegarde terminée — Entrée pour fermer cette fenêtre…'"
    setsid -f kitty --title='Backup NAS' bash -lc "$inner" >/dev/null 2>&1 || true
fi
