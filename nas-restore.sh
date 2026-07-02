#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# nas-restore.sh — Rejoue automatiquement une chaîne de backups NAS (Rev0li)
#
# Pendant opérationnel de nas-backup.sh : trouve le dernier full de chaque
# subvolume sur le NAS, les incréments qui le suivent, VÉRIFIE les sidecars
# .sha256 (côté NAS, sans transfert), puis applique le tout dans l'ordre via
# btrfs receive et promeut le résultat en subvolume `root` / `home`.
# Remplace l'étape la plus risquée de restore.md §7 (rejeu manuel de chaîne).
#
# Le DERNIER snapshot reçu est conservé dans le top-level : c'est le parent
# qui permet à nas-backup.sh de reprendre les incrémentaux après restauration
# (les state-files backups/nas-backup-state/ reviennent avec `home`).
#
# À lancer depuis un live USB (ou une machine saine) :
#   sudo mount -t btrfs -o subvolid=5 /dev/sdX3 /mnt/top
#
# Usage :
#   ./nas-restore.sh --list                        # voir ce qui est restaurable
#   ./nas-restore.sh --dest /mnt/top               # restaure root + home
#   ./nas-restore.sh --dest /mnt/top --subvol root # un seul subvolume
#   ./nas-restore.sh --boot /mnt/restore/boot --efi /mnt/restore/boot/efi
#   ./nas-restore.sh --sysinfo ./sysinfo           # récupère l'identité système
#                                                  # (partitions, UUID, fstab...)
#
# Options :
#   --dest DIR        top-level Btrfs monté (subvolid=5) où recevoir les subvols
#   --subvol NAME     root|home (répétable) — défaut : root home
#   --boot DIR        extrait le dernier boot-*.tar.zst dans DIR
#   --efi DIR         extrait le dernier boot-efi-*.tar.zst dans DIR
#   --sysinfo DIR     extrait le dernier sysinfo-*.tar.zst dans DIR
#   --list            liste les chaînes disponibles et sort
#   --keep-snapshots  garde TOUS les subvolumes intermédiaires reçus
#   --no-verify       saute la vérification sha256 (déconseillé)
#
# Live USB sans ~/.ssh/config : surcharger l'hôte et le chemin —
#   NAS_HOST=admin@192.168.1.42 NAS_DEST_PATH=/volume1/backup-rev0/fedora_backup \
#     ./nas-restore.sh --list
#
# Procédure bare-metal complète (partitionnement, chroot, GRUB) : restore.md
# ═══════════════════════════════════════════════════════════════════════════

set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────
NAS_HOST="${NAS_HOST:-nas-songsurf}"
NAS_DEST_PATH="${NAS_DEST_PATH:-/volume1/backup-rev0/fedora_backup}"

# ── Couleurs ─────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "$(date '+%H:%M:%S') ${CYAN}→${NC} $1"; }
ok()   { echo -e "$(date '+%H:%M:%S') ${GREEN}✓${NC} $1"; }
warn() { echo -e "$(date '+%H:%M:%S') ${YELLOW}⚠${NC} $1"; }
die()  { echo -e "$(date '+%H:%M:%S') ${RED}✗${NC} $1" >&2; exit 1; }

usage() { sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; }

# ── Arguments ────────────────────────────────────────────────────────────────
DEST=""; BOOT_DIR=""; EFI_DIR=""; SYSINFO_DIR=""
LIST=0; VERIFY=1; KEEP_SNAPSHOTS=0
declare -a SUBVOLS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --dest)           DEST="${2:?--dest requiert un chemin}"; shift 2 ;;
        --subvol)         SUBVOLS+=("${2:?--subvol requiert un nom}"); shift 2 ;;
        --boot)           BOOT_DIR="${2:?--boot requiert un chemin}"; shift 2 ;;
        --efi)            EFI_DIR="${2:?--efi requiert un chemin}"; shift 2 ;;
        --sysinfo)        SYSINFO_DIR="${2:?--sysinfo requiert un chemin}"; shift 2 ;;
        --list)           LIST=1; shift ;;
        --no-verify)      VERIFY=0; shift ;;
        --keep-snapshots) KEEP_SNAPSHOTS=1; shift ;;
        -h|--help)        usage; exit 0 ;;
        *)                die "Option inconnue : $1 (voir --help)" ;;
    esac
done
[ ${#SUBVOLS[@]} -eq 0 ] && SUBVOLS=(root home)

if [ "$LIST" -eq 0 ] && [ -z "$DEST" ] && [ -z "$BOOT_DIR" ] && [ -z "$EFI_DIR" ] && [ -z "$SYSINFO_DIR" ]; then
    usage
    exit 1
fi

# Live USB → souvent root ; machine normale → sudo à la demande.
SUDO="sudo"
[ "$(id -u)" -eq 0 ] && SUDO=""

# ── Inventaire NAS ───────────────────────────────────────────────────────────
log "Connexion à $NAS_HOST..."
FILES="$(ssh -o ConnectTimeout=10 "$NAS_HOST" "ls -1 '$NAS_DEST_PATH'")" \
    || die "NAS inaccessible ou $NAS_DEST_PATH introuvable (NAS_HOST/NAS_DEST_PATH surchargeables en env)."
ok "NAS accessible — $(printf '%s\n' "$FILES" | grep -c '\.zst$' || true) fichier(s) .zst."

# chain_for <subvol> : affiche, dans l'ordre d'application, le dernier full
# puis chaque incrément qui le suit (STAMP lexicographique = chronologique).
chain_for() {
    local sv="$1" full full_stamp
    full="$(printf '%s\n' "$FILES" | grep -E "^${sv}-[0-9]{8}_[0-9]{6}_full\.btrfs\.zst$" | sort | tail -1)"
    [ -z "$full" ] && return 1
    full_stamp="${full#"${sv}"-}"; full_stamp="${full_stamp%_full.btrfs.zst}"
    printf '%s\n' "$full"
    printf '%s\n' "$FILES" \
        | grep -E "^${sv}-[0-9]{8}_[0-9]{6}_inc\.btrfs\.zst$" | sort \
        | while IFS= read -r f; do
              local s="${f#"${sv}"-}"; s="${s%_inc.btrfs.zst}"
              [ "$s" \> "$full_stamp" ] && printf '%s\n' "$f"
          done
    return 0
}

# latest_of <prefix> : dernier "<prefix>-STAMP.tar.zst" (vide si aucun ;
# ne retourne jamais ≠0, sinon set -e tuerait le script sur un grep vide)
latest_of() {
    printf '%s\n' "$FILES" | grep -E "^${1}-[0-9]{8}_[0-9]{6}\.tar\.zst$" | sort | tail -1 || true
}

# verify_file <fichier> : sha256sum -c côté NAS (aucun transfert réseau)
verify_file() {
    local f="$1"
    [ "$VERIFY" -eq 1 ] || return 0
    if ! printf '%s\n' "$FILES" | grep -qx "${f}.sha256"; then
        warn "Pas de sidecar .sha256 pour $f (backup antérieur au durcissement) — vérification sautée."
        return 0
    fi
    log "Vérification sha256 (côté NAS) : $f"
    ssh "$NAS_HOST" "cd '$NAS_DEST_PATH' && sha256sum -c --quiet '${f}.sha256'" \
        || die "CORRUPTION détectée : $f — chaîne non fiable, ne pas restaurer telle quelle."
    ok "Intègre : $f"
}

# ── Mode --list ──────────────────────────────────────────────────────────────
if [ "$LIST" -eq 1 ]; then
    for sv in "${SUBVOLS[@]}"; do
        echo ""
        log "═══ Chaîne '$sv' (ordre d'application) ═══"
        if chain="$(chain_for "$sv")"; then
            printf '%s\n' "$chain" | nl -w2 -s'. '
        else
            warn "Aucun full pour '$sv' — chaîne non restaurable (relancer nas-backup.sh --full)."
        fi
    done
    echo ""
    log "═══ Archives ═══"
    for p in boot boot-efi sysinfo; do
        f="$(latest_of "$p")"
        [ -n "$f" ] && echo "   $f" || warn "aucun ${p}-*.tar.zst"
    done
    exit 0
fi

# ── Restauration des subvolumes Btrfs ────────────────────────────────────────
if [ -n "$DEST" ]; then
    [ -d "$DEST" ] || die "$DEST n'existe pas."
    [ "$(findmnt -n -o FSTYPE --target "$DEST")" = "btrfs" ] || die "$DEST n'est pas sur un filesystem Btrfs."
    findmnt -n -o OPTIONS --target "$DEST" | grep -qE 'subvolid=5|subvol=/(\s|,|$)' \
        || warn "$DEST ne semble pas être le top-level (subvolid=5) — les subvols seront reçus là où tu es."

    for sv in "${SUBVOLS[@]}"; do
        echo ""
        log "═══ Restauration du subvolume '$sv' ═══"
        if ! chain="$(chain_for "$sv")"; then
            warn "Aucun full pour '$sv' sur le NAS — ignoré."
            continue
        fi
        [ -e "$DEST/$sv" ] && die "$DEST/$sv existe déjà — le supprimer/renommer d'abord (btrfs subvolume delete)."

        log "Chaîne : $(printf '%s\n' "$chain" | wc -l) fichier(s)."
        while IFS= read -r f; do verify_file "$f"; done <<< "$chain"

        last_name=""
        while IFS= read -r f; do
            log "Réception : $f"
            ssh "$NAS_HOST" "cat '$NAS_DEST_PATH/$f'" | zstd -d | $SUDO btrfs receive "$DEST"
            last_name="${f%_full.btrfs.zst}"; last_name="${last_name%_inc.btrfs.zst}"
            ok "Reçu : $last_name"
        done <<< "$chain"

        $SUDO btrfs subvolume snapshot "$DEST/$last_name" "$DEST/$sv" >/dev/null
        ok "Subvolume '$sv' promu depuis $last_name."

        if [ "$KEEP_SNAPSHOTS" -eq 0 ]; then
            while IFS= read -r f; do
                name="${f%_full.btrfs.zst}"; name="${name%_inc.btrfs.zst}"
                [ "$name" = "$last_name" ] && continue
                $SUDO btrfs subvolume delete "$DEST/$name" >/dev/null
                log "Snapshot intermédiaire supprimé : $name"
            done <<< "$chain"
            ok "Snapshot $last_name conservé (parent pour reprendre les incrémentaux)."
        fi
    done
fi

# ── Archives tar (boot, efi, sysinfo) ────────────────────────────────────────
restore_tar() {
    local prefix="$1" dir="$2"; shift 2
    local extra=("$@") f
    echo ""
    log "═══ Extraction '$prefix' ═══"
    f="$(latest_of "$prefix")"
    [ -z "$f" ] && { warn "Aucun ${prefix}-*.tar.zst sur le NAS — ignoré."; return; }
    [ -d "$dir" ] || die "$dir n'existe pas (le créer/monter d'abord)."
    verify_file "$f"
    log "Extraction : $f → $dir"
    ssh "$NAS_HOST" "cat '$NAS_DEST_PATH/$f'" | zstd -d | $SUDO tar -xpf - ${extra[@]+"${extra[@]}"} -C "$dir"
    ok "$prefix restauré dans $dir."
}

[ -n "$BOOT_DIR" ]    && restore_tar boot     "$BOOT_DIR" --selinux --acls --xattrs
[ -n "$EFI_DIR" ]     && restore_tar boot-efi "$EFI_DIR"
[ -n "$SYSINFO_DIR" ] && restore_tar sysinfo  "$SYSINFO_DIR"

echo ""
ok "Restauration NAS terminée."
log "Suite bare-metal (fstab, chroot, GRUB, efibootmgr) : voir restore.md §8-11."
