# Tuto — Tester la restauration NAS dans une VM (drill, zéro risque)

> But : **prouver que `restore.md` fonctionne vraiment**, sur une VM jetable,
> sans jamais toucher au disque réel. Si une étape casse ici, c'est un bug de
> doc ou de backup trouvé au calme — pas le jour du sinistre.
>
> Principe : la **VM = la « nouvelle machine »**, un **Live ISO Fedora** = le
> milieu de secours. On y rejoue `restore.md` presque tel quel.
>
> Pourquoi c'est plus simple qu'un vrai bare-metal :
> - La VM est **isolée** → elle ne voit pas les disques de l'hôte → **on réutilise
>   les UUID d'origine** (donc **pas** d'édition de `/etc/fstab`, on saute `restore.md` §10).
> - `efibootmgr` écrit dans la **NVRAM propre de la VM** (OVMF) → l'étape bootloader
>   est testée fidèlement, sans polluer la NVRAM de ton PC.
> - Dans le Live, `sudo` est **sans mot de passe** (pas de YubiKey à sortir).

---

## 0. Ce que ce test valide (et ne valide pas)

| ✅ Validé | ❌ Non couvert (normal) |
|---|---|
| Intégrité des streams `root` + `home` (`btrfs receive`) | La NVRAM du **vrai** firmware (spécifique à ta CM) |
| Chaîne de boot : shim → GRUB → BLS → kernel → initramfs → systemd | Le GPU **NVIDIA** / la session **Hyprland** (pas de GPU sous QEMU) |
| `/boot` + `/boot/efi` (tar) et le `fstab` | Le dual-boot Windows (`/dev/sdb`, absent de la VM) |
| La procédure `efibootmgr` (dans la NVRAM VM) | — |

Succès = **la VM boote le système restauré jusqu'à un login** (on vise le mode
texte multi-user, pas le bureau graphique).

---

## 1. Sur l'hôte — prérequis

Déjà présents chez toi (vérifiés) : `qemu-system-x86_64`, OVMF
(`/usr/share/edk2/ovmf/OVMF_CODE.fd` + `OVMF_VARS.fd`), `/dev/kvm`, ~165 Go libres.

À récupérer :

- **Une ISO Fedora Live** (Workstation Live conseillée : shell + `btrfs-progs`,
  `zstd`, `tar`, `openssh`, `sgdisk` déjà dedans). Pose-la p.ex. dans `~/Downloads/`.
- L'affichage QEMU : si `-display gtk` râle plus bas, `sudo dnf install qemu-ui-gtk`
  (ou remplace par `-display sdl`, ou `-vnc :1` + un client VNC).

```bash
DRILL=/home/rev0li/restore-drill      # dossier de travail (déjà en nodatacow)
ISO=~/Downloads/Fedora-Workstation-Live-x86_64-*.iso   # ← adapte au nom réel

# Disque virtuel (~100 Go, sparse) + NVRAM UEFI dédiée à la VM
qemu-img create -f qcow2 "$DRILL/drill.qcow2" 100G
cp /usr/share/edk2/ovmf/OVMF_VARS.fd "$DRILL/OVMF_VARS.drill.fd"
```

---

## 2. Sur l'hôte — lancer la VM sur le Live ISO

Le disque est présenté en **SATA (AHCI)** → il apparaît en `/dev/sda` dans la VM
(comme sur ta vraie machine, et compatible avec l'initramfs restauré).

```bash
qemu-system-x86_64 \
  -name restore-drill -machine q35,accel=kvm -cpu host -smp 4 -m 6G \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/ovmf/OVMF_CODE.fd \
  -drive if=pflash,format=raw,file="$DRILL/OVMF_VARS.drill.fd" \
  -drive file="$DRILL/drill.qcow2",format=qcow2,if=none,id=disk0 \
    -device ich9-ahci,id=ahci -device ide-hd,drive=disk0,bus=ahci.0 \
  -cdrom "$ISO" -boot menu=on \
  -nic user,model=virtio-net-pci \
  -display gtk
```

> Au boot OVMF, si besoin appuie sur **Échap/F2** pour choisir le CD-ROM.
> Choisis **« Test this media & start Fedora »** ou démarre le live, puis ouvre un
> **terminal** dans la session live.

**Réseau NAS** : le mode `user` (NAT) route vers ton LAN via l'hôte, donc le NAS
`192.168.1.45` est joignable depuis la VM. Vérifie dans le terminal live :

```bash
ping -c1 192.168.1.45
```

Si ça ne passe pas, arrête la VM et remplace `-nic user,...` par un pont
(`-nic bridged,br=<ton_pont>,model=virtio-net-pci`) — demande-moi si besoin.

---

## 3. Dans la VM (Live) — se connecter au NAS

Le Live n'a pas ta clé SSH. Deux options, la plus simple d'abord :

**Option A — mot de passe SSH (si activé sur le Synology).**
Rien à copier, on tape le mot de passe à chaque `ssh` (ou on ouvre un `ssh` maître) :

```bash
NAS="rev0li08@192.168.1.45"
BK=/volume1/backup-rev0/fedora_backup
ssh -o StrictHostKeyChecking=accept-new "$NAS" true   # accepte la clé d'hôte + teste
```

**Option B — passer ta clé via un dossier partagé 9p** (si le NAS refuse le mot de passe).
Sur l'**hôte**, avant de lancer la VM, ajoute une copie de la clé au partage puis
ajoute le flag `-virtfs` à la commande QEMU :

```bash
# hôte
mkdir -p "$DRILL/share" && cp ~/.ssh/nas_songsurf "$DRILL/share/"
# … et ajoute à la commande qemu de l'étape 2 :
#   -virtfs local,path=$DRILL/share,mount_tag=drillshare,security_model=mapped-xattr,id=drillshare
```

```bash
# VM (live)
mkdir -p /mnt/share && sudo mount -t 9p -o trans=virtio,version=9p2000.L drillshare /mnt/share
mkdir -p ~/.ssh && cp /mnt/share/nas_songsurf ~/.ssh/ && chmod 600 ~/.ssh/nas_songsurf
NAS="rev0li08@192.168.1.45"; BK=/volume1/backup-rev0/fedora_backup
alias ssh='ssh -i ~/.ssh/nas_songsurf -o StrictHostKeyChecking=accept-new'
```

Repère les fichiers (ici ceux du 1er juillet ; adapte si tu refais le drill plus tard) :

```bash
ssh "$NAS" "cat $BK/backup.log"        # historique
ROOT=root-20260701_011551_full.btrfs.zst
HOME_=home-20260701_011551_full.btrfs.zst
BOOT=boot-20260701_011551.tar.zst
EFI=boot-efi-20260701_011551.tar.zst
```

> Ta chaîne actuelle n'a **que des fulls** (le dernier `--full` a purgé les
> incréments) → **aucun `_inc` à réappliquer**. Cas le plus simple.

---

## 4. Dans la VM — partitionner `/dev/sda` (= `restore.md` §5)

```bash
lsblk                       # confirme que la cible est bien /dev/sda (100 Go)
DISK=/dev/sda

sudo sgdisk --zap-all "$DISK"
sudo sgdisk -n 1:2048:+600M -t 1:ef00 -c 1:"EFI System Partition" "$DISK"
sudo sgdisk -n 2:0:+2048M   -t 2:8300 -c 2:"boot"                "$DISK"
sudo sgdisk -n 3:0:0        -t 3:8300 -c 3:"fedora"              "$DISK"
sudo partprobe "$DISK"
```

## 5. Formater en **réutilisant les UUID d'origine** (VM isolée → sans risque, = `restore.md` §6)

```bash
sudo mkfs.vfat  -F32 -i 0E3DAFE4 -n EFI "${DISK}1"
sudo mkfs.ext4  -U 8510bfa7-5e82-49bf-8cd3-144593749b8b -L boot "${DISK}2"
sudo mkfs.btrfs -U 6849cd01-809a-4da6-851b-11fe50f615f9 -L fedora "${DISK}3"
```

> Comme on garde les UUID d'origine, le `fstab` restauré et le stub GRUB de l'ESP
> pointeront déjà juste : **on saute entièrement `restore.md` §10**.

## 6. Recevoir `root` et `home` (= `restore.md` §7)

On monte le top-level avec `compress=zstd` pour que `home` tienne à l'aise.

```bash
sudo mkdir -p /mnt/top
sudo mount -t btrfs -o subvolid=5,compress=zstd "${DISK}3" /mnt/top

# root (~9,5 Gio compressés) puis home (~46 Gio) — ça tire depuis le NAS, sois patient
ssh "$NAS" "cat $BK/$ROOT"  | zstd -d | sudo btrfs receive /mnt/top/
ssh "$NAS" "cat $BK/$HOME_" | zstd -d | sudo btrfs receive /mnt/top/

# Les subvols reçus portent le nom du snapshot ; on en fait 'root' et 'home' inscriptibles
sudo btrfs subvolume snapshot /mnt/top/root-20260701_011551 /mnt/top/root
sudo btrfs subvolume snapshot /mnt/top/home-20260701_011551 /mnt/top/home
sudo btrfs subvolume delete   /mnt/top/root-20260701_011551
sudo btrfs subvolume delete   /mnt/top/home-20260701_011551
sudo umount /mnt/top
```

## 7. Monter proprement + restaurer `/boot` et `/boot/efi` (= `restore.md` §8)

```bash
sudo mkdir -p /mnt/restore
sudo mount -o subvol=root "${DISK}3" /mnt/restore
sudo mount -o subvol=home "${DISK}3" /mnt/restore/home
sudo mount "${DISK}2" /mnt/restore/boot
sudo mount "${DISK}1" /mnt/restore/boot/efi

ssh "$NAS" "cat $BK/$BOOT" | zstd -d | sudo tar -xpf - --selinux --acls --xattrs -C /mnt/restore/boot/
ssh "$NAS" "cat $BK/$EFI"  | zstd -d | sudo tar -xpf - -C /mnt/restore/boot/efi/
```

## 8. Chroot : GRUB + initramfs + entrée UEFI (= `restore.md` §9)

```bash
for d in dev proc sys; do sudo mount --bind /$d /mnt/restore/$d; done
sudo mount --bind /sys/firmware/efi/efivars /mnt/restore/sys/firmware/efi/efivars
sudo cp /etc/resolv.conf /mnt/restore/etc/resolv.conf     # DNS dans le chroot au besoin
sudo chroot /mnt/restore /bin/bash
```

Dans le chroot :

```bash
# initramfs : --no-hostonly pour embarquer TOUS les pilotes (portable VM/autre matériel)
dracut --force --regenerate-all --no-hostonly

# GRUB
grub2-mkconfig -o /etc/grub2-efi.cfg

# Entrée UEFI → écrite dans la NVRAM de la VM (OVMF), pas celle de l'hôte
efibootmgr -c -d /dev/sda -p 1 -L "Fedora" -l '\EFI\fedora\shimx64.efi'
efibootmgr -v      # vérifie l'entrée

# Confort drill : boot en mode texte (évite NVIDIA/SDDM sous QEMU) + SELinux permissif au 1er boot
systemctl set-default multi-user.target
grubby --update-kernel=ALL --args="enforcing=0"

exit
```

## 9. Démonter et rebooter la VM sur le disque restauré

```bash
sudo umount -R /mnt/restore
# Dans la fenêtre QEMU : Machine ▸ Reset, et retire le CD (ou choisis le disque
# dur dans le menu de boot OVMF/Échap). Le mieux : ferme la VM…
```

…puis **relance-la SANS le `-cdrom`** (sinon elle rebooterait sur l'ISO) :

```bash
# hôte — même commande qu'à l'étape 2, mais sans la ligne -cdrom/-boot :
qemu-system-x86_64 \
  -name restore-drill -machine q35,accel=kvm -cpu host -smp 4 -m 6G \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/ovmf/OVMF_CODE.fd \
  -drive if=pflash,format=raw,file="$DRILL/OVMF_VARS.drill.fd" \
  -drive file="$DRILL/drill.qcow2",format=qcow2,if=none,id=disk0 \
    -device ich9-ahci,id=ahci -device ide-hd,drive=disk0,bus=ahci.0 \
  -nic user,model=virtio-net-pci -display gtk
```

## 10. Vérifs de réussite (dans la VM restaurée)

Tu dois arriver à un **login texte**. Connecte-toi (`rev0li` + ton mot de passe), puis :

```bash
findmnt /                 # / monté depuis /dev/sda3, subvol=root
findmnt /home /boot /boot/efi
ls ~                      # tes données home sont là
uname -r ; cat /etc/os-release
journalctl -b -p err --no-pager | head   # pas d'erreur bloquante ?
```

Tout est cohérent → **`restore.md` est prouvé de bout en bout.** 🎉

## 11. Nettoyage (sur l'hôte)

```bash
# ferme la VM, puis :
rm -rf /home/rev0li/restore-drill/drill.qcow2 \
       /home/rev0li/restore-drill/OVMF_VARS.drill.fd \
       /home/rev0li/restore-drill/share
```

---

## Pièges connus / notes

- **Long & gourmand** : le drill tire ~56 Go depuis le NAS (comme un vrai
  restore). Prévoyez le temps et la place.
- **`sudo` sans mot de passe** dans le Live (utilisateur `liveuser`) : normal.
- **SELinux** : si le 1er boot boucle sur un relabel, `enforcing=0` (étape 8) l'évite ;
  au 1er vrai boot post-relabel on peut le repasser en `enforcing`.
- **Pas de GUI** : Hyprland/NVIDIA ne démarreront pas sous QEMU — c'est attendu,
  ce n'est pas un échec de restauration (d'où le mode texte).
- **Enseignements pour `restore.md`** (à répercuter si le drill valide) :
  ajouter `--no-hostonly` au `dracut` (portabilité matériel/VM), et préciser que
  le cas « réutiliser les UUID » s'applique aussi à une VM isolée (pas d'édition fstab).
```
