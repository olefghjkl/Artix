#!/usr/bin/env bash
# =============================================================================
# Artix Linux installer (LIVE ISO phase) -- dinit init
# -----------------------------------------------------------------------------
# Run this from the Artix live ISO as root.
# It will:
#   1) let you partition the disk (cfdisk) or use an existing layout
#   2) format & label partitions (ROOT / BOOT / HOME / SWAP / ESP)
#   3) mount everything under /mnt
#   4) start the NTP daemon (dinit)
#   5) basestrap base/base-devel + dinit + elogind-dinit + kernel + firmware
#   6) fstabgen -U /mnt >> /mnt/etc/fstab
#   7) copy chroot-setup.sh into /mnt/root and drop you inside artix-chroot
#
# After the chroot phase finishes, this script will unmount and reboot.
# =============================================================================

set -euo pipefail

# ---------- pretty output ----------------------------------------------------
RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YLW=$'\033[1;33m'
BLU=$'\033[0;34m'; BLD=$'\033[1m'; NC=$'\033[0m'
info() { printf "%s[*]%s %s\n" "$BLU"  "$NC" "$*"; }
ok()   { printf "%s[+]%s %s\n" "$GRN"  "$NC" "$*"; }
warn() { printf "%s[!]%s %s\n" "$YLW"  "$NC" "$*"; }
err()  { printf "%s[x]%s %s\n" "$RED"  "$NC" "$*" >&2; }
die()  { err "$*"; exit 1; }
hr()   { printf '%s%s%s\n' "$BLD" "----------------------------------------------------------------" "$NC"; }

ask() {
    # ask "prompt" ["default"]  -> echoes answer
    local prompt="$1" default="${2:-}" ans
    if [[ -n "$default" ]]; then
        read -rp "$prompt [$default]: " ans
        printf '%s' "${ans:-$default}"
    else
        read -rp "$prompt: " ans
        printf '%s' "$ans"
    fi
}

confirm() {
    local ans
    read -rp "$1 [y/N]: " ans
    [[ "$ans" =~ ^[Yy]$ ]]
}

require_root() {
    [[ $EUID -eq 0 ]] || die "Run this script as root."
}

require_cmd() {
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || die "Missing required command: $c"
    done
}

# ---------- preflight --------------------------------------------------------
require_root
require_cmd cfdisk fdisk lsblk mkfs.ext4 mkfs.fat mkswap swapon mount \
            basestrap fstabgen artix-chroot dinitctl ping

hr
info "Artix Linux installer (dinit)"
hr

# ---------- detect firmware --------------------------------------------------
if [[ -d /sys/firmware/efi/efivars ]]; then
    FIRMWARE="uefi"
    ok  "Detected firmware: UEFI"
else
    FIRMWARE="bios"
    ok  "Detected firmware: BIOS / Legacy"
fi

# ---------- choose disk ------------------------------------------------------
echo
lsblk -d -o NAME,SIZE,MODEL,TYPE | grep -E 'disk$' || true
echo
DISK=$(ask "Target disk" "/dev/sda")
[[ -b "$DISK" ]] || die "$DISK is not a block device."

# ---------- partitioning -----------------------------------------------------
echo
warn "You are about to modify: $DISK"
warn "ALL DATA ON THE SELECTED PARTITIONS WILL BE DESTROYED."
confirm "Continue?" || die "Aborted by user."

echo
info "Partition layout guidance:"
if [[ "$FIRMWARE" == "uefi" ]]; then
    cat <<EOF
  Suggested (GPT / UEFI):
    ${DISK}1  ->  ~512 MiB  EFI System   (type 'EFI System')
    ${DISK}2  ->  rest      Linux root   (ext4)        [required]
    ${DISK}3  ->  optional  Linux home   (ext4)
    ${DISK}4  ->  optional  Linux swap
EOF
else
    cat <<EOF
  Suggested (DOS / BIOS):
    ${DISK}1  ->  optional  /boot        (ext4)
    ${DISK}2  ->  root      (ext4)                    [required]
    ${DISK}3  ->  optional  /home        (ext4)
    ${DISK}4  ->  optional  swap
EOF
fi
echo
if confirm "Launch cfdisk now to edit $DISK?"; then
    cfdisk "$DISK"
fi

echo
lsblk "$DISK"
echo

# ---------- partition selection ---------------------------------------------
ROOT_PART=$(ask "Root partition (required)" "${DISK}2")
[[ -b "$ROOT_PART" ]] || die "$ROOT_PART is not a block device."

BOOT_PART=""
HOME_PART=""
SWAP_PART=""
ESP_PART=""

if [[ "$FIRMWARE" == "uefi" ]]; then
    ESP_PART=$(ask "EFI System Partition (required on UEFI)" "${DISK}1")
    [[ -b "$ESP_PART" ]] || die "$ESP_PART is not a block device."
else
    if confirm "Separate /boot partition?"; then
        BOOT_PART=$(ask "Boot partition" "${DISK}1")
        [[ -b "$BOOT_PART" ]] || die "$BOOT_PART is not a block device."
    fi
fi

if confirm "Separate /home partition?"; then
    HOME_PART=$(ask "Home partition" "${DISK}3")
    [[ -b "$HOME_PART" ]] || die "$HOME_PART is not a block device."
fi

if confirm "Swap partition?"; then
    SWAP_PART=$(ask "Swap partition" "${DISK}4")
    [[ -b "$SWAP_PART" ]] || die "$SWAP_PART is not a block device."
fi

# ---------- final confirmation ----------------------------------------------
echo
hr
info "About to format the following:"
printf "  %-6s %s  (ext4, label ROOT)\n" "ROOT:"  "$ROOT_PART"
[[ -n "$ESP_PART"  ]] && printf "  %-6s %s  (fat32, label ESP)\n"  "ESP:"   "$ESP_PART"
[[ -n "$BOOT_PART" ]] && printf "  %-6s %s  (ext4, label BOOT)\n"  "BOOT:"  "$BOOT_PART"
[[ -n "$HOME_PART" ]] && printf "  %-6s %s  (ext4, label HOME)\n"  "HOME:"  "$HOME_PART"
[[ -n "$SWAP_PART" ]] && printf "  %-6s %s  (swap, label SWAP)\n"  "SWAP:"  "$SWAP_PART"
hr
confirm "Proceed with formatting?" || die "Aborted."

# ---------- format -----------------------------------------------------------
info "Formatting root: $ROOT_PART"
mkfs.ext4 -F -L ROOT "$ROOT_PART"

if [[ -n "$BOOT_PART" ]]; then
    info "Formatting /boot: $BOOT_PART"
    mkfs.ext4 -F -L BOOT "$BOOT_PART"
fi

if [[ -n "$HOME_PART" ]]; then
    info "Formatting /home: $HOME_PART"
    mkfs.ext4 -F -L HOME "$HOME_PART"
fi

if [[ -n "$SWAP_PART" ]]; then
    info "Formatting swap: $SWAP_PART"
    mkswap -L SWAP "$SWAP_PART"
fi

if [[ -n "$ESP_PART" ]]; then
    info "Formatting ESP: $ESP_PART"
    mkfs.fat -F 32 "$ESP_PART"
    fatlabel "$ESP_PART" ESP || warn "fatlabel failed (non-fatal)"
fi

# udev needs a moment to pick up new labels
sleep 2
udevadm settle || true

# ---------- mount ------------------------------------------------------------
info "Mounting partitions under /mnt"
[[ -n "$SWAP_PART" ]] && swapon /dev/disk/by-label/SWAP

mount /dev/disk/by-label/ROOT /mnt

mkdir -p /mnt/boot
mkdir -p /mnt/home

[[ -n "$BOOT_PART" ]] && mount /dev/disk/by-label/BOOT /mnt/boot
[[ -n "$HOME_PART" ]] && mount /dev/disk/by-label/HOME /mnt/home

if [[ "$FIRMWARE" == "uefi" ]]; then
    mkdir -p /mnt/boot/efi
    mount /dev/disk/by-label/ESP /mnt/boot/efi
fi

ok "Mounts complete:"
mount | grep -E ' /mnt(/|\s)' || true

# ---------- internet check ---------------------------------------------------
info "Checking internet connectivity..."
if ! ping -c 2 -W 3 artixlinux.org >/dev/null 2>&1; then
    warn "Cannot reach artixlinux.org."
    warn "If you need wireless, configure it now (connmanctl / wpa_supplicant),"
    warn "then re-run this script, or open another TTY to fix the network."
    confirm "Continue anyway?" || die "Aborted: no internet."
else
    ok "Internet is up."
fi

# ---------- NTP (dinit) ------------------------------------------------------
info "Starting NTP daemon (dinit)..."
dinitctl start ntpd || warn "Could not start ntpd via dinit (non-fatal)."

# ---------- kernel choice ----------------------------------------------------
echo
info "Choose a kernel:"
echo "  1) linux       (stable, default)"
echo "  2) linux-lts   (long-term support)"
echo "  3) linux-zen   (desktop tuned)"
KCHOICE=$(ask "Selection" "1")
case "$KCHOICE" in
    1) KERNEL="linux" ;;
    2) KERNEL="linux-lts" ;;
    3) KERNEL="linux-zen" ;;
    *) KERNEL="linux" ;;
esac
ok "Kernel: $KERNEL"

# ---------- basestrap --------------------------------------------------------
info "Running basestrap (this may take a while)..."
basestrap /mnt \
    base base-devel \
    dinit elogind-dinit \
    "$KERNEL" linux-firmware

# ---------- fstab ------------------------------------------------------------
info "Generating /etc/fstab (UUID based)"
fstabgen -U /mnt >> /mnt/etc/fstab
ok "fstab written. Preview:"
echo
cat /mnt/etc/fstab
echo
warn "Please review /mnt/etc/fstab before rebooting."
confirm "Does the fstab look correct?" || {
    warn "Opening editor..."
    ${EDITOR:-nano} /mnt/etc/fstab
}

# ---------- stage the chroot script -----------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f "$SCRIPT_DIR/chroot-setup.sh" ]]; then
    die "chroot-setup.sh not found next to this script ($SCRIPT_DIR)."
fi
install -Dm755 "$SCRIPT_DIR/chroot-setup.sh" /mnt/root/chroot-setup.sh

# Export firmware mode into the chroot
cat > /mnt/root/.artix-install.env <<EOF
FIRMWARE=$FIRMWARE
DISK=$DISK
KERNEL=$KERNEL
EOF

# ---------- chroot -----------------------------------------------------------
hr
info "Entering artix-chroot to finish configuration..."
hr
artix-chroot /mnt /bin/bash -lc '/root/chroot-setup.sh'
CHROOT_RC=$?

if [[ $CHROOT_RC -ne 0 ]]; then
    err "chroot-setup.sh exited with code $CHROOT_RC"
    warn "You are back on the live system. /mnt is still mounted."
    warn "Fix the issue and re-run:  artix-chroot /mnt /root/chroot-setup.sh"
    exit $CHROOT_RC
fi

# ---------- cleanup & reboot -------------------------------------------------
ok "Chroot phase finished."
rm -f /mnt/root/.artix-install.env
echo
if confirm "Unmount /mnt and reboot now?"; then
    info "Unmounting..."
    umount -R /mnt || warn "umount -R /mnt had issues."
    [[ -n "$SWAP_PART" ]] && swapoff "$SWAP_PART" || true
    ok "Rebooting. Remove the installation media."
    sleep 2
    reboot
else
    warn "Not rebooting. Remember to 'umount -R /mnt' before you reboot."
fi
