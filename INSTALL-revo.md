# Guide d'installation — Fedora + Hyprland (Rev0li)

Tuto « infra » : chaque phase a un **objectif**, la **commande**, le **pourquoi**,
et un **point de vérification** avant de passer à la suite.

> **Matériel cible** : Intel i5-7600K · NVIDIA GTX 1060 6 Go · 16 Go RAM · Fedora 40+ (DNF5).
> **Voir aussi** : [`README-revo.md`](README-revo.md) (ce que font les scripts, bash + Ansible).

---

## Pré-requis : c'est toi qui installes Fedora

Ces scripts **ne posent pas l'OS**, ils **configurent un Fedora déjà installé**.

1. **Toi** → installer **Fedora Workstation** (ou un spin minimal / *Everything*), créer
   ton utilisateur, connecter le réseau.
2. **Toi** → `sudo dnf install -y git` (souvent déjà présent).
3. **Ensuite seulement** → `git clone …` (voir Phase 0).

> Pas besoin d'interface graphique pour les Phases 0–1 : un TTY (`Ctrl+Alt+F3`)
> sur un Fedora minimal suffit. Il faut juste **réseau + git**.

---

## Vue d'ensemble (le pipeline)

```
Fedora minimal installé
   │
   ├─ Phase 0 : préparer le terrain (update, git, clone)
   ├─ Phase 1 : install.sh        → Hyprland + NVIDIA + couche desktop (KooL)
   │                                 + couche shell (dotfiles, branche fedora_dotfile)
   ├─ Phase 2 : reboot            → NVIDIA modeset actif
   ├─ Phase 3 : check-install.sh  → diagnostic automatique
   └─ Phase 4 : backup.sh         → snapshot de référence ("état connu bon")
```

Principe directeur : **idempotent et reproductible**. Chaque script se relance sans
casser, tout est loggé. Si une machine meurt, tu rejoues le pipeline.

---

## Phase 0 — Préparer le terrain

```bash
# 1. Système à jour (évite les conflits paquets/akmod après coup)
sudo dnf upgrade --refresh -y

# 2. Outils minimaux pour bootstrapper
sudo dnf install -y git

# 3. Récupérer ton install configurée (la branche dédiée)
git clone https://github.com/Rev0li/Fedora-Hyprland-revo.git
cd Fedora-Hyprland-revo
git checkout revo/dotfiles-integration
```

> **Pourquoi cette branche ?** Elle contient ta version modifiée (zsh sans oh-my-zsh,
> intégration de tes dotfiles, backup/restore/check). `main` = l'upstream JaKooLit.

**✅ Vérif** : `ls backup.sh restore.sh check-install.sh install.sh` liste les 4 fichiers.

---

## Phase 1 — Lancer l'installation

Deux modes, au choix.

### Mode A — interactif (recommandé la 1re fois)

```bash
./install.sh
```

Dans le menu `whiptail` (**SPACE** pour cocher, **TAB** pour naviguer), coche au minimum :

| Option | Pourquoi |
|--------|----------|
| `nvidia` | **obligatoire** pour ta GTX 1060 |
| `zsh` | installe zsh + outils CLI, te passe en zsh (sans oh-my-zsh) |
| `dots` | pose la couche desktop KooL **puis** tes dotfiles (`fedora_dotfile`) |
| `sddm`, `thunar`, `bluetooth`, `xdph`, `gtk_themes` | selon tes besoins |

### Mode B — non-interactif (reproductible / infra)

```bash
./install.sh --preset preset.sh
```

`preset.sh` prédéfinit les `ON/OFF`. **Une seule chose à régler pour ta machine** :

```bash
nvidia="ON"     # ← OFF par défaut, à passer ON pour la GTX 1060
```

> **Réflexe infra** : le mode B est ton *playbook* — versionné, rejouable à l'identique
> sur une autre machine. Le mode A est pour découvrir.

**Sous le capot** (l'ordre compte) :

1. `copr.sh` (dépôts tiers) · `00-hypr-pkgs.sh` (deps) · `hyprland.sh`
2. `nvidia.sh` → `akmod-nvidia` + `nvidia-drm.modeset=1` dans GRUB
3. `zsh.sh` → zsh + deps CLI, shell par défaut (**pas** d'oh-my-zsh)
4. `dotfiles-main.sh` → KooL Hyprland-Dots (desktop) **puis** clone `Rev0li/dotfiles`
   branche `fedora_dotfile` + lance son `install.sh` (tes symlinks gagnent)

**✅ Vérif** : le script confirme que Hyprland est installé. Logs dans `Install-Logs/` :

```bash
ls -t Install-Logs/ | head        # dernier log
grep -i error Install-Logs/*.log   # chercher les erreurs
```

---

## Phase 2 — Reboot

```bash
sudo reboot
```

> **Non négociable avec NVIDIA** : `nvidia-drm.modeset=1` n'est pris en compte qu'au
> boot. Sans reboot → Hyprland peut refuser de démarrer (écran noir / Wayland qui plante).

---

## Phase 3 — Diagnostic automatique

Après login (via SDDM, ou `Hyprland` au TTY si pas de SDDM) :

```bash
cd ~/Fedora-Hyprland-revo
./check-install.sh
```

Le script vérifie **en lecture seule** : OS Fedora, Hyprland, NVIDIA (driver + modeset +
GRUB), shell zsh, branche `fedora_dotfile`, symlinks dotfiles, binaires
(starship/hx/wezterm/eza), présence d'un snapshot.

- Sortie **`0`** = tout est conforme (warnings tolérés).
- Sortie **`1`** = au moins une vérif **critique** a échoué (affichée en rouge).

**Lecture des résultats :**

| Symbole | Sens |
|---------|------|
| `✓` vert | OK |
| `⚠` jaune | non bloquant (ex. binaire absent du PATH → `exec zsh`) |
| `✗` rouge | critique (ex. symlink non créé, modeset inactif) |

**Pannes typiques et correctifs :**

- `✗ ~/.zshrc existe mais n'est PAS un symlink` → la couche KooL n'a pas été écrasée :
  relance `bash install-scripts/dotfiles-main.sh`.
- `✗ module nvidia_drm non chargé` → tu n'as pas (re)booté après `nvidia.sh`.
- `⚠ branche = 'main'` → `git -C ~/dotfiles checkout fedora_dotfile`.
- `⚠ binaire absent du PATH` → recharge le shell : `exec zsh`.

---

## Phase 4 — Snapshot de référence

Dès que le système te convient, fige l'état :

```bash
./backup.sh
```

Crée `backups/<timestamp>/` (paquets DNF, apps Flatpak, dépôts COPR, archive
`~/.config`) + un lien `backups/latest`.

> **Réflexe infra** : c'est ton **point de restauration**. Refais-en un après chaque
> grosse modif (« je sais que cet état marche »).

**✅ Vérif** :

```bash
cat backups/latest/manifest.txt              # date, kernel, version Fedora
wc -l backups/latest/dnf-userinstalled.txt   # nb de paquets capturés
```

---

## En cas de pépin — restaurer

Sur une nouvelle machine, ou après avoir cassé quelque chose :

```bash
./restore.sh                 # rejoue le dernier snapshot (latest)
./restore.sh 20260623_141500 # un snapshot précis
./restore.sh latest -y       # sans confirmation pour les configs
./restore.sh --no-configs    # paquets seulement
```

Ordre rejoué : **COPR → DNF → Flatpak → configs** (l'existant est sauvegardé dans
`~/.config/.restore-backup_<date>/` avant écrasement). Idempotent.

---

## Schéma mental à retenir

| Couche | Qui la pose | Comment la modifier ensuite |
|--------|-------------|------------------------------|
| **Système** (paquets, NVIDIA) | `install.sh` / `restore.sh` | éditer `preset.sh`, relancer |
| **Desktop** (hypr, waybar…) | KooL Hyprland-Dots | via `~/.config` (capturé par `backup.sh`) |
| **Shell/terminal/éditeur** | dotfiles, branche `fedora_dotfile` | éditer `~/dotfiles`, commit/push sur `fedora_dotfile` |

Les trois couches sont **découplées** : tu peux refaire l'OS sans perdre tes dotfiles
(ils sont sur git), et changer tes dotfiles sans toucher au desktop.

---

## Aide-mémoire (cheat sheet)

```bash
# Installation complète, reproductible
sudo dnf upgrade --refresh -y && sudo dnf install -y git
git clone https://github.com/Rev0li/Fedora-Hyprland-revo.git
cd Fedora-Hyprland-revo && git checkout revo/dotfiles-integration
# (régler nvidia="ON" dans preset.sh)
./install.sh --preset preset.sh
sudo reboot
# après login :
./check-install.sh && ./backup.sh
```
