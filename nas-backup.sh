#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# nas-backup.sh — Sauvegarde Btrfs incrémentale vers le NAS via SSH (Rev0li)
#
# Stratégie :
#   1. Monte le top-level Btrfs (/dev/sda3, subvolid=5)
#   2. Crée un snapshot read-only du subvolume (root / home)
#   3. btrfs send [-p parent_précédent] | zstd | ssh nas-songsurf
#      → sha256 calculé PENDANT l'upload, puis relu depuis le disque NAS et
#        comparé ; sidecar <fichier>.sha256 déposé à côté sur le NAS
#   4. En cas de succès VÉRIFIÉ seulement : supprime l'ancien parent local,
#      purge l'ancienne chaîne NAS (si --full), garde le nouveau parent
#   5. Démonte le top-level
#   6. Archive en plus /boot (ext4) et /boot/efi (vfat) en tar.zst
#      (partitions hors Btrfs, indispensables pour un système bootable —
#      pas d'incrémental ici, elles changent rarement et sont petites)
#   7. Pousse un sysinfo-STAMP.tar.zst : table de partitions (sgdisk --backup),
#      blkid, lsblk, fstab, efibootmgr, subvolumes — l'« identité système »
#      nécessaire pour repartitionner à l'identique en bare-metal restore
#
# Premier run  → envoi complet  (fichier *_full.btrfs.zst)
# Runs suivants → envoi incrémental (fichier *_inc.btrfs.zst, ~10× plus petit)
# La chaîne complète (full + tous les incréments depuis) reste sur le NAS :
# un incrément seul n'est pas restaurable sans son parent, donc rien n'est
# purgé tant qu'un nouveau full VÉRIFIÉ n'a pas remplacé toute la chaîne (--full).
# /boot et /boot/efi → toujours en full (*.tar.zst), une seule version gardée sur le NAS
#
# Intégrité : chaque fichier est hashé (sha256) pendant l'upload puis RELU
# depuis le disque NAS et comparé. Sidecar <fichier>.sha256 sur le NAS —
# vérifiable à tout moment : ssh nas-songsurf "cd <NAS_DEST_PATH> && sha256sum -c *.sha256"
# Aucune purge (parent local, chaîne NAS, tar boot) avant que ça passe.
#
# Prérequis :
#   • snapper installé : ./install-scripts/snapper.sh
#   • NAS_DEST_PATH existant sur le NAS (créé automatiquement s'il est absent)
#   • Clé SSH fonctionnelle : ssh nas-songsurf true
#
# Usage :
#   ./nas-backup.sh                  # root + home + boot + boot/efi (incrémental si possible)
#   ./nas-backup.sh --root-only      # root uniquement (home exclu ; boot/efi inclus)
#   ./nas-backup.sh --full           # force un nouveau full pour root/home ;
#                                    # l'ancienne chaîne NAS n'est purgée qu'après
#                                    # vérification sha256 du nouveau full
#   NAS_DEST_PATH=/data/bkp ./nas-backup.sh
#
# Astuce : le timer systemd (voir systemd/user/) rappelle un --full 1×/semaine
# (dimanche 20:30) pour borner la longueur de la chaîne d'incréments — une
# chaîne courte = restore plus simple et moins de points de défaillance.
#
# Restauration (depuis une nouvelle machine / live USB) :
#   ./nas-restore.sh --list                    # voir ce qui est restaurable
#   ./nas-restore.sh --dest /mnt/top           # rejoue la chaîne automatiquement
#   (vérifie les .sha256, applique full + incréments dans l'ordre, promeut les
#    subvolumes root/home. Procédure complète — partitionnement, boot/efi,
#    chroot, GRUB : voir restore.md.)
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
FORCE_FULL=0
for arg in "$@"; do
    case "$arg" in
        --root-only) SUBVOLS=(root) ;;
        --full) FORCE_FULL=1 ;;
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
UP_SUM_FILE="$STATE_DIR/.upload.sha256"

# ── Upload vérifié vers le NAS ───────────────────────────────────────────────
# upload_verified <fichier_nas> : lit le flux sur stdin, l'envoie sur le NAS,
# calcule le sha256 local PENDANT l'envoi, puis RELIT le fichier depuis le
# disque NAS et compare (détecte troncature, disque plein, bitrot immédiat).
# Si tout est bon : dépose un sidecar <fichier>.sha256 (format `sha256sum -c`).
# Sinon : supprime le fichier NAS et retourne 1 — l'appelant ne doit RIEN
# purger (parent local, chaîne, ancien tar) tant que ce retour n'est pas 0.
upload_verified() {
    local nas_file="$1"
    local base local_sum remote_sum i
    base="$(basename "$nas_file")"

    : > "$UP_SUM_FILE"
    if ! tee >(sha256sum | cut -d' ' -f1 > "$UP_SUM_FILE") \
            | ssh "$NAS_HOST" "cat > '$nas_file'"; then
        warn "Envoi échoué : $base"
        ssh "$NAS_HOST" "rm -f '$nas_file'" 2>/dev/null || true
        return 1
    fi

    # Le hash local est écrit par un process substitution asynchrone → on lui
    # laisse le temps de se terminer (quelques ms en pratique).
    for i in {1..100}; do [ -s "$UP_SUM_FILE" ] && break; sleep 0.1; done
    local_sum="$(cat "$UP_SUM_FILE")"

    remote_sum="$(ssh "$NAS_HOST" "sha256sum '$nas_file'" 2>/dev/null | cut -d' ' -f1)"

    if [ -z "$local_sum" ] || [ "$remote_sum" != "$local_sum" ]; then
        warn "Checksum invalide pour $base (local=${local_sum:-?} nas=${remote_sum:-?}) — fichier NAS supprimé."
        ssh "$NAS_HOST" "rm -f '$nas_file'" 2>/dev/null || true
        return 1
    fi

    ssh "$NAS_HOST" "echo '$local_sum  $base' > '${nas_file}.sha256'"
    ok "Intégrité vérifiée sur le NAS : $base"
}

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
    CHAIN_FILE="$STATE_DIR/${SUBVOL}.chain"

    # Créer le snapshot read-only
    log "Snapshot read-only → $SNAP_NAME"
    sudo btrfs subvolume snapshot -r "$SUBVOL_PATH" "$SNAP_PATH"
    ok "Snapshot créé."

    # Déterminer si envoi complet ou incrémental
    PARENT_ARG=""
    FILE_SUFFIX="_full"
    PREV_LOCAL_NAME=""
    [ -f "$PARENT_FILE" ] && PREV_LOCAL_NAME=$(cat "$PARENT_FILE")

    if [ -z "$PREV_LOCAL_NAME" ]; then
        log "Premier backup — envoi complet."
    elif [ "$FORCE_FULL" -eq 1 ]; then
        log "Full forcé (--full) — la chaîne NAS précédente sera purgée après succès."
    elif [ -d "$BTRFS_TOP/$PREV_LOCAL_NAME" ]; then
        PARENT_ARG="-p $BTRFS_TOP/$PREV_LOCAL_NAME"
        FILE_SUFFIX="_inc"
        log "Mode incrémental (parent : $PREV_LOCAL_NAME)."
    else
        warn "Parent $PREV_LOCAL_NAME absent du top-level — envoi complet."
    fi

    NAS_FILE="${NAS_DEST_PATH}/${SNAP_NAME}${FILE_SUFFIX}.btrfs.zst"

    # Envoi : btrfs send | zstd | upload vérifié (sha256 comparé après relecture NAS)
    # shellcheck disable=SC2086
    if sudo btrfs send $PARENT_ARG "$SNAP_PATH" \
           | zstd -T0 -1 -q \
           | upload_verified "$NAS_FILE"; then
        ok "Envoyé → $NAS_HOST:$NAS_FILE"
        # Enregistrer dans le log NAS
        ssh "$NAS_HOST" \
            "echo \"$(date '+%Y-%m-%d %H:%M:%S') $SNAP_NAME${FILE_SUFFIX}\" >> '${NAS_DEST_PATH}/backup.log'"
        # Supprimer l'ancien parent local (libère de l'espace), qu'il ait servi de diff ou non
        if [ -n "$PREV_LOCAL_NAME" ] && [ -d "$BTRFS_TOP/$PREV_LOCAL_NAME" ]; then
            sudo btrfs subvolume delete "$BTRFS_TOP/$PREV_LOCAL_NAME"
            log "Ancien parent local supprimé : $PREV_LOCAL_NAME"
        fi

        if [ "$FILE_SUFFIX" = "_full" ]; then
            # Nouveau full VÉRIFIÉ → toute l'ancienne chaîne NAS devient obsolète
            if [ -f "$CHAIN_FILE" ]; then
                while IFS= read -r old_file; do
                    [ -z "$old_file" ] && continue
                    if ssh "$NAS_HOST" "[ -f '${NAS_DEST_PATH}/${old_file}' ]" 2>/dev/null; then
                        ssh "$NAS_HOST" "rm -f '${NAS_DEST_PATH}/${old_file}' '${NAS_DEST_PATH}/${old_file}.sha256'"
                        log "Ancienne sauvegarde NAS purgée : $old_file"
                    fi
                done < "$CHAIN_FILE"
            fi
            echo "${SNAP_NAME}${FILE_SUFFIX}.btrfs.zst" > "$CHAIN_FILE"
        else
            # Incrémental : on garde tout (full + incréments précédents) pour rester restaurable
            echo "${SNAP_NAME}${FILE_SUFFIX}.btrfs.zst" >> "$CHAIN_FILE"
        fi

        # Mémoriser le nouveau parent
        echo "$SNAP_NAME" > "$PARENT_FILE"
        ok "Parent mis à jour → $SNAP_NAME"
    else
        # Échec du send/zstd OU de l'upload/vérification (pipefail couvre les deux).
        # Si btrfs send est mort en cours de route, un fichier tronqué peut avoir
        # passé la vérification (hash du flux tronqué) → on nettoie NAS + sidecar.
        warn "Envoi/vérification échoué pour $SUBVOL. Snapshot local supprimé ; parent et chaîne inchangés."
        ssh "$NAS_HOST" "rm -f '$NAS_FILE' '${NAS_FILE}.sha256'" 2>/dev/null || true
        sudo btrfs subvolume delete "$SNAP_PATH" 2>/dev/null || true
        ERRORS=$((ERRORS + 1))
    fi
done

# ── Sauvegarde des partitions non-Btrfs (boot, EFI) ─────────────────────────
# Pas de snapshot/incrémental possible hors Btrfs : on archive tel quel.
# Une seule version est gardée sur le NAS (l'ancienne est supprimée après succès).
backup_plain_partition() {
    local mount_point="$1" label="$2"
    shift 2
    local tar_extra_args=("$@")

    echo ""
    log "═══ Partition : $label ($mount_point) ═══"

    if ! mountpoint -q "$mount_point" 2>/dev/null; then
        warn "$mount_point n'est pas monté — ignoré."
        return
    fi

    local LAST_FILE="$STATE_DIR/${label}.last"
    local SNAP_NAME="${label}-${STAMP}"
    local NAS_FILE="${NAS_DEST_PATH}/${SNAP_NAME}.tar.zst"

    log "Archivage → $NAS_FILE"
    if sudo tar "${tar_extra_args[@]}" -cpf - -C "$mount_point" . \
            | zstd -T0 -3 -q \
            | upload_verified "$NAS_FILE"; then
        ok "Envoyé → $NAS_HOST:$NAS_FILE"
        ssh "$NAS_HOST" \
            "echo \"$(date '+%Y-%m-%d %H:%M:%S') $SNAP_NAME\" >> '${NAS_DEST_PATH}/backup.log'"

        # L'ancienne version n'est supprimée qu'APRÈS vérification de la nouvelle
        if [ -f "$LAST_FILE" ]; then
            local prev_name prev_nas_file
            prev_name=$(cat "$LAST_FILE")
            prev_nas_file="${NAS_DEST_PATH}/${prev_name}.tar.zst"
            if [ "$prev_name" != "$SNAP_NAME" ] && ssh "$NAS_HOST" "[ -f '$prev_nas_file' ]" 2>/dev/null; then
                ssh "$NAS_HOST" "rm -f '$prev_nas_file' '${prev_nas_file}.sha256'"
                log "Ancienne sauvegarde NAS supprimée : ${prev_name}.tar.zst"
            fi
        fi
        echo "$SNAP_NAME" > "$LAST_FILE"
        ok "Dernière sauvegarde mise à jour → $SNAP_NAME"
    else
        warn "Envoi/vérification échoué pour $label."
        ssh "$NAS_HOST" "rm -f '$NAS_FILE' '${NAS_FILE}.sha256'" 2>/dev/null || true
        ERRORS=$((ERRORS + 1))
    fi
}

backup_plain_partition /boot boot --selinux --acls --xattrs
backup_plain_partition /boot/efi boot-efi

# ── Identité système (sysinfo) ───────────────────────────────────────────────
# Capture tout ce qu'il faut pour repartitionner À L'IDENTIQUE lors d'un
# bare-metal restore : table de partitions, UUID, fstab, entrées EFI,
# subvolumes. Quelques Ko — une seule version gardée, comme boot/efi.
backup_sysinfo() {
    echo ""
    log "═══ Identité système (sysinfo) ═══"

    local SNAP_NAME="sysinfo-${STAMP}"
    local NAS_FILE="${NAS_DEST_PATH}/${SNAP_NAME}.tar.zst"
    local LAST_FILE="$STATE_DIR/sysinfo.last"
    local TMP
    TMP="$(mktemp -d)"

    # Disques physiques portant /, /boot, /boot/efi → sauvegarde GPT (sgdisk)
    local mp src
    local -a devs=()
    for mp in / /boot /boot/efi; do
        src="$(findmnt -n -o SOURCE "$mp" 2>/dev/null | sed 's/\[.*//')" || true
        [ -n "$src" ] && [ -b "$src" ] && devs+=("$src")
    done
    if command -v sgdisk >/dev/null 2>&1 && [ ${#devs[@]} -gt 0 ]; then
        local d
        while IFS= read -r d; do
            [ -z "$d" ] && continue
            sudo sgdisk --backup="$TMP/sgdisk-${d}.gpt.bin" "/dev/$d" >/dev/null 2>&1 \
                || warn "sgdisk --backup /dev/$d impossible."
        done < <(lsblk -no PKNAME "${devs[@]}" 2>/dev/null | sort -u)
    else
        warn "sgdisk indisponible — table de partitions non sauvegardée (dnf install gdisk)."
    fi

    sudo blkid > "$TMP/blkid.txt" 2>/dev/null || true
    lsblk -f -o NAME,FSTYPE,LABEL,UUID,PARTUUID,SIZE,MOUNTPOINTS > "$TMP/lsblk.txt" 2>/dev/null || true
    cat /etc/fstab > "$TMP/fstab" 2>/dev/null || true
    sudo efibootmgr -v > "$TMP/efibootmgr.txt" 2>/dev/null || true
    sudo btrfs subvolume list / > "$TMP/btrfs-subvolumes.txt" 2>/dev/null || true
    {
        echo "date=$STAMP"
        echo "host=$(hostname)"
        echo "kernel=$(uname -r)"
        echo "fedora=$(. /etc/os-release 2>/dev/null && echo "${VERSION_ID:-?}")"
    } > "$TMP/manifest.txt"

    if tar -cf - -C "$TMP" . | zstd -T0 -3 -q | upload_verified "$NAS_FILE"; then
        ok "Envoyé → $NAS_HOST:$NAS_FILE"
        ssh "$NAS_HOST" \
            "echo \"$(date '+%Y-%m-%d %H:%M:%S') $SNAP_NAME\" >> '${NAS_DEST_PATH}/backup.log'"

        if [ -f "$LAST_FILE" ]; then
            local prev_name prev_nas_file
            prev_name=$(cat "$LAST_FILE")
            prev_nas_file="${NAS_DEST_PATH}/${prev_name}.tar.zst"
            if [ "$prev_name" != "$SNAP_NAME" ] && ssh "$NAS_HOST" "[ -f '$prev_nas_file' ]" 2>/dev/null; then
                ssh "$NAS_HOST" "rm -f '$prev_nas_file' '${prev_nas_file}.sha256'"
                log "Ancien sysinfo NAS supprimé : ${prev_name}.tar.zst"
            fi
        fi
        echo "$SNAP_NAME" > "$LAST_FILE"
    else
        warn "Envoi/vérification échoué pour sysinfo."
        ssh "$NAS_HOST" "rm -f '$NAS_FILE' '${NAS_FILE}.sha256'" 2>/dev/null || true
        ERRORS=$((ERRORS + 1))
    fi

    rm -rf "$TMP"
}

backup_sysinfo

echo ""
if [ "$ERRORS" -eq 0 ]; then
    ok "Backup NAS terminé avec succès (${STAMP})."
else
    warn "Backup terminé avec $ERRORS erreur(s) — voir les messages ci-dessus."
    exit 1
fi
