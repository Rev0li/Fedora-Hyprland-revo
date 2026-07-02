# last-task-test.md — Valider le durcissement backup (session 2026-07-02)

> Le pipeline a été durci (sha256 vérifié, purge conditionnelle, `nas-restore.sh`,
> full hebdo, sysinfo, preset `--unattended`) — commits `f58dc1a..5b870e5`.
> Tout est testé en isolation, mais **trois choses restent à valider en réel**.
> Ce fichier est la checklist : coche, puis supprime-le quand tout est ✅.

---

## 1. Valider le full lancé le 02/07 (~5 min, dès qu'il est terminé)

C'est la **première chaîne vérifiée** (sidecars + sysinfo). À contrôler :

```bash
# a. Le run s'est bien terminé (dernière ligne : "Backup NAS terminé avec succès")
#    → relis la sortie du terminal kitty du backup.

# b. Vue d'ensemble : chaque subvolume doit avoir UN full récent, zéro orphelin
./nas-restore.sh --list

# c. Intégrité : chaque fichier a son sidecar et tout doit répondre "OK"
ssh nas-songsurf "cd /volume1/backup-rev0/fedora_backup && sha256sum -c *.sha256"

# d. Contenu attendu sur le NAS :
ssh nas-songsurf "ls -la /volume1/backup-rev0/fedora_backup/"
```

**Critères ✅ :**

- [ ] `root-<STAMP>_full.btrfs.zst` + `home-<STAMP>_full.btrfs.zst` du 02/07, chacun avec `.sha256`
- [ ] `boot-<STAMP>.tar.zst`, `boot-efi-<STAMP>.tar.zst`, **`sysinfo-<STAMP>.tar.zst`** (nouveau) + leurs `.sha256`
- [ ] Les **anciens fichiers du 01/07 ont disparu** (purge post-vérification)
- [ ] `sha256sum -c` répond `OK` pour tous
- [ ] Localement : `cat backups/nas-backup-state/root.chain` = **une seule ligne** (le nouveau full) ; `root.parent` = le nouveau STAMP

**Si ❌ (mismatch ou fichier manquant)** : ne rien purger à la main — relance
simplement `./nas-backup.sh --full`. Le script ne touche jamais à l'ancienne
chaîne tant qu'un nouveau full n'est pas vérifié.

---

## 2. Premier cycle hebdo automatique (dimanche 06/07, puis lundi)

- [ ] Avant dimanche : `systemctl --user list-timers 'nas-backup*'` affiche
      `NEXT` = dimanche 20:30 pour `nas-backup-reminder-full.timer`
      (si `NEXT` est vide : un rappel précédent attend encore un clic —
      il expire seul au bout de 4 h, ou `systemctl --user stop nas-backup-reminder-full.service`)
- [ ] Dimanche 20:30 : la notif « Sauvegarde NAS hebdomadaire (complète) » apparaît
- [ ] Après le run : refaire le bloc 1 (nouvelle chaîne, ancienne purgée)

---

## 3. Prochain drill VM (à planifier — suit `tuto_vm_test.md`)

Deux choses n'ont **jamais tourné en conditions réelles** :

### a. `nas-restore.sh` (le rejeu automatique)

Dans la VM du drill, après l'étape partitionnement (`tuto_vm_test.md` §4-5) :

```bash
NAS=<user@ip>  BK=/volume1/backup-rev0/fedora_backup

NAS_HOST=$NAS NAS_DEST_PATH=$BK ./nas-restore.sh --list             # inventaire
NAS_HOST=$NAS NAS_DEST_PATH=$BK ./nas-restore.sh --sysinfo ./sysinfo # layout de réf.
sudo mount -t btrfs -o subvolid=5 /dev/sda3 /mnt/top
NAS_HOST=$NAS NAS_DEST_PATH=$BK ./nas-restore.sh --dest /mnt/top    # root + home
NAS_HOST=$NAS NAS_DEST_PATH=$BK ./nas-restore.sh \
  --boot /mnt/restore/boot --efi /mnt/restore/boot/efi
```

- [ ] `--list` cohérent avec le contenu NAS
- [ ] `--dest` : vérification sha256 puis réception sans erreur, subvols `root`/`home`
      promus, **le dernier snapshot `root-<STAMP>` reste** dans le top-level
      (c'est le parent de reprise des incrémentaux)
- [ ] La VM boote après le chroot/GRUB (`restore.md` §9-11)
- [ ] Bonus : depuis le système restauré, `./nas-backup.sh` repart en **incrémental**
      (pas en full) — preuve que la reprise de parent fonctionne

### b. `install.sh --preset preset.sh --unattended`

Dans une **VM Fedora fraîche** (jamais sur la vraie machine) :

```bash
./install.sh --preset preset.sh --unattended
```

- [ ] Zéro question posée, sélection affichée = preset (sans `nvidia` si la VM
      n'a pas de GPU NVIDIA — le garde-fou doit le filtrer seul)
- [ ] Install complète, `./check-install.sh` OK après reboot

---

## 4. Chantier ouvert (non planifié) : copie offsite — 3-2-1

Le NAS est **l'unique copie hors machine**. Un sinistre commun (foudre, vol,
ransomware qui atteint le NAS) emporte tout. Options discutées, à trancher :

- `rclone` chiffré (crypt) du dossier NAS vers un cloud, en cron sur le NAS
- ou disque externe branché ponctuellement, copie du dossier, puis débranché

Les `.sha256` déjà en place permettront de vérifier la copie offsite telle quelle
(`sha256sum -c`), quel que soit le support.
