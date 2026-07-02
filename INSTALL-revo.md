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
./install.sh --preset preset.sh                # checklist PRÉ-COCHÉE par le preset (tu valides)
./install.sh --preset preset.sh --unattended   # AUCUNE question : sélection = preset
```

`preset.sh` prédéfinit les `ON/OFF` (déjà réglé pour cette machine :
`nvidia="ON"` pour la GTX 1060, `snapper="ON"`, `dots="ON"`...). En
`--unattended`, les garde-fous de la checklist restent actifs : `nvidia`
seulement si GPU détecté, `sddm` seulement si aucun autre login manager.

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

## Phase 5a — Snapshots Btrfs locaux (snapper)

Protège contre les mises à jour cassantes (`dnf update`, fausse manip…).
Rollback instantané depuis le menu GRUB, sans réinstaller.

```bash
./install-scripts/snapper.sh
# ou, si tu repasses par install.sh :
# preset.sh contient déjà snapper="ON"
```

**Ce qui est installé** :

| Composant | Rôle |
|-----------|------|
| `snapper` | gestion des snapshots Btrfs |
| `python3-dnf-plugin-snapper` | snapshot automatique avant/après chaque `dnf` |
| `grub-btrfs` | snapshots visibles dans le menu GRUB au boot |

**Rétention automatique** : 5 horaires · 7 quotidiens · 4 hebdo · 3 mensuels (root + home).

**✅ Vérif** :

```bash
snapper list                          # doit lister au moins une config (root, home)
systemctl status snapper-timeline.timer
```

**Commandes du quotidien** :

```bash
snapper -c root create -d "avant maj nvidia"   # snapshot manuel
snapper list                                    # voir tous les snapshots
snapper -c root diff 3 5                       # diff entre snapshots n°3 et 5
snapper -c root undochange 3..5                # annuler les changements 3→5
```

**Rollback depuis GRUB** : au boot, dans le menu GRUB → *Fedora Linux snapshots* →
choisir un snapshot → booter dedans → si OK, le définir comme défaut.

---

## Phase 5b — Backup incrémental vers le NAS

Protège contre la **perte du disque** ou le **changement de machine**.
Utilise `btrfs send` : premier envoi complet, suivants incrémentaux (~10× plus petits).

Chaque fichier envoyé est **vérifié** (sha256 calculé pendant l'upload, relu
depuis le disque NAS, sidecar `.sha256` déposé à côté) — rien n'est purgé tant
que la vérification n'a pas réussi. Un `sysinfo-STAMP.tar.zst` (table GPT,
`blkid`, `fstab`, `efibootmgr`, subvolumes) part aussi à chaque run : de quoi
repartitionner à l'identique le jour du bare-metal restore.

### 1. Configurer le chemin NAS

Ouvre `nas-backup.sh` et ajuste si besoin :

```bash
NAS_DEST_PATH="/volume1/backup-rev0/fedora_backup"  # chemin sur nas-songsurf
```

Créer le dossier sur le NAS si absent :

```bash
ssh nas-songsurf "mkdir -p /volume1/backup-rev0/fedora_backup"
```

### 2. Premier backup (envoi complet)

```bash
./nas-backup.sh              # root + home
./nas-backup.sh --root-only  # root uniquement (plus rapide)
```

Le premier envoi est **complet** — prévois de la bande passante (taille du subvolume root).
Les suivants seront **incrémentaux** (seulement le diff depuis le dernier envoi).

**✅ Vérif** :

```bash
ssh nas-songsurf "ls /volume1/backup-rev0/fedora_backup/"
# doit lister : root-STAMP_full.btrfs.zst  home-STAMP_full.btrfs.zst
#               boot-STAMP.tar.zst  boot-efi-STAMP.tar.zst  sysinfo-STAMP.tar.zst
#               + un .sha256 par fichier, et backup.log
ssh nas-songsurf "cat /volume1/backup-rev0/fedora_backup/backup.log"
# contrôle d'intégrité à la demande :
ssh nas-songsurf "cd /volume1/backup-rev0/fedora_backup && sha256sum -c *.sha256"
# ou, vue d'ensemble des chaînes restaurables :
./nas-restore.sh --list
```

### 3. Automatiser le *rappel* (recommandé) — notification interactive

Choix assumé : **pas de backup en tâche de fond.** Un backup NAS envoie `/home`
(secrets compris) hors machine et fait de grosses opérations root ; il doit
rester un acte conscient, authentifié (mot de passe sudo + touch YubiKey). On
automatise donc le **rappel**, pas l'exécution.

```bash
./install-scripts/nas-backup-reminder.sh   # aucun sudo : timers systemd --user
```

Ce qu'il installe (unités versionnées dans `systemd/user/`) :

| Timer (`--user`) | Quand | Action |
|---|---|---|
| `nas-backup-reminder.timer` | tous les jours 20:00 | **notif swaync** « Sauvegarde due » + bouton → incrémental |
| `nas-backup-reminder-full.timer` | dimanche 20:30 | **notif** « Sauvegarde complète » + bouton → `--full` (chaîne bornée à ~7 incréments) |

Au clic sur **« Lancer »**, `nas-backup-notify.sh` ouvre un terminal kitty qui
exécute `nas-backup.sh` : `sudo` y demande **mot de passe + touch YubiKey**
(ta config `pam_u2f` existante). Rien ne part vers le NAS sans ce geste.

- **Pas de nag inutile** : le rappel quotidien se tait si une sauvegarde a eu
  lieu il y a moins de 20 h.
- `Persistent=true` : un rappel manqué (session fermée à l'heure prévue)
  s'affiche à la prochaine ouverture de session.
- Les snapshots **snapper locaux** restent, eux, automatiques (Phase 5a) : ils
  couvrent l'« oups » en continu, sans réseau ni secret qui sort.

**✅ Vérif** :

```bash
systemctl --user list-timers 'nas-backup*'                          # prochains rappels
systemctl --user start --no-block nas-backup-reminder-full.service  # tester la notif tout de suite
./nas-backup.sh                                                     # ou lancer un backup à la main
```

> **Restauration** : les unités vivent dans `~/.config/systemd/user`
> (subvolume `home`), donc un `restore.md` complet les remet en place. En cas de
> doute, relancer `./install-scripts/nas-backup-reminder.sh` (idempotent, sans
> sudo) réarme tout.

---

## En cas de pépin — restaurer

### Rollback local (snapper — le plus rapide)

Depuis le **menu GRUB** au boot : *Fedora Linux snapshots* → choisir le snapshot voulu.

Ou depuis un système en marche :

```bash
snapper -c root undochange N..0   # revenir de l'état N à l'état 0 (actuel)
```

### Restauration paquets/configs (restore.sh)

Sur une nouvelle machine, ou après avoir cassé quelque chose :

```bash
./restore.sh                 # rejoue le dernier snapshot (latest)
./restore.sh 20260623_141500 # un snapshot précis
./restore.sh latest -y       # sans confirmation pour les configs
./restore.sh --no-configs    # paquets seulement
```

Ordre rejoué : **COPR → RPM Fusion + `.repo` tiers → DNF → remotes + Flatpak →
configs** (l'existant est sauvegardé dans `~/.config/.restore-backup_<date>/`
avant écrasement). Idempotent.

### Restauration NAS (perte disque / nouvelle machine)

**Guide complet pas-à-pas : [`restore.md`](restore.md)** (partitionnement,
UUID, chroot, GRUB/efibootmgr). Le rejeu de la chaîne est automatisé :

```bash
# Depuis un live USB (NAS_HOST=admin@IP si pas de ~/.ssh/config)
./nas-restore.sh --list                    # inventaire des chaînes restaurables
./nas-restore.sh --sysinfo ./sysinfo       # layout disque/UUID de référence
sudo mount -t btrfs -o subvolid=5 /dev/sdX3 /mnt/top
./nas-restore.sh --dest /mnt/top           # vérifie les sha256, rejoue
                                           # full + incréments, promeut root/home
./nas-restore.sh --boot /mnt/restore/boot --efi /mnt/restore/boot/efi
```

> Le dernier snapshot reçu est conservé dans le top-level : c'est le parent qui
> permet à `nas-backup.sh` de **reprendre les incrémentaux** après restauration.

---

## Schéma mental à retenir

| Couche | Qui la pose | Comment la modifier ensuite |
|--------|-------------|------------------------------|
| **Système** (paquets, NVIDIA) | `install.sh` / `restore.sh` | éditer `preset.sh`, relancer |
| **Desktop** (hypr, waybar…) | KooL Hyprland-Dots | via `~/.config` (capturé par `backup.sh`) |
| **Shell/terminal/éditeur** | dotfiles, branche `fedora_dotfile` | éditer `~/dotfiles`, commit/push sur `fedora_dotfile` |
| **Snapshots locaux** | snapper + grub-btrfs | `snapper list` / rollback GRUB |
| **Backup NAS** | `nas-backup.sh` | `btrfs send` incrémental + sha256 vérifié vers `nas-songsurf` |
| **Restauration NAS** | `nas-restore.sh` + `restore.md` | rejeu vérifié de la chaîne (full + incréments) |

Les couches sont **découplées** : tu peux refaire l'OS sans perdre tes dotfiles
(sur git), snapshotter sans toucher au desktop, et sauvegarder vers le NAS indépendamment.

---

## Aide-mémoire (cheat sheet)

```bash
# Installation complète, reproductible
sudo dnf upgrade --refresh -y && sudo dnf install -y git
git clone https://github.com/Rev0li/Fedora-Hyprland-revo.git
cd Fedora-Hyprland-revo && git checkout revo/dotfiles-integration
# (preset.sh est déjà réglé pour cette machine : nvidia="ON", snapper="ON"...)
./install.sh --preset preset.sh --unattended
sudo reboot
# après login :
./check-install.sh && ./backup.sh

# Snapshots Btrfs locaux
snapper list
snapper -c root create -d "note"

# Backup NAS
./nas-backup.sh              # incrémental (sha256 vérifié + sysinfo)
./nas-backup.sh --full       # nouveau full (rappel auto le dimanche 20:30)
./nas-restore.sh --list      # état des chaînes restaurables sur le NAS
```
