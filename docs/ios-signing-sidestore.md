# Установка неподписанного IPA на iPhone без Mac

Практическое руководство для проекта `schedly`: сборка в GitHub Actions на `macos-latest`,
установка на iPhone без Mac и без платного аккаунта Apple Developer.

Документ описывает модель подписи, сравнение всех рабочих способов установки, пошаговый
процесс для рекомендуемого пути (SideStore), требования к `.ipa`, собранному из
`flutter build ios --release --no-codesign`, и подводные камни.

## Оглавление

1. [Модель подписи: что даёт бесплатный Apple ID](#1-модель-подписи-что-даёт-бесплатный-apple-id)
2. [Сравнение способов установки без Mac](#2-сравнение-способов-установки-без-mac)
3. [Рекомендуемый путь: SideStore, шаг за шагом](#3-рекомендуемый-путь-sidestore-шаг-за-шагом)
4. [Требования к `.ipa` из CI](#4-требования-к-ipa-из-ci)
5. [Подводные камни](#5-подводные-камни)
6. [Альтернатива: если появится Mac (`flutter build ipa` и Xcode)](#6-альтернатива-если-появится-mac-flutter-build-ipa-и-xcode)
7. [Источники](#7-источники)
8. [Что не удалось подтвердить по первоисточникам](#8-что-не-удалось-подтвердить-по-первоисточникам)

---

## 1. Модель подписи: что даёт бесплатный Apple ID

iOS не устанавливает приложения, подписанные произвольным сертификатом. Чтобы запустить
своё приложение на своём устройстве, используется механизм **development-подписи**:
приложение подписывается сертификатом разработчика, а для устройства выписывается
provisioning-профиль, где перечислены разрешённые App ID и UDID устройства.

Бесплатный Apple ID тоже умеет выписывать такой сертификат и профиль — именно на этом
основаны SideStore, AltStore и Sideloadly. Разница с платным аккаунтом — в сроках жизни
и лимитах.

| Параметр | Бесплатный Apple ID | Apple Developer Program |
|---|---|---|
| Срок жизни подписи приложения | 7 дней, затем приложение перестаёт запускаться | 1 год ([SideStore FAQ](https://docs.sidestore.io/docs/faq), [Sideloadly FAQ](https://sideloadly.io/)) |
| Одновременно установленных приложений | 3, **включая сам SideStore** | без этого ограничения ([SideStore FAQ](https://docs.sidestore.io/docs/faq)) |
| Регистрация App ID (bundle id) | не более 10 новых App ID за 7 дней ([SideStore: ошибка 1009/3013](https://docs.sidestore.io/docs/troubleshooting/error-codes), [AltStore: App IDs](https://faq.altstore.io/altstore-classic/app-ids)) | лимиты выше, ограничение снимается вместе с 3-app лимитом |
| Стоимость | 0 | 99 USD/год ([SideStore FAQ](https://docs.sidestore.io/docs/faq)) |
| Нужен ли Mac | нет (для SideStore/Sideloadly/AltStore-путей) | нет для установки, но сертификат удобнее выписывать через Xcode |

Важные следствия:

- **7 дней — не «срок годности файла», а срок годности подписи.** Пока приложение
  подписано сертификатом, оно запускается. Через 7 дней iOS отказывается его запускать —
  нужно переподписать тем же bundle id.
- **Каждое приложение + каждый app extension = отдельный App ID.** Если в приложении есть
  расширения (Notification Service Extension, Share Extension, Widget Extension), они
  расходуют дополнительные App ID из лимита 10 за 7 дней
  ([AltStore: App IDs](https://faq.altstore.io/altstore-classic/app-ids)).
- **App ID нельзя удалить вручную** — он «освобождается» примерно через 7 дней после
  регистрации ([SideStore: ошибка 1009](https://docs.sidestore.io/docs/troubleshooting/error-codes)).
  Это значит, что неудачные попытки установки с разными bundle id съедают недельный лимит.
- **bundle id — это идентификатор приложения в системе.** Смена `CFBundleIdentifier` при
  переустановке = iOS считает это другим приложением: старые данные остаются в контейнере
  старого bundle id и в новом приложении не видны ([Apple: CFBundleIdentifier](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleidentifier)).

---

## 2. Сравнение способов установки без Mac

Все варианты ниже позволяют поставить `.ipa` на iPhone, не имея Mac. Они различаются тем,
что требуется на ПК, что требуется на телефоне и какой ценой достигается результат.

| Способ | Что нужно на ПК | Что нужно на iPhone | Подписывает | Плюсы | Минусы |
|---|---|---|---|---|---|
| **SideStore** (рекомендуется) | Один раз: ПК под Windows 8+/macOS High Sierra+/Linux/Chromebook и программа **iloader**; на Windows iloader требует установленный iTunes ([prerequisites](https://docs.sidestore.io/docs/installation/prerequisites), [iloader.app](https://iloader.app)) | iOS/iPadOS 15.0+, код-пароль, Wi-Fi (мобильная сеть не подходит), приложение **LocalDevVPN** из App Store, включённый Режим разработчика | Скопированный на устройство сертификат + профиль (через Apple API) | ПК нужен один раз; обновления и переподпись — на самом телефоне; автоматический refresh в фоне | Нужен постоянный включённый VPN (LocalDevVPN); pairing file может «протухнуть»; те же лимиты: 3 приложения / 10 App ID в неделю |
| **AltStore + AltServer** | Постоянно запущенный AltServer на Windows/macOS; **iTunes и iCloud, скачанные с сайта Apple, а не из Microsoft Store** ([how-to-install-altstore-windows](https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows.md)) | iOS 16+ требует Режим разработчика; Wi-Fi, общий с ПК, либо кабель | AltServer (через Apple API) | Зрелый и хорошо документированный проект; не нужен VPN-профиль | ПК должен быть включён и в той же сети для refresh; на Windows версия iCloud из Store официально не поддерживается; лимиты те же |
| **Sideloadly** | Windows 7+ или macOS 10.12+; **«web»-версии iTunes и iCloud** (Store-версии нужно удалить) ([sideloadly.io](https://sideloadly.io/)) | iOS 7–26+; Режим разработчика на новых iOS; USB-кабель | Sideloadly локально | Самый простой разовый путь: drag-n-drop IPA, есть логи установки, умеет менять bundle id/имя; автоматический фоновый re-sign | Нужен ПК для каждой переподписи (или постоянно работающий демон на ПК); тоже требует iTunes/iCloud |
| **TrollStore** | Зависит от метода установки: часть способов обходится без ПК, часть требует компьютер ([гайды ios.cfw.guide](https://ios.cfw.guide/installing-trollstore)) | **Только уязвимые версии iOS**: 14.0 beta 2 – 16.6.1, 16.7 RC (20H18), 17.0 ([README opa334/TrollStore](https://github.com/opa334/TrollStore)) | Permasign — подпись не истекает | Подпись «навсегда», лимиты 7 дней и 3 приложений не действуют | 16.7.x (кроме 16.7 RC) и 17.0.1+ не будут поддерживаться никогда; для современных iOS неприменимо |
| **Apple Developer Program** ($99/год) | Не нужен | — | Xcode/инструмент | Сертификат на 1 год, нет переподписи каждые 7 дней, нет лимита 3 приложений ([SideStore FAQ](https://docs.sidestore.io/docs/faq)) | Платно; по-прежнему нужен компьютер/инструмент для первичной установки |

Дополнительно:

- **AltStore PAL** — легальный альтернативный маркетплейс AltStore для ЕС (страны, где
  разрешены альтернативные маркетплейсы). Вне ЕС неприменим
  ([AltStore PAL docs](https://faq.altstore.io/altstore-pal/what-is-altstore-pal.md)).
- **LiveContainer** позволяет обойти лимит 3 приложений, но не лимит 10 App ID
  ([SideStore FAQ](https://docs.sidestore.io/docs/faq)).

### 2.1. Про JitterbugPair, StosVPN и WireGuard — устаревшие шаги

Прежние инструкции SideStore требовали: получить pairing file утилитой **JitterbugPair**
(или `idevice_pair`), поставить VPN-профиль **StosVPN** либо **WireGuard** с конфигом
`SideStore.conf`, и так далее. В актуальной документации SideStore эти шаги вынесены в
раздел **«Alternative/Outdated Instructions»**, и по каждому есть явная оговорка:

- WireGuard: «only works on SideStore versions between 0.3.1-0.6.1, and 0.6.3-nightly.4e6756d
  on, and is not recommended if you have an alternative available (LocalDevVPN)»
  ([SideStore docs: Alternative](https://docs.sidestore.io/docs/advanced/alternative)).
- Актуальный путь: **iloader** на ПК + **LocalDevVPN** из App Store; iloader сам кладёт
  pairing file в приложения («Manage Pairing File» → «Place»)
  ([prerequisites](https://docs.sidestore.io/docs/installation/prerequisites),
  [install](https://docs.sidestore.io/docs/installation/install),
  [pairing file](https://docs.sidestore.io/docs/advanced/pairing-file)).

**AltServer для установки SideStore не нужен** — SideStore прямо отвечает на этот вопрос
в FAQ: «Nope, you can sideload SideStore directly by following our helpful guide»
([SideStore FAQ](https://docs.sidestore.io/docs/faq)). AltServer остался лишь как
альтернативный (устаревший) способ установки, полезный в одном сценарии — несколько
устройств на одном Apple ID с общим экспортированным сертификатом
([Alternative](https://docs.sidestore.io/docs/advanced/alternative)).

---

## 3. Рекомендуемый путь: SideStore, шаг за шагом

Схема целиком:

```
GitHub Actions (macos-latest)
  flutter build ios --release --no-codesign
  → Payload/Runner.app → Schedly-unsigned.ipa (artifact)
        |
        v  скачать artifact
  Перенос Schedly-unsigned.ipa на iPhone (iCloud Drive / Files / AirDrop / мессенджер)
        |
        v
  ПК (Windows): iloader + iTunes → установка самого SideStore + запись pairing file
        |
        v
  iPhone: доверие сертификату → Режим разработчика → LocalDevVPN → вход в SideStore
        |
        v
  SideStore → My Apps → «+» → выбрать Schedly-unsigned.ipa → SideStore переподписывает
        и устанавливает приложение
        |
        v
  Раз в 7 дней: открыть SideStore с включённым LocalDevVPN и нажать refresh
```

### 3.1. Что понадобится

| Что | Где взять | Обязательность |
|---|---|---|
| iPhone с iOS 15.0+ и код-паролем | — | да |
| Wi-Fi (не мобильный интернет) | — | да ([prerequisites](https://docs.sidestore.io/docs/installation/prerequisites)) |
| Apple ID | appleid.apple.com | да |
| ПК (Windows 8+/macOS/Linux/Chromebook) + кабель | — | только для первичной установки |
| iloader | [iloader.app](https://iloader.app) или [github.com/nab138/iloader](https://github.com/nab138/iloader) | да, для установки SideStore и pairing file |
| iTunes (на Windows) | apple.com/itunes | да, требование iloader на Windows ([iloader.app](https://iloader.app)) |
| LocalDevVPN | App Store: `apps.apple.com/app/localdevvpn/id6755608044` | да, включать при установке/refresh ([prerequisites](https://docs.sidestore.io/docs/installation/prerequisites)) |

Артефакт `.ipa` собирается в CI — ПК для сборки не нужен.

### 3.2. Шаг 1. Подготовка сборки в CI

Требования к проекту (детали в разделе 4):

- Уникальный `CFBundleIdentifier`, например `ru.dnevnik.schedly`.
- Зафиксированные `CFBundleShortVersionString` / `CFBundleVersion` (они же
  `build-name` / `build-number` из `pubspec.yaml`).
- Сборка строго для устройства: `flutter build ios --release --no-codesign`.

Проверка перед CI: в `ios/Runner/Info.plist` не должно быть значений, заимствованных из
шаблона, и не должно быть пробелов/кириллицы в `CFBundleIdentifier`.

### 3.3. Шаг 2. Скачивание артефакта `.ipa`

1. Открыть нужный run в GitHub Actions.
2. Внизу страницы run — раздел **Artifacts**.
3. Скачать `Schedly-unsigned.ipa`.

Если артефакт скачался как `.zip` — распаковать; внутри должен быть `.ipa`
(это тоже zip-контейнер, но с расширением `.ipa`).

### 3.4. Шаг 3. Перенос `.ipa` на iPhone

Работает любой из способов:

- iCloud Drive / Google Drive / Яндекс.Диск → приложение «Файлы» на iPhone.
- AirDrop с устройства Apple.
- Отправить себе в мессенджере/почте и сохранить в «Файлы» (на iOS «Сохранить в Файлы»).
- Кабелем через iTunes: «Файловый доступ» у приложения «Файлы» (менее удобно).

Практика: хранить IPA в одном и том же месте, например
`Файлы → На iPhone → Schedly`, чтобы каждый раз не искать файл.

### 3.5. Шаг 4. Первичная установка SideStore на ПК

Порядок из официальной документации
([prerequisites](https://docs.sidestore.io/docs/installation/prerequisites),
[install](https://docs.sidestore.io/docs/installation/install)):

1. Установить **LocalDevVPN** на iPhone из App Store и один раз подключиться к нему
   (система спросит «Allow VPN Configurations» — разрешить, ввести код-пароль).
2. На ПК установить **iloader** (на Windows предварительно — iTunes).
3. Подключить iPhone кабелем. Если появится запрос — «Доверять» и ввести код-пароль.
4. Открыть iloader.
5. Войти в свой Apple Account. Обратите внимание: **логин чувствителен к регистру**
   ([install](https://docs.sidestore.io/docs/installation/install)).
   Можно использовать аккаунт, не связанный с устройством.
6. Выбрать своё устройство в списке.
7. Нажать **Install SideStore (Stable)**.
8. Дождаться сообщения об успехе; iloader автоматически размещает pairing file.
   Если нужно разместить его вручную: **Manage Pairing File** → напротив «SideStore»
   нажать **Place**, должно появиться «Pairing file placed successfully!»
   ([pairing file](https://docs.sidestore.io/docs/advanced/pairing-file)).

Примечания:

- Если iloader предложит обновиться — согласиться (это требование официального гайда).
- Проблемы именно с iloader разбирает не сообщество SideStore, а сервер idevice
  ([install](https://docs.sidestore.io/docs/installation/install)).
- Доступ к Apple ID получает только Apple: iloader эмулирует Xcode и работает с Apple API
  напрямую ([iloader.app, Technical Details](https://iloader.app)).

### 3.6. Шаг 5. Доверие сертификату и Режим разработчика

На iPhone ([install](https://docs.sidestore.io/docs/installation/install),
[Apple: Enabling Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)):

1. `Настройки → Основные → VPN и управление устройством` (в англ. локали
   `General → VPN & Device Management`).
2. В разделе «Developer App» выбрать профиль с именем вашего Apple Account.
3. Нажать «Доверять/Trust <имя>», затем «Разрешить и перезапустить», ввести код-пароль.
4. `Настройки → Конфиденциальность и безопасность` → внизу включить **Режим разработчика**
   (Developer Mode). Устройство перезагрузится; после перезагрузки подтвердить включение
   и ввести код-пароль.

Важный нюанс от Apple: **переключатель «Режим разработчика» появляется в настройках только
после того, как устройство было сопряжено с Mac или было начато сопряжение**
([Apple: Enabling Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)).
На практике для sideloading сопряжение с ПК выполняет iloader (шаг 4), после чего пункт
появляется. Если пункта нет — сначала выполнить шаг 4, затем искать переключатель.

### 3.7. Шаг 6. VPN-профиль

1. Открыть **LocalDevVPN**.
2. Нажать **Connect**, разрешить VPN-конфигурацию, ввести код-пароль.

VPN должен быть включён **всякий раз**, когда вы устанавливаете, обновляете или
обновляете подпись приложений в SideStore; трафик при этом не уходит на внешние серверы,
поэтому батарея не расходуется ([prerequisites](https://docs.sidestore.io/docs/installation/prerequisites),
[SideStore FAQ](https://docs.sidestore.io/docs/faq)).

Если профиль не подключается — см. `docs/ios-troubleshooting.md`, раздел про VPN.

### 3.8. Шаг 7. Pairing file: что это и когда переделывать

Pairing file — файл сопряжения (в старых версиях `.plist`, сейчас
`.mobiledevicepairing`), которым SideStore разговаривает с внутренними сервисами
устройства (AFC/installation_proxy) через локальный VPN
([Alternative: JitterbugPair](https://docs.sidestore.io/docs/advanced/alternative)).

Если pairing file недействителен, типичная ошибка:
«AFC was unable to manage files on the device. This usually means an invalid pairing»
([SideStore discussion](https://github.com/orgs/SideStore/discussions/1073)).

Файл может «протухнуть»:

- после обновления iOS или сброса устройства;
- **в случайные моменты** — по документации SideStore это поведение Apple, и исправить
  его со стороны SideStore невозможно ([SideStore FAQ](https://docs.sidestore.io/docs/faq),
  [install](https://docs.sidestore.io/docs/installation/install)).

Замена pairing file через iloader ([pairing file](https://docs.sidestore.io/docs/advanced/pairing-file)):

1. Подключить устройство кабелем (по Wi-Fi тоже работает, но кабель надёжнее).
2. В iloader нажать **Delete Stored Pairing**.
3. Выбрать устройство в списке и на устройстве подтвердить **Trust**.
4. Нажать **Manage Pairing File**.
5. Напротив «SideStore» (и других нужных приложений) нажать **Place**.
   Должно появиться зелёное «Pairing file placed successfully!».
6. Если ошибка осталась — перезагрузить телефон и ПК и повторить.

### 3.9. Шаг 8. Установка Schedly

1. Убедиться, что LocalDevVPN подключён и Wi-Fi активен.
2. Открыть **SideStore** и войти тем же Apple Account, что использовался в iloader.
3. **Сразу после входа** зайти в `My Apps` и нажать счётчик `7 DAYS` справа от SideStore,
   чтобы обновить саму SideStore. Это обязательный шаг: сторонние установщики присваивают
   SideStore свой app group ID, и без refresh приложения с «чужим» group ID пропадают из
   списка ([SideStore FAQ](https://docs.sidestore.io/docs/faq)).
4. Если появится запрос про сертификат («revoke or create a new signing certificate») —
   согласиться ([install](https://docs.sidestore.io/docs/installation/install)).
5. `My Apps` → **+** → выбрать `Schedly-unsigned.ipa` из «Файлов».
6. Дождаться установки; SideStore переподпишет приложение своим сертификатом и поставит его.

Итого занято слотов: SideStore + Schedly = 2 из 3 для бесплатного Apple ID.

### 3.10. Шаг 9. Обновление и продление подписи

- **Обновление версии:** собрать новый IPA тем же bundle id, положить в «Файлы», открыть
  SideStore → `My Apps` → **+** → выбрать новый IPA. Данные сохранятся, если bundle id не
  менялся.
- **Продление:** раз в 7 дней приложение перестаёт запускаться. С включённым
  LocalDevVPN открыть SideStore → `My Apps` → нажать счётчик дней у Schedly (или «Refresh All»).
  SideStore умеет обновлять подпись автоматически, пока включён VPN.
- Диагностика продления — в `docs/ios-troubleshooting.md`.

### 3.11. Чек-лист на весь путь

- [ ] `CFBundleIdentifier` уникален, в обратном DNS, только латиница/цифры/точки/дефисы.
- [ ] IPA собран для устройства (arm64), а не для симулятора.
- [ ] IPA лежит в «Файлы» на iPhone.
- [ ] Установлен LocalDevVPN, профиль разрешён.
- [ ] Установлен iloader (на Windows — с iTunes), вход в Apple Account выполнен.
- [ ] SideStore установлен через iloader, pairing file размещён (Place).
- [ ] Сертификат подтверждён в `Настройки → Основные → VPN и управление устройством`.
- [ ] Включён Режим разработчика, устройство перезагружено.
- [ ] После первого входа в SideStore сделан refresh самой SideStore.
- [ ] Установлен Schedly, проверен запуск.

---

## 4. Требования к `.ipa` из CI

### 4.1. Сборка и упаковка

Сборка без подписи (macOS-раннер, Xcode из образа `macos-latest`):

```bash
flutter clean
flutter pub get
cd ios && pod install && cd ..
flutter build ios --release --no-codesign
```

Результат: `build/ios/iphoneos/Runner.app` — не подписанный, но полностью
сконфигурированный бандл для устройства.

Упаковка в IPA (Payload в корне архива — обязательное требование структуры IPA):

```bash
mkdir -p Payload
cp -R build/ios/iphoneos/Runner.app Payload/
zip -qry Schedly-unsigned.ipa Payload
```

Флаги `zip` здесь значимы: `-q` — тихий режим, `-r` — рекурсивно, `-y` — сохранять
симлинки как ссылки, а не разворачивать их содержимое (иначе бандл раздувается и ломается).
Проверка структуры:

```bash
unzip -l Schedly-unsigned.ipa | head
# в списке должен быть каталог Payload/ и внутри — Runner.app/
```

Альтернатива для macOS (сохраняет расширенные атрибуты и ресурсные форки):

```bash
ditto -c -k --sequesterRsrc --keepParent Payload Schedly-unsigned.ipa
```

### 4.2. Рабочий процесс GitHub Actions

```yaml
name: ios-unsigned-ipa
on:
  workflow_dispatch:
  push:
    tags: ['v*']

jobs:
  build:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4

      # community-экшен; при обновлении проверьте актуальную мажорную версию
      - uses: subosito/flutter-action@v2
        with:
          channel: stable

      - name: Dependencies
        run: flutter pub get

      - name: Pods
        working-directory: ios
        run: pod install

      - name: Build (unsigned)
        run: flutter build ios --release --no-codesign

      - name: Package IPA
        run: |
          mkdir -p Payload
          cp -R build/ios/iphoneos/Runner.app Payload/
          zip -qry Schedly-unsigned.ipa Payload
          unzip -l Schedly-unsigned.ipa | head -20

      - uses: actions/upload-artifact@v4
        with:
          name: Schedly-unsigned-ipa
          path: Schedly-unsigned.ipa
          if-no-files-found: error
```

Практические замечания по CI:

- Версию приложения удобно прокидывать из тега:
  `flutter build ios --release --no-codesign --build-name=1.2.3 --build-number=$GITHUB_RUN_NUMBER`.
  В iOS `build-name` попадает в `CFBundleShortVersionString`, `build-number` — в
  `CFBundleVersion` ([Flutter: Build and release an iOS app](https://docs.flutter.dev/deployment/ios)).
- Шаг `pod install` можно не выделять отдельно: `flutter build` сам вызывает CocoaPods.
  Отдельный шаг полезен, чтобы явно увидеть ошибку подов.
- `flutter build ios --no-codesign` — штатный способ получить сборку без подписи; список
  актуальных флагов всегда можно посмотреть локально командой
  `flutter build ios --help`.

### 4.3. Критичные поля `Info.plist`

| Ключ | Что делает | Почему критичен при sideload | Источник |
|---|---|---|---|
| `CFBundleIdentifier` | Уникальный идентификатор приложения | Пара (Apple ID + bundle id) регистрируется как App ID. Смена bundle id = новое приложение: данные и слот расходуются заново, возможен расход недельного лимита 10 App ID. Только `A–Z a–z 0–9 - .`, обычно reverse-DNS (`ru.dnevnik.schedly`), регистр не учитывается | [Apple: CFBundleIdentifier](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleidentifier) |
| `CFBundleDisplayName` | Имя под иконкой на домашнем экране | Именно его видит пользователь. Полезно, если имя должно быть на кириллице. Ошибка 3009 возникает из-за **не-ASCII символов в имени приложения при регистрации в Apple** — имя приложения при регистрации формируется из bundle, поэтому безопаснее держать англоязычный `CFBundleName`/bundle id и задать человекочитаемый `CFBundleDisplayName` | [SideStore: 3009](https://docs.sidestore.io/docs/troubleshooting/error-codes) |
| `CFBundleShortVersionString` | Версия для пользователя (`1.2.3`) | Должна расти при выпуске; из неё берётся `--build-name` | [Flutter: iOS](https://docs.flutter.dev/deployment/ios) |
| `CFBundleVersion` | Номер сборки (`1`, `2`, …) | Должен быть уникальным для каждой сборки; из него берётся `--build-number` | [Flutter: iOS](https://docs.flutter.dev/deployment/ios) |
| `UIBackgroundModes` | Разрешённые фоновые режимы | Если приложение честно использует фоновые задачи, режим нужно объявить; допустимые значения включают `audio`, `fetch`, `processing`, `remote-notification`, `location`, `bluetooth-central` и др. Фиктивное указание режимов приведёт к отказу при попытке использовать их без прав | [Apple: UIBackgroundModes](https://developer.apple.com/documentation/bundleresources/information-property-list/uibackgroundmodes) |
| `NSAppTransportSecurity` | Исключения ATS для HTTP | По умолчанию ATS требует HTTPS и блокирует «небезопасные» соединения. Если сервер расписания отдаётся по HTTP, запросы будут падать в приложении при работающем браузере. Точечное решение — `NSExceptionDomains` для нужного домена, а не глобальный `NSAllowsArbitraryLoads` | [Apple: NSAppTransportSecurity](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity) |
| `UILaunchStoryboardName` | Launch screen | Обычно уже указан в шаблоне Flutter. Если ключ убрать/сломать, приложение может открываться в уменьшенном окне или вести себя некорректно | [Apple: Information Property List](https://developer.apple.com/documentation/bundleresources/information-property-list) |

Пример целевых значений:

```xml
<key>CFBundleIdentifier</key>
<string>ru.dnevnik.schedly</string>
<key>CFBundleDisplayName</key>
<string>Дневник</string>
<key>CFBundleName</key>
<string>Schedly</string>
<key>CFBundleShortVersionString</key>
<string>1.0.0</string>
<key>CFBundleVersion</key>
<string>1</string>
<key>UILaunchStoryboardName</key>
<string>LaunchScreen</string>
<key>UIBackgroundModes</key>
<array>
  <string>fetch</string>
  <string>processing</string>
</array>
<key>NSAppTransportSecurity</key>
<dict>
  <key>NSExceptionDomains</key>
  <dict>
    <key>example.ru</key>
    <dict>
      <key>NSExceptionAllowsInsecureHTTPLoads</key>
      <true/>
      <key>NSIncludesSubdomains</key>
      <true/>
    </dict>
  </dict>
</dict>
```

### 4.4. Что проверить в готовом IPA до установки

```bash
# структура
unzip -l Schedly-unsigned.ipa | head -30

# архитектуры бинарника (macOS)
lipo -info Payload/Runner.app/Runner
# ожидается: arm64 — сборка для устройства.
# x86_64 / arm64-simulator означает сборку под симулятор: на iPhone она не запустится.

# ключевые поля plist
plutil -p Payload/Runner.app/Info.plist | grep -E 'CFBundle(Identifier|ShortVersionString|Version|DisplayName)'
```

Отсутствие `arm64` — самая частая причина «установилось, но падает сразу»: см.
`docs/ios-troubleshooting.md`.

---

## 5. Подводные камни

1. **Переподпись каждые 7 дней.** Через 7 дней приложение перестаёт запускаться (часто
   без внятного сообщения). Лечится refresh в SideStore с включённым LocalDevVPN
   ([SideStore FAQ](https://docs.sidestore.io/docs/faq)).
2. **Максимум 3 приложения одновременно, включая сам SideStore.** Итого остаётся 2 слота
   под свои приложения ([SideStore FAQ](https://docs.sidestore.io/docs/faq)).
3. **Лимит 10 App ID за 7 дней.** Каждая установка нового bundle id расходует App ID;
   App ID не удаляются вручную и освобождаются примерно через 7 дней. Не экспериментируйте
   с bundle id «по кругу» — слоты кончатся ([SideStore: 1009/3013](https://docs.sidestore.io/docs/troubleshooting/error-codes),
   [AltStore: App IDs](https://faq.altstore.io/altstore-classic/app-ids)).
4. **Смена bundle id = новая установка и потеря доступа к старым данным.** Если данные
   лежат только локально, они останутся в контейнере прежнего bundle id и в новом
   приложении не появятся. Обязательное условие перед сменой bundle id — экспорт данных
   или синхронизация с сервером.
5. **«Unable to install» из-за занятого bundle id.** Если приложение с таким bundle id
   уже установлено с другим сертификатом, iOS откажется ставить новое. Решения:
   удалить старое приложение (данные пропадут — сначала выгрузить их) либо использовать
   другой bundle id. В SideStore аналогичная ошибка — код 3011 «bundle identifier has
   already been registered» ([error codes](https://docs.sidestore.io/docs/troubleshooting/error-codes)).
6. **Режим разработчика обязателен на iOS 16+.** Без него приложение не запустится;
   переключатель виден только после сопряжения с компьютером, а после включения требуется
   перезагрузка ([Apple: Enabling Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)).
7. **Доверие сертификату — вручную.** `Настройки → Основные → VPN и управление устройством`
   → Developer App → Trust. Пока не подтверждено, приложение не запускается (ошибка 1011
   в SideStore: «denied permission to launch the app… you still need to trust your Apple
   Account in Settings») ([SideStore FAQ](https://docs.sidestore.io/docs/faq),
   [error codes](https://docs.sidestore.io/docs/troubleshooting/error-codes)).
8. **VPN должен быть включён.** Без LocalDevVPN SideStore не устанавливает и не обновляет
   подписи (ошибка 1414 «No Wi-Fi/StosVPN») и не сможет продлить приложение в фоне
   ([error codes](https://docs.sidestore.io/docs/troubleshooting/error-codes)).
9. **Pairing file может протухнуть** после обновления/сброса iOS и «в случайные моменты»;
   перевыпускается через iloader ([pairing file](https://docs.sidestore.io/docs/advanced/pairing-file)).
10. **Установка SideStore «не через iloader» ломает app group.** Refresh самой SideStore
    сразу после первого входа обязателен, иначе часть приложений пропадёт из списка
    ([SideStore FAQ](https://docs.sidestore.io/docs/faq)).
11. **Мобильный интернет не подходит.** Нужен именно Wi-Fi
    ([prerequisites](https://docs.sidestore.io/docs/installation/prerequisites)).
12. **Windows: версии iTunes/iCloud из Microsoft Store не поддерживаются** — для iloader
    нужен iTunes с сайта Apple, для AltStore — iTunes **и** iCloud с сайта Apple,
    для Sideloadly — «web»-версии обоих ([iloader.app](https://iloader.app),
    [AltStore Windows](https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows.md),
    [sideloadly.io](https://sideloadly.io/)).
13. **Ошибки входа и блокировка Apple ID.** Устаревшие Anisette-серверы, используемые
    многими пользователями, известны тем, что приводят к блокировке Apple ID — нужно
    использовать официальные Anisette-серверы
    ([SideStore FAQ](https://docs.sidestore.io/docs/faq)). При ошибке входа попробуйте
    сменить Anisette URL в настройках SideStore.
14. **Расход места.** Ошибка `(512) Failed to write to disk` означает нехватку места на
    устройстве ([error codes](https://docs.sidestore.io/docs/troubleshooting/error-codes)).
15. **TrollStore — не для современных iOS.** Поддерживаются 14.0 beta 2 – 16.6.1,
    16.7 RC (20H18), 17.0; 16.7.x (кроме 16.7 RC) и 17.0.1+ не будут поддерживаться
    никогда ([README](https://github.com/opa334/TrollStore)). Не тратьте время на этот
    путь, если у вас свежая iOS.

---

## 6. Альтернатива: если появится Mac (`flutter build ipa` и Xcode)

Этот путь не нужен для SideStore, но полезен, если появится доступ к Mac: подписанный IPA
можно ставить и продлевать без 7-дневного цикла (при платном аккаунте — на год).

### 6.1. Сборка

```bash
# версия/номер сборки (эквивалент CFBundleShortVersionString / CFBundleVersion)
flutter build ipa --release \
  --build-name=1.0.0 \
  --build-number=1 \
  --export-method development
```

По документации Flutter результатом будут:

- Xcode-архив `build/ios/archive/*.xcarchive`;
- app bundle `build/ios/ipa/*.ipa`.

Для ad-hoc/development/enterprise можно менять `--export-method`
([Flutter: Build and release an iOS app](https://docs.flutter.dev/deployment/ios)).

### 6.2. Подпись в Xcode

1. `open ios/Runner.xcworkspace`.
2. Target **Runner** → вкладка **Signing & Capabilities**.
3. Включить **Automatically manage signing**, выбрать Team (для бесплатного Apple ID это
   Personal Team).
4. Убедиться, что Bundle Identifier совпадает с тем, что используется в sideload-сборке,
   если вы хотите сохранить данные существующей установки.
5. Вкладка **General** → Identity: Display Name, Version, Build.
6. **Product → Archive** → в органайзере **Distribute App** → выбрать способ
   распространения (Development/Ad Hoc) → **Export**, получить IPA.

Ограничения бесплатного Apple ID сохраняются и здесь: 7 дней и лимиты App ID
([Flutter: iOS](https://docs.flutter.dev/deployment/ios),
[SideStore FAQ](https://docs.sidestore.io/docs/faq)).

### 6.3. Что даёт платный аккаунт

- Сертификат действует 1 год вместо 7 дней, переподпись раз в неделю не нужна.
- Снимается ограничение на 3 одновременно установленных приложения
  ([SideStore FAQ](https://docs.sidestore.io/docs/faq)).

---

## 7. Источники

Официальные документы инструментов:

- SideStore, Prerequisites — https://docs.sidestore.io/docs/installation/prerequisites
- SideStore, Install — https://docs.sidestore.io/docs/installation/install
- SideStore, FAQ (лимиты 3/10, 7 дней, Anisette, 365 дней с платным аккаунтом) — https://docs.sidestore.io/docs/faq
- SideStore, Common Issues — https://docs.sidestore.io/docs/troubleshooting/common-issues
- SideStore, Error Codes — https://docs.sidestore.io/docs/troubleshooting/error-codes
- SideStore, Alternative/Outdated Instructions (JitterbugPair, WireGuard, exploits) — https://docs.sidestore.io/docs/advanced/alternative
- SideStore, Pairing File — https://docs.sidestore.io/docs/advanced/pairing-file
- iloader (Windows требует iTunes; техническое описание процесса) — https://iloader.app
- AltStore, How to Install (Windows) — https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows.md
- AltStore, App IDs — https://faq.altstore.io/altstore-classic/app-ids.md
- AltStore, AltServer — https://faq.altstore.io/altstore-classic/altserver.md
- AltStore, Troubleshooting Guide — https://faq.altstore.io/altstore-classic/troubleshooting-guide.md
- Sideloadly (требования к iTunes/iCloud, 7 дней / 1 год) — https://sideloadly.io/
- TrollStore, README (поддерживаемые версии iOS) — https://github.com/opa334/TrollStore

Apple:

- Enabling Developer Mode on a device — https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device
- CFBundleIdentifier — https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleidentifier
- UIBackgroundModes — https://developer.apple.com/documentation/bundleresources/information-property-list/uibackgroundmodes
- NSAppTransportSecurity — https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity
- Information Property List — https://developer.apple.com/documentation/bundleresources/information-property-list

Flutter:

- Build and release an iOS app — https://docs.flutter.dev/deployment/ios

---

## 8. Что не удалось подтвердить по первоисточникам

Помечаю честно: пункты ниже **не подтверждены на страницах Apple** в этой проверке.
Они опираются на документацию инструментов sideloading (SideStore, AltStore, Sideloadly),
которая сама по себе является для этих цифр основным практическим источником.

1. **Числовые лимиты бесплатного Apple ID (7 дней, 3 приложения, 10 App ID за 7 дней)
   не подтверждены ссылкой на developer.apple.com.** Страницы Apple по этой теме закрыты
   для автоматического чтения. Цифры подтверждены: [SideStore FAQ](https://docs.sidestore.io/docs/faq),
   [SideStore error codes 1009/3013](https://docs.sidestore.io/docs/troubleshooting/error-codes),
   [AltStore App IDs](https://faq.altstore.io/altstore-classic/app-ids),
   [Sideloadly FAQ](https://sideloadly.io/). Если нужна гарантия — проверьте сами в личном
   кабинете developer.apple.com (Certificates, Identifiers & Profiles) и в Xcode.
2. **Минимальная версия iOS для SideStore:** документация противоречива —
   [intro](https://docs.sidestore.io/docs/intro) говорит «iOS/iPadOS 14+», а
   [prerequisites](https://docs.sidestore.io/docs/installation/prerequisites) требует
   «iOS/iPadOS 15.0 or higher». В документе взято требование prerequisites (15.0+).
   Не подтверждено, какая планка актуальна на текущий релиз — проверьте сами.
3. **Границы эксплойта SparseRestore для обхода лимита 3 приложений** описаны
   противоречиво: [FAQ](https://docs.sidestore.io/docs/faq) упоминает «iOS versions
   18 db5/18.0.1 and below», а [Alternative](https://docs.sidestore.io/docs/advanced/alternative) —
   «17.0 – 18.1 beta 4 (не включая 17.7.1)». Точный диапазон не подтверждён.
4. **Поведение обхода лимита через Lara/Darksword** (iOS 17.0–18.7.1 и 26.0.x, исключения
   для M5 и A19; подтверждено на 16.7.2) взято из документации SideStore и не проверялось
   нами на устройствах. Не подтверждено, проверяйте сами.
5. **Совместимость AltServer с приложением «Apple Devices» из Microsoft Store.**
   Официальная инструкция AltStore по-прежнему требует iTunes и iCloud **с сайта Apple**
   ([источник](https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows.md)).
   Работает ли актуальный AltServer с Microsoft Store-версией Apple Devices — не
   подтверждено, проверяйте сами.
6. **Точное число сертификатов, доступных бесплатному Apple ID.** Известно лишь, что
   SideStore при исчерпании предлагает «revoke or create a new signing certificate»
   ([install](https://docs.sidestore.io/docs/installation/install)); конкретные цифры
   Apple не публикует в общедоступной справке — не подтверждено.
7. **Флаг `flutter build ios --no-codesign`** подтверждён как рабочий и широко
   используемый, но в прочитанных страницах документации Flutter явного описания этого
   флага нет. Проверьте локально: `flutter build ios --help`.
8. **Команда `zip -qry` и `ditto`** — стандартные утилиты macOS; конкретных слов
   «именно так» в документации SideStore/Flutter нет, это практика упаковки IPA.
   Структура (`Payload/Runner.app` в корне архива) — требование формата IPA.
