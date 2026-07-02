# Restauration complète (bare-metal) — Fedora-Hyprland-revo

> **Ce guide ≠ `restore.sh`.** `restore.sh`/`backup.sh` ne réinstallent que les
> paquets DNF/Flatpak/COPR + quelques dossiers `~/.config` (Hyprland, waybar...) —
> pratique pour une install fraîche, mais ça ne récupère ni tes fichiers, ni
> `/boot`, ni `/boot/efi`. **Ce document-ci** sert le jour où le disque est mort
> (ou la machine remplacée) et qu'il faut tout reconstruire à partir du NAS.
>
> Source des backups : `nas-backup.sh`. Voir aussi le header de ce script pour
> le résumé rapide ; ce document est la version détaillée, pas-à-pas.

## 1. Ce qui est sauvegardé, et où

NAS : `nas-songsurf:/volume1/backup-rev0/fedora_backup/`

| Composant | Méthode | Fichiers NAS | Rétention |
|---|---|---|---|
| `/` (subvol `root`) | `btrfs send/receive` | `root-STAMP_full.btrfs.zst` + `root-STAMP_inc.btrfs.zst` (0..N) | Toute la chaîne gardée jusqu'au prochain `--full` |
| `/home` (subvol `home`) | `btrfs send/receive` | `home-STAMP_full.btrfs.zst` + `home-STAMP_inc.btrfs.zst` (0..N) | Idem |
| `/boot` (ext4) | `tar --selinux --acls --xattrs` | `boot-STAMP.tar.zst` | 1 seule version (toujours full) |
| `/boot/efi` (vfat) | `tar` | `boot-efi-STAMP.tar.zst` | 1 seule version (toujours full) |
| Identité système (GPT, blkid, fstab, efibootmgr, subvols) | `tar` | `sysinfo-STAMP.tar.zst` | 1 seule version |

Chaque fichier a un sidecar `<fichier>.sha256` (vérifié à l'upload, re-vérifiable
à tout moment : `ssh nas-songsurf "cd <dossier> && sha256sum -c *.sha256"`).
`backup.log` sur le NAS liste l'historique des runs dans l'ordre chronologique.

> **Raccourci** : `nas-restore.sh` automatise l'inventaire, la vérification
> sha256 et le rejeu de chaîne (§4 et §7). Les commandes manuelles restent
> documentées en fallback.

## 2. Layout disque actuel (référence, machine "Fedora-Hyprland-revo")

Disque cible : **`/dev/sda`** (256 Go, table **GPT**). ⚠️ Il y a un second disque
`/dev/sdb` (Windows / BitLocker, dual-boot) — **ne jamais le toucher** pendant
cette procédure, il a son propre ESP indépendant.

| Partition | Taille | FS | Point de montage | UUID/Type |
|---|---|---|---|---|
| `/dev/sda1` | 600 MiB | vfat (FAT32) | `/boot/efi` | UUID=`0E3D-AFE4`, type `ef00` (EFI System) |
| `/dev/sda2` | 2048 MiB | ext4 | `/boot` | UUID=`8510bfa7-5e82-49bf-8cd3-144593749b8b`, type `8300` (Linux) |
| `/dev/sda3` | ~259672 MiB (reste du disque) | btrfs (subvols `root` + `home`) | `/` et `/home` | UUID=`6849cd01-809a-4da6-851b-11fe50f615f9`, type `8300` (Linux) |

`/etc/fstab` actuel (sera restauré tel quel avec `root`, donc inutile de le
réécrire **si** tu reformates avec les mêmes UUID ci-dessous — voir étape 4) :

```
UUID=6849cd01-809a-4da6-851b-11fe50f615f9 / btrfs subvol=root,compress=zstd:1 0 0
UUID=8510bfa7-5e82-49bf-8cd3-144593749b8b /boot ext4 defaults 1 2
UUID=0E3D-AFE4 /boot/efi vfat umask=0077,shortname=winnt 0 2
UUID=6849cd01-809a-4da6-851b-11fe50f615f9 /home btrfs subvol=home,compress=zstd:1 0 0
```

Boot UEFI via **shim** (Secure Boot était désactivé au moment du backup) :
`Boot0001* Fedora` → `\EFI\FEDORA\SHIMX64.EFI` sur `sda1`.

## 3. Pré-requis

- Live USB Fedora (Workstation ou Everything netinstall) — a déjà `btrfs-progs`,
  `tar`, `zstd`, `openssh-client`, `sgdisk` de base.
- Connectivité réseau + ta clé SSH (ou un mot de passe) pour joindre `nas-songsurf`.
- **Le disque cible doit être vide / remplacé.** Si l'ancien `/dev/sda` est
  encore branché en même temps qu'un nouveau disque, voir l'avertissement
  UUID à l'étape 4.

## 4. Identifier les fichiers à restaurer

```bash
# Depuis le live USB, sans ~/.ssh/config : surcharger NAS_HOST
NAS_HOST=admin@IP_DU_NAS ./nas-restore.sh --list

# Bonus : récupérer l'identité système (table GPT, UUID, fstab, efibootmgr)
# AVANT de partitionner — utile si ce document a dérivé de la réalité.
NAS_HOST=admin@IP_DU_NAS ./nas-restore.sh --sysinfo ./sysinfo
```

`--list` affiche, pour `root` et `home`, la chaîne exacte (dernier full + tous
les incréments qui le suivent, dans l'ordre d'application) et les archives
boot/efi/sysinfo disponibles.

<details><summary>Fallback manuel (sans nas-restore.sh)</summary>

```bash
ssh nas-songsurf "cat /volume1/backup-rev0/fedora_backup/backup.log"
ssh nas-songsurf "ls -la /volume1/backup-rev0/fedora_backup/"
```

Pour `root` (idem pour `home`) : prends le **dernier** `root-*_full.btrfs.zst`
dans le log, puis **tous** les `root-*_inc.btrfs.zst` qui le suivent
chronologiquement. Note les STAMP dans l'ordre — tu les appliqueras un par un.

Pour `/boot` et `/boot/efi` : un seul fichier existe à la fois
(`boot-STAMP.tar.zst`, `boot-efi-STAMP.tar.zst`) — prends celui présent.
</details>

## 5. Partitionner le disque cible

```bash
lsblk   # repère le bon disque cible, PAS /dev/sdb (Windows)
DISK=/dev/sda   # adapter si le nom diffère sur le live USB

sudo sgdisk --zap-all "$DISK"                                   # ⚠️ efface tout sur $DISK
sudo sgdisk -n 1:2048:+600M  -t 1:ef00 -c 1:"EFI System Partition" "$DISK"
sudo sgdisk -n 2:0:+2048M    -t 2:8300 -c 2:"boot"                "$DISK"
sudo sgdisk -n 3:0:0         -t 3:8300 -c 3:"fedora"              "$DISK"
sudo partprobe "$DISK"
```

## 6. Formater — en réutilisant les UUID d'origine

**Seulement si l'ancien disque a disparu pour de bon** (remplacement physique).
Ça évite d'avoir à toucher `/etc/fstab` après restauration : il pointera déjà
vers les bons UUID.

```bash
sudo mkfs.vfat -F32 -i 0E3DAFE4 -n EFI "${DISK}1"
sudo mkfs.ext4 -U 8510bfa7-5e82-49bf-8cd3-144593749b8b -L boot "${DISK}2"
sudo mkfs.btrfs -U 6849cd01-809a-4da6-851b-11fe50f615f9 -L fedora "${DISK}3"
```

> ⚠️ Si l'ancien `/dev/sda` est encore connecté en parallèle (test de
> restauration sur un disque annexe, ancien disque pas mort), **ne mets PAS
> les mêmes UUID** (conflit UUID dupliqué = montages ambigus / erreurs noyau).
> Dans ce cas, laisse `mkfs` générer des UUID aléatoires (omets `-i`/`-U`) et
> corrige `/etc/fstab` après l'étape 9 avec les nouveaux UUID (`blkid`).

## 7. Recevoir `root` et `home` (Btrfs)

```bash
sudo mkdir -p /mnt/top
sudo mount -t btrfs -o subvolid=5 "${DISK}3" /mnt/top

# Vérifie les sha256, rejoue full + incréments dans l'ordre, promeut root/home,
# nettoie les intermédiaires (garde le dernier snapshot = parent pour que
# nas-backup.sh reprenne les incrémentaux après restauration) :
NAS_HOST=admin@IP_DU_NAS ./nas-restore.sh --dest /mnt/top

sudo umount /mnt/top
```

<details><summary>Fallback manuel (sans nas-restore.sh)</summary>

```bash
# root : full, puis CHAQUE inc dans l'ordre chronologique du backup.log
ssh nas-songsurf "cat /volume1/backup-rev0/fedora_backup/root-FULLSTAMP_full.btrfs.zst" \
  | zstd -d | sudo btrfs receive /mnt/top/
ssh nas-songsurf "cat /volume1/backup-rev0/fedora_backup/root-INC1STAMP_inc.btrfs.zst" \
  | zstd -d | sudo btrfs receive /mnt/top/
# ... répéter pour chaque _inc suivant, dans l'ordre ...

# Le dernier subvolume reçu (le plus récent STAMP) devient "root" :
sudo btrfs subvolume snapshot /mnt/top/root-DERNIERSTAMP /mnt/top/root

# Nettoyage des subvolumes intermédiaires (gardent juste root) :
sudo btrfs subvolume delete /mnt/top/root-FULLSTAMP /mnt/top/root-INC1STAMP   # etc.

# Même procédure pour home → /mnt/top/home
ssh nas-songsurf "cat /volume1/backup-rev0/fedora_backup/home-FULLSTAMP_full.btrfs.zst" \
  | zstd -d | sudo btrfs receive /mnt/top/
# ... incréments home ...
sudo btrfs subvolume snapshot /mnt/top/home-DERNIERSTAMP /mnt/top/home
sudo btrfs subvolume delete /mnt/top/home-FULLSTAMP   # etc.
```
</details>

## 8. Monter pour le chroot + restaurer boot/efi

```bash
sudo mkdir -p /mnt/restore
sudo mount -o subvol=root "${DISK}3" /mnt/restore
sudo mount -o subvol=home "${DISK}3" /mnt/restore/home
sudo mount "${DISK}2" /mnt/restore/boot
sudo mount "${DISK}1" /mnt/restore/boot/efi

NAS_HOST=admin@IP_DU_NAS ./nas-restore.sh \
  --boot /mnt/restore/boot --efi /mnt/restore/boot/efi
```

<details><summary>Fallback manuel (sans nas-restore.sh)</summary>

```bash
ssh nas-songsurf "cat /volume1/backup-rev0/fedora_backup/boot-STAMP.tar.zst" \
  | zstd -d | sudo tar -xpf - --selinux --acls --xattrs -C /mnt/restore/boot/
ssh nas-songsurf "cat /volume1/backup-rev0/fedora_backup/boot-efi-STAMP.tar.zst" \
  | zstd -d | sudo tar -xpf - -C /mnt/restore/boot/efi/
```
</details>

## 9. Chroot et finalisation du bootloader

```bash
for d in dev proc sys; do sudo mount --bind /$d /mnt/restore/$d; done
sudo chroot /mnt/restore /bin/bash
```

Dans le chroot :

```bash
# Régénère l'initramfs (utile si le matériel a changé)
dracut --force --regenerate-all

# Régénère grub.cfg (le symlink Fedora pointe déjà vers le bon chemin EFI)
grub2-mkconfig -o /etc/grub2-efi.cfg

# Recrée l'entrée NVRAM UEFI (les anciens GUID de partition ne sont plus valides
# après le repartitionnement, même si les UUID de filesystem ont été conservés)
# Si efibootmgr râle "EFI variables are not supported" :
#   mount -t efivarfs efivarfs /sys/firmware/efi/efivars
efibootmgr -c -d /dev/sda -p 1 -L "Fedora" -l '\EFI\fedora\shimx64.efi'
efibootmgr -v   # vérifie qu'il n'y a pas de doublon / entrée Windows perdue

exit
```

## 10. Si tu n'as PAS réutilisé les UUID d'origine (étape 6, cas disque parallèle)

```bash
blkid "${DISK}1" "${DISK}2" "${DISK}3"
sudo nano /mnt/restore/etc/fstab   # remplace les anciens UUID par les nouveaux
```

## 11. Démonter et redémarrer

```bash
sudo umount /mnt/restore/boot/efi /mnt/restore/boot /mnt/restore/dev \
            /mnt/restore/proc /mnt/restore/sys /mnt/restore/home /mnt/restore
sudo reboot
```

Retire le Live USB au redémarrage. Si le firmware ne propose pas "Fedora" dans
le menu de boot, masher la touche du menu boot UEFI (F12/F11 selon carte mère)
et sélectionner l'entrée recréée à l'étape 9.

## Notes / pièges connus

- Un fichier `_inc` seul, sans son `_full` parent, **n'est pas restaurable** —
  c'est pour ça que `nas-backup.sh` garde toute la chaîne sur le NAS (voir son
  header) et ne purge l'ancienne chaîne qu'après **vérification sha256** du
  nouveau full. Si jamais tu trouves un NAS avec uniquement des `_inc` orphelins
  (ancien bug corrigé début juillet 2026), il faudra relancer un `--full`
  depuis la machine source avant de pouvoir t'en servir — `nas-restore.sh --list`
  le détecte et te le dit.
- `/boot` et `/boot/efi` n'ont **qu'une seule version** sur le NAS — pas
  d'historique, juste le dernier état connu. Normal : ils changent rarement
  (mises à jour kernel/GRUB) et sont petits.
- Le swap est en `zram` (RAM compressée) — rien à restaurer, il se recrée
  automatiquement au boot.
