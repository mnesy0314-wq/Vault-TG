#!/system/bin/sh
#
# denylist.sh — что модуль не пишет никогда, и что писать можно.
#
# Два списка с разными правилами сопоставления, и это принципиально:
#
#   DENY  сопоставляется по шаблону (можно закрыть целое пространство имён).
#         Запись ломает устройство ИЛИ создаёт противоречие, проверяемое
#         приложением бесплатно. Профиль с таким ключом отвергается целиком.
#
#   ALLOW сопоставляется ТОЛЬКО по точным именам. Никаких глобов.
#         Причина конкретная: шаблон `ro.product.*` захватил бы
#         ro.product.cpu.abilist (падение нативного кода),
#         ro.product.board (выбор HAL),
#         ro.product.first_api_level и ro.product.property_source_order.
#         Один ленивый глоб — и модуль пишет то, что обязан не трогать.
#
# Ключ вне обоих списков не блокируется, но помечается: скорее всего
# это опечатка или скопированный мусор.

# ---------------------------------------------------------------- DENY ---
#
# Печатает причину и возвращает 0, если свойство запрещено. Иначе 1.
deny_reason() {
    case "${1:-}" in

    # --- Загрузка. Запись = кирпич или тихая потеря железа. ----------------
    ro.hardware|ro.hardware.*|ro.boot.hardware)
        echo "init импортирует по нему init.\$X.rc, а libhardware ищет HAL-библиотеки (camera.\$X.so, sensors.\$X.so). Подмена = загрузка без камеры/датчиков или bootloop. Вдобавок значение приходит из androidboot.hardware в командной строке ядра" ;;
    ro.board.platform|ro.product.board|ro.arch)
        echo "второе и третье звено цепочки выбора HAL в libhardware (variant_keys: ro.hardware, ro.product.board, ro.board.platform, ro.arch). Опасно вдвойне: ro.product.board — это ещё и Build.BOARD, поэтому выглядит как поле идентичности. Вендорные HAL Unisoc стартуют в 'on boot', то есть ПОСЛЕ post-fs-data и увидят подменённое значение — отказ датчиков и GPS без падения загрузки, а значит watchdog не сработает" ;;
    ro.boot.*|ro.bootloader|ro.revision)
        echo "приходит от загрузчика через командную строку ядра; на это состояние опираются verified boot и вендорные сервисы" ;;
    ro.crypto.*)
        echo "параметры шифрования /data. Подмена = раздел не расшифруется" ;;
    ro.zygote|dalvik.vm.*)
        echo "конфигурация среды исполнения (разрядность zygote, параметры ART). К идентичности отношения не имеет, к работоспособности — прямое" ;;

    # --- Версия Android. Запись = массовые падения приложений. ------------
    ro.build.version.sdk|*.build.version.sdk)
        echo "приложения ветвятся по Build.VERSION.SDK_INT постоянно, а PackageManager сверяет minSdk при установке. Заявить SDK, не соответствующий реальному фреймворку, — это отказы установки, падения и неработающие API" ;;
    ro.build.version.release|ro.build.version.release_or_codename|ro.build.version.codename)
        echo "должно соответствовать реальному SDK; расхождение release и sdk проверяется одним сравнением" ;;
    ro.build.version.preview_sdk|ro.build.version.preview_sdk_fingerprint)
        echo "на релизной сборке всегда 0. Другое значение объявляет устройство предрелизным — редчайшее состояние, то есть метка" ;;
    ro.product.first_api_level|ro.board.api_level|ro.board.first_api_level|ro.vendor.api_level)
        echo "уровень API, с которым устройство вышло с завода. Читается фреймворком для выбора режимов совместимости и участвует в аттестации" ;;

    # --- Процессор и память. Запись = падения нативного кода. -------------
    ro.product.cpu.abi|ro.product.cpu.abilist|ro.product.cpu.abilist32|ro.product.cpu.abilist64|*.cpu.abi*)
        echo "по нему выбирается разрядность нативных библиотек в APK. Подмена = установка кода под чужую архитектуру и падение при загрузке .so. Противоречит /proc/cpuinfo, читаемому без разрешений" ;;
    ro.soc.model|ro.soc.manufacturer)
        echo "Build.SOC_MODEL доступен без разрешений с API 31, но GL_RENDERER, имена кодеков (c2.sprd.*) и /proc/cpuinfo продолжат называть настоящий чип. Подмена СОЗДАЁТ противоречие вместо того, чтобы убрать. При профиле того же класса железа настоящее значение и есть правильное" ;;
    ro.config.low_ram|ro.config.medium_ram|ro.lmk.*)
        echo "ActivityManager.isLowRamDevice() и состав предустановленных Go-пакетов от этого не изменятся, а MemTotal читается прямо из ядра. Снятие флага на 2.7 ГБ включает поведение, на которое не хватит памяти" ;;
    ro.sf.lcd_density|ro.sf.lcd_density.*)
        echo "должно соответствовать физической панели. Расхождение с DisplayMetrics и Display.getMode() читается бесплатно — ровно та ошибка, которой этот телефон уже страдает из-за wm override" ;;

    # --- Treble / вендорный интерфейс. ------------------------------------
    ro.vndk.version|ro.product.vndk.version|ro.treble.enabled|ro.apex.updatable)
        echo "определяет namespace компоновщика для вендорных библиотек. Подмена = вендорные процессы не стартуют" ;;
    ro.product.property_source_order)
        echo "порядок резолва партиционных свойств. Копирование чужого порядка само по себе выдаёт подмену. Плюс init принимает только {odm, product, system_ext, system, vendor} и откатывается к умолчанию при мусоре" ;;

    # --- Идентификаторы, подмена которых бессмысленна или вредна. ---------
    ro.serialno)
        echo "SELinux neverallow не пускает untrusted_app к serialno_prop, так что стороннее приложение это не прочитает: приватности ноль. Зато значение идёт в DRM, камеру и keymint, и меняет серийник для adb. Чистый риск без выгоды" ;;
    ro.debuggable|ro.secure|ro.build.characteristics)
        echo "описывает режим сборки и класс устройства; расхождение с реальным состоянием — сильный сигнал модификации" ;;
    *_for_attestation)
        echo "используется аппаратной аттестацией ключей, которая всё равно сообщает настоящие manufacturer/model из защищённого хранилища. Этот модуль аттестацию не трогает" ;;

    # --- Вендорное пространство Transsion. --------------------------------
    ro.os_*|ro.tran*|ro.transsion.*|ro.sys.tran.*|ro.vendor.os_*|ro.itel_style.*)
        echo "флаги функций оболочки HiOS, их читает системный UI. Подмена ломает оболочку. Отдельно: их ~900 штук, и они выдают Transsion независимо от ro.product.*, поэтому кросс-брендовый профиль без их зачистки — полумаскировка" ;;

    # --- Устойчивые свойства. ---------------------------------------------
    persist.*)
        echo "init сохраняет их в /data/property/persistent_properties. Модуль не сможет откатить изменение, сняв себя, — а подмена идентичности обязана быть обратима удалением модуля" ;;

    *) return 1 ;;
    esac
    return 0
}

deny_check() { deny_reason "${1:-}" >/dev/null 2>&1; }

# --------------------------------------------------------------- ALLOW ---
#
# ТОЛЬКО точные имена. Перечислено полностью и намеренно многословно:
# список, который нельзя прочитать глазами, нельзя и проверить.
allow_check() {
    case "${1:-}" in

    # Базовая идентичность — единственное, что читает класс Build.
    ro.product.model|ro.product.brand|ro.product.manufacturer|\
    ro.product.device|ro.product.name)
        return 0 ;;

    # Партиционные варианты. init использует как источник только
    # {odm, product, system_ext, system, vendor} и только когда базовое
    # свойство пусто. Остальные пишем потому, что их читает getprop.
    ro.product.system.model|ro.product.system.brand|ro.product.system.manufacturer|\
    ro.product.system.device|ro.product.system.name|\
    ro.product.system_ext.model|ro.product.system_ext.brand|ro.product.system_ext.manufacturer|\
    ro.product.system_ext.device|ro.product.system_ext.name|\
    ro.product.product.model|ro.product.product.brand|ro.product.product.manufacturer|\
    ro.product.product.device|ro.product.product.name|\
    ro.product.odm.model|ro.product.odm.brand|ro.product.odm.manufacturer|\
    ro.product.odm.device|ro.product.odm.name|\
    ro.product.vendor.model|ro.product.vendor.brand|ro.product.vendor.manufacturer|\
    ro.product.vendor.device|ro.product.vendor.name|\
    ro.product.vendor_dlkm.model|ro.product.vendor_dlkm.brand|ro.product.vendor_dlkm.manufacturer|\
    ro.product.vendor_dlkm.device|ro.product.vendor_dlkm.name|\
    ro.product.odm_dlkm.model|ro.product.odm_dlkm.brand|ro.product.odm_dlkm.manufacturer|\
    ro.product.odm_dlkm.device|ro.product.odm_dlkm.name|\
    ro.product.system_dlkm.model|ro.product.system_dlkm.brand|ro.product.system_dlkm.manufacturer|\
    ro.product.system_dlkm.device|ro.product.system_dlkm.name|\
    ro.product.bootimage.model|ro.product.bootimage.brand|ro.product.bootimage.manufacturer|\
    ro.product.bootimage.device|ro.product.bootimage.name)
        return 0 ;;

    # Описание сборки.
    ro.build.fingerprint|ro.build.id|ro.build.display.id|ro.build.description|\
    ro.build.flavor|ro.build.product|ro.build.type|ro.build.tags|\
    ro.build.user|ro.build.host|ro.build.date|ro.build.date.utc|\
    ro.build.version.incremental|ro.build.version.security_patch)
        return 0 ;;

    # Партиционные fingerprint'ы и их спутники — двигаются только вместе.
    ro.system.build.fingerprint|ro.system.build.id|ro.system.build.tags|\
    ro.system.build.type|ro.system.build.version.incremental|\
    ro.system.build.date|ro.system.build.date.utc|\
    ro.system_ext.build.fingerprint|ro.system_ext.build.id|ro.system_ext.build.tags|\
    ro.system_ext.build.type|ro.system_ext.build.version.incremental|\
    ro.system_ext.build.date|ro.system_ext.build.date.utc|\
    ro.product.build.fingerprint|ro.product.build.id|ro.product.build.tags|\
    ro.product.build.type|ro.product.build.version.incremental|\
    ro.product.build.date|ro.product.build.date.utc|\
    ro.bootimage.build.fingerprint|ro.bootimage.build.id|ro.bootimage.build.tags|\
    ro.bootimage.build.type|ro.bootimage.build.version.incremental|\
    ro.bootimage.build.date|ro.bootimage.build.date.utc|\
    ro.odm.build.fingerprint|ro.odm.build.id|ro.odm.build.tags|\
    ro.odm.build.type|ro.odm.build.version.incremental|\
    ro.odm.build.date|ro.odm.build.date.utc|\
    ro.vendor.build.fingerprint|ro.vendor.build.id|ro.vendor.build.tags|\
    ro.vendor.build.type|ro.vendor.build.version.incremental|\
    ro.vendor.build.date|ro.vendor.build.date.utc)
        return 0 ;;

    *) return 1 ;;
    esac
}

# --------------------------------------------------------------- проверка ---
#
# Единственная дверь, через которую профиль попадает в модуль.
# Ни одно свойство не применяется, пока весь файл не проверен.
#
# Возвращает 1, если найден хоть один запрещённый ключ или битая строка.
deny_scan_profile() {
    _file="${1:-}"
    [ -f "$_file" ] || { echo "профиль не найден: $_file"; return 1; }

    _bad=0; _warn=0; _n=0

    while IFS= read -r _line || [ -n "$_line" ]; do
        _n=$((_n + 1))
        case "$_line" in ''|'#'*) continue ;; esac
        case "$_line" in
            *=*) : ;;
            *) echo "  строка $_n: не в формате ключ=значение: $_line"
               _bad=$((_bad + 1)); continue ;;
        esac

        _key="${_line%%=*}"
        _key="${_key#"${_key%%[![:space:]]*}"}"
        _key="${_key%"${_key##*[![:space:]]}"}"
        _val="${_line#*=}"

        if _why="$(deny_reason "$_key")"; then
            echo "  ЗАПРЕЩЕНО  $_key"
            echo "             $_why"
            _bad=$((_bad + 1))
            continue
        fi

        if ! allow_check "$_key"; then
            echo "  неизвестно $_key (нет в списке разрешённых — опечатка?)"
            _warn=$((_warn + 1))
        fi

        # Лимит длины значения. Строго в БАЙТАХ, не в символах.
        #
        # bionic PROP_VALUE_MAX = 92. Пока и старое, и новое значение
        # короче, resetprop делает __system_property_update2 на месте и
        # сохраняет указатель prop_info — процессы с закэшированным
        # хендлом увидят новое значение. От 92 байт приходится удалять и
        # создавать заново: хендлы повисают, а свойство становится
        # "длинным", и старые читатели через __system_property_get()
        # получают буквальную строку
        # "Must use __system_property_read_callback() to read".
        # Это максимально громкий признак подмены.
        _len=$(printf '%s' "$_val" | wc -c)
        if [ "$_len" -gt 91 ]; then
            echo "  СЛИШКОМ ДЛИННО $_key: $_len байт (максимум 91)"
            echo "             при 92+ байтах resetprop удаляет и пересоздаёт свойство;"
            echo "             старые читатели получат 'Must use __system_property_read_callback()'"
            _bad=$((_bad + 1))
        fi
    done < "$_file"

    if [ "$_bad" -gt 0 ]; then
        echo "профиль отвергнут: проблем — $_bad"
        return 1
    fi
    [ "$_warn" -gt 0 ] && echo "предупреждений: $_warn"
    return 0
}
