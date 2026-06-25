#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# nas-backup.sh — Sauvegarde Btrfs incrémentale vers le NAS via SSH (Rev0li)
#
# Stratégie :
#   1. Monte le top-level Btrfs (/dev/sda3, subvolid=5)
#   2. Crée un snapshot read-only du subvolume (root / home)
#   3. btrfs send [-p parent_précédent] | zstd | ssh nas-songsurf
#   4. En cas de succès : supprime l'ancien parent, garde le nouveau
#   5. Démonte le top-level
#
# Premier run  → envoi complet  (fichier *_full.btrfs.zst)
# Runs suivants → envoi incrémental (fichier *_inc.btrfs.zst, ~10× plus petit)
#
# Prérequis :
#   • snapper installé : ./install-scripts/snapper.sh
#   • NAS_DEST_PATH existant sur le NAS (créé automatiquement s'il est absent)
#   • Clé SSH fonctionnelle : ssh nas-songsurf true
#
# Usage :
#   ./nas-backup.sh                  # root + home
#   ./nas-backup.sh --root-only      # root uniquement
#   NAS_DEST_PATH=/data/bkp ./nas-backup.sh
#
# Restauration (depuis une nouvelle machine) :
#   ssh nas-songsurf "cat <NAS_DEST_PATH>/root-STAMP_full.btrfs.zst" \
#     | zstd -d | sudo btrfs receive /mnt/restore/
#   # Appliquer ensuite les fichiers _inc dans l'ordre chronologique.
#   # Voir INSTALL-revo.md § Restauration NAS.
# ═══════════════════════════════════════════════════════════════════════════

set -euo pipefail

# ── Configuration (à adapter) ─────────────────────────────────────────────────
NAS_HOST="nas-songsurf"
NAS_DEST_PATH="${NAS_DEST_PATH:-/volume1/backup-rev0/fedora_backup}"
# Device Btrfs — déduit automatiquement depuis fstab/findmnt
BTRFS_DEV="$(findmnt -n -o SOURCE / | sed 's/\[.*//')"

# ── Chemins internes ─────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="$SCRIPT_DIR/backups/nas-backup-state"
BTRFS_TOP="/run/nas-btrfs-top-$$"

# ── Couleurs ─────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "$(date '+%H:%M:%S') ${CYAN}→${NC} $1"; }
ok()   { echo -e "$(date '+%H:%M:%S') ${GREEN}✓${NC} $1"; }
warn() { echo -e "$(date '+%H:%M:%S') ${YELLOW}⚠${NC} $1"; }
die()  { echo -e "$(date '+%H:%M:%S') ${RED}✗${NC} $1" >&2; exit 1; }

# ── Arguments ────────────────────────────────────────────────────────────────
declare -a SUBVOLS=(root home)
for arg in "$@"; do
    case "$arg" in
        --root-only) SUBVOLS=(root) ;;
        *) die "Option inconnue : $arg" ;;
    esac
done

# ── Pré-vérifications ────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] && die "Ne pas lancer en root (sudo est appelé au besoin)."
command -v btrfs >/dev/null 2>&1 || die "btrfs-progs non installé (dnf install btrfs-progs)."
command -v zstd  >/dev/null 2>&1 || die "zstd non installé (dnf install zstd)."

log "Test de connectivité SSH → $NAS_HOST..."
ssh -o ConnectTimeout=8 -o BatchMode=yes "$NAS_HOST" true 2>/dev/null \
    || die "NAS $NAS_HOST inaccessible. Backup annulé."
ok "NAS accessible."

ssh "$NAS_HOST" "mkdir -p '$NAS_DEST_PATH'" \
    || die "Impossible de créer $NAS_DEST_PATH sur le NAS."

mkdir -p "$STATE_DIR"

# ── Montage du top-level Btrfs ───────────────────────────────────────────────
cleanup() {
    if mountpoint -q "$BTRFS_TOP" 2>/dev/null; then
        sudo umount "$BTRFS_TOP" 2>/dev/null || true
    fi
    sudo rmdir "$BTRFS_TOP" 2>/dev/null || true
}
trap cleanup EXIT

STAMP="$(date +%Y%m%d_%H%M%S)"
sudo mkdir -p "$BTRFS_TOP"
sudo mount -t btrfs -o subvolid=5 "$BTRFS_DEV" "$BTRFS_TOP"
log "Top-level Btrfs monté ($BTRFS_DEV → $BTRFS_TOP)."

# ── Envoi de chaque subvolume ────────────────────────────────────────────────
ERRORS=0

for SUBVOL in "${SUBVOLS[@]}"; do
    echo ""
    log "═══ Subvolume : $SUBVOL ═══"

    SUBVOL_PATH="$BTRFS_TOP/$SUBVOL"
    if [ ! -d "$SUBVOL_PATH" ]; then
        warn "$SUBVOL_PATH introuvable dans le top-level — ignoré."
        continue
    fi

    SNAP_NAME="${SUBVOL}-${STAMP}"
    SNAP_PATH="$BTRFS_TOP/$SNAP_NAME"
    PARENT_FILE="$STATE_DIR/${SUBVOL}.parent"

    # Créer le snapshot read-only
    log "Snapshot read-only → $SNAP_NAME"
    sudo btrfs subvolume snapshot -r "$SUBVOL_PATH" "$SNAP_PATH"
    ok "Snapshot créé."

    # Déterminer si envoi complet ou incrémental
    PARENT_ARG=""
    PARENT_NAME=""
    FILE_SUFFIX="_full"

    if [ -f "$PARENT_FILE" ]; then
        prev_name=$(cat "$PARENT_FILE")
        prev_path="$BTRFS_TOP/$prev_name"
        if [ -d "$prev_path" ]; then
            PARENT_ARG="-p $prev_path"
            PARENT_NAME="$prev_name"
            FILE_SUFFIX="_inc"
            log "Mode incrémental (parent : $prev_name)."
        else
            warn "Parent $prev_name absent du top-level — envoi complet."
        fi
    else
        log "Premier backup — envoi complet."
    fi

    NAS_FILE="${NAS_DEST_PATH}/${SNAP_NAME}${FILE_SUFFIX}.btrfs.zst"

    # Envoi : btrfs send | zstd | ssh
    # shellcheck disable=SC2086
    if sudo btrfs send $PARENT_ARG "$SNAP_PATH" \
           | zstd -T0 -1 -q \
           | ssh "$NAS_HOST" "cat > '$NAS_FILE'"; then
        ok "Envoyé → $NAS_HOST:$NAS_FILE"
        # Enregistrer dans le log NAS
        ssh "$NAS_HOST" \
            "echo \"$(date '+%Y-%m-%d %H:%M:%S') $SNAP_NAME${FILE_SUFFIX}\" >> '${NAS_DEST_PATH}/backup.log'"
        # Supprimer l'ancien parent local (libère de l'espace)
        if [ -n "$PARENT_NAME" ] && [ -d "$BTRFS_TOP/$PARENT_NAME" ]; then
            sudo btrfs subvolume delete "$BTRFS_TOP/$PARENT_NAME"
            log "Ancien parent supprimé : $PARENT_NAME"
        fi
        # Supprimer l'ancienne sauvegarde NAS (seulement si on vient d'envoyer un incrémental)
        if [ -n "$PARENT_NAME" ]; then
            for old_suffix in _full _inc; do
                old_nas_file="${NAS_DEST_PATH}/${PARENT_NAME}${old_suffix}.btrfs.zst"
                if ssh "$NAS_HOST" "[ -f '$old_nas_file' ]" 2>/dev/null; then
                    ssh "$NAS_HOST" "rm -f '$old_nas_file'"
                    log "Ancienne sauvegarde NAS supprimée : ${PARENT_NAME}${old_suffix}.btrfs.zst"
                fi
            done
        fi
        # Mémoriser le nouveau parent
        echo "$SNAP_NAME" > "$PARENT_FILE"
        ok "Parent mis à jour → $SNAP_NAME"
    else
        warn "Envoi échoué pour $SUBVOL. Snapshot local supprimé ; parent inchangé."
        sudo btrfs subvolume delete "$SNAP_PATH" 2>/dev/null || true
        ERRORS=$((ERRORS + 1))
    fi
done

echo ""
if [ "$ERRORS" -eq 0 ]; then
    ok "Backup NAS terminé avec succès (${STAMP})."
else
    warn "Backup terminé avec $ERRORS erreur(s) — voir les messages ci-dessus."
    exit 1
fi
