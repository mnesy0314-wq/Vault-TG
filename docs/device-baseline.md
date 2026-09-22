# База: Tecno Spark Go 1 (TECNO KL4)

Измерено `tools/collect-device-info.sh` на реальном устройстве.
Всё в этом файле — **факты с устройства**, не предположения.
Интерпретация помечена отдельно.

## Идентичность

| Свойство | Значение |
|---|---|
| `ro.product.model` | `TECNO KL4` |
| `ro.product.device` | `TECNO-KL4` |
| `ro.product.name` | `KL4-RU` |
| `ro.product.brand` / `manufacturer` | `TECNO` |
| `ro.build.fingerprint` | `TECNO/KL4-RU/TECNO-KL4:14/UP1A.231005.007/260414V512:user/release-keys` |
| `ro.build.id` | `UP1A.231005.007` |
| `ro.build.version.incremental` | `260414V512` |
| `ro.build.description` | `ums9230_KL4_go-user 14 UP1A.231005.007 595 release-keys` |
| `ro.build.flavor` | `tssi_arm64_tecno_go-user` |
| `ro.build.display.id` | `KL4-F201ABCU-UGo-RU-260414V512` |

### Порядок резолва свойств

```
ro.product.property_source_order = odm,product,vendor,system_ext,system
```

Значит `ro.product.model` собирается init'ом из `ro.product.odm.model` (первый в
списке). Модуль подмены обязан менять **и** базовое свойство, **и** все
партиционные варианты — иначе приложение, читающее `ro.product.odm.model`
напрямую, увидит настоящее значение.

Отдельно: `ro.product.system.model = tssi`, `ro.product.system.device =
tssi_arm64_tecno`. Это Treble System Single Image — обобщённый системный
образ. Само по себе не проблема, но означает, что `system`-партиция не несёт
брендовых значений, а `odm`/`vendor`/`product` несут.

### Расщепление fingerprint по партициям

| Партиция | Версия в fingerprint |
|---|---|
| `ro.build` / `system` / `system_ext` / `product` / `bootimage` | `14 / UP1A.231005.007` |
| `ro.odm.build` / `ro.vendor.build` | **`13 / TP1A.220624.014`** |

Это нормально (Treble GRF: вендорная часть заморожена на Android 13, системная
обновлена до 14). Но для модуля это развилка: если переписать только системные
fingerprint'ы, `ro.vendor.build.fingerprint` продолжит говорить `TECNO`.

## Неизменяемая сигнатура железа

Это то, что подменой свойств **не скрыть**. Любой профиль подмены обязан быть
совместим с этой таблицей, иначе спуф сам становится меткой.

| Сигнал | Реальное значение | Как читает приложение |
|---|---|---|
| Платформа | `ums9230` | `ro.board.platform`, но также косвенно через GPU/кодеки |
| SoC | Unisoc (Spreadtrum) T615 | `Build.SOC_MODEL`, `/proc/cpuinfo` |
| Ядра | 8, `arm64-v8a` | `Runtime.availableProcessors()`, `/proc/cpuinfo` |
| ABI | `arm64-v8a,armeabi-v7a,armeabi` | `Build.SUPPORTED_ABIS` |
| RAM | 2 855 468 kB (~2.72 ГБ) | `ActivityManager.MemoryInfo.totalMem` |
| Класс | `ro.config.low_ram = true` | `ActivityManager.isLowRamDevice()` |
| Экран (физический) | 720×1600 @ 320 dpi | `Display.getMode()` |
| Android | 14, SDK 34, патч 2026-05-01 | `Build.VERSION.*` |
| VNDK / Treble | 33 / включён | `ro.vndk.version` |

## Найденная проблема приватности (не связанная с подменой)

На устройстве **активен override экрана**:

```
wm size     = Physical size: 720x1600   Override size: 540x1209
wm density  = Physical density: 320     Override density: 240
```

Приложения через `DisplayMetrics` видят **override**, а не физическое
разрешение. `540×1209 @ 240 dpi` — крайне редкая комбинация: у серийных
устройств такого разрешения не бывает. Это делает устройство более
узнаваемым, а не менее.

Сброс:

```sh
wm size reset
wm density reset
```

*(Интерпретация: уникальность комбинации оценена рассуждением, не замером
доли в популяции устройств. Но 540×1209 не соответствует ни одному известному
серийному экрану, поэтому вывод устойчив.)*

## Окружение

| | |
|---|---|
| Magisk | 30.7 (`30700`), `MAGISK:R` |
| `resetprop` | `/system_ext/bin/resetprop` |
| Zygisk | доступен (модуль `zygisksu`) |
| Другие модули | `GPUTurboBoost`, `hosts`, `pubgfpsunlocker`, `sfanalysis`, `universal-gms-doze` |
| Всего `ro.*` свойств | 902 |

Наличие Zygisk важно: подмена на уровне свойств видна любому приложению,
читающему `/system/build.prop` или партиционные свойства напрямую. Zygisk
позволяет перехватывать чтение в конкретном процессе.

## Вендорные свойства Transsion

Найдено ~40 свойств `ro.os_*` (`ro.os_dynamicbar_support`,
`ro.os_microintelligence_support`, …) и `ro.itel_style.*`.

Это фирменные флаги HiOS. Они **остаются на месте** при подмене
`ro.product.*` — и сами по себе однозначно выдают Transsion-устройство.
Трогать их опасно: их читает системный UI HiOS.

*(Интерпретация: вывод о том, что их читает системный UI, следует из их
назначения — флаги функций оболочки. На поведение при изменении не проверялось.)*
