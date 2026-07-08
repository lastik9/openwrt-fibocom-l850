# openwrt-fibocom-l850

Installer for the **Fibocom L850-GL** modem (firmware reports itself as `L850`, Intel XMM7360 chip) on **OpenWrt 25 (apk)**: deploys the XMM drivers, creates the network interface and installs the [4IceG](https://github.com/4IceG) panels — `3ginfo-lite`, `sms-tool-js`, `modemband` — in a single run on a clean system.

![OpenWrt](https://img.shields.io/badge/OpenWrt-25.x%20(apk)-blue)
![Shell](https://img.shields.io/badge/shell-POSIX%20sh-green)
![License](https://img.shields.io/badge/license-MIT-lightgrey)

[Русский](README.md) · **English**

---

The script installs everything needed to run and monitor the Fibocom L850-GL modem on OpenWrt 25 and creates a ready-to-use interface. The modem is brought up in **NCM** mode via the **XMM** protocol — the same way KeeneticOS drives it. This is the stable mode for this module; ModemManager and MBIM proved unreliable on this hardware.

## ⚠️ Read this about the cable first — it's cause #1

The most common reason for "modem drops every few seconds / `USB disconnect` / `error -71`", especially **under load**, is a **thin USB cable**. Cheap charge-only cables sag under the modem's peak current and the device resets on the bus.

**Use a thick USB 3.0 data cable** (an external-SSD cable works great). No software setting fixes this — the cable is the fix. This took the most time to track down during debugging.

### Why

The L850-GL is an M.2 modem built on the Intel XMM7360 chip. Unlike Qualcomm modems (qmi/mbim), it works over the **XMM** protocol, and its AT port is `cdc-acm` (`/dev/ttyACM*`), not `option`/`ttyUSB*`. With the router's USB controller the module is stable specifically in **NCM** mode (proto `xmm`), not MBIM. The script deploys the required packages, optionally switches the modem into NCM, and configures the 4IceG panels against the correct port, working around the usual pitfalls (see "Known issues").

### What the script does

1. Installs the XMM stack via the [132lan](https://openwrt.132lan.ru) modem feed: `luci-proto-xmm`, `xmm-modem`, `kmod-usb-acm`, `kmod-usb-net-cdc-ncm`, `kmod-usb-serial-option`, etc., plus `sms-tool`.
2. **Optionally** (`DO_MODE_SWITCH=1`, one-time for a new modem) switches the module from **MBIM to NCM** — a self-checking step, skipped if the modem is already in NCM.
3. Adds the [4IceG/Modem-extras-apk](https://github.com/4IceG/Modem-extras-apk) apk repository and its key (idempotent, alongside the 132lan feed).
4. Installs the panels `luci-app-3ginfo-lite`, `luci-app-sms-tool-js`, `luci-app-modemband` (+ Russian locales).
5. **Auto-detects the AT port**: probes `ttyACM0..3` with `AT+CGMM` and picks the one reporting L850 (falling back to any port that replies `OK`).
6. Creates the **`LTE`** interface (proto `xmm`, detected port, APN, `pdp=ip` — IPv4 only) and adds it to the `wan` firewall zone.
7. Binds the panels to the detected port: 3ginfo (`device` + `network`), modemband (`set_port` + `iface`), sms-tool (ports + `7` prefix).
8. Reboots the router (10-second countdown, cancel with `Ctrl+C`).

### Requirements

- OpenWrt **25.x** with the **apk** package manager (not for opkg builds).
- A **Fibocom L850-GL** modem (Intel XMM7360), plugged in and detected (`/dev/ttyACM*` present).
- A **thick USB 3.0 cable** (see above) and router power from a **5V/3A or PD wall adapter**, not a weak power bank.
- **Internet on the router** at install time (another uplink or an already-working modem) — packages and keys are downloaded.
- **SSH** access and root.

### Installation

Run **on the router** (over SSH):

```sh
wget https://raw.githubusercontent.com/lastik9/openwrt-fibocom-l850/main/install-fibocom-l850.sh
sh install-fibocom-l850.sh
```

A brand-new modem often ships in MBIM — then run once with the NCM switch:

```sh
DO_MODE_SWITCH=1 sh install-fibocom-l850.sh
```

After reboot, open **LuCI → Network → Interfaces** (`LTE` should show Carrier/RX/TX) and **LuCI → Modem(s)** (refresh with Ctrl+F5 — signal, operator, band).

Settings are exposed as environment variables: `APN` (default `internet`; YOTA = `internet.yota`), `DO_MODE_SWITCH`, `AUTO_REBOOT`. The interface name and other bits are editable at the top of the script.

### Known issues

- **`USB disconnect` / `error -71`, especially under load** — almost always the **cable**. Use a thick USB 3.0 data cable. Cause #1, see the top.
- **Modem drops during active transfer** — router power. Use a **5V/3A or PD wall adapter**, not a power bank.
- **`cdc_mbim` comes up, `/dev/cdc-wdm0` present** — modem is in MBIM. Run the install with `DO_MODE_SWITCH=1` (switch to NCM).
- **`Failed add repository modem_kmod!`** while 132lan `add.sh` runs — harmless, does not affect the install.
- **`Carrier: Absent` / IP but no internet** — wrong **APN**. Fix your operator's APN in the interface and `Save & Apply`.
- **3ginfo shows no data** — check the AT port (`ls -l /dev/ttyACM*`, then `sms_tool -d /dev/ttyACM0 at ATI`); if the live port differs, fix `device` in 3ginfo.
- **Band locking** via modemband or `AT+XACT` — careful: lock a band absent at your location and the modem won't register. Revert: `AT+XACT=2,,,0` (allow all LTE bands).
- **Editing scripts on Windows?** Save with **LF (Unix)** line endings. CRLF in `#!/bin/sh` breaks execution on the router. Guarded by `.gitattributes`.

### Diagnostics

```sh
ls -l /dev/ttyACM*                                   # modem ports
sms_tool -d /dev/ttyACM0 at 'AT+CGMM'                # model (this modem: "L850")
sms_tool -d /dev/ttyACM0 at 'AT+CSQ'                 # signal (xx,yy)
sms_tool -d /dev/ttyACM0 at 'AT+COPS?'               # operator
sms_tool -d /dev/ttyACM0 at 'AT+GTUSBMODE?'          # USB mode: 0=NCM, 7=MBIM
uci show network.LTE                                 # interface config
ifstatus LTE | grep -i up                            # interface up?
ping -I wwan0 -c 20 8.8.8.8                           # traffic (run 15-20 min under load)
```

### Tested on

OpenWrt 25.12.x (mediatek/filogic, `aarch64_cortex-a53`), router **Cudy TR3000 (MT7981)**, modem **Fibocom L850-GL**, firmware `18500.5001.00.05.27.30`, adapter **Vertell VT-STATION-M.2**, operators MegaFon and Yota.

### Credits

This project is just an installer. The real work lives in the **[4IceG](https://github.com/4IceG)** projects:

- [luci-app-3ginfo-lite](https://github.com/4IceG/luci-app-3ginfo-lite) — modem monitoring panel
- [luci-app-sms-tool-js](https://github.com/4IceG/luci-app-sms-tool-js) — SMS / USSD / AT commands
- [luci-app-modemband](https://github.com/4IceG/luci-app-modemband) — LTE band management
- [Modem-extras-apk](https://github.com/4IceG/Modem-extras-apk) — apk package repository

Thanks also to [132lan](https://openwrt.132lan.ru) for the modem feed with XMM drivers, and to [lastik9/openwrt-fibocom-l860gl](https://github.com/lastik9/openwrt-fibocom-l860gl), used as the basis.

Installed components belong to their authors and are distributed under their own licenses. The MIT license covers only this installer's code.

### License

[MIT](LICENSE) © 2026
