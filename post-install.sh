#!/usr/bin/env bash
#
# Post-install: AUR packages.
#
# Run this as your NORMAL user (not root, no sudo in front) from a terminal on
# the installed system, after you have logged in and are online:
#
#     bash ~/post-install.sh
#
# Steps:
#   1. install yay (AUR helper) if it is missing
#   2. install the Limine snapshot tools (bootable snapshots in the boot menu)
#   3. install your own AUR packages
#   4. enable the snapshot sync service
#
# A failure in one step does not stop the later ones; a summary is printed at
# the end. Everything shown on screen is also saved to ~/post-install.log.

############################## CONFIG ##############################
# Needed for snapshot entries in the Limine menu. Leave these alone.
SYSTEM_AUR_PKGS="limine-mkinitcpio-hook limine-snapper-sync"

# Your own AUR packages, space-separated, e.g. "brave-bin protonup-qt"
AUR_PKGS="heroic-games-launcher-bin protonplus headset-battery-indicator-git octopi"

# yes = remove build-only dependencies (Java, Gradle, ...) after building
REMOVE_MAKEDEPS="yes"
####################################################################

set -uo pipefail

# ------------------------------ logging --------------------------------
SELF=$(readlink -f "$0")
LOG="$HOME/post-install.log"
if [[ -z ${POST_INSTALL_LOGGING:-} ]] && command -v script >/dev/null 2>&1; then
    export POST_INSTALL_LOGGING=1
    exec script -qefa "$LOG" -c "bash $(printf '%q' "$SELF")"
fi

log()  { printf '\e[1;34m==>\e[0m %s\n' "$*"; }
warn() { printf '\e[1;33m[warn]\e[0m %s\n' "$*" >&2; }
die()  { printf '\e[1;31m[error]\e[0m %s\n' "$*" >&2; exit 1; }

# ------------------------------ preflight ------------------------------
[[ $EUID -ne 0 ]]              || die "Run this as your normal user, not root (and without sudo)."
command -v sudo    >/dev/null  || die "sudo is not installed."
command -v git     >/dev/null  || die "git is not installed."
command -v makepkg >/dev/null  || die "makepkg is missing (install base-devel)."
ping -c1 -W3 archlinux.org >/dev/null 2>&1 || die "No network."

log "Authenticating sudo (needed to install packages)"
sudo -v || die "sudo authentication failed."
# keep the sudo ticket alive during long builds
( while true; do sudo -n true; sleep 50; kill -0 "$$" 2>/dev/null || exit; done ) &
KEEPALIVE=$!
trap 'kill "$KEEPALIVE" 2>/dev/null' EXIT

FAILED=()

# --------------------------------- yay ---------------------------------
if ! command -v yay >/dev/null 2>&1; then
    log "Installing yay"
    tmp=$(mktemp -d)
    if git clone https://aur.archlinux.org/yay-bin.git "$tmp/yay-bin" \
        && (cd "$tmp/yay-bin" && makepkg -si --noconfirm); then
        log "yay installed"
    else
        FAILED+=("yay")
    fi
    rm -rf "$tmp"
fi
command -v yay >/dev/null 2>&1 || die "yay is not available, so nothing else can be installed."

YAY_OPTS=(--noconfirm --needed)
if [[ $REMOVE_MAKEDEPS == yes ]]; then YAY_OPTS+=(--removemake); fi

# install_group LABEL PKG...  -> returns 0 on success, 1 on failure
install_group() {
    local label=$1; shift
    (( $# )) || return 0
    log "Installing $label: $*"
    if yay -S "${YAY_OPTS[@]}" "$@"; then
        return 0
    fi
    warn "$label: yay reported a failure"
    return 1
}

# ---------------------- snapshot boot tools ----------------------------
SNAP_OK=no
# shellcheck disable=SC2086
if install_group "snapshot boot tools" $SYSTEM_AUR_PKGS; then
    SNAP_OK=yes
else
    FAILED+=("snapshot boot tools ($SYSTEM_AUR_PKGS)")
fi

# --------------------------- your packages -----------------------------
if [[ -n $AUR_PKGS ]]; then
    # shellcheck disable=SC2086
    if ! install_group "your AUR packages" $AUR_PKGS; then
        # one bad name can abort the whole transaction, so retry one by one
        log "Retrying your AUR packages one at a time"
        for pkg in $AUR_PKGS; do
            install_group "$pkg" "$pkg" || FAILED+=("$pkg")
        done
    fi
fi

# ---------------------------- enable service ---------------------------
if [[ $SNAP_OK == yes ]]; then
    log "Enabling limine-snapper-sync"
    sudo systemctl enable --now limine-snapper-sync.service \
        || FAILED+=("enabling limine-snapper-sync.service")
fi

# a Gradle daemon may still be running from the builds; it would exit on its own
pkill -f GradleDaemon 2>/dev/null || true

# -------------------------------- summary ------------------------------
echo
if (( ${#FAILED[@]} )); then
    warn "Finished with problems:"
    printf '  - %s\n' "${FAILED[@]}"
    echo "Full output: $LOG"
    exit 1
fi
log "All done."
echo "Check the snapshot entries with:  sudo cat /boot/limine.conf   (look for //Snapshots)"
echo "Full output saved in: $LOG"
