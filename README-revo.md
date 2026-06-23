# Fedora-Hyprland — Setup personnel (Rev0li)

Fork pédagogique de [JaKooLit/Fedora-Hyprland](https://github.com/JaKooLit/Fedora-Hyprland),
adapté pour :

1. **Intégrer mes dotfiles** ([Rev0li/dotfiles](https://github.com/Rev0li/dotfiles) :
   WezTerm, Zsh modulaire, Helix, Starship) à la place d'oh-my-zsh.
2. **Ajouter `backup.sh` / `restore.sh`** : snapshots horodatés (DNF + Flatpak +
   COPR + configs).
3. **Documenter chaque étape** en bash *et* en équivalent Ansible.

> **Matériel cible** : Intel i5-7600K · NVIDIA GTX 1060 6 Go · 16 Go RAM · Fedora 40+ (DNF5).

---

## 1. Architecture du projet upstream (rappel)

```
install.sh                 # menu whiptail → coche des options → boucle case
└── execute_script "X.sh"  # lance install-scripts/X.sh selon la sélection
    ├── Global_functions.sh  # helpers : install_package(), couleurs, logs
    ├── copr.sh / 00-hypr-pkgs.sh / hyprland.sh / nvidia.sh ...
    ├── zsh.sh               # ← MODIFIÉ (voir §2)
    └── dotfiles-main.sh     # ← MODIFIÉ (voir §2)
preset.sh                  # surcharge les ON/OFF : ./install.sh --preset preset.sh
```

Chaque sous-script `source Global_functions.sh` (qui fournit `install_package()`,
les couleurs `tput`, et écrit dans `Install-Logs/`). C'est le **point d'accroche**
que je réutilise pour rester cohérent avec l'upstream.

---

## 2. Intégration de mes dotfiles

### Principe : deux couches

| Couche | Source | Contenu | Script |
|--------|--------|---------|--------|
| **Desktop** | `JaKooLit/Hyprland-Dots` | hypr, waybar, rofi, swaync… | `dotfiles-main.sh` (couche 1) |
| **Shell/terminal** | `Rev0li/dotfiles` (branche `fedora_dotfile`) | zsh, wezterm, helix, starship | `dotfiles-main.sh` (couche 2) |

L'ordre est important : **mes dotfiles sont posés APRÈS** ceux de KooL, donc mes
symlinks (`~/.zshrc`, `~/.config/wezterm`, `~/.config/helix`) **écrasent** les
fichiers copiés par KooL.

### 2.1 `zsh.sh` — ce qui a changé

**Avant** (upstream) : installe oh-my-zsh + plugins, copie `assets/.zshrc`.
**Après** (moi) : installe seulement `zsh` + outils CLI (fzf, git, unzip…), passe
le shell par défaut à zsh, et **laisse la config à mes dotfiles**.

```bash
# Cœur du nouveau zsh.sh
for ZSHP in fzf git curl tar unzip fontconfig zsh util-linux; do
  install_package "$ZSHP"          # helper de Global_functions.sh (idempotent : rpm -q)
done

# zsh par défaut si ce n'est pas déjà le cas
[ "$(basename "$SHELL")" != "zsh" ] && chsh -s "$(command -v zsh)"
```

<details><summary><b>Équivalent Ansible</b></summary>

```yaml
- name: Installer zsh + outils CLI
  ansible.builtin.dnf:
    name: [zsh, fzf, git, curl, tar, unzip, fontconfig, util-linux]
    state: present
  become: true

- name: Définir zsh comme shell par défaut
  ansible.builtin.user:
    name: "{{ ansible_user_id }}"
    shell: /usr/bin/zsh
  become: true
```
Le module `dnf` est **idempotent par nature** (`state: present` = "installe si
absent"), exactement comme la garde `rpm -q` de `install_package()`.
</details>

### 2.2 `dotfiles-main.sh` — ce qui a changé

```bash
# Couche 1 — KooL (inchangé) : git clone Hyprland-Dots && ./copy.sh

# Couche 2 — mes dotfiles (ajout) — branche dédiée Fedora : fedora_dotfile
BRANCH="fedora_dotfile"
if [ -d "$HOME/dotfiles/.git" ]; then
  git -C "$HOME/dotfiles" fetch origin "$BRANCH"
  git -C "$HOME/dotfiles" checkout "$BRANCH"
  git -C "$HOME/dotfiles" pull --ff-only origin "$BRANCH"   # déjà cloné → mise à jour
else
  git clone --depth=1 --branch "$BRANCH" https://github.com/Rev0li/dotfiles "$HOME/dotfiles"
fi
( cd "$HOME/dotfiles" && ./install.sh )        # pose les symlinks + binaires
```

Mon `~/dotfiles/install.sh` est déjà idempotent : sa fonction `link()` sauvegarde
tout fichier réel avant de créer le symlink (`~/.dotfiles_backup_<date>/`).

<details><summary><b>Équivalent Ansible</b></summary>

```yaml
- name: Cloner / mettre à jour mes dotfiles (branche Fedora)
  ansible.builtin.git:
    repo: https://github.com/Rev0li/dotfiles
    dest: "{{ ansible_env.HOME }}/dotfiles"
    version: fedora_dotfile
    depth: 1
    update: true

- name: Créer les symlinks de configuration
  ansible.builtin.file:
    src:   "{{ ansible_env.HOME }}/dotfiles/{{ item.src }}"
    dest:  "{{ ansible_env.HOME }}/{{ item.dest }}"
    state: link
    force: true
  loop:
    - { src: "zsh/custom_zshrc.zsh", dest: ".zshrc" }
    - { src: "helix",               dest: ".config/helix" }
    - { src: "wezterm/wezterm.lua",  dest: ".config/wezterm/wezterm.lua" }
```
Le module `git` gère clone *et* update (`update: true`) ; `file: state=link`
remplace la logique de `link()`.
</details>

---

## 3. NVIDIA (GTX 1060) — inchangé, à conserver

`nvidia.sh` (upstream) installe `akmod-nvidia`, `xorg-x11-drv-nvidia-cuda`, et
ajoute à GRUB : `nvidia-drm.modeset=1 nvidia_drm.fbdev=1` + blacklist `nouveau`.
**Je n'y touche pas** : c'est exactement ce qu'il faut pour Wayland/Hyprland sur
Pascal (GTX 10xx).

```bash
sudo dnf install -y akmod-nvidia xorg-x11-drv-nvidia-cuda libva libva-nvidia-driver
# GRUB : rd.driver.blacklist=nouveau modprobe.blacklist=nouveau nvidia-drm.modeset=1
sudo grub2-mkconfig -o /boot/grub2/grub.cfg   # → REBOOT obligatoire
```

<details><summary><b>Équivalent Ansible</b></summary>

```yaml
- name: Pilotes NVIDIA
  ansible.builtin.dnf:
    name: [akmod-nvidia, xorg-x11-drv-nvidia-cuda, libva, libva-nvidia-driver]
    state: present
  become: true

- name: Activer le modeset NVIDIA dans GRUB
  ansible.builtin.lineinfile:
    path: /etc/default/grub
    regexp: '^GRUB_CMDLINE_LINUX="(?!.*nvidia-drm\.modeset)(.*)"$'
    line: 'GRUB_CMDLINE_LINUX="rd.driver.blacklist=nouveau modprobe.blacklist=nouveau nvidia-drm.modeset=1 nvidia_drm.fbdev=1 \1"'
    backrefs: true
  become: true
  notify: regenerate grub
```
</details>

---

## 4. backup.sh — snapshot horodaté

```bash
./backup.sh                       # → ./backups/<timestamp>/ + lien ./backups/latest
BACKUP_ROOT=/mnt/nas ./backup.sh  # destination personnalisée (ex. NAS Tailscale)
```

Contenu d'un snapshot :

| Fichier | Source | Commande clé |
|---------|--------|--------------|
| `dnf-userinstalled.txt` | paquets installés explicitement | `dnf repoquery --userinstalled` |
| `flatpak-apps.txt` | applis Flatpak | `flatpak list --app` |
| `copr-repos.txt` | dépôts COPR activés | parse de `/etc/yum.repos.d/` |
| `config-backup.tar.gz` | configs `~/.config` (hors dotfiles) | `tar -czf` |
| `manifest.txt` | métadonnées (date, kernel, Fedora) | — |

> Les dossiers gérés par **mes dotfiles** (helix, wezterm) sont **exclus** du
> snapshot : ils vivent déjà dans le dépôt git versionné.

Le script est **idempotent** (chaque run = nouveau dossier daté, jamais d'écrasement)
et **tolérant aux pannes** : si une source manque (pas de flatpak, pas de COPR),
il logge un `⚠` et continue.

<details><summary><b>Équivalent Ansible</b></summary>

```yaml
- name: Lister les paquets DNF user-installed
  ansible.builtin.command: dnf repoquery --userinstalled --qf '%{name}'
  register: dnf_pkgs
  changed_when: false

- name: Archiver les configs ~/.config
  community.general.archive:
    path: "{{ ansible_env.HOME }}/.config/{{ item }}"
    dest: "{{ snap_dir }}/config-backup.tar.gz"
    format: gz
  loop: [hypr, waybar, rofi, swaync]
```
</details>

---

## 5. restore.sh — rejouer un snapshot

```bash
./restore.sh                  # restaure le dernier snapshot (latest)
./restore.sh 20260623_141500  # un snapshot précis
./restore.sh latest -y        # sans confirmation pour les configs
./restore.sh --no-configs     # paquets seulement
```

Ordre des étapes (les paquets DNF peuvent dépendre des COPR) :

1. `sudo dnf copr enable -y <repo>` pour chaque COPR
2. `sudo dnf install -y --skip-unavailable` sur la liste DNF
3. `flatpak install -y flathub <app>` pour chaque appli
4. extraction de l'archive de configs (**l'existant est sauvegardé** dans
   `~/.config/.restore-backup_<date>/` avant écrasement)

**Idempotent** : DNF et Flatpak ignorent ce qui est déjà installé, donc on peut
relancer sans risque. `--skip-unavailable` évite qu'un paquet disparu casse tout.

<details><summary><b>Équivalent Ansible</b></summary>

Le restore est précisément ce pour quoi Ansible brille : un playbook *est* un état
désiré rejouable. La logique impérative de `restore.sh` (COPR → DNF → Flatpak →
configs) correspond à une suite de tâches `dnf` / `flatpak` / `unarchive`, chacune
idempotente, sans le `--skip-unavailable` à gérer à la main.
</details>

---

## 6. Procédure complète d'installation

```bash
# 1. Mise à jour système + reboot (recommandé par l'upstream)
sudo dnf upgrade --refresh -y && reboot

# 2. Lancer l'install (menu interactif) — cocher : nvidia, zsh, dots, ...
./install.sh
#    ou en non-interactif via preset :
./install.sh --preset preset.sh

# 3. Reboot (obligatoire pour NVIDIA modeset)

# 4. Premier backup de référence
./backup.sh
```

---

## 7. Conventions respectées

- **Idempotence** : `install_package` (rpm -q), `link()` (backup avant symlink),
  snapshots datés.
- **Logs horodatés** : `Install-Logs/` (upstream) et `backups/<date>/*.log` (mes scripts).
- **Sécurité** : aucun secret en clair ; NAS accessible via Tailscale uniquement.
- **Push dotfiles git** : volontairement laissé en option commentée dans `backup.sh`
  (décommenter le bloc final pour committer/pousser `~/dotfiles` à chaque backup).
```
