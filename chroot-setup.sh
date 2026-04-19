#!/usr/bin/env bash
# =============================================================================
# Artix Linux installer (CHROOT phase) -- dinit init
# -----------------------------------------------------------------------------
# This script runs inside `artix-chroot /mnt` and performs:
#   - timezone + hwclock
#   - locale
#   - hostname / hosts
#   - root password + regular user
#   - DHCP client + connman-dinit
#   - GRUB install (BIOS or UEFI) + os-prober + (optional) microcode
#   - optional Xorg + Desktop Environment + Display Manager (dinit)
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
    local prompt="$1" default="${2:-}" ans
    if [[ -n "$default" ]]; then
        read -rp "$prompt [$default]: " ans
        printf '%s' "${ans:-$default}"
    else
        read -rp "$prompt: " ans
        printf '%s' "$ans"
    fi
}
confirm() { local ans; read -rp "$1 [y/N]: " ans; [[ "$ans" =~ ^[Yy]$ ]]; }

# ---------- env passed from live-phase --------------------------------------
FIRMWARE="bios"
DISK="/dev/sda"
KERNEL="linux"
if [[ -f /root/.artix-install.env ]]; then
    # shellcheck disable=SC1091
    source /root/.artix-install.env
fi
ok "Chroot phase -- firmware=$FIRMWARE  disk=$DISK  kernel=$KERNEL"

# ---------- basic tooling ---------------------------------------------------
info "Installing base tooling (nano, grub, os-prober, efibootmgr)..."
pacman -Sy --noconfirm --needed nano grub os-prober efibootmgr

# =============================================================================
# 1. Time zone + hwclock
# =============================================================================
hr
info "Time zone configuration"
echo "Examples: Europe/London, America/New_York, Asia/Jerusalem, Asia/Tokyo"
TZ=$(ask "Time zone (Region/City)" "UTC")
if [[ -f "/usr/share/zoneinfo/$TZ" ]]; then
    ln -sf "/usr/share/zoneinfo/$TZ" /etc/localtime
    ok "Time zone set to $TZ"
else
    warn "/usr/share/zoneinfo/$TZ not found. Falling back to UTC."
    ln -sf /usr/share/zoneinfo/UTC /etc/localtime
fi
hwclock --systohc
ok "hwclock --systohc done (UTC)."

# =============================================================================
# 2. Locale
# =============================================================================
hr
info "Locale configuration"
LOCALE=$(ask "Primary locale" "en_US.UTF-8")

# uncomment the requested locale and en_US.UTF-8 as a sane fallback
sed -i -E "s/^#\s*(en_US\.UTF-8 UTF-8)/\1/" /etc/locale.gen
sed -i -E "s|^#\s*(${LOCALE//./\\.} UTF-8)|\1|" /etc/locale.gen || true

if ! grep -qE "^${LOCALE//./\\.} UTF-8" /etc/locale.gen; then
    echo "$LOCALE UTF-8" >> /etc/locale.gen
fi

locale-gen
cat > /etc/locale.conf <<EOF
LANG=$LOCALE
LC_COLLATE=C
EOF
ok "Locale set to $LOCALE (LC_COLLATE=C)."

# =============================================================================
# 3. Hostname + hosts
# =============================================================================
hr
HOST=$(ask "Hostname" "artix")
echo "$HOST" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOST}.localdomain  ${HOST}
EOF
ok "Hostname = $HOST, /etc/hosts written."

# =============================================================================
# 4. Root password + user
# =============================================================================
hr
info "Set the ROOT password"
until passwd root; do warn "Try again."; done

USERNAME=$(ask "Create a regular user (leave blank to skip)" "")
if [[ -n "$USERNAME" ]]; then
    useradd -m -G wheel -s /bin/bash "$USERNAME"
    info "Set password for $USERNAME"
    until passwd "$USERNAME"; do warn "Try again."; done

    if confirm "Grant $USERNAME sudo access via wheel group?"; then
        pacman -S --noconfirm --needed sudo
        # Uncomment "%wheel ALL=(ALL:ALL) ALL" safely
        sed -i -E 's/^#\s*(%wheel ALL=\(ALL(:ALL)?\) ALL)/\1/' /etc/sudoers
        ok "wheel group has sudo privileges."
    fi
fi

# =============================================================================
# 5. Network: DHCP client + connman (dinit)
# =============================================================================
hr
info "Network configuration"
echo "  1) connman (recommended, GUI-friendly)"
echo "  2) dhcpcd  (simple wired DHCP)"
echo "  3) both"
NET_CHOICE=$(ask "Choose" "1")

case "$NET_CHOICE" in
    1)
        pacman -S --noconfirm --needed connman-dinit
        ln -sf ../connmand /etc/dinit.d/boot.d/connmand
        ok "connmand enabled under dinit."
        ;;
    2)
        pacman -S --noconfirm --needed dhcpcd-dinit
        ln -sf ../dhcpcd /etc/dinit.d/boot.d/dhcpcd
        ok "dhcpcd enabled under dinit."
        ;;
    3)
        pacman -S --noconfirm --needed connman-dinit dhcpcd
        ln -sf ../connmand /etc/dinit.d/boot.d/connmand
        ok "connmand enabled; dhcpcd installed (not auto-enabled)."
        ;;
    *)
        warn "Skipping network daemon install."
        ;;
esac

if confirm "Also install wpa_supplicant (wireless)?"; then
    pacman -S --noconfirm --needed wpa_supplicant
fi

# =============================================================================
# 6. CPU microcode (optional but recommended)
# =============================================================================
hr
CPU_VENDOR=$(grep -m1 -o -E 'GenuineIntel|AuthenticAMD' /proc/cpuinfo || true)
case "$CPU_VENDOR" in
    GenuineIntel)
        info "Intel CPU detected; installing intel-ucode."
        pacman -S --noconfirm --needed intel-ucode
        ;;
    AuthenticAMD)
        info "AMD CPU detected; installing amd-ucode."
        pacman -S --noconfirm --needed amd-ucode
        ;;
    *)
        warn "Could not detect CPU vendor; skipping microcode."
        ;;
esac

# =============================================================================
# 7. GRUB
# =============================================================================
hr
info "Installing GRUB bootloader..."
if [[ "$FIRMWARE" == "uefi" ]]; then
    grub-install --target=x86_64-efi \
                 --efi-directory=/boot/efi \
                 --bootloader-id=grub \
                 --recheck
else
    grub-install --target=i386-pc --recheck "$DISK"
fi

# Enable os-prober to see other OSes (Windows, etc.)
if ! grep -q '^GRUB_DISABLE_OS_PROBER=false' /etc/default/grub; then
    echo 'GRUB_DISABLE_OS_PROBER=false' >> /etc/default/grub
fi

grub-mkconfig -o /boot/grub/grub.cfg
ok "GRUB installed and configured."

# =============================================================================
# 8. Optional: Xorg + Desktop Environment + Display Manager
# =============================================================================
hr
if confirm "Install Xorg + a Desktop Environment now?"; then
    pacman -S --noconfirm --needed xorg

    echo "Desktop Environment:"
    echo "  1) KDE Plasma   (plasma + kde-applications)"
    echo "  2) GNOME        (gnome)"
    echo "  3) MATE         (mate + mate-extra)"
    echo "  4) XFCE         (xfce4 + xfce4-goodies)"
    echo "  5) LXQt         (lxqt)"
    echo "  6) none"
    DE_CHOICE=$(ask "Choose" "4")

    case "$DE_CHOICE" in
        1) pacman -S --noconfirm --needed plasma kde-applications ;;
        2) pacman -S --noconfirm --needed gnome ;;
        3) pacman -S --noconfirm --needed mate mate-extra ;;
        4) pacman -S --noconfirm --needed xfce4 xfce4-goodies ;;
        5) pacman -S --noconfirm --needed lxqt ;;
        *) warn "No DE installed." ;;
    esac

    echo
    echo "Display Manager (dinit versions):"
    echo "  1) SDDM    (good for KDE/LXQt)"
    echo "  2) LightDM (good for XFCE/MATE)"
    echo "  3) GDM     (good for GNOME)"
    echo "  4) LXDM"
    echo "  5) none (use startx / .xinitrc)"
    DM_CHOICE=$(ask "Choose" "2")

    case "$DM_CHOICE" in
        1) pacman -S --noconfirm --needed sddm-dinit
           ln -sf ../sddm    /etc/dinit.d/boot.d/sddm    ;;
        2) pacman -S --noconfirm --needed lightdm-dinit
           ln -sf ../lightdm /etc/dinit.d/boot.d/lightdm ;;
        3) pacman -S --noconfirm --needed gdm-dinit
           ln -sf ../gdm     /etc/dinit.d/boot.d/gdm     ;;
        4) pacman -S --noconfirm --needed lxdm-dinit
           ln -sf ../lxdm    /etc/dinit.d/boot.d/lxdm    ;;
        *) warn "No display manager enabled." ;;
    esac
fi

# =============================================================================
# Done
# =============================================================================
hr
ok "Chroot configuration complete."
echo
info "Summary:"
printf "  hostname : %s\n" "$HOST"
printf "  timezone : %s\n" "$TZ"
printf "  locale   : %s\n" "$LOCALE"
printf "  kernel   : %s\n" "$KERNEL"
printf "  firmware : %s\n" "$FIRMWARE"
printf "  init     : dinit\n"
echo
ok "You can now exit the chroot (the live-phase script will reboot)."
