#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# restore.sh — Rejoue un snapshot créé par backup.sh (Rev0li)
#
# Étapes (dans l'ordre, car les paquets DNF peuvent dépendre des dépôts) :
#   1. Active les dépôts COPR
#   2. Réactive RPM Fusion + dépôts tiers (sinon akmod-nvidia & co sautés en silence)
#   3. Installe les paquets DNF
#   4. Recrée les remotes Flatpak puis installe les applications
#   5. Restaure les configs ~/.config (sauvegarde l'existant avant d'écraser)
#
# Idempotent : DNF/Flatpak ignorent ce qui est déjà installé ; relançable.
#
# Usage :
#   ./restore.sh                 # restaure le snapshot `latest`
#   ./restore.sh 20260623_141500 # restaure un snapshot précis
#   ./restore.sh latest -y       # sans confirmation pour les configs
#   ./restore.sh --no-configs    # paquets seulement, pas les configs
# ═══════════════════════════════════════════════════════════════════════════

set -euo pipefail

# ── Couleurs ───────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'

# ── Arguments ──────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_ROOT="${BACKUP_ROOT:-$SCRIPT_DIR/backups}"
SNAP_NAME="latest"
ASSUME_YES=0
DO_CONFIGS=1

for arg in "$@"; do
  case "$arg" in
    -y|--yes)     ASSUME_YES=1 ;;
    --no-configs) DO_CONFIGS=0 ;;
    -*)           echo "Option inconnue : $arg" >&2; exit 1 ;;
    *)            SNAP_NAME="$arg" ;;
  esac
done

SNAP_DIR="$BACKUP_ROOT/$SNAP_NAME"
[ -d "$SNAP_DIR" ] || { echo -e "${RED}✗${NC} Snapshot introuvable : $SNAP_DIR" >&2; exit 1; }
# Résout le lien `latest` vers son vrai nom pour les logs
SNAP_REAL="$(basename "$(readlink -f "$SNAP_DIR")")"
LOG="$SNAP_DIR/restore.log"

log()  { echo -e "$(date '+%H:%M:%S') ${CYAN}→${NC} $1" | tee -a "$LOG"; }
ok()   { echo -e "$(date '+%H:%M:%S') ${GREEN}✓${NC} $1" | tee -a "$LOG"; }
warn() { echo -e "$(date '+%H:%M:%S') ${YELLOW}⚠${NC} $1" | tee -a "$LOG"; }

if [[ $EUID -eq 0 ]]; then
  echo -e "${RED}✗${NC} Ne pas lancer en root (sudo est appelé au besoin)." >&2
  exit 1
fi

log "Restauration du snapshot ${SNAP_REAL}"

# ── 1. Dépôts COPR ─────────────────────────────────────────────────────────
if [ -s "$SNAP_DIR/copr-repos.txt" ]; then
  log "Activation des dépôts COPR..."
  while IFS= read -r repo; do
    [ -z "$repo" ] && continue
    if sudo dnf copr enable -y "$repo" 2>>"$LOG"; then
      ok "COPR activé : $repo"
    else
      warn "Échec activation COPR : $repo"
    fi
  done <"$SNAP_DIR/copr-repos.txt"
else
  log "Aucun dépôt COPR à activer."
fi

# ── 2. RPM Fusion ──────────────────────────────────────────────────────────
if [ -s "$SNAP_DIR/rpmfusion.txt" ]; then
  log "Réactivation des dépôts RPM Fusion..."
  FEDORA_VER="$(rpm -E %fedora)"
  while IFS= read -r rel; do
    [ -z "$rel" ] && continue
    if rpm -q --quiet "$rel"; then
      ok "RPM Fusion déjà présent : $rel"
      continue
    fi
    flavor="${rel#rpmfusion-}"; flavor="${flavor%-release}"   # free | nonfree
    url="https://mirrors.rpmfusion.org/${flavor}/fedora/${rel}-${FEDORA_VER}.noarch.rpm"
    if sudo dnf install -y "$url" 2>>"$LOG"; then
      ok "RPM Fusion activé : $rel"
    else
      warn "Échec RPM Fusion : $rel — les paquets qui en dépendent (akmod-nvidia...) seront SAUTÉS !"
    fi
  done <"$SNAP_DIR/rpmfusion.txt"
else
  log "Aucun dépôt RPM Fusion à réactiver (snapshot ancien ou machine sans RPM Fusion)."
fi

# Dépôts tiers (.repo copiés par backup.sh : brave, vscode, docker...)
if [ -d "$SNAP_DIR/yum-repos-tiers" ] && ls "$SNAP_DIR/yum-repos-tiers"/*.repo >/dev/null 2>&1; then
  log "Restauration des dépôts tiers (.repo)..."
  for repof in "$SNAP_DIR/yum-repos-tiers"/*.repo; do
    base="$(basename "$repof")"
    if [ -f "/etc/yum.repos.d/$base" ]; then
      ok "Dépôt tiers déjà présent : $base"
    elif sudo install -m 0644 "$repof" "/etc/yum.repos.d/$base" 2>>"$LOG"; then
      ok "Dépôt tiers restauré : $base"
    else
      warn "Échec restauration dépôt tiers : $base"
    fi
  done
fi

# ── 3. Paquets DNF ─────────────────────────────────────────────────────────
if [ -s "$SNAP_DIR/dnf-userinstalled.txt" ]; then
  log "Installation des paquets DNF (déjà installés ignorés)..."
  # --skip-unavailable (DNF5) : ne casse pas si un paquet n'existe plus.
  if xargs -a "$SNAP_DIR/dnf-userinstalled.txt" -r \
       sudo dnf install -y --skip-unavailable 2>&1 | tee -a "$LOG"; then
    ok "Paquets DNF traités."
  else
    warn "dnf a renvoyé une erreur — voir $LOG."
  fi
else
  warn "Liste DNF vide ou absente."
fi

# ── 4. Applications Flatpak ────────────────────────────────────────────────
if [ -s "$SNAP_DIR/flatpak-apps.txt" ]; then
  if command -v flatpak >/dev/null 2>&1; then
    log "Restauration des remotes Flatpak..."
    if [ -s "$SNAP_DIR/flatpak-remotes.txt" ]; then
      while IFS=$'\t' read -r rname rurl; do
        [ -n "$rname" ] || continue
        case "$rname" in
          # Les .flatpakrepo embarquent la clé GPG — indispensable ; l'URL
          # brute capturée par `flatpak remotes` n'y suffit pas.
          flathub)      rurl="https://flathub.org/repo/flathub.flatpakrepo" ;;
          flathub-beta) rurl="https://flathub.org/beta-repo/flathub-beta.flatpakrepo" ;;
          fedora)       continue ;;   # préinstallé sur Fedora
        esac
        if flatpak remote-add --if-not-exists "$rname" "$rurl" 2>>"$LOG"; then
          ok "Remote Flatpak : $rname"
        else
          warn "Échec remote Flatpak : $rname ($rurl) — à ré-ajouter à la main (clé GPG requise)."
        fi
      done <"$SNAP_DIR/flatpak-remotes.txt"
    else
      # Anciens snapshots sans flatpak-remotes.txt → flathub par défaut
      flatpak remote-add --if-not-exists flathub \
        https://flathub.org/repo/flathub.flatpakrepo 2>>"$LOG" || true
    fi

    log "Installation des applications Flatpak..."
    while IFS=$'\t' read -r app origin; do
      [ -z "$app" ] && continue
      origin="${origin:-flathub}"   # anciens snapshots : une seule colonne
      if flatpak install -y "$origin" "$app" 2>>"$LOG"; then
        ok "Flatpak : $app (← $origin)"
      else
        warn "Échec Flatpak : $app (remote $origin)"
      fi
    done <"$SNAP_DIR/flatpak-apps.txt"
  else
    warn "flatpak non installé — applications ignorées."
  fi
else
  log "Aucune application Flatpak à restaurer."
fi

# ── 5. Configs ~/.config ───────────────────────────────────────────────────
if [ "$DO_CONFIGS" -eq 1 ] && [ -f "$SNAP_DIR/config-backup.tar.gz" ]; then
  if [ "$ASSUME_YES" -ne 1 ]; then
    echo -ne "${YELLOW}?${NC} Restaurer les configs ~/.config (l'existant sera sauvegardé) ? [y/N] "
    read -r ans < /dev/tty
    [[ "$ans" =~ ^[Yy]$ ]] || { warn "Configs ignorées (choix utilisateur)."; DO_CONFIGS=0; }
  fi
fi

if [ "$DO_CONFIGS" -eq 1 ] && [ -f "$SNAP_DIR/config-backup.tar.gz" ]; then
  PRE="$HOME/.config/.restore-backup_$(date +%Y%m%d_%H%M%S)"
  log "Sauvegarde de l'existant → $PRE"
  if [ -f "$SNAP_DIR/config-dirs.txt" ]; then
    while IFS= read -r d; do
      [ -e "$HOME/.config/$d" ] || continue
      mkdir -p "$PRE"
      mv "$HOME/.config/$d" "$PRE/"
    done <"$SNAP_DIR/config-dirs.txt"
  fi
  tar -xzf "$SNAP_DIR/config-backup.tar.gz" -C "$HOME/.config" 2>>"$LOG"
  ok "Configs restaurées dans ~/.config"
else
  log "Étape configs ignorée."
fi

echo ""
ok "Restauration terminée (snapshot ${SNAP_REAL})."
log "Pense à reconnecter ta session / reboot pour Hyprland & NVIDIA."
