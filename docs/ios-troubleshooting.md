# Диагностика проблем установки и запуска (iOS, sideload)

Документ дополняет `docs/ios-signing-sidestore.md`. Речь о ситуации: приложение собрано в
GitHub Actions, установлено на iPhone через SideStore/AltStore/Sideloadly, и что-то
не работает. Предполагается, что Mac и платного аккаунта Apple Developer нет.

## Оглавление

1. [Быстрый алгоритм: где именно сломалось](#1-быстрый-алгоритм-где-именно-сломалось)
2. [Таблица «симптом → причина → решение»](#2-таблица-симптом--причина--решение)
3. [Разбор сложных случаев](#3-разбор-сложных-случаев)
4. [Коды ошибок SideStore](#4-коды-ошибок-sidestore)
5. [Как читать логи](#5-как-читать-логи)
6. [Источники](#6-источники)
7. [Что не удалось подтвердить](#7-что-не-удалось-подтвердить)

---

## 1. Быстрый алгоритм: где именно сломалось

Разделяйте четыре стадии — у них разные причины и разные инструменты:

| Стадия | Признак | Куда смотреть |
|---|---|---|
| A. Сборка в CI | Job упал до появления артефакта | логи run в GitHub Actions, шаги `pod install` / `flutter build` |
| B. Доставка и подпись | IPA не ставится, SideStore/AltStore показывает ошибку | сообщение об ошибке и его код, раздел 4 |
| C. Доверие и запуск | Установилось, но не запускается или падает сразу | «Untrusted Developer», Режим разработчика, крешлоги |
| D. Работа приложения | Запускается, но данные/сеть не работают | логи приложения, ATS, парсинг PDF, состояние сервера |

Первые три стадии почти всегда снимаются одним из трёх действий: обновить pairing file,
включить LocalDevVPN, подтвердить сертификат в настройках. Стадия D — это уже обычная
разработка, а не проблема sideloading.

---

## 2. Таблица «симптом → причина → решение»

| Симптом | Вероятная причина | Решение |
|---|---|---|
| B. IPA не устанавливается, «Unable to install» | Bundle id уже занят другой установкой с другим сертификатом; либо не уникальный/невалидный `CFBundleIdentifier` | Удалить прежнее приложение с тем же bundle id (предварительно выгрузить данные) либо сменить bundle id на новый. Проверить формат: только `A–Z a–z 0–9 - .`, reverse-DNS. Ошибка 3011 в SideStore — то же самое ([error codes](https://docs.sidestore.io/docs/troubleshooting/error-codes), [Apple: CFBundleIdentifier](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleidentifier)) |
| B. Ошибка 1007 «This app is in an invalid format» | IPA собран неправильно: `Payload` не в корне архива, вложенная папка, `.app` без `Info.plist`, битый архив | Перепаковать: `mkdir -p Payload && cp -R build/ios/iphoneos/Runner.app Payload/ && zip -qry Schedly-unsigned.ipa Payload`. Проверить `unzip -l` ([error codes](https://docs.sidestore.io/docs/troubleshooting/error-codes)) |
| C. «Untrusted Developer» / «Не удалось проверить разработчика» при первом запуске | Сертификат не подтверждён на устройстве | `Настройки → Основные → VPN и управление устройством` → Developer App → ваш Apple Account → «Доверять» → «Разрешить и перезапустить» ([install](https://docs.sidestore.io/docs/installation/install)) |
| C. Ошибка 1011 «SideStore was denied permission to launch the app» | Нажат «Cancel» в диалоге «SideStore wants to open …» или не подтверждён сертификат | Повторить запуск и нажать «Разрешить»; проверить доверие сертификату (см. строку выше) ([error codes](https://docs.sidestore.io/docs/troubleshooting/error-codes)) |
| C. Приложение вылетает сразу после запуска | Сборка для симулятора: бинарник `x86_64`/`arm64-simulator` вместо `arm64` | Проверить `lipo -info Payload/Runner.app/Runner`; собрать `flutter build ios --release --no-codesign` (это сборка под устройство), а не `flutter build ios --simulator` |
| C. Приложение вылетает сразу после запуска | Deployment target выше версии iOS на устройстве | Понизить `iOS Deployment Target` до версии устройства (Flutter поддерживает iOS 13+; проверьте, что плагины не требуют большего) ([Flutter: iOS](https://docs.flutter.dev/deployment/ios)); проверить `MinimumOSVersion` в `Info.plist` |
| C. Приложение вылетает сразу после запуска | Режим разработчика не включён (iOS 16+) | `Настройки → Конфиденциальность и безопасность → Режим разработчика`, затем перезагрузка и подтверждение ([Apple: Enabling Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)) |
| C. Приложение вылетает на фоновой задаче/уведомлении | Объявлен `UIBackgroundModes`, но нет реальных прав/режима, или наоборот отсутствует нужный режим | Сверить объявленные режимы (`audio`, `fetch`, `processing`, `remote-notification`, …) с фактическим использованием ([Apple: UIBackgroundModes](https://developer.apple.com/documentation/bundleresources/information-property-list/uibackgroundmodes)) |
| A. CI падает на `pod install` / CocoaPods | Несовпадение версии плагина и podspec, отсутствие Podfile.lock, устаревший CocoaPods на раннере, ошибка в Podfile | Смотреть вывод шага; локально воспроизвести: `cd ios && pod install --repo-update`; зафиксировать `Podfile.lock` в репозитории; обновить CocoaPods в шаге CI; проверить, что `ios/Podfile` не задаёт platform ниже требуемого плагинами ([Flutter: iOS](https://docs.flutter.dev/deployment/ios)) |
| A. `No profiles for 'X' were found` в CI | Где-то осталась попытка подписать сборку (не передан `--no-codesign`, либо запущен `flutter build ipa`) | Использовать `flutter build ios --release --no-codesign`; не выполнять `flutter build ipa` без сертификата |
| B. Приложение «не видно» в SideStore / пропало из `My Apps` | SideStore установлен не через iloader, ему присвоен чужой app group ID | Сразу после первого входа сделать refresh самой SideStore (нажать счётчик дней в `My Apps`); не устанавливать ничего до этого ([SideStore FAQ](https://docs.sidestore.io/docs/faq)) |
| B. Ошибка 1012 «shared app group could not be accessed» | SideStore установлен способом, не поддерживающим его app group | Переустановить SideStore через iloader ([error codes](https://docs.sidestore.io/docs/troubleshooting/error-codes)) |
| B. VPN-профиль SideStore не подключается / постоянно отваливается | DNS-блокировщик, отсутствие Wi-Fi, конфликт с другим VPN, устаревший профиль | Выключить DNS-блокеры; убедиться, что подключены и Wi-Fi, и LocalDevVPN; перезапустить SideStore и LocalDevVPN; если не помогло — перевыпустить pairing file через iloader ([common issues](https://docs.sidestore.io/docs/troubleshooting/common-issues)) |
| B. `AFC was unable to manage files… invalid pairing` / код 27 | Pairing file недействителен: истёк после обновления/сброса iOS или случайно | Перевыпустить pairing file: iloader → **Delete Stored Pairing** → подтвердить Trust на устройстве → **Manage Pairing File** → **Place** ([pairing file](https://docs.sidestore.io/docs/advanced/pairing-file)) |
| B. Код 1414 «No Wi-Fi/StosVPN» | Не подключены Wi-Fi и/или LocalDevVPN | Включить оба. Без VPN SideStore не устанавливает и не обновляет приложения ([error codes](https://docs.sidestore.io/docs/troubleshooting/error-codes)) |
| B. Код 1009 / 3013 «cannot register more than 10 App IDs within a 7-day period» | Исчерпан недельный лимит регистрации App ID | Дождаться истечения старых App ID (~7 дней; вручную их не удалить). Каждый app extension расходует отдельный App ID — при частых экспериментах с bundle id лимит кончается быстро ([error codes](https://docs.sidestore.io/docs/troubleshooting/error-codes), [AltStore: App IDs](https://faq.altstore.io/altstore-classic/app-ids)) |
| B. «Maximum number of apps installed» / не даёт поставить третье приложение | Лимит бесплатного Apple ID: 3 приложения, включая сам SideStore | Удалить лишнее приложение (данные выгрузить заранее) либо перейти на платный аккаунт. Обходы существуют только для отдельных версий iOS ([SideStore FAQ](https://docs.sidestore.io/docs/faq)) |
| B. Приложение «не видно» в SideStore, хотя файл выбран | Файл лежит не в локальном хранилище «Файлы», а в облаке, и не скачался | Переместить IPA в `Файлы → На iPhone`, дождаться полной загрузки (облачные файлы подгружаются по требованию) |
| B/C. После переустановки пропали все данные | Изменён `CFBundleIdentifier` — для iOS это другое приложение | Вернуть прежний bundle id (данные старого контейнера станут доступны) либо восстановить данные из экспорта/облака. Дальше: всегда хранить данные вне контейнера приложения ([Apple: CFBundleIdentifier](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleidentifier)) |
| D. HTTP-запросы падают, а в Safari тот же адрес открывается | App Transport Security блокирует незащищённые соединения (типичный текст ошибки: «App Transport Security policy requires the use of a secure connection») | Перевести сервер на HTTPS. Если нельзя — добавить точечное исключение в `Info.plist`: `NSAppTransportSecurity → NSExceptionDomains → <домен> → NSExceptionAllowsInsecureHTTPLoads = true` ([Apple: NSAppTransportSecurity](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity)) |
| D. Пустой список расписания, ошибок в UI нет | Парсер PDF упал молча: сервер вернул HTML-страницу вместо PDF, изменилась вёрстка, неверная кодировка | Проверить, что ответ начинается с `%PDF` и `Content-Type: application/pdf`; логировать размер и первые байты тела; обрабатывать коды != 200 и редиректы; писать понятную ошибку в UI, а не пустой список (подробнее — раздел 3.2) |
| D. Проверка доступности файла падает, хотя скачивание работает | Сервер отвечает 405/403 на `HEAD`, либо закрывает соединение при HEAD | Не использовать `HEAD` как проверку: делать `GET` с `Range: bytes=0-0`, либо считать 405 признаком «ресурс есть» (подробнее — раздел 3.3) |
| B. Ошибка 3021 «anisette data is invalid» / 1100 «session expired» | Неверные дата и время на устройстве/ПК либо истёкшая сессия Apple ID | Включить автоматическую установку даты и времени; войти в SideStore заново; сменить Anisette URL ([error codes](https://docs.sidestore.io/docs/troubleshooting/error-codes)) |
| D/B. «Cannot verify server identity» | Некорректный сертификат сервера (просрочен, самоподписан, неполная цепочка) либо сбитое время на устройстве | Проверить часы; проверить сертификат сервера (`openssl s_client -connect host:443`); при self-signed — установить и доверять корневому сертификату вручную. Если в приложении включён certificate pinning — сверить отпечаток (см. раздел 3.4) |
| B. Ошибка 512 «Failed to write to disk» | Мало свободного места на iPhone | Освободить место, повторить ([error codes](https://docs.sidestore.io/docs/troubleshooting/error-codes)) |
| B. Ошибка 3009 «The name for this app is invalid» | Имя приложения для регистрации в Apple содержит не-ASCII символы (например, кириллицу в `CFBundleName`) | Задать латинское `CFBundleName`/bundle id, а кириллицу оставить только в `CFBundleDisplayName` ([error codes](https://docs.sidestore.io/docs/troubleshooting/error-codes)) |
| B. «Bundle identifier unavailable: An invalid value 'Дневник' was provided for the parameter 'appIdName'» | Кириллическое имя в `CFBundleDisplayName`: при регистрации App ID подставляется именно оно, а Apple принимает в имени только ASCII (`A–Z a–z 0–9 . - _`) | Вернуть латинское `CFBundleDisplayName` (в проекте — `Schedly`) и пересобрать `.ipa`; после этого повторить установку. Кириллицу нельзя указывать ни в `CFBundleName`, ни в `CFBundleDisplayName` |
| B. Ошибка `ldid.cpp(X): X` при установке | Повреждены/некорректны подписи внутри IPA (заголовки Mach-O) | По документации SideStore: переподписать IPA во вспомогательном приложении (например, Feather) любым `.mobileprovision` и `.p12`, перепаковать в IPA и установить заново ([error codes](https://docs.sidestore.io/docs/troubleshooting/error-codes)) |
| B. SideStore зависает на середине установки | Кэш, проблемы протокола/Anisette | Обновить или перезапустить SideStore → Clear Cache → сменить Anisette Server → в servers сбросить `adi.pb` и войти заново → перезагрузить устройство → пересоздать pairing file → переустановить SideStore через iloader ([common issues](https://docs.sidestore.io/docs/troubleshooting/common-issues)) |
| B. SideStore не запускается | Установлен не через iloader; повреждена app group | Переустановить SideStore через iloader. Если не помогло: удалить SideStore и всё, что через него поставлено, поставить SideStore заново, импортировать pairing file, войти (на запрос refresh ответить «нет»), затем установить сам `SideStore.ipa` внутрь SideStore ([common issues](https://docs.sidestore.io/docs/troubleshooting/common-issues)) |
| B. В `Настройках` нет пункта «Режим разработчика» | Apple показывает его только если начато сопряжение или устройство ранее сопрягалось с Mac | Сначала подключить устройство к ПК с iloader и выполнить сопряжение (шаг установки SideStore), затем искать переключатель в `Конфиденциальность и безопасность` ([Apple: Enabling Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)) |
| B. Вход в SideStore не проходит, аккаунт блокируется | Устаревший/перегруженный Anisette-сервер; известная проблема, приводящая к блокировке Apple ID | Использовать официальные Anisette-серверы или поднять свой; сменить Anisette URL в настройках SideStore ([SideStore FAQ](https://docs.sidestore.io/docs/faq)) |
| B. Ошибка 1102 «Apple ID cannot be used for development» | Не приняты условия Apple Developer Program | Войти на developer.apple.com и принять актуальные условия; при необходимости создать отдельный Apple ID только для sideloading ([error codes](https://docs.sidestore.io/docs/troubleshooting/error-codes)) |
| B. Ошибка 3003 «app-specific password is required» | Apple требует пароль приложения вместо основного | Создать пароль приложения на appleid.apple.com ([error codes](https://docs.sidestore.io/docs/troubleshooting/error-codes)) |
| B. Код 27 на iOS 26.4+ | Требуется более новый SideStore | Обновить SideStore до nightly ([error codes](https://docs.sidestore.io/docs/troubleshooting/error-codes)) |

---

## 3. Разбор сложных случаев

### 3.1. ATS-блокировка HTTP: «в браузере работает, в приложении нет»

Симптом: тот же URL открывается в Safari, но в приложении запрос падает с ошибкой вида
«App Transport Security policy requires the use of a secure connection» или тихо не доходит.

Причина: ATS по умолчанию требует HTTPS и дополнительно проверяет параметры TLS,
блокируя соединения, не соответствующие минимуму
([Apple: NSAppTransportSecurity](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity)).
В Safari другие правила, поэтому сравнение «в браузере работает» ничего не доказывает.

Диагностика:

1. Открыть URL в Safari **на том же устройстве** и убедиться, что это тот же хост, что
   использует приложение (частый случай — http-редирект на https с редиректом обратно).
2. Проверить `Info.plist` собранного IPA:
   ```bash
   plutil -p Payload/Runner.app/Info.plist | grep -A 20 NSAppTransportSecurity
   ```
3. Убедиться, что после правки `Info.plist` IPA пересобран: изменения в
   `ios/Runner/Info.plist` не попадают в уже собранный артефакт.

Правильное решение — HTTPS. Временное — точечное исключение только для нужного домена:

```xml
<key>NSAppTransportSecurity</key>
<dict>
  <key>NSExceptionDomains</key>
  <dict>
    <key>schedule.example.ru</key>
    <dict>
      <key>NSExceptionAllowsInsecureHTTPLoads</key>
      <true/>
      <key>NSIncludesSubdomains</key>
      <true/>
    </dict>
  </dict>
</dict>
```

Глобальный `NSAllowsArbitraryLoads` работает, но снимает защиту для всех соединений
приложения; Apple в документации прямо советует сначала улучшать сервер, а не ослаблять ATS
([Apple: NSAppTransportSecurity](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity)).

Практическое замечание: ATS не влияет на LocalDevVPN — он локальный и не использует
внешних серверов ([SideStore FAQ](https://docs.sidestore.io/docs/faq)). То есть VPN не может
быть причиной блокировки внешнего HTTP.

### 3.2. Пустой список расписания из-за ошибки парсинга PDF

Симптом: экран расписания пуст, приложение не падает, внятной ошибки нет.

Порядок действий:

1. Скачать тот же PDF в Safari на iPhone и открыть его — если Safari тоже не показывает
   PDF, проблема на стороне сервера (страница ошибки, редирект на логин, отдан HTML).
2. В коде логировать не «успех/ошибку», а факты: HTTP-код, `Content-Type`,
   `Content-Length`, первые байты тела. Валидный PDF начинается с сигнатуры `%PDF-`.
3. Проверить, что тело не усечено: при `Content-Length` > фактического размера часть
   страниц может отсутствовать и парсер вернёт пустой список без исключения.
4. Проверить кодировку текстовых слоёв PDF. Частая причина «пустого результата» — текст
   извлекается как пустая строка из-за нестандартной кодировки шрифта.
5. Показывать в UI явное состояние: «не удалось получить файл» / «формат изменился»,
   с кнопкой «повторить»; это резко ускоряет диагностику.
6. Зафиксировать реальный PDF как тестовую фикстуру в репозитории и покрыть парсер
   модульным тестом. Тогда регрессия от изменения вёрстки сервера ловится в CI, а не на
   телефоне.

### 3.3. Отказ HEAD-запроса на сервере

Симптом: проверка «файл доступен» падает, хотя тот же URL скачивается обычным GET.

Причина: часть серверов (и почти все CDN за WAF) не поддерживают `HEAD`, отвечая
405/403 или закрывая соединение.

Решения:

- Не использовать `HEAD` для проверки существования. Делать `GET` с `Range: bytes=0-0`
  и проверять код/`Content-Range`.
- Трактовать `405 Method Not Allowed` как «ресурс существует, метод не разрешён»,
  а не как ошибку.
- Если проверка нужна для экономии трафика — кэшировать результат проверки, а не
  выполнять HEAD перед каждым скачиванием.

Проверка с ПК:

```bash
curl -I https://schedule.example.ru/plan.pdf        # HEAD: смотрим код
curl -s -o /dev/null -w '%{http_code}\n' -r 0-0 https://schedule.example.ru/plan.pdf  # GET с Range
```

### 3.4. Время и сертификаты: 3021, 1100, «Cannot verify server identity»

Три разных, но связанных случая:

1. **Сбитое время.** Валидация сертификатов и подписей завязана на время. Ошибка 3021
   «anisette data is invalid» и 1100 «session expired» часто лечатся включением
   автоматической установки даты/времени ([error codes](https://docs.sidestore.io/docs/troubleshooting/error-codes)).
   Проверить время и на iPhone, и на ПК, который работает с iloader/AltServer/Sideloadly.
2. **«Cannot verify server identity».** Приложение или система не смогла проверить TLS
   сертификат сервера: самоподписанный, просроченный, отсутствует промежуточный
   сертификат в цепочке, или домен не совпадает с CN/SAN. Проверить с ПК:
   ```bash
   openssl s_client -connect schedule.example.ru:443 -servername schedule.example.ru </dev/null \
     | openssl x509 -noout -subject -issuer -dates
   ```
   Если сертификат самоподписанный — нужно установить и явно доверять корневому
   сертификату на устройстве. Если в приложении включён certificate pinning, при
   перевыпуске сертификата сервера отпечаток нужно обновлять вместе с приложением —
   иначе после продления сертификата приложение перестанет подключаться.
3. **Сертификат разработчика.** Отдельная сущность: подпись приложения живёт 7 дней
   ([SideStore FAQ](https://docs.sidestore.io/docs/faq)) и продлевается через SideStore, а не
   в настройках сертификатов сервера. Не путайте эти два сертификата при диагностике.

### 3.5. Данные, bundle id и переустановка

Модель, которую важно понимать:

- Данные приложения лежат в контейнере, привязанном к `CFBundleIdentifier`.
- Смена bundle id = новое приложение; данные старого контейнера остаются «в старом»
  приложении и новому недоступны
  ([Apple: CFBundleIdentifier](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleidentifier)).
- Переустановка того же bundle id (например, для продления подписи) данные сохраняет.
- Перенос приложения из AltStore/Sideloadly в SideStore данные сохраняет, если не удалять
  исходное приложение ([SideStore FAQ](https://docs.sidestore.io/docs/faq)).

Практические правила:

1. Пока приложение не пишет в облако, добавьте экспорт/импорт данных в файл — это
   единственная страховка при смене bundle id и при сбросе подписи с удалением приложения.
2. Не меняйте bundle id «для проверки»: каждый новый bundle id расходует App ID из
   недельного лимита 10 и занимает слот приложения из трёх
   ([AltStore: App IDs](https://faq.altstore.io/altstore-classic/app-ids),
   [SideStore FAQ](https://docs.sidestore.io/docs/faq)).
3. Перед удалением приложения во время разбора проблем сначала выгрузите данные.

### 3.6. AFC / pairing: почему это самая частая причина «не устанавливается»

Диагностический признак — сочетание: Wi-Fi есть, VPN подключён, но установка обрывается,
а в логах/на экране ошибка про AFC или pairing.

Порядок устранения строго по официальному списку
([common issues](https://docs.sidestore.io/docs/troubleshooting/common-issues)):

1. Если используется WireGuard или StosVPN — перейти на LocalDevVPN.
2. Отключить DNS-блокировщики.
3. Убедиться, что одновременно подключены LocalDevVPN и Wi-Fi.
4. Повторить установку (иногда помогает несколько нажатий подряд).
5. Перезапустить SideStore.
6. Перезапустить LocalDevVPN.
7. Перевыпустить pairing file через iloader.

Отдельно: pairing file «стареет» после обновления/сброса iOS и иногда случайно — это
поведение Apple, а не дефект SideStore
([pairing file](https://docs.sidestore.io/docs/advanced/pairing-file)).

---

## 4. Коды ошибок SideStore

Полный список — в [документации SideStore](https://docs.sidestore.io/docs/troubleshooting/error-codes).
Ниже — те, которые реально встречаются при установке своего IPA.

| Код | Текст | Что делать |
|---|---|---|
| 1006 | Не удалось определить UDID устройства | Сбросить pairing file (Settings → Reset Pairing File в SideStore), в iloader — Delete Stored Pairing и заново Place; при необходимости задать Device IP `10.7.0.1` в настройках VPN-конфигурации SideStore, сменить Anisette, перезагрузить устройство |
| 1007 | Неверный формат приложения | Перепаковать IPA (`Payload` в корне архива) или взять IPA из другого источника |
| 1009 / 3013 | Нельзя регистрировать более 10 App ID за 7 дней | Ждать истечения App ID; не менять bundle id без необходимости |
| 1011 | Отказано в разрешении на запуск приложения | Нажать «Разрешить», а не «Отмена»; подтвердить доверие сертификату в настройках |
| 1012 | Нет доступа к shared app group | Переустановить SideStore через iloader |
| 1414 | Нет Wi-Fi / StosVPN | Включить Wi-Fi и LocalDevVPN |
| 27 (minimuxer) | AFC не смог работать с файлами устройства | Включить Wi-Fi + LocalDevVPN; перевыпустить pairing file; на iOS 26.4+ обновить SideStore до nightly |
| 4 (minimuxer) | AFC не смог работать с файлами устройства | Попытка включить JIT на неподдерживаемой версии iOS (поддерживается 17.4–18.6) |
| 3002 | Неверный Apple ID или пароль | Проверить учётные данные; при необходимости создать отдельный Apple ID |
| 3003 | Требуется пароль приложения | Создать пароль приложения на appleid.apple.com |
| 3009 | Неверное имя приложения | Убрать не-ASCII символы из имени, по которому приложение регистрируется в Apple |
| 3011 | Bundle id уже зарегистрирован | Использовать другой bundle id или удалить прежнюю установку |
| 3021 | Неверные anisette-данные | Проверить дату/время на устройстве, войти заново, сменить Anisette-сервер |
| 1100 | Сессия истекла | Проверить дату/время, войти заново |
| 1102 | Apple ID не может использоваться для разработки | Принять условия на developer.apple.com; при необходимости создать новый Apple ID |
| 512 | Не удалось записать на диск | Освободить место на устройстве |
| -1011 | NSURLErrorDomain | Войти на developer.apple.com и принять обновлённые условия |

---

## 5. Как читать логи

### 5.1. Что доступно без Mac

| Инструмент | Что даёт | Как получить |
|---|---|---|
| Данные аналитики iOS | Крешлоги приложений, включая sideload | `Настройки → Конфиденциальность и безопасность → Аналитика и улучшения → Данные аналитики`. Искать записи с именем приложения (`Schedly-…`); открыть и «Поделиться», отправив файл себе |
| Логи SideStore | Сообщения об ошибках установки/refresh | Экран ошибки в SideStore с кодом (см. раздел 4) |
| Логи iloader | Установка SideStore, pairing, работа с Apple ID | В iloader есть просмотр и экспорт логов ([iloader.app](https://iloader.app)) |
| Логи Sideloadly | Логи установки и системные логи устройства | Встроенные «Installation Logs» и «Device System Logs» ([sideloadly.io](https://sideloadly.io/)) |
| Логи GitHub Actions | Стадия сборки: pod install, Xcode-ошибки | Страница run → нужный шаг → полный вывод |
| `idevicesyslog` | Поток системного лога устройства по USB | libimobiledevice на ПК (Windows/Linux/macOS); на Windows нужен Apple Mobile Device Support из состава iTunes, на Linux — usbmuxd ([libimobiledevice.org](https://libimobiledevice.org/)) |
| `idevicecrashreport` | Выгрузка крешлогов с устройства на ПК | libimobiledevice; в версии 1.4.0 добавлена фильтрация крешлогов по имени файла ([libimobiledevice.org](https://libimobiledevice.org/)) |
| `ideviceinfo` | Версия iOS, модель, UDID, флаги | `ideviceinfo -k ProductVersion` — быстрый способ проверить, что устройство вообще видно ([libimobiledevice.org](https://libimobiledevice.org/)) |
| `ideviceinstaller` | Список/установка приложений на устройстве с ПК | libimobiledevice; с версии 1.2.0 команды оформлены как подкоманды (`install`, `list`) |

Типовой сценарий с Windows-ПК (телефон подключён кабелем, доверен компьютеру):

```powershell
# версия iOS и модель
ideviceinfo -k ProductVersion
ideviceinfo -k ProductType

# живой системный лог в момент запуска приложения
idevicesyslog | Select-String -Pattern "Schedly|crash|CRASH|Termination|assert"

# выгрузить крешлоги на ПК
idevicecrashreport -u <UDID> -e C:\temp\crash
```

Ошибки запуска iOS печатает в syslog в виде строк с `Termination Reason`,
`Exception Type`, `DYLD`, `Library not loaded` — это то, что нужно искать при падении сразу
после старта.

### 5.2. Что даёт Mac (если появится)

- `flutter logs`, `flutter attach` — только для debug/profile сборок, запущенных с
  подключением к инструментам разработчика; для release IPA, установленного через
  SideStore, не работает.
- Xcode → **Window → Devices and Simulators → View Device Logs** — символизированные
  крешлоги.
- Console.app — системный лог с фильтрами.

### 5.3. Сборка release с символами

Dart-символы (для читаемых стеков Dart после обфускации):

```bash
flutter build ios --release --no-codesign \
  --obfuscate \
  --split-debug-info=build/symbols
```

Флаги `--obfuscate` / `--split-debug-info` рекомендованы документацией Flutter
([Flutter: Build and release an iOS app](https://docs.flutter.dev/deployment/ios)).
Каталог `build/symbols` нужно сохранять как CI-артефакт — без него стектрейсы Dart в
крешлогах будут нечитаемы.

Нативные символы iOS лежат в dSYM внутри `build/ios/archive/*.xcarchive`, который
создаётся командой `flutter build ipa`. При сборке только `flutter build ios` архива нет —
для символизации нативных крешей удобнее отдельно собирать `flutter build ipa` с
подписью, когда появится Mac.

Приоритет действий при разборе падения:

1. Понять, на какой стадии падает: до первого кадра Flutter (нативная причина —
   архитектура, entitlement, dyld) или после (ошибка Dart/логики).
2. Для нативной причины читать `idevicesyslog` в момент запуска.
3. Для Dart-причины искать исключение в данных аналитики iOS и в собственных логах
   приложения; убедиться, что сборка не была обфусцирована без сохранённых символов.

### 5.4. Чек-лист сбора информации перед обращением за помощью

- [ ] Модель iPhone и точная версия iOS.
- [ ] Версия/канал SideStore (stable/nightly) или другого установщика.
- [ ] Точная версия Flutter и вывод `flutter build ios --release --no-codesign`.
- [ ] Что именно выведено в CI на шаге `pod install` (если падало там).
- [ ] Скриншот ошибки в SideStore с кодом.
- [ ] Есть ли в `My Apps` счётчик дней и сколько дней осталось.
- [ ] Включены ли LocalDevVPN и Wi-Fi одновременно.
- [ ] Обновлялся ли pairing file, и когда.
- [ ] Крашлог из «Данные аналитики» или вывод `idevicesyslog` в момент падения.

---

## 6. Источники

- SideStore, Common Issues — https://docs.sidestore.io/docs/troubleshooting/common-issues
- SideStore, Error Codes — https://docs.sidestore.io/docs/troubleshooting/error-codes
- SideStore, Install — https://docs.sidestore.io/docs/installation/install
- SideStore, Prerequisites — https://docs.sidestore.io/docs/installation/prerequisites
- SideStore, Pairing File — https://docs.sidestore.io/docs/advanced/pairing-file
- SideStore, FAQ — https://docs.sidestore.io/docs/faq
- SideStore, Alternative/Outdated Instructions — https://docs.sidestore.io/docs/advanced/alternative
- SideStore discussion об AFC/invalid pairing — https://github.com/orgs/SideStore/discussions/1073
- AltStore, App IDs — https://faq.altstore.io/altstore-classic/app-ids.md
- AltStore, Troubleshooting Guide — https://faq.altstore.io/altstore-classic/troubleshooting-guide.md
- AltStore, How to Install (Windows) — https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows.md
- Sideloadly — https://sideloadly.io/
- iloader — https://iloader.app
- libimobiledevice — https://libimobiledevice.org/
- Apple, Enabling Developer Mode on a device — https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device
- Apple, CFBundleIdentifier — https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleidentifier
- Apple, UIBackgroundModes — https://developer.apple.com/documentation/bundleresources/information-property-list/uibackgroundmodes
- Apple, NSAppTransportSecurity — https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity
- Flutter, Build and release an iOS app — https://docs.flutter.dev/deployment/ios

---

## 7. Что не удалось подтвердить

1. **Точный путь к экрану аналитики в конкретной версии iOS.** Описан стандартный путь
   `Настройки → Конфиденциальность и безопасность → Аналитика и улучшения → Данные
   аналитики`; Apple не публикует удобную для цитирования справку по этому экрану, и
   формулировки пунктов различаются между версиями iOS и локалями. Проверьте у себя.
2. **Формат имён крешлогов sideload-приложений (`<AppName>-<дата>.ips`).** Расширение и
   префикс менялись между версиями iOS; ориентируйтесь на поиск по имени приложения в
   списке, а не на маску файла.
3. **Набор конкретных строк в syslog для падений** (`Termination Reason`,
   `Library not loaded` и т. п.) — это общеизвестная практика чтения логов iOS, а не
   документированный контракт Apple. Не подтверждено первоисточником.
4. **Работа `idevicesyslog` и `idevicecrashreport` на Windows проверяется по документации
   libimobiledevice**, а не тестировалась в рамках подготовки этого документа. По
   документации на Windows требуется Apple Mobile Device Support (входит в iTunes);
   поддержка `usbmuxd` на Windows неполная ([libimobiledevice.org](https://libimobiledevice.org/)).
5. **Лимиты 7 дней / 3 приложения / 10 App ID** подтверждены документацией SideStore,
   AltStore и Sideloadly, но не страницей developer.apple.com (страницы Apple закрыты для
   автоматического чтения). См. раздел 8 в `ios-signing-sidestore.md`.
6. **Флаги `--obfuscate` и `--split-debug-info`** рекомендованы документацией Flutter, но
   точное поведение символизации нативных iOS-крешей через dSYM в документе не проверялось.
7. **Код ошибки ATS** в разных версиях iOS формулируется по-разному; приведённый текст
   «App Transport Security policy requires the use of a secure connection» — типичная
   формулировка системного сообщения, а не цитата из документации.
