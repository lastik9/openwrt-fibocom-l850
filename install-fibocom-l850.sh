#!/bin/sh
#
# install-fibocom-l850.sh
# Rus-friendly installer for Fibocom L850-GL (Intel XMM7360) on a clean
# OpenWrt 25.12.x (apk-based) router — tested on Cudy TR3000 (MT7981).
#
# Data path: proto "xmm" over NCM (3x cdc-acm + 3x cdc-ncm), AT on /dev/ttyACM*.
# This mirrors what KeeneticOS does and is the stable mode for this modem;
# ModemManager/MBIM proved unstable on this hardware.
#
# Installs: proto xmm (132lan feed) + sms-tool, and the GUI panels
#           3ginfo-lite / sms-tool-js / modemband (4IceG feed) + RU i18n,
#           then creates the LTE interface and binds every panel to the AT port.
#
# Usage:
#   scp to router, then:  sh install-fibocom-l850gl.sh
#   Env flags:
#     APN=internet            # default APN (MegaFon). YOTA = internet.yota
#     AUTO_REBOOT=0           # don't reboot at the end
#     DO_MODE_SWITCH=1        # ONE-TIME: switch a brand-new modem MBIM -> NCM
#                             # (writes modem NVM; only needed once per modem)
#
# >>> HARDWARE NOTE, READ THIS <<<
# The single biggest cause of "modem drops every few seconds / USB disconnect /
# error -71" is a THIN USB CABLE. Thin charge-only cables sag under the modem's
# peak current. Use a THICK USB 3.0 data cable (an SSD-grade cable works great).
# No amount of software fixes this — the cable is the fix.

# ----------------------------- configuration -------------------------------
APN="${APN:-internet}"                 # MegaFon default; YOTA = internet.yota
AUTO_REBOOT="${AUTO_REBOOT:-1}"
DO_MODE_SWITCH="${DO_MODE_SWITCH:-0}"  # off by default; safe, idempotent run
IFACE="LTE"
MODEL_MATCH='L850|L860|Fibocom'        # AT+CGMM reply pattern

FEEDS="/etc/apk/repositories.d/customfeeds.list"
KEYDIR="/etc/apk/keys"
REPO_ADB="https://github.com/4IceG/Modem-extras-apk/raw/refs/heads/main/myapk/packages.adb"
REPO_KEY="https://github.com/4IceG/Modem-extras-apk/raw/refs/heads/main/myapk/IceG-apkpub.pem"
LAN132_BASE="https://openwrt.132lan.ru/packages"
LOG="/tmp/fibocom-l850-install.log"

# ------------------------------- helpers -----------------------------------
say()  { echo ""; echo ">>> $*" | tee -a "$LOG" >&2; }
info() {          echo "    $*" | tee -a "$LOG" >&2; }
warn() {          echo "!!! $*" | tee -a "$LOG" >&2; }
die()  {          echo "*** $*" | tee -a "$LOG" >&2; echo "*** aborting (see $LOG)" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

download() {  # url dest  -> nonzero on failure/empty
    wget -q "$1" -O "$2.part" 2>>"$LOG" && [ -s "$2.part" ] || { rm -f "$2.part"; return 1; }
    mv "$2.part" "$2"
}

# find the AT port that actually answers (ttyACM0..3).
# L850 firmware reports "L850" via AT+CGMM but NOT via ATI, so probe CGMM first,
# then fall back to any port that replies OK.
find_at_port() {
    have sms_tool || return 1
    for p in /dev/ttyACM0 /dev/ttyACM1 /dev/ttyACM2 /dev/ttyACM3; do
        [ -c "$p" ] || continue
        if sms_tool -D -d "$p" at "AT+CGMM" 2>/dev/null | grep -qiE "$MODEL_MATCH"; then
            echo "$p"; return 0
        fi
    done
    for p in /dev/ttyACM0 /dev/ttyACM1 /dev/ttyACM2 /dev/ttyACM3; do
        [ -c "$p" ] || continue
        if sms_tool -D -d "$p" at "AT" 2>/dev/null | grep -qi "OK"; then
            echo "$p"; return 0
        fi
    done
    return 1
}

: > "$LOG"

# ------------------------------ preflight ----------------------------------
say "Preflight"
[ "$(id -u)" = 0 ]          || die "run as root"
have apk                    || die "'apk' not found — needs apk-based OpenWrt (24.10+/25.x)"
[ -r /etc/openwrt_release ] || die "not OpenWrt?"
# shellcheck disable=SC1091
. /etc/openwrt_release
case "$DISTRIB_RELEASE" in
    [0-9]*.[0-9]*) REL=$(echo "$DISTRIB_RELEASE" | awk -F. '{print $1"."$2}') ;;
    *)             REL="$DISTRIB_RELEASE" ;;
esac
info "release $DISTRIB_RELEASE (feed branch $REL), APN '$APN'"
apk update >>"$LOG" 2>&1 || die "apk update failed — check internet/DNS"

# --- 1. proto xmm drivers (132lan feed) ------------------------------------
say "Step 1: proto xmm + sms-tool (132lan feed)"
ADD_URL="${LAN132_BASE}/${REL}/packages/add.sh"
info "fetching $ADD_URL"
if download "$ADD_URL" /tmp/132lan-add.sh; then
    sh /tmp/132lan-add.sh >>"$LOG" 2>&1 || warn "132lan add.sh returned an error"
    apk update >>"$LOG" 2>&1 || warn "apk update after feed add failed"
else
    warn "could not fetch 132lan add.sh — luci-proto-xmm may be missing"
fi
apk add luci-proto-xmm >>"$LOG" 2>&1 || die "failed to install luci-proto-xmm (core)"
apk add sms-tool        >>"$LOG" 2>&1 || die "failed to install sms-tool (needed for AT)"

# --- 2. (optional, one-time) switch modem MBIM -> NCM -----------------------
# A brand-new L850 often enumerates as MBIM (cdc_mbim + /dev/cdc-wdm0). proto
# xmm needs NCM. This writes NVM permanently, so it's opt-in and self-checking.
if [ "$DO_MODE_SWITCH" = 1 ]; then
    say "Step 2: MBIM -> NCM switch (one-time, writes NVM)"
    for m in cdc-acm option cdc_ncm cdc_mbim; do modprobe "$m" 2>/dev/null; done
    sleep 3
    ATP="$(find_at_port)"
    if [ -z "$ATP" ]; then
        warn "no AT port found — skipping mode switch"
    elif [ ! -e /dev/cdc-wdm0 ]; then
        info "no /dev/cdc-wdm0 — modem already in NCM, nothing to do"
    else
        info "AT port $ATP; setting USB mode to NCM (0)"
        sms_tool -D -d "$ATP" at "AT+GTUSBMODE=0"            >>"$LOG" 2>&1
        # fallback for firmwares using the nvm form:
        sms_tool -D -d "$ATP" at "at@nvm:cal_usbmode.num=0"  >>"$LOG" 2>&1
        sms_tool -D -d "$ATP" at "at@store_nvm(cal_usbmode)" >>"$LOG" 2>&1
        info "rebooting modem (AT+CFUN=15) — wait ~25s"
        sms_tool -D -d "$ATP" at "AT+CFUN=15"                >>"$LOG" 2>&1
        sleep 25
    fi
else
    info "Step 2: mode switch skipped (set DO_MODE_SWITCH=1 for a new modem in MBIM)"
fi

# --- 3. GUI panels (4IceG feed) --------------------------------------------
say "Step 3: adding 4IceG apk repository"
if grep -qF "$REPO_ADB" "$FEEDS" 2>/dev/null; then
    info "repo already present"
else
    echo "$REPO_ADB" >> "$FEEDS" && info "repo added" || warn "could not write $FEEDS"
fi
mkdir -p "$KEYDIR"
if [ -s "$KEYDIR/IceG-apkpub.pem" ]; then
    info "signing key present"
elif download "$REPO_KEY" "$KEYDIR/IceG-apkpub.pem"; then
    info "signing key installed"
else
    warn "no 4IceG key — its packages will be skipped"
fi
apk update >>"$LOG" 2>&1 || warn "apk update (4IceG) failed"

say "Step 3b: installing panels (3ginfo-lite / sms-tool-js / modemband) + RU"
add_opt() { apk add "$1" >>"$LOG" 2>&1 && info "installed $1" || warn "skipped $1"; }
add_opt luci-app-3ginfo-lite
add_opt luci-i18n-3ginfo-lite-ru
add_opt luci-app-sms-tool-js
add_opt luci-i18n-sms-tool-js-ru
add_opt luci-app-modemband
add_opt luci-i18n-modemband-ru

# --- 4. detect AT port ------------------------------------------------------
say "Step 4: detecting AT port"
for m in cdc-acm option cdc_ncm; do modprobe "$m" 2>/dev/null; done
n=0; while [ "$n" -lt 15 ]; do ls /dev/ttyACM* >/dev/null 2>&1 && break; sleep 1; n=$((n+1)); done
AT_PORT="$(find_at_port)"
if [ -n "$AT_PORT" ]; then
    info "AT port: $AT_PORT"
else
    AT_PORT="/dev/ttyACM0"
    warn "no live AT port probed; defaulting to $AT_PORT (verify after reboot)"
fi

# --- 5. create/adjust the LTE interface (proto xmm, NCM, IPv4) --------------
say "Step 5: configuring interface '$IFACE' (proto xmm, IPv4)"
uci set network.$IFACE=interface
uci set network.$IFACE.proto='xmm'
uci set network.$IFACE.device="$AT_PORT"
uci set network.$IFACE.apn="$APN"
uci set network.$IFACE.pdp='ip'          # IPv4 only — dual-stack is buggy here
uci set network.$IFACE.auth='none'
uci -q delete network.$IFACE.pdptype
uci -q delete network.$IFACE.iptype
uci commit network
# firewall: put it in the wan zone (zone[1] on a stock config)
if ! uci -q get firewall.@zone[1] >/dev/null; then
    warn "wan firewall zone not found — set it in LuCI (Network→Firewall)"
else
    uci -q del_list firewall.@zone[1].network="$IFACE"
    uci add_list firewall.@zone[1].network="$IFACE"
    uci commit firewall
    info "added $IFACE to wan zone"
fi

# --- 6. bind panels to the AT port -----------------------------------------
say "Step 6: binding panels to $AT_PORT"
if uci -q get 3ginfo.@3ginfo[0] >/dev/null; then
    uci set 3ginfo.@3ginfo[0].device="$AT_PORT"
    uci set 3ginfo.@3ginfo[0].network="$IFACE"
    uci commit 3ginfo; info "3ginfo bound"
fi
if uci -q get modemband.@modemband[0] >/dev/null; then
    uci set modemband.@modemband[0].set_port="$AT_PORT"
    uci set modemband.@modemband[0].iface="$IFACE"
    uci commit modemband; info "modemband bound"
fi
if uci -q get sms_tool_js.@sms_tool_js[0] >/dev/null; then
    S="sms_tool_js.@sms_tool_js[0]"
    uci set "$S".pnumber='7'              # RU country prefix
    uci set "$S".readport="$AT_PORT"
    uci set "$S".sendport="$AT_PORT"
    uci set "$S".ussdport="$AT_PORT"
    uci set "$S".atport="$AT_PORT"
    uci commit sms_tool_js; info "sms-tool bound"
fi

# --- 7. bring up + restart UI ----------------------------------------------
say "Step 7: bringing up $IFACE and restarting UI"
reload_config 2>>"$LOG"
ifup "$IFACE" 2>>"$LOG"
/etc/init.d/rpcd restart   >>"$LOG" 2>&1 || warn "rpcd restart failed"
/etc/init.d/uhttpd restart >>"$LOG" 2>&1 || warn "uhttpd restart failed"

# --- 8. summary ------------------------------------------------------------
say "Done."
info "Interface : $IFACE (proto xmm)"
info "AT port   : $AT_PORT"
info "APN       : $APN"
info "Log       : $LOG"
info "Check:  ifstatus $IFACE | grep -E '\"up\"|address'"
info "Test :  ping -I wwan0 -c 20 8.8.8.8   (run a long transfer to be sure)"
info "LuCI  : Ctrl+F5, then Modem Info / SMS / Modemband tabs"
info "CABLE : if you see USB disconnects, swap to a thick USB3 data cable!"

if [ "$AUTO_REBOOT" = 1 ]; then
    say "Rebooting in 10s (Ctrl+C to cancel; AUTO_REBOOT=0 to skip)"
    i=10; while [ "$i" -gt 0 ]; do printf '\r    %2ds ' "$i"; sleep 1; i=$((i-1)); done
    echo ""; sync; reboot
else
    info "AUTO_REBOOT=0 — reboot recommended before first heavy use."
fi
