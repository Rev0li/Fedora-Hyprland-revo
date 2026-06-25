# Fixes NVIDIA — Curseur GDM + Ghost cursor Hyprland

> **Matériel :** Intel i5-7600K · NVIDIA GTX 1060 6 Go · Fedora 44 · Hyprland · GDM
> **Date :** 2026-06-25 — fixes validés après reboot

---

## 1. Curseur noir sur l'écran de connexion GDM

**Symptôme :** le thème de curseur Bibata-Modern-Ice n'apparaît pas sur GDM — curseur noir par défaut.

**Cause :** le thème n'était installé que dans `~/.icons/` (home utilisateur), inaccessible à l'utilisateur système `gdm`.

### Fix

```bash
# 1. Copier le thème dans le répertoire système
sudo cp -r ~/.icons/Bibata-Modern-Ice /usr/share/icons/

# 2. Créer un override dconf pour GDM (SANS créer /etc/dconf/profile/gdm)
sudo mkdir -p /etc/dconf/db/gdm.d
sudo tee /etc/dconf/db/gdm.d/10-cursor << 'EOF'
[org/gnome/desktop/interface]
cursor-theme='Bibata-Modern-Ice'
cursor-size=24
EOF
sudo dconf update
```

> **Important — ne pas créer `/etc/dconf/profile/gdm`** avec `user-db:user` : cela casse GDM (exit code 1, `gdm-launch-environment` plante).

---

## 2. Ghost cursor (curseur fantôme figé) après login GDM → Hyprland

**Symptôme :** après connexion sur GDM, deux curseurs apparaissent dans Hyprland — un figé à la position du clic de login, un qui se déplace normalement.

**Cause :** Mutter (compositeur GDM) utilise le hardware cursor NVIDIA via un DRM plane. Quand Hyprland prend le contrôle, il désactive ses propres hardware cursors (`cursor:no_hardware_cursors = 1`, auto-détecté NVIDIA), mais le DRM plane de GDM reste "peint" à la dernière position connue.

### Fix A — Désactiver le hardware cursor dans Mutter/GDM

Mutter de GDM est lancé via le profil PAM `gdm-launch-environment` → `pam_env.so` → lit `/etc/environment`. C'est le seul vecteur qui atteint réellement le gnome-shell de GDM (les variables du service systemd sont ignorées par `gdm-session-worker`).

```bash
echo 'MUTTER_DEBUG_DISABLE_HW_CURSORS=1' | sudo tee -a /etc/environment
```

### Fix B — Reset DPMS + warp curseur au démarrage Hyprland (workaround communauté)

Force Hyprland à réacquérir le DRM plane et effacer le ghost au boot de session.

Fichier : `~/.config/hypr/UserConfigs/Startup_Apps.conf`

```ini
exec-once = sleep 2 && hyprctl dispatch dpms off && sleep 0.5 && hyprctl dispatch dpms on
exec-once = sleep 2.5 && hyprctl dispatch movecursor 9999 9999
exec-once = sleep 3 && hyprctl dispatch movecursor 1 1
```

> L'écran clignote ~2 secondes après login (cycle DPMS) — comportement attendu et normal.

Les deux fixes sont complémentaires. Fix A agit à la source (GDM ne crée plus de plane hardware à nettoyer), Fix B est le filet de sécurité côté Hyprland.

---

## Ce qui casse GDM — à ne jamais faire

| Méthode | Effet |
|---------|-------|
| `sudo -u gdm dbus-launch gsettings set ...` | Crée une session dbus gdm orpheline → peut casser l'authentification GDM |
| Créer `/etc/dconf/profile/gdm` avec `user-db:user` | GDM crash exit 1 (`gdm-launch-environment` meurt, cherche une base dconf user qu'il n'a pas) |
| `Environment=` dans `gdm.service.d/override.conf` | Ignoré par `gdm-session-worker` qui reconstruit l'env depuis PAM |

### Récupération en cas de crash GDM (via snapshot Btrfs)

```bash
# Monter le snapshot Btrfs sur /mnt, puis :
sudo rm /mnt/etc/dconf/profile/gdm
sudo rm /mnt/etc/dconf/db/gdm.d/10-cursor
sudo rm -f /mnt/etc/dconf/db/gdm
sudo chroot /mnt dconf update
```

---

## Config Hyprland en place (rappel)

Ces options sont déjà dans `~/.config/hypr/configs/SystemSettings.conf` :

```ini
cursor {
    no_hardware_cursors = 1    # auto-détecté NVIDIA, évite le double curseur hardware
    enable_hyprcursor = true
    inactive_timeout = 3       # cache le curseur après 3s d'inactivité
}
```

Variables d'environnement dans `UserConfigs/ENVariables.conf` :

```ini
env = XCURSOR_THEME,Bibata-Modern-Ice
env = XCURSOR_SIZE,24
env = HYPRCURSOR_THEME,Bibata-Modern-Ice
env = HYPRCURSOR_SIZE,24
```
