#!/bin/sh
#
# uninstall-fibocom-l850.sh
# Reverses install-fibocom-l850.sh, returning the router to its pre-install
# state — no reflash needed.
#
# By default removes EVERYTHING the installer added:
#   - the LTE interface + its firewall membership
#   - the panel packages + luci-proto-xmm and their (orphaned) dependencies
#   - the panel config files (3ginfo, modemband, sms_tool_js)
#   - the added apk feeds (132lan + 4IceG) and the IceG signing key
#   - sms-tool
#
# The ONLY thing not touched: the modem USB mode. The installer changes it
# only if you ran it with DO_MODE_SWITCH=1, so by default there is nothing to
# revert; NCM is also this modem's normal operating mode. Rewriting the modem
# NVM "just in case" is a real hardware write and is avoided. If you truly want
# the factory MBIM state back, pass RESTORE_MBIM=1 (writes NVM).
#
# If you changed IFACE / FW_ZONE in the installer, match them here.
#
# Usage:  sh uninstall-fibocom-l850.sh
#   Flags: RESTORE_MBIM=1   # also switch the modem back to MBIM (writes NVM)
#          AUTO_REBOOT=0    # don't reboot at the end
#
# Safe to run even if some parts are already gone.

IFACE="LTE_Fibocom_L850"
FW_ZONE="wan"
FEEDS="/etc/apk/repositories.d/customfeeds.list"

RESTORE_MBIM="${RESTORE_MBIM:-0}"
AUTO_REBOOT="${AUTO_REBOOT:-1}"

# World packages the installer added explicitly (dependents first). Deleting
# these makes apk cascade-remove their orphaned deps. sms-tool is included:
# the installer added it, so a clean uninstall removes it too.
PKGS="luci-i18n-3ginfo-lite-ru luci-i18n-sms-tool-js-ru luci-i18n-modemband-ru
      luci-app-3ginfo-lite luci-app-sms-tool-js luci-app-modemband
      luci-proto-xmm sms-tool"

# Dependencies to mop up in case they weren't auto-orphaned (harmless if
# already gone, or refused because still needed elsewhere).
DEPS="modemband xmm-modem chat comgt
      kmod-usb-serial-option kmod-usb-serial-wwan kmod-usb-serial
      kmod-usb-net-rndis kmod-usb-net-cdc-ncm kmod-usb-net-cdc-ether
      kmod-usb-net kmod-usb-acm kmod-mii"

say() { echo ""; echo ">>> $1"; }

# --- 0. (optional) restore modem to MBIM -----------------------------------
# Runs FIRST, while sms-tool is still installed (step 2 removes it).
if [ "$RESTORE_MBIM" = 1 ]; then
    say "Restoring modem to MBIM mode (writes NVM)"
    ifdown "$IFACE" 2>/dev/null
    ATP=""
    for p in /dev/ttyACM0 /dev/ttyACM1 /dev/ttyACM2 /dev/ttyACM3; do
        [ -c "$p" ] || continue
        if command -v sms_tool >/dev/null 2>&1 && \
           sms_tool -D -d "$p" at "AT" 2>/dev/null | grep -qi OK; then ATP="$p"; break; fi
    done
    if [ -n "$ATP" ]; then
        sms_tool -D -d "$ATP" at "AT+GTUSBMODE=7"            2>/dev/null
        sms_tool -D -d "$ATP" at "at@nvm:cal_usbmode.num=7"  2>/dev/null
        sms_tool -D -d "$ATP" at "at@store_nvm(cal_usbmode)" 2>/dev/null
        sms_tool -D -d "$ATP" at "AT+CFUN=15"                2>/dev/null
        echo "   sent MBIM switch on $ATP (modem will reboot)"
    else
        echo "   no AT port found — skipped"
    fi
fi

# --- 1. Remove the network interface + firewall membership -----------------
say "Removing interface '$IFACE'"
uci -q delete network."$IFACE" && uci commit network
ZONE_SECT="$(uci show firewall 2>/dev/null | grep "\.name='${FW_ZONE}'" | head -n1 | sed "s/\.name='${FW_ZONE}'.*//")"
if [ -n "$ZONE_SECT" ]; then
    uci -q del_list "${ZONE_SECT}".network="$IFACE" && uci commit firewall
    echo "   removed from firewall zone '$FW_ZONE'"
fi

# --- 2. Remove packages (two passes handle dependency ordering) ------------
say "Removing packages (incl. sms-tool)"
# Pass 1 does the real work; pass 2 mops up leftovers whose deps blocked them
# the first time. Both filter apk's per-package "OK: <size> in <n> packages"
# summary: for a package that is already gone apk prints *only* that line, so a
# long PKGS/DEPS list produces a wall of identical "OK:" lines that looks like
# the script hung (and tempts people to hit Ctrl+C). Real "Purging ..." lines
# are kept, so you still see what is being removed.
for pkg in $PKGS $DEPS; do
    apk del "$pkg" 2>/dev/null | grep -vE '^OK:' || true
done
echo "   second pass (mopping up leftovers, quiet)..."
for pkg in $PKGS $DEPS; do
    apk del "$pkg" >/dev/null 2>&1 || true
done
echo "   packages removed"

# --- 3. Remove panel config files ------------------------------------------
say "Removing leftover configs"
rm -f /etc/config/3ginfo /etc/config/modemband /etc/config/sms_tool_js

# --- 4. Remove added apk feeds + IceG key ----------------------------------
say "Removing added apk feeds and key"
if [ -f "$FEEDS" ]; then
    sed -i '\#4IceG/Modem-extras-apk#d' "$FEEDS"
    sed -i '\#132lan#d' "$FEEDS"
fi
rm -f /etc/apk/keys/IceG-apkpub.pem
apk update 2>/dev/null

say "Готово — состояние возвращено к тому, что было до установки."
echo "    Удалены: интерфейс, привязка к firewall, пакеты панелей + luci-proto-xmm,"
echo "    их зависимости, конфиги, фиды 132lan/4IceG и ключ, sms-tool."
if [ "$RESTORE_MBIM" = 1 ]; then
    echo "    Режим модема: запрошен возврат в MBIM (команда отправлена выше)."
else
    echo "    Единственное НЕ тронутое — режим модема: NCM оставлен намеренно."
    echo "    Установщик по умолчанию режим не менял (менять нечего), а перезапись"
    echo "    NVM 'на всякий случай' рискованна. Вернуть заводской MBIM: RESTORE_MBIM=1."
fi

if [ "$AUTO_REBOOT" = 1 ]; then
    echo "    Сейчас роутер перезагрузится, чтобы выгрузились снятые драйверы и пропали ttyACM."
    echo ""
    echo ">>> Перезагрузка через 10 секунд (Ctrl+C — отмена)"
    i=10
    while [ "$i" -gt 0 ]; do
        printf '\r   перезагрузка через %2d с ... ' "$i"
        sleep 1
        i=$((i - 1))
    done
    echo ""
    sync
    reboot
else
    echo "    AUTO_REBOOT=0 — перезагрузи роутер вручную, чтобы выгрузить драйверы."
fi
