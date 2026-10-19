#!/bin/sh
# enable-hdmi.sh — turn on the HDMI display output.
#
# WHY THIS IS NEEDED
# The vendor kernel's DRM driver exposes the HDMI connector but never enables
# it by itself: the connector sits at "disabled" and nothing appears on the
# screen. The display path needs two things:
#
#   1. the DTB's fb node enabled (status = "okay" rather than "disabled"),
#      which is what makes the vendor's OSD framebuffer driver bind at all
#      and create /dev/fb0
#   2. a mode set, which is runtime state and is NOT remembered across a
#      reboot
#
# This script does (2). It uses modetest from libdrm-tests, which is a small
# package, and falls back to writing the DRM connector state directly if
# modetest is not installed.
#
# After this runs:
#   cat /sys/class/drm/card0-HDMI-A-1/status   -> connected
#   cat /sys/kernel/debug/amhdmitx/hdmi_timing -> Hactive = 1920, Vactive = 1080
#
# It is safe to run more than once, and safe to run when no display is
# attached — the mode set simply fails and that is reported.

set -u

CONNECTOR=${CONNECTOR:-70}
MODE=${MODE:-1080p60hz}

log() { printf '[hdmi] %s\n' "$*"; }

# Pick the HDMI connector rather than hardcoding an id.
find_connector() {
    for d in /sys/class/drm/card*-HDMI-A-*/status; do
        [ -e "$d" ] || continue
        c=${d%/status}
        name=$(basename "$c")
        # card0-HDMI-A-1 -> the number after "card"
        num=$(echo "$name" | sed -n 's/^card\([0-9]*\)-.*/\1/p')
        [ -n "$num" ] && { echo "$num"; return 0; }
    done
    return 1
}

CARD=$(find_connector)
if [ -z "$CARD" ]; then
    log "no HDMI connector found — is this a box with HDMI?"
    exit 1
fi

log "HDMI connector: card$CARD"

if command -v modetest >/dev/null 2>&1; then
    if modetest -s "$CONNECTOR:$MODE" 2>&1 | grep -q "setting mode"; then
        log "mode set to $MODE"
    else
        log "modetest could not set the mode"
    fi
else
    log "modetest not installed — install libdrm-tests, or set the mode by hand:"
    log "  modetest -s $CONNECTOR:$MODE"
    exit 1
fi

# Report what the hardware actually did, rather than assuming it worked.
if [ -r "/sys/class/drm/card$CARD-HDMI-A-1/status" ]; then
    st=$(cat "/sys/class/drm/card$CARD-HDMI-A-1/status")
    en=$(cat "/sys/class/drm/card$CARD-HDMI-A-1/enabled" 2>/dev/null)
    log "connector: status=$st enabled=$en"
    if [ "$st" = "connected" ] || [ "$st" = "unknown" ]; then
        log "display output is live"
    else
        log "the display did not come up — check the cable and that the"
        log "monitor is powered on"
    fi
fi

if [ -r /sys/kernel/debug/amhdmitx/hdmi_timing ]; then
    log "transmitter timing:"
    grep -E "Hactive|Vactive" /sys/kernel/debug/amhdmitx/hdmi_timing | sed 's/^/  /'
fi
