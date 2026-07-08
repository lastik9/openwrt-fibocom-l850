# openwrt-fibocom-l850

Установщик модема **Fibocom L850-GL** (в прошивке рапортует себя как `L850`, чип Intel XMM7360) на **OpenWrt 25 (apk)**: разворачивает XMM-драйверы, создаёт сетевой интерфейс и ставит панели [4IceG](https://github.com/4IceG) — `3ginfo-lite`, `sms-tool-js`, `modemband` — за один прогон на чистой системе.

![OpenWrt](https://img.shields.io/badge/OpenWrt-25.x%20(apk)-blue)
![Shell](https://img.shields.io/badge/shell-POSIX%20sh-green)
![License](https://img.shields.io/badge/license-MIT-lightgrey)

**Русский** · [English](README.en.md)

---

Скрипт устанавливает всё, что нужно для работы и мониторинга модема Fibocom L850-GL на OpenWrt 25, и сам создаёт готовый к работе интерфейс. Модем поднимается в режиме **NCM** через протокол **XMM** — так же, как его штатно поднимает KeeneticOS. Это стабильный режим для этого модуля; ModemManager и MBIM на данном железе оказались нестабильны.

## ⚠️ Сначала про кабель — это причина №1

Самая частая причина «модем отваливается каждые несколько секунд / `USB disconnect` / `error -71`», особенно **под нагрузкой** — **тонкий USB-кабель**. Дешёвые зарядные кабели проседают по току на пике трафика, и модем сбрасывается на шине.

**Используй толстый USB 3.0 кабель для данных** (отлично подходит кабель от внешнего SSD). Никакие настройки это не лечат — лечит кабель. При отладке именно на это ушло больше всего времени.

### Зачем

L850-GL — это M.2-модем на чипе Intel XMM7360. В отличие от Qualcomm-модемов (qmi/mbim) он работает через протокол **XMM**, а его AT-порт — это `cdc-acm` (`/dev/ttyACM*`), а не `option`/`ttyUSB*`. На связке с USB-контроллером роутера модуль стабилен именно в **NCM**-режиме (proto `xmm`), а не в MBIM. Скрипт разворачивает нужный набор пакетов, при необходимости переключает модем в NCM и настраивает панели 4IceG под правильный порт, обходя типичные грабли (см. «Известные болячки»).

### Что делает скрипт

1. Ставит XMM-стек через модемный фид [132lan](https://openwrt.132lan.ru): `luci-proto-xmm`, `xmm-modem`, `kmod-usb-acm`, `kmod-usb-net-cdc-ncm`, `kmod-usb-serial-option` и др., плюс `sms-tool`.
2. **Опционально** (`DO_MODE_SWITCH=1`, разово для нового модема) переводит модуль из **MBIM в NCM** — самопроверяющийся шаг, пропускается, если модем уже в NCM.
3. Подключает apk-репозиторий [4IceG/Modem-extras-apk](https://github.com/4IceG/Modem-extras-apk) и его ключ (идемпотентно, рядом с фидом 132lan).
4. Ставит панели `luci-app-3ginfo-lite`, `luci-app-sms-tool-js`, `luci-app-modemband` (+ русские локали).
5. **Автоопределяет AT-порт**: опрашивает `ttyACM0..3` командой `AT+CGMM` и выбирает отвечающий как L850 (с откатом на порт, ответивший `OK`).
6. Создаёт интерфейс **`LTE_Fibocom_L850`** (proto `xmm`, найденный порт, APN, `pdp=ip` — только IPv4) и добавляет его в firewall-зону `wan`.
7. Настраивает панели под найденный порт: 3ginfo (`device` + `network`), modemband (`set_port` + `iface`), sms-tool (порты + префикс `7`).
8. Перезагружает роутер (с 10-секундным отсчётом и возможностью отмены `Ctrl+C`).

### Требования

- OpenWrt **25.x** с пакетным менеджером **apk** (для opkg-сборок скрипт не предназначен).
- Модем **Fibocom L850-GL** (Intel XMM7360), воткнут и определился (порты `/dev/ttyACM*` присутствуют).
- **Толстый USB 3.0 кабель** (см. блок выше) и питание роутера от **БП 5V/3A или PD из розетки**, не от слабого повербанка.
- **Интернет на роутере** на момент установки (через другой аплинк или уже поднятый модем) — качаются пакеты и ключи.
- Доступ по **SSH** и права root.

### Установка

Команды выполняются **на роутере** (по SSH):

```sh
wget https://raw.githubusercontent.com/lastik9/openwrt-fibocom-l850/main/install-fibocom-l850.sh
sh install-fibocom-l850.sh
```

Новый модем «из коробки» часто приходит в MBIM — тогда один раз запусти с переключением в NCM:

```sh
DO_MODE_SWITCH=1 sh install-fibocom-l850.sh
```

После перезагрузки открой **LuCI → Network → Interfaces** (у `LTE_Fibocom_L850` должны появиться Carrier/RX/TX) и **LuCI → Modem(s)** (обнови Ctrl+F5 — сигнал, оператор, бэнд).

Настройки вынесены в переменные окружения: `APN` (по умолчанию `internet` — МегаФон; YOTA — `internet.yota`), `DO_MODE_SWITCH`, `AUTO_REBOOT`. Имя интерфейса и прочее правится в шапке скрипта.

### Удаление

```sh
wget https://raw.githubusercontent.com/lastik9/openwrt-fibocom-l850/main/uninstall-fibocom-l850.sh
sh uninstall-fibocom-l850.sh
```

Деинсталлятор убирает интерфейс `LTE_Fibocom_L850` и его привязку к firewall, снимает пакеты панелей и XMM-стек, удаляет их конфиги и перезагружает роутер. По умолчанию **не трогает**: режим модема (NCM остаётся), сторонние фиды 132lan/4IceG и утилиту `sms-tool`.

Флаги: `PURGE_FEEDS=1` — удалить и фиды с ключом; `PURGE_SMSTOOL=1` — снести и `sms-tool`; `RESTORE_MBIM=1` — вернуть модем в MBIM (пишет NVM); `AUTO_REBOOT=0` — без перезагрузки.

### Известные болячки

- **`USB disconnect` / `error -71`, особенно под нагрузкой** — почти всегда **кабель**. Поставь толстый USB 3.0 data-кабель. Причина №1, см. блок в начале.
- **Модем отваливается при активной передаче** — питание роутера. Используй БП **5V/3A или PD из розетки**, не повербанк.
- **Поднимается `cdc_mbim`, есть `/dev/cdc-wdm0`** — модем в MBIM. Запусти установку с `DO_MODE_SWITCH=1` (перевод в NCM).
- **`Failed add repository modem_kmod!`** при работе `add.sh` 132lan — безвредно, на установку не влияет.
- **`Carrier: Absent` / IP есть, интернета нет** — неверный **APN**. Исправь APN оператора в интерфейсе и `Save & Apply`.
- **3ginfo не показывает данные** — проверь AT-порт (`ls -l /dev/ttyACM*`, затем `sms_tool -d /dev/ttyACM0 at ATI`); если рабочий порт другой — поправь `device` в 3ginfo.
- **Лок бэндов** через modemband или `AT+XACT` — осторожно: залочишь отсутствующий в точке бэнд — модем не зарегистрируется. Откат: `AT+XACT=2,,,0` (разрешить все LTE-бэнды).
- **Правишь скрипты на Windows?** Сохраняй переводы строк **LF (Unix)**. CRLF в `#!/bin/sh` ломает запуск на роутере. Подстраховано файлом `.gitattributes`.

### Диагностика

```sh
ls -l /dev/ttyACM*                                   # порты модема
sms_tool -d /dev/ttyACM0 at 'ATI'                    # ответ модема
sms_tool -d /dev/ttyACM0 at 'AT+CSQ'                 # сигнал (xx,yy)
sms_tool -d /dev/ttyACM0 at 'AT+COPS?'               # оператор
sms_tool -d /dev/ttyACM0 at 'AT+GTUSBMODE?'          # режим USB: 0=NCM, 7=MBIM
uci show network.LTE_Fibocom_L850                                 # конфиг интерфейса
ifstatus LTE_Fibocom_L850 | grep -i up                            # поднят ли интерфейс
ping -I wwan0 -c 20 8.8.8.8                           # трафик (гоняй 15-20 мин под нагрузкой)
```

### Проверено на

OpenWrt 25.12.x (mediatek/filogic, `aarch64_cortex-a53`), роутер **Cudy TR3000 (MT7981)**, модем **Fibocom L850-GL**, прошивка `18500.5001.00.05.27.30`, адаптер **Vertell VT-STATION-M.2**, операторы МегаФон и Yota.

### Благодарности

Проект — лишь установщик. Основная работа сделана в проектах **[4IceG](https://github.com/4IceG)**:

- [luci-app-3ginfo-lite](https://github.com/4IceG/luci-app-3ginfo-lite) — панель мониторинга модема
- [luci-app-sms-tool-js](https://github.com/4IceG/luci-app-sms-tool-js) — SMS / USSD / AT-команды
- [luci-app-modemband](https://github.com/4IceG/luci-app-modemband) — управление LTE-диапазонами
- [Modem-extras-apk](https://github.com/4IceG/Modem-extras-apk) — apk-репозиторий пакетов

Также спасибо [132lan](https://openwrt.132lan.ru) за модемный фид с XMM-драйверами, и проекту [lastik9/openwrt-fibocom-l860gl](https://github.com/lastik9/openwrt-fibocom-l860gl), взятому за основу.

Устанавливаемые компоненты — собственность их авторов и распространяются под их лицензиями. Лицензия MIT покрывает только код этого установщика.

### Лицензия

[MIT](LICENSE) © 2026
