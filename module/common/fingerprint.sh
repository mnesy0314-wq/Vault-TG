#!/system/bin/sh
#
# fingerprint.sh — разбор и проверка Android build fingerprint.
#
# Грамматика зафиксирована в AOSP (build/core/Makefile):
#
#   BUILD_FINGERPRINT :=
#       $(PRODUCT_BRAND)/$(TARGET_PRODUCT)/$(TARGET_DEVICE):$(PLATFORM_VERSION)/
#       $(BUILD_ID)/$(BUILD_NUMBER):$(TARGET_BUILD_VARIANT)/$(BUILD_VERSION_TAGS)
#
# То есть ровно:
#
#   brand/product/device:release/id/incremental:type/tags
#
# Это не украшение, а инвариант: fingerprint выводится ИЗ остальных свойств.
# Профиль, где fingerprint не сходится со своими же компонентами, самопротиворечив
# и вскрывается одной строкой кода в приложении. Отсюда вся ценность этого файла.
#
# Только функции — предполагается `. fingerprint.sh`.

# --------------------------------------------------------------- разбор ---
#
# Разбирает fingerprint в 8 полей. Печатает по одному в строке, в порядке:
#   brand product device release id incremental type tags
# Возвращает 1, если строка не разбирается.
#
# Разделители неоднозначны (incremental может содержать что угодно, кроме ':'),
# поэтому режем от краёв внутрь, а не слева направо:
#   - первое ':' отделяет brand/product/device
#   - последнее ':' отделяет type/tags
#   - остаток между ними — release/id/incremental
#
fp_parse() {
    _fp="${1:-}"
    [ -n "$_fp" ] || return 1

    case "$_fp" in
        *:*:*) : ;;          # нужно минимум два ':'
        *) return 1 ;;
    esac

    _head="${_fp%%:*}"                 # brand/product/device
    _rest="${_fp#*:}"                  # release/id/incremental:type/tags
    _tail="${_rest##*:}"               # type/tags
    _mid="${_rest%:*}"                 # release/id/incremental

    # brand/product/device
    case "$_head" in *?/?*/?*) : ;; *) return 1 ;; esac
    _brand="${_head%%/*}"
    _hr="${_head#*/}"
    _product="${_hr%%/*}"
    _device="${_hr#*/}"
    case "$_device" in */*) return 1 ;; esac   # ровно три поля, не больше

    # release/id/incremental
    case "$_mid" in *?/?*/?*) : ;; *) return 1 ;; esac
    _release="${_mid%%/*}"
    _mr="${_mid#*/}"
    _id="${_mr%%/*}"
    _incremental="${_mr#*/}"

    # type/tags
    case "$_tail" in *?/?*) : ;; *) return 1 ;; esac
    _type="${_tail%%/*}"
    _tags="${_tail#*/}"

    for _f in "$_brand" "$_product" "$_device" "$_release" \
              "$_id" "$_incremental" "$_type" "$_tags"; do
        [ -n "$_f" ] || return 1
    done

    printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
        "$_brand" "$_product" "$_device" "$_release" \
        "$_id" "$_incremental" "$_type" "$_tags"
}

# Достаёт одно поле по имени: fp_field <fingerprint> <brand|product|...>
fp_field() {
    _fp="${1:-}"; _want="${2:-}"
    _parsed="$(fp_parse "$_fp")" || return 1
    _n=0
    for _name in brand product device release id incremental type tags; do
        _n=$((_n + 1))
        if [ "$_name" = "$_want" ]; then
            printf '%s\n' "$_parsed" | sed -n "${_n}p"
            return 0
        fi
    done
    return 1
}

# Собирает fingerprint из 8 полей.
fp_build() {
    [ $# -eq 8 ] || return 1
    for _a in "$@"; do
        [ -n "$_a" ] || return 1
        # Поля не должны сами содержать разделители — иначе результат
        # не разберётся обратно.
        case "$_a" in */*|*:*) return 1 ;; esac
    done
    printf '%s/%s/%s:%s/%s/%s:%s/%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8"
}

# -------------------------------------------------------------- проверки ---

FP_ERRORS=''
_fp_err() { FP_ERRORS="${FP_ERRORS}${FP_ERRORS:+
}$1"; }

# Структурная проверка одного fingerprint.
# Не обращается к устройству — чистая функция, пригодна для offline-валидации профиля.
fp_validate_syntax() {
    _fp="${1:-}"
    _parsed="$(fp_parse "$_fp")" || { _fp_err "fingerprint не разбирается: '$_fp'"; return 1; }

    _release="$(printf '%s\n' "$_parsed" | sed -n 4p)"
    _id="$(printf '%s\n' "$_parsed" | sed -n 5p)"
    _type="$(printf '%s\n' "$_parsed" | sed -n 7p)"
    _tags="$(printf '%s\n' "$_parsed" | sed -n 8p)"

    _rc=0

    # release: "14", "13", "12L", "8.1.0"
    case "$_release" in
        ''|*[!0-9.L]*) _fp_err "release '$_release' не похож на версию Android"; _rc=1 ;;
    esac

    # build id: UP1A.231005.007, TP1A.220624.014, QP1A.190711.020
    # Формат AOSP: 4 символа платформы, точка, YYMMDD, точка, порядковый номер.
    if ! printf '%s' "$_id" | grep -qE '^[A-Z]{2}[0-9A-Z]{2}\.[0-9]{6}\.[0-9]{3}([.A-Z0-9]*)?$'; then
        # Некоторые вендоры отходят от схемы — предупреждаем, но не валим.
        _fp_err "ПРЕДУПРЕЖДЕНИЕ: build id '$_id' не соответствует схеме AOSP (XXNN.YYMMDD.NNN)"
    fi

    case "$_type" in
        user|userdebug|eng) : ;;
        *) _fp_err "build type '$_type' недопустим (ожидается user/userdebug/eng)"; _rc=1 ;;
    esac

    case "$_tags" in
        release-keys|dev-keys|test-keys) : ;;
        *) _fp_err "build tags '$_tags' нестандартны (ожидается release-keys/dev-keys/test-keys)"; _rc=1 ;;
    esac

    # Матрица совместимости type x tags.
    #
    # Ключи подписи жёстко связаны с вариантом сборки:
    #   user       + release-keys  — розничная прошивка, единственный массовый случай
    #   userdebug  + release-keys  — бывает (инженерные образцы на релизных ключах)
    #   userdebug  + test/dev-keys — обычная отладочная сборка
    #   eng        + test/dev-keys — локальная сборка разработчика
    #
    # Невозможные комбинации:
    #   user + test/dev-keys — розницу не подписывают тестовыми ключами
    #   eng  + release-keys  — инженерную сборку не подписывают релизными
    case "$_type/$_tags" in
        user/release-keys|userdebug/release-keys|\
        userdebug/test-keys|userdebug/dev-keys|\
        eng/test-keys|eng/dev-keys)
            : ;;
        *)
            _fp_err "несочетаемо: type=$_type с tags=$_tags в природе не встречается"
            _rc=1 ;;
    esac

    return $_rc
}

# Главная проверка когерентности: fingerprint против набора свойств.
#
#   fp_validate_coherence <fingerprint> <brand> <product> <device> \
#                         <release> <id> <incremental> <type> <tags>
#
# Каждое поле fingerprint ДОЛЖНО совпадать с соответствующим свойством,
# потому что именно так его собирает система сборки. Расхождение — это
# то, что отличает настоящее устройство от подделки.
fp_validate_coherence() {
    _fp="${1:-}"
    shift
    [ $# -eq 8 ] || { _fp_err "fp_validate_coherence: нужно 8 свойств, получено $#"; return 1; }

    _parsed="$(fp_parse "$_fp")" || { _fp_err "fingerprint не разбирается: '$_fp'"; return 1; }

    _rc=0
    _n=0
    for _name in brand product device release id incremental type tags; do
        _n=$((_n + 1))
        _from_fp="$(printf '%s\n' "$_parsed" | sed -n "${_n}p")"
        eval "_expected=\${$_n}"
        if [ "$_from_fp" != "$_expected" ]; then
            _fp_err "рассогласование '$_name': fingerprint='$_from_fp', свойство='$_expected'"
            _rc=1
        fi
    done

    return $_rc
}

# Проверка, что дата патча безопасности правдоподобна для этого build id.
#
# build id (XXNN.YYMMDD.NNN) несёт дату тега платформы AOSP, а НЕ дату сборки
# вендора: у TECNO KL4 тег UP1A.231005.007 (окт 2023) при incremental 260414
# (апр 2026) и патче 2026-05. Патч НОВЕЕ тега — норма.
#
# А вот патч СТАРШЕ тега платформы физически невозможен: нельзя собрать
# Android 14 с патчем, выпущенным до релиза Android 14. Это и ловим.
fp_validate_patch_date() {
    _id="${1:-}"; _patch="${2:-}"     # _patch в формате YYYY-MM-DD

    _stamp="$(printf '%s' "$_id" | sed -n 's/^[A-Z0-9]\{4\}\.\([0-9]\{6\}\)\..*$/\1/p')"
    [ -n "$_stamp" ] || return 0      # нестандартный id — проверять нечего

    _build_y="20$(printf '%s' "$_stamp" | cut -c1-2)"
    _build_m="$(printf '%s' "$_stamp" | cut -c3-4)"

    _patch_y="$(printf '%s' "$_patch" | cut -d- -f1)"
    _patch_m="$(printf '%s' "$_patch" | cut -d- -f2)"

    case "$_patch_y$_patch_m" in
        ''|*[!0-9]*) _fp_err "security_patch '$_patch' не в формате YYYY-MM-DD"; return 1 ;;
    esac

    _build_n=$((_build_y * 12 + _build_m))
    _patch_n=$((_patch_y * 12 + _patch_m))

    # Патч старше сборки более чем на 2 месяца — почти наверняка ошибка профиля.
    if [ "$_patch_n" -lt $((_build_n - 2)) ]; then
        _fp_err "security_patch ($_patch) сильно старше даты сборки из build id ($_build_y-$_build_m)"
        return 1
    fi
    return 0
}

fp_errors() { printf '%s' "$FP_ERRORS"; }
fp_reset_errors() { FP_ERRORS=''; }
