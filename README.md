# OBS Camera: iPhone как веб-камера для OBS

Проект состоит из двух частей:

| Часть | Папка | Что делает |
|---|---|---|
| iOS-приложение | [ios-app](ios-app) | Снимает камерой, кодирует в H.264 (аппаратно, VideoToolbox) и отправляет по Wi‑Fi или USB-кабелю |
| Плагин OBS | [obs-plugin](obs-plugin) | Добавляет источник **iPhone Camera**: принимает поток, декодирует через FFmpeg и выводит в OBS |

```
Wi‑Fi:  iPhone ── H.264 → TCP ──────────────────────────▶ плагин: TCP-сервер :47100
        NWBrowser ◀── Bonjour/mDNS «_obsiphonecam._tcp» ── Avahi

USB:    iPhone: слушает 127.0.0.1:47101 ◀── кабель ── usbmuxd ◀── плагин подключается
```

Два режима подключения, переключаются и в приложении, и в свойствах источника OBS:

- **Wi‑Fi.** Плагин открывает TCP-порт (по умолчанию **47100**) и объявляет себя через Bonjour (Avahi).
  iPhone находит компьютер сам. Если mDNS недоступен, IP-адрес вводится вручную.
- **USB-кабель.** iPhone не может сам подключиться к компьютеру по кабелю, поэтому направление
  обратное: приложение слушает порт **47101** (только loopback, через Wi‑Fi он не виден), а плагин
  раз в секунду подключается к нему через `usbmuxd`. Работает без сети, задержка и стабильность лучше.
- Задержка минимальная: без B-кадров, OBS выводит кадры без буферизации, при перегрузке
  сети iPhone пропускает кадры до следующего ключевого, а не копит очередь.
- Если соединение оборвалось (перезапуск OBS, сбой Wi‑Fi), приложение переподключается само.

## Плагин на Linux

### 1. Зависимости

Ubuntu / Debian:
```bash
sudo apt install build-essential cmake pkg-config libavcodec-dev libavutil-dev libavahi-compat-libdnssd-dev libusbmuxd-dev usbmuxd libobs-dev
```

Fedora:
```bash
sudo dnf install gcc cmake pkgconf-pkg-config ffmpeg-free-devel avahi-compat-libdns_sd-devel libusbmuxd-devel usbmuxd obs-studio-devel
```

Arch:
```bash
sudo pacman -S base-devel cmake ffmpeg avahi libusbmuxd usbmuxd obs-studio
```

Если пакета разработки OBS (`libobs-dev` / `obs-studio-devel`) нет, скрипт установки сам скачает
заголовки libobs нужной версии. На ARM дополнительно нужен `libsimde-dev`.

`libusbmuxd` (версии 2.0+) и служба `usbmuxd` нужны только для подключения по кабелю. Без них
плагин соберётся, но режим USB покажет, что он недоступен.

### 2. Сборка и установка (для текущего пользователя)

```bash
cd obs-plugin && ./scripts/install-linux.sh
```

Плагин ставится в `~/.config/obs-studio/plugins/obs-iphone-camera/`. Перезапустите OBS
и добавьте **Источники → + → iPhone Camera**.

Вручную то же самое:
```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=$HOME/.config/obs-studio/plugins/obs-iphone-camera
cmake --build build -j && cmake --install build
```

### 3. Сеть

- Компьютер и iPhone должны быть в одной сети, и в ней не должна быть включена изоляция клиентов
  (в гостевых Wi‑Fi она часто включена).
- Для автопоиска должен работать `avahi-daemon`: `systemctl status avahi-daemon`.
- Если включён файрвол, откройте порты:
  ```bash
  sudo ufw allow 47100/tcp && sudo ufw allow 5353/udp
  ```
  (для firewalld: `sudo firewall-cmd --permanent --add-port=47100/tcp --add-service=mdns && sudo firewall-cmd --reload`).

### 4. USB-кабель

1. В приложении на iPhone выберите **USB-кабель**.
2. Подключите iPhone к компьютеру. При первом подключении iPhone спросит «Доверять этому компьютеру?»:
   нажмите **Доверять** и введите код-пароль.
3. В OBS в свойствах источника выберите **Подключение → USB-кабель**. Если подключено несколько
   iPhone, выберите нужный в списке **iPhone** (по UDID).

Проверить, что Linux видит телефон: `systemctl status usbmuxd` (служба запускается сама при
подключении iPhone) и `idevice_id -l` из пакета `libimobiledevice-utils`. Файрвол для USB настраивать
не нужно.

### OBS из Flatpak

Flatpak-версия OBS работает в песочнице со своими библиотеками, поэтому плагин, собранный
под системный FFmpeg, может там не загрузиться. Надёжнее всего OBS из пакетов дистрибутива
(или PPA `obsproject/obs-studio`). Если нужен именно Flatpak, плагин придётся собирать внутри
SDK `org.kde.Sdk` той же версии, что у OBS, и класть в
`~/.var/app/com.obsproject.Studio/config/obs-studio/plugins/`.

### Свойства источника

- **Статус**: ожидание или подключённое устройство, разрешение, fps. В режиме Wi‑Fi здесь же
  показаны IP-адреса компьютера для ручного ввода; в режиме USB — что мешает подключиться
  (нет `usbmuxd`, iPhone не подключён, приложение не в режиме USB). Обновляется кнопкой «Обновить статус».
- **Подключение**: Wi‑Fi или USB-кабель.
- **Порт** (Wi‑Fi): для нескольких iPhone добавьте несколько источников с разными портами.
- **iPhone** (USB): первый подключённый кабелем или конкретный по UDID.
- **Оставлять последний кадр**: что показывать при отключении телефона.

## iOS-приложение

Нужны Xcode 16+ и [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
cd ios-app && xcodegen generate && open OBSCamera.xcodeproj
```

В Xcode: target **OBSCamera → Signing & Capabilities → Team**: выберите свою команду
(подойдёт и бесплатный Personal Team), подключите iPhone и нажмите Run.

При первом запуске iOS попросит доступ к камере и к **локальной сети**; разрешите оба.

Архитектура (MVVM, SwiftUI):
- `Views/`: `ContentView` (превью, режим Wi‑Fi/USB, список компьютеров, ручной IP), `SettingsView`, `CameraPreviewView`
- `ViewModels/CameraViewModel`: состояние экрана, режим подключения, автопереподключение
- `Services/`: `CameraCaptureService` (AVFoundation), `TestPatternSource`, `H264Encoder` (VideoToolbox),
  `StreamConnection` (Network.framework, TCP), `HostBrowser` (Bonjour), `USBListener` (порт для USB),
  `StreamingEngine` (связывает всё вместе)
- `Models/`: настройки, режим подключения, протокол, модель хоста

Настройки: основная/фронтальная камера или тестовая картинка, 720p/1080p, 24/30/60 fps,
битрейт 2–30 Мбит/с, горизонтальная/вертикальная ориентация. В симуляторе камеры нет,
поэтому там всегда отправляется тестовая картинка.

## Проверка без OBS

В `obs-plugin` собирается консольный приёмник, использующий тот же сетевой код и декодер:

```bash
cd obs-plugin && cmake -S . -B build -DBUILD_PLUGIN=OFF && cmake --build build
./build/obscam-receiver-test --snapshot frame.ppm      # Wi‑Fi: ждёт iPhone, объявляет себя через Bonjour
./build/obscam-receiver-test --usb                     # USB: подключается к iPhone через usbmuxd
./build/obscam-receiver-test --connect 127.0.0.1:47101 # USB-режим приложения в симуляторе
```

Он печатает fps и разрешение и может сохранить кадр в файл.

## Протокол

Одно TCP-соединение, данные идут от iPhone к OBS в обоих режимах; отличается только то, кто
открывает соединение. Сообщения вида `[тип: u8][длина: u32 BE][данные]`:

| Тип | Данные |
|---|---|
| `0x01` HELLO | имя устройства (UTF‑8) |
| `0x02` CONFIG | SPS + PPS (Annex‑B), отправляется перед каждым ключевым кадром |
| `0x03` FRAME | `[pts_us: u64 BE][flags: u8, бит 0 = keyframe][кадр H.264, Annex‑B]` |
| `0x04` PING | пусто, раз в секунду, если нет кадров (приложение в фоне) |

Описание протокола продублировано в [protocol.h](obs-plugin/src/protocol.h) и
[WireProtocol.swift](ios-app/OBSCamera/Models/WireProtocol.swift); при изменении правьте оба файла.

## Ограничения

- Только видео, без звука.
- iOS не даёт снимать камерой, пока приложение в фоне: держите его открытым
  (экран не гаснет, пока идёт трансляция).
