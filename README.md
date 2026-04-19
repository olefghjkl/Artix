# Artix Linux installer (dinit)

Two-phase, interactive installer for Artix Linux using the **dinit** init
system, following the official Artix install guide.

## Files

- `install-artix.sh` — runs on the **live ISO** (partition, format, mount,
  `basestrap`, `fstabgen`, then enters `artix-chroot`).
- `chroot-setup.sh` — runs **inside the chroot** (timezone, locale, hostname,
  users, network daemon, GRUB, optional Xorg/DE/DM).

`install-artix.sh` copies `chroot-setup.sh` to `/mnt/root/` and executes it
via `artix-chroot /mnt`.

## Requirements

- Boot from the official **Artix dinit** live ISO
  (<https://artixlinux.org/download.php>).
- A working network connection (wired is auto-configured; for Wi-Fi use
  `connmanctl` or `wpa_supplicant` before running the script).
- Target disk you are willing to wipe.

## Usage

From the live ISO, log in as `root` and bring both scripts into the live
environment (USB, `scp`, `curl`, whatever you prefer). Keep them in the
**same directory**.

```sh
chmod +x install-artix.sh chroot-setup.sh
./install-artix.sh
```

The script will:

1. Detect **UEFI vs BIOS**.
2. Ask for the target disk (default `/dev/sda`) and offer to launch `cfdisk`.
3. Ask which partition is root / ESP / boot / home / swap.
4. Format them (`ext4` with labels `ROOT` / `BOOT` / `HOME`, `swap` labelled
   `SWAP`, ESP as `fat32` labelled `ESP`).
5. Mount everything under `/mnt`.
6. Start `ntpd` via `dinitctl`.
7. `basestrap /mnt base base-devel dinit elogind-dinit <kernel> linux-firmware`.
8. `fstabgen -U /mnt >> /mnt/etc/fstab` (with a review step).
9. Drop into `artix-chroot` and run `chroot-setup.sh`, which:
   - sets timezone, runs `hwclock --systohc`
   - generates locale, writes `/etc/locale.conf`
   - writes `/etc/hostname` and `/etc/hosts`
   - sets root password and (optionally) creates a `wheel`/sudo user
   - installs a network daemon (`connman-dinit` by default) and enables it
     under `/etc/dinit.d/boot.d/`
   - installs Intel or AMD microcode (auto-detected)
   - installs and configures GRUB (BIOS or UEFI, with `os-prober`)
   - optionally installs Xorg + a DE (KDE/GNOME/MATE/XFCE/LXQt) and a
     DM (`sddm-dinit`, `lightdm-dinit`, `gdm-dinit`, or `lxdm-dinit`)
10. Unmounts and reboots.

## dinit notes

Enabling a service under dinit from inside the chroot is done with a
symlink into the `boot.d` directory, e.g.:

```sh
ln -sf ../connmand /etc/dinit.d/boot.d/connmand
```

The service will start on the **next boot** of the installed system (the
live ISO's `dinitctl start` only affects the live environment, not the
chroot target).

## Safety

- The script prompts before every destructive step (partitioning, formatting,
  reboot).
- Nothing is run automatically with `--noconfirm` on the host live ISO —
  `--noconfirm` is only used inside the chroot for package installs so the
  installer can run unattended between prompts.
- If the chroot phase fails, `/mnt` is left mounted and you can re-enter with
  `artix-chroot /mnt /root/chroot-setup.sh`.

## Manual fallback (if you prefer to do it yourself)

The install-artix.sh script mirrors the Artix guide exactly. If something
goes wrong, the equivalent manual commands are:

```sh
# partition
cfdisk /dev/sda

# format
mkfs.ext4 -L ROOT /dev/sda2
mkfs.fat  -F 32   /dev/sda1 && fatlabel /dev/sda1 ESP   # UEFI only
mkswap    -L SWAP /dev/sda4                              # optional

# mount
mount   /dev/disk/by-label/ROOT /mnt
mkdir   /mnt/boot /mnt/boot/efi
mount   /dev/disk/by-label/ESP  /mnt/boot/efi            # UEFI only
swapon  /dev/disk/by-label/SWAP

# base system (dinit)
dinitctl start ntpd
basestrap /mnt base base-devel dinit elogind-dinit linux linux-firmware
fstabgen -U /mnt >> /mnt/etc/fstab
artix-chroot /mnt
```

Then follow the steps inside `chroot-setup.sh` by hand.
