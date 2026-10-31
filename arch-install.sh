#!/usr/bin/env bash
#
# Arch Linux installer: UEFI, Limine, LUKS2 encryption, btrfs + Snapper snapshots
#
#   Drive 1 (DISK_SYS):  4G ESP (/boot, unencrypted) + LUKS2 containing btrfs
#                        with @, @games, @snapshots, ...
#   Drive 2 (DISK_HOME): LUKS2 containing btrfs, subvolume @home -> /home
#                        (same passphrase; unlocked automatically by a keyfile
#                        stored on the encrypted root)
#
# Run from the official Arch live ISO as root:
#   copy this script somewhere on the live system (e.g. /root), then:  bash arch-install.sh
#
# !! This ERASES both drives. Edit the CONFIG block first. !!

set -Eeuo pipefail

############################## CONFIG ##############################
DISK_SYS="/dev/nvme0n1"        # root + games
DISK_HOME="/dev/nvme1n1"       # /home only
HOSTNAME="midgar"
USERNAME="chou"
TIMEZONE="America/Kentucky/Louisville"
LOCALE="en_US.UTF-8"
KEYMAP="us"
DESKTOP="kde"                  # kde | gnome | none
GAMING="yes"                   # yes = multilib, Steam, gamemode, mangohud, 32-bit GPU libs
EXTRA_PKGS="firefox discord
    prismlauncher lutris goverlay
    gpu-screen-recorder gpu-screen-recorder-notification gpu-screen-recorder-ui
    kdeconnect
    bluez bluez-utils bluedevil
    ufw plasma-firewall
    headsetcontrol ntfs-3g
    spectacle gwenview plasma-systemmonitor okular
    haruna mpv elisa nano
    noto-fonts noto-fonts-cjk noto-fonts-emoji
    gamescope pipewire-jack"               # space-separated extra packages, e.g. "firefox neovim"
PLYMOUTH="yes"                 # yes = graphical boot splash with a password box for the LUKS prompt
PLYMOUTH_THEME="bgrt"      # must include a password dialog; list with: plymouth-set-default-theme -l
ESP_SIZE="4G"                  # ESP holds kernels + Limine, so keep it roomy
BTRFS_OPTS="noatime,compress=zstd:1,ssd,discard=async,space_cache=v2"
####################################################################

log()  { printf '\e[1;34m==>\e[0m %s\n' "$*"; }
warn() { printf '\e[1;33m[warn]\e[0m %s\n' "$*" >&2; }
die()  { printf '\e[1;31m[error]\e[0m %s\n' "$*" >&2; exit 1; }
trap 'die "Failed at line $LINENO: $BASH_COMMAND"' ERR

# nvme0n1 -> nvme0n1p1, sda -> sda1
part() { case "$1" in *[0-9]) echo "${1}p${2}" ;; *) echo "${1}${2}" ;; esac; }

# ------------------------------ preflight ------------------------------
[[ $EUID -eq 0 ]]                || die "Run as root."
[[ -d /sys/firmware/efi/efivars ]] || die "Not booted in UEFI mode."
[[ -b $DISK_SYS && -b $DISK_HOME ]] || die "Check DISK_SYS / DISK_HOME; one is not a block device."
[[ $DISK_SYS != "$DISK_HOME" ]]  || die "DISK_SYS and DISK_HOME must differ."
for d in "$DISK_SYS" "$DISK_HOME"; do
    if lsblk -nr -o MOUNTPOINTS "$d" | grep -q .; then
        die "$d has mounted partitions (is it the live USB?). Unmount first."
    fi
done
ping -c1 -W3 archlinux.org >/dev/null 2>&1 || die "No network. Connect first (iwctl for Wi-Fi)."
[[ $DESKTOP =~ ^(kde|gnome|none)$ ]] || die "DESKTOP must be kde, gnome or none."

echo
lsblk -o NAME,SIZE,MODEL,TYPE,MOUNTPOINTS "$DISK_SYS" "$DISK_HOME"
echo
warn "EVERYTHING on $DISK_SYS and $DISK_HOME will be destroyed."
read -rp "Type ERASE to continue: " reply
[[ $reply == ERASE ]] || die "Aborted."

read -rsp "Password for root: " ROOT_PW; echo
read -rsp "Password for $USERNAME: " USER_PW; echo
[[ -n $ROOT_PW && -n $USER_PW ]] || die "Passwords cannot be empty."

read -rsp "Disk encryption passphrase (used for BOTH drives): " LUKS_PW; echo
read -rsp "Repeat disk encryption passphrase: " LUKS_PW2; echo
[[ -n $LUKS_PW && $LUKS_PW == "$LUKS_PW2" ]] || die "Passphrases are empty or do not match."
unset LUKS_PW2

timedatectl set-ntp true
sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 10/' /etc/pacman.conf

# ----------------------------- partitioning ----------------------------
log "Partitioning"
for d in "$DISK_SYS" "$DISK_HOME"; do
    wipefs -af "$d"
    sgdisk --zap-all "$d"
done
sgdisk -n1:0:+"$ESP_SIZE" -t1:ef00 -c1:ESP      -n2:0:0 -t2:8309 -c2:cryptroot "$DISK_SYS"
sgdisk -n1:0:0            -t1:8309 -c1:crypthome "$DISK_HOME"
partprobe "$DISK_SYS" "$DISK_HOME"
udevadm settle
sleep 2

ESP=$(part "$DISK_SYS" 1)
ROOT_RAW=$(part "$DISK_SYS" 2)
HOME_RAW=$(part "$DISK_HOME" 1)

log "Encrypting both drives (LUKS2, same passphrase)"
for p in "$ROOT_RAW" "$HOME_RAW"; do
    printf '%s' "$LUKS_PW" | cryptsetup luksFormat --batch-mode --type luks2 --key-file=- "$p"
done
printf '%s' "$LUKS_PW" | cryptsetup open --allow-discards --key-file=- "$ROOT_RAW" cryptroot
printf '%s' "$LUKS_PW" | cryptsetup open --allow-discards --key-file=- "$HOME_RAW" crypthome
ROOT_LUKS_UUID=$(blkid -s UUID -o value "$ROOT_RAW")
HOME_LUKS_UUID=$(blkid -s UUID -o value "$HOME_RAW")

# From here on, ROOT_PART / HOME_PART are the *unlocked* devices that hold btrfs
ROOT_PART=/dev/mapper/cryptroot
HOME_PART=/dev/mapper/crypthome

log "Formatting"
mkfs.fat -F32 -n ESP "$ESP"
mkfs.btrfs -f -L arch-root "$ROOT_PART"
mkfs.btrfs -f -L arch-home "$HOME_PART"

# ---------------------------- subvolumes -------------------------------
log "Creating subvolumes"
mount "$ROOT_PART" /mnt
for sv in @ @snapshots @games @var_log @var_cache @var_tmp @tmp; do
    btrfs subvolume create "/mnt/$sv"
done
umount /mnt

mount "$HOME_PART" /mnt
btrfs subvolume create /mnt/@home
umount /mnt

log "Mounting"
mount -o "$BTRFS_OPTS,subvol=@" "$ROOT_PART" /mnt
mkdir -p /mnt/{boot,home,games,tmp,.snapshots,var/log,var/cache,var/tmp}
mount -o "$BTRFS_OPTS,subvol=@snapshots" "$ROOT_PART" /mnt/.snapshots
mount -o "$BTRFS_OPTS,subvol=@games"     "$ROOT_PART" /mnt/games
mount -o "$BTRFS_OPTS,subvol=@var_log"   "$ROOT_PART" /mnt/var/log
mount -o "$BTRFS_OPTS,subvol=@var_cache" "$ROOT_PART" /mnt/var/cache
mount -o "$BTRFS_OPTS,subvol=@var_tmp"   "$ROOT_PART" /mnt/var/tmp
mount -o "$BTRFS_OPTS,subvol=@tmp"       "$ROOT_PART" /mnt/tmp
mount -o "$BTRFS_OPTS,subvol=@home"      "$HOME_PART" /mnt/home
mount -o umask=0077 "$ESP" /mnt/boot
chmod 1777 /mnt/tmp /mnt/var/tmp

# ------------------------------ packages -------------------------------
log "Installing base system"
UCODE=intel-ucode
grep -q AuthenticAMD /proc/cpuinfo && UCODE=amd-ucode

GPU=none
GPU_INFO=$(lspci -nn | grep -Ei 'vga|3d|display' || true)
if   grep -qi nvidia <<<"$GPU_INFO";                  then GPU=nvidia
elif grep -Eqi 'amd|ati|radeon' <<<"$GPU_INFO";       then GPU=amd
elif grep -qi intel <<<"$GPU_INFO";                   then GPU=intel
fi
log "Detected GPU vendor: $GPU"

PKGS=(base linux linux-headers linux-firmware "$UCODE" btrfs-progs cryptsetup
      limine efibootmgr dosfstools
      networkmanager sudo base-devel git vim man-db man-pages bash-completion
      snapper snap-pac inotify-tools zram-generator reflector pciutils
      pipewire pipewire-alsa pipewire-pulse wireplumber btrfs-assistant)
# shellcheck disable=SC2206
PKGS+=($EXTRA_PKGS)
if [[ $PLYMOUTH == yes ]]; then PKGS+=(plymouth); fi
pacstrap -K /mnt "${PKGS[@]}"

genfstab -U /mnt >> /mnt/etc/fstab

# ------------------------- hand-off to chroot --------------------------
umask 077
{
    printf 'DISK_SYS=%q\n'   "$DISK_SYS"
    printf 'HOSTNAME_=%q\n'  "$HOSTNAME"
    printf 'USERNAME=%q\n'   "$USERNAME"
    printf 'TIMEZONE=%q\n'   "$TIMEZONE"
    printf 'LOCALE=%q\n'     "$LOCALE"
    printf 'KEYMAP=%q\n'     "$KEYMAP"
    printf 'DESKTOP=%q\n'    "$DESKTOP"
    printf 'GAMING=%q\n'     "$GAMING"
    printf 'GPU=%q\n'        "$GPU"
    printf 'PLYMOUTH=%q\n'        "$PLYMOUTH"
    printf 'PLYMOUTH_THEME=%q\n'  "$PLYMOUTH_THEME"
    printf 'ROOT_LUKS_UUID=%q\n'  "$ROOT_LUKS_UUID"
    printf 'HOME_LUKS_UUID=%q\n'  "$HOME_LUKS_UUID"
    printf 'ROOT_PW=%q\n'    "$ROOT_PW"
    printf 'USER_PW=%q\n'    "$USER_PW"
    printf 'LUKS_PW=%q\n'    "$LUKS_PW"
} > /mnt/root/install.env
umask 022

cat > /mnt/root/chroot-setup.sh <<'CHROOT_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "[chroot error] line $LINENO: $BASH_COMMAND" >&2; exit 1' ERR
# shellcheck disable=SC1091
source /root/install.env
log()  { printf '\e[1;34m  ->\e[0m %s\n' "$*"; }
warn() { printf '\e[1;33m  [warn]\e[0m %s\n' "$*" >&2; }

log "Timezone / locale / hostname"
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
hwclock --systohc
sed -i "s/^#\(${LOCALE//./\\.} \)/\1/" /etc/locale.gen
locale-gen
echo "LANG=$LOCALE"    > /etc/locale.conf
echo "KEYMAP=$KEYMAP"  > /etc/vconsole.conf
echo "$HOSTNAME_"      > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1  localhost
::1        localhost
127.0.1.1  $HOSTNAME_.localdomain $HOSTNAME_
EOF

log "Users"
echo "root:$ROOT_PW" | chpasswd
useradd -m -G wheel -s /bin/bash "$USERNAME"
echo "$USERNAME:$USER_PW" | chpasswd
echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/10-wheel
chmod 440 /etc/sudoers.d/10-wheel
chown "$USERNAME:$USERNAME" /games

log "pacman: multilib + color"
sed -i 's/^#Color/Color/; s/^#ParallelDownloads.*/ParallelDownloads = 10/' /etc/pacman.conf
grep -q '^ILoveCandy' /etc/pacman.conf || sed -i '/^Color/a ILoveCandy' /etc/pacman.conf
if [[ $GAMING == yes ]]; then
    sed -i '/^#\[multilib\]/,/^#Include/ s/^#//' /etc/pacman.conf
fi
pacman -Syu --noconfirm

log "GPU / desktop / gaming packages"
PKGS=()
case $GPU in
    nvidia) PKGS+=(nvidia-open nvidia-utils nvidia-settings)
            [[ $GAMING == yes ]] && PKGS+=(lib32-nvidia-utils) ;;
    amd)    PKGS+=(mesa vulkan-radeon libva-mesa-driver)
            [[ $GAMING == yes ]] && PKGS+=(lib32-mesa lib32-vulkan-radeon) ;;
    intel)  PKGS+=(mesa vulkan-intel intel-media-driver)
            [[ $GAMING == yes ]] && PKGS+=(lib32-mesa lib32-vulkan-intel) ;;
esac
case $DESKTOP in
    kde)   PKGS+=(plasma-desktop sddm konsole dolphin kate plasma-nm plasma-pa kscreen
                  xdg-desktop-portal-kde ark kde-gtk-config breeze-gtk) ;;
    gnome) PKGS+=(gnome-shell gdm nautilus gnome-console gnome-control-center
                  gnome-tweaks xdg-desktop-portal-gnome) ;;
esac
if [[ $GAMING == yes ]]; then
    PKGS+=(vulkan-icd-loader lib32-vulkan-icd-loader ttf-liberation
           steam gamemode lib32-gamemode mangohud lib32-mangohud)
fi
(( ${#PKGS[@]} )) && pacman -S --noconfirm --needed "${PKGS[@]}"

log "Home drive keyfile (lives on the encrypted root, so one passphrase unlocks both)"
install -d -m 700 /etc/cryptsetup-keys.d
dd if=/dev/urandom of=/etc/cryptsetup-keys.d/home.key bs=64 count=1 iflag=fullblock status=none
chmod 000 /etc/cryptsetup-keys.d/home.key
printf '%s' "$LUKS_PW" | cryptsetup luksAddKey --key-file=- \
    "/dev/disk/by-uuid/$HOME_LUKS_UUID" /etc/cryptsetup-keys.d/home.key
echo "crypthome UUID=$HOME_LUKS_UUID /etc/cryptsetup-keys.d/home.key luks,discard" >> /etc/crypttab

log "mkinitcpio"
mkdir -p /etc/mkinitcpio.conf.d
if [[ $PLYMOUTH == yes ]]; then
    # plymouth must come before sd-encrypt so the passphrase prompt is drawn graphically
    HOOKS_LINE="HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block plymouth sd-encrypt filesystems)"
    plymouth-set-default-theme "$PLYMOUTH_THEME"
else
    HOOKS_LINE="HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems)"
fi
echo "$HOOKS_LINE" > /etc/mkinitcpio.conf.d/arch.conf
mkinitcpio -P

log "Limine (UEFI, kernels live on the FAT ESP mounted at /boot)"
CMDLINE="rd.luks.name=$ROOT_LUKS_UUID=cryptroot rd.luks.options=discard root=/dev/mapper/cryptroot rootflags=subvol=@ rw quiet loglevel=3 amdgpu.gpu_recovery=1"
if [[ $PLYMOUTH == yes ]]; then CMDLINE+=" splash"; fi
mkdir -p /boot/EFI/BOOT
cp /usr/share/limine/BOOTX64.EFI /boot/EFI/BOOT/BOOTX64.EFI
cat > /boot/limine.conf <<EOF
timeout: 5

/Arch Linux
    protocol: linux
    path: boot():/vmlinuz-linux
    cmdline: $CMDLINE
    module_path: boot():/initramfs-linux.img

/Arch Linux (fallback initramfs)
    protocol: linux
    path: boot():/vmlinuz-linux
    cmdline: $CMDLINE
    module_path: boot():/initramfs-linux-fallback.img
EOF

# Re-copy the Limine EFI binary whenever the limine package updates
mkdir -p /etc/pacman.d/hooks
cat > /etc/pacman.d/hooks/95-limine-efi.hook <<'EOF'
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = limine

[Action]
Description = Deploying Limine EFI binary to the ESP
When = PostTransaction
Exec = /usr/bin/cp /usr/share/limine/BOOTX64.EFI /boot/EFI/BOOT/BOOTX64.EFI
EOF

efibootmgr --create --disk "$DISK_SYS" --part 1 --label "Arch Linux (Limine)" \
    --loader '\EFI\BOOT\BOOTX64.EFI' >/dev/null \
    || warn "efibootmgr failed; the firmware should still find EFI/BOOT/BOOTX64.EFI on its own."

log "Snapper (root config on the @snapshots subvolume)"
umount /.snapshots
rmdir /.snapshots
snapper --no-dbus -c root create-config /
btrfs subvolume delete /.snapshots
mkdir /.snapshots
mount /.snapshots          # picks up the @snapshots entry from fstab
chmod 750 /.snapshots
snapper --no-dbus -c root set-config \
    "TIMELINE_CREATE=yes" "TIMELINE_CLEANUP=yes" \
    "TIMELINE_LIMIT_HOURLY=5" "TIMELINE_LIMIT_DAILY=7" \
    "TIMELINE_LIMIT_WEEKLY=2" "TIMELINE_LIMIT_MONTHLY=1" "TIMELINE_LIMIT_YEARLY=0" \
    "NUMBER_LIMIT=10" "NUMBER_LIMIT_IMPORTANT=5"
snapper --no-dbus -c root create -d "Fresh install"

log "Settings for the Limine snapshot tools (installed later by post-install.sh)"
cat > /etc/default/limine <<EOF
TARGET_OS_NAME="Arch Linux"
ESP_PATH="/boot"
KERNEL_CMDLINE[default]="$CMDLINE"
ENABLE_UKI=no
ENABLE_LIMINE_FALLBACK=yes
BOOT_ORDER="*, *fallback, Snapshots"
MAX_SNAPSHOT_ENTRIES=5
EOF

log "zram swap, services"
cat > /etc/systemd/zram-generator.conf <<'EOF'
[zram0]
zram-size = ram
compression-algorithm = zstd
EOF

log "Mirror list: reflector (US mirrors, refreshed weekly by its timer)"
cat > /etc/xdg/reflector/reflector.conf <<'EOF'
--save /etc/pacman.d/mirrorlist
--protocol https
--country US
--latest 20
--sort rate
EOF

log "Firewall (ufw): block incoming, allow outgoing; open the KDE Connect ports"
# Rules are added first, while ufw is still marked disabled, so nothing tries to
# touch the live kernel's firewall from inside the chroot.
ufw default deny incoming  >/dev/null 2>&1 || warn "could not set ufw default incoming policy"
ufw default allow outgoing >/dev/null 2>&1 || warn "could not set ufw default outgoing policy"
ufw allow 1714:1764/tcp    >/dev/null 2>&1 || warn "could not add the KDE Connect TCP rule"
ufw allow 1714:1764/udp    >/dev/null 2>&1 || warn "could not add the KDE Connect UDP rule"
# Same effect as running "ufw enable": ufw switches itself on at every boot
sed -i 's/^ENABLED=.*/ENABLED=yes/' /etc/ufw/ufw.conf

systemctl enable NetworkManager.service fstrim.timer \
    snapper-timeline.timer snapper-cleanup.timer \
    "btrfs-scrub@-.timer" "btrfs-scrub@home.timer" \
    bluetooth.service ufw.service systemd-timesyncd.service reflector.timer
[[ $DESKTOP == kde   ]] && systemctl enable sddm.service
[[ $DESKTOP == gnome ]] && systemctl enable gdm.service

rm -f /root/install.env /root/chroot-setup.sh
CHROOT_EOF
chmod 700 /mnt/root/chroot-setup.sh

log "Configuring the new system"
arch-chroot /mnt /root/chroot-setup.sh

# Put post-install.sh in the new user's home, if it sits next to this script
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
POST_NOTE="Then log in, open Konsole and run:  bash ~/post-install.sh"
if [[ -f $SCRIPT_DIR/post-install.sh ]]; then
    install -m 755 "$SCRIPT_DIR/post-install.sh" "/mnt/home/$USERNAME/post-install.sh"
    arch-chroot /mnt chown "$USERNAME:$USERNAME" "/home/$USERNAME/post-install.sh"
else
    warn "post-install.sh was not found next to this script, so it was not copied."
    POST_NOTE="Then copy post-install.sh into your home folder, log in, and run it in Konsole."
fi

# ------------------------------- finish --------------------------------
log "Cleaning up"
rm -f /mnt/root/install.env /mnt/root/chroot-setup.sh
sync
umount -R /mnt
cryptsetup close crypthome
cryptsetup close cryptroot

cat <<EOF

Done. Remove the USB stick and run:  reboot

  /        @        on $ROOT_PART
  /games   @games   on $ROOT_PART   (owned by $USERNAME; add it as a Steam library)
  /home    @home    on $HOME_PART

Snapshots: sudo snapper -c root list

$POST_NOTE
EOF
