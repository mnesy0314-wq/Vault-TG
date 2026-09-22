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
    _fp_fp="${1:-}"
    [ -n "$_fp_fp" ] || return 1

    case "$_fp_fp" in
        *:*:*) : ;;          # нужно минимум два ':'
        *) return 1 ;;
    esac

    _fp_head="${_fp_fp%%:*}"                 # brand/product/device
    _fp_rest="${_fp_fp#*:}"                  # release/id/incremental:type/tags
    _fp_tail="${_fp_rest##*:}"               # type/tags
    _fp_mid="${_fp_rest%:*}"                 # release/id/incremental

    # brand/product/device
    case "$_fp_head" in *?/?*/?*) : ;; *) return 1 ;; esac
    _fp_brand="${_fp_head%%/*}"
    _fp_hr="${_fp_head#*/}"
    _fp_product="${_fp_hr%%/*}"
    _fp_device="${_fp_hr#*/}"
    case "$_fp_device" in */*) return 1 ;; esac   # ровно три поля, не больше

    # release/id/incremental
    case "$_fp_mid" in *?/?*/?*) : ;; *) return 1 ;; esac
    _fp_release="${_fp_mid%%/*}"
    _fp_mr="${_fp_mid#*/}"
    _fp_id="${_fp_mr%%/*}"
    _fp_incremental="${_fp_mr#*/}"

    # type/tags
    case "$_fp_tail" in *?/?*) : ;; *) return 1 ;; esac
    _fp_type="${_fp_tail%%/*}"
    _fp_tags="${_fp_tail#*/}"

    for _fp_f in "$_fp_brand" "$_fp_product" "$_fp_device" "$_fp_release" \
              "$_fp_id" "$_fp_incremental" "$_fp_type" "$_fp_tags"; do
        [ -n "$_fp_f" ] || return 1
    done

    printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
        "$_fp_brand" "$_fp_product" "$_fp_device" "$_fp_release" \
        "$_fp_id" "$_fp_incremental" "$_fp_type" "$_fp_tags"
}

# Достаёт одно поле по имени: fp_field <fingerprint> <brand|product|...>
fp_field() {
    _fp_fp="${1:-}"; _fp_want="${2:-}"
    _fp_parsed="$(fp_parse "$_fp_fp")" || return 1
    _fp_n=0
    for _fp_name in brand product device release id incremental type tags; do
        _fp_n=$((_fp_n + 1))
        if [ "$_fp_name" = "$_fp_want" ]; then
            printf '%s\n' "$_fp_parsed" | sed -n "${_fp_n}p"
            return 0
        fi
    done
    return 1
}

# Собирает fingerprint из 8 полей.
fp_build() {
    [ $# -eq 8 ] || return 1
    for _fp_a in "$@"; do
        [ -n "$_fp_a" ] || return 1
        # Поля не должны сами содержать разделители — иначе результат
        # не разберётся обратно.
        case "$_fp_a" in */*|*:*) return 1 ;; esac
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
    _fp_fp="${1:-}"
    _fp_parsed="$(fp_parse "$_fp_fp")" || { _fp_err "fingerprint не разбирается: '$_fp_fp'"; return 1; }

    _fp_release="$(printf '%s\n' "$_fp_parsed" | sed -n 4p)"
    _fp_id="$(printf '%s\n' "$_fp_parsed" | sed -n 5p)"
    _fp_type="$(printf '%s\n' "$_fp_parsed" | sed -n 7p)"
    _fp_tags="$(printf '%s\n' "$_fp_parsed" | sed -n 8p)"

    _fp_rc=0

    # release: "14", "13", "12L", "8.1.0"
    case "$_fp_release" in
        ''|*[!0-9.L]*) _fp_err "release '$_fp_release' не похож на версию Android"; _fp_rc=1 ;;
    esac

    # build id: UP1A.231005.007, TP1A.220624.014, QP1A.190711.020
    # Формат AOSP: 4 символа платформы, точка, YYMMDD, точка, порядковый номер.
    if ! printf '%s' "$_fp_id" | grep -qE '^[A-Z]{2}[0-9A-Z]{2}\.[0-9]{6}\.[0-9]{3}([.A-Z0-9]*)?$'; then
        # Некоторые вендоры отходят от схемы — предупреждаем, но не валим.
        _fp_err "ПРЕДУПРЕЖДЕНИЕ: build id '$_fp_id' не соответствует схеме AOSP (XXNN.YYMMDD.NNN)"
    fi

    case "$_fp_type" in
        user|userdebug|eng) : ;;
        *) _fp_err "build type '$_fp_type' недопустим (ожидается user/userdebug/eng)"; _fp_rc=1 ;;
    esac

    case "$_fp_tags" in
        release-keys|dev-keys|test-keys) : ;;
        *) _fp_err "build tags '$_fp_tags' нестандартны (ожидается release-keys/dev-keys/test-keys)"; _fp_rc=1 ;;
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
    case "$_fp_type/$_fp_tags" in
        user/release-keys|userdebug/release-keys|\
        userdebug/test-keys|userdebug/dev-keys|\
        eng/test-keys|eng/dev-keys)
            : ;;
        *)
            _fp_err "несочетаемо: type=$_fp_type с tags=$_fp_tags в природе не встречается"
            _fp_rc=1 ;;
    esac

    return $_fp_rc
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
    _fp_fp="${1:-}"
    shift
    [ $# -eq 8 ] || { _fp_err "fp_validate_coherence: нужно 8 свойств, получено $#"; return 1; }

    _fp_parsed="$(fp_parse "$_fp_fp")" || { _fp_err "fingerprint не разбирается: '$_fp_fp'"; return 1; }

    _fp_rc=0
    _fp_n=0
    for _fp_name in brand product device release id incremental type tags; do
        _fp_n=$((_fp_n + 1))
        _fp_from_fp="$(printf '%s\n' "$_fp_parsed" | sed -n "${_fp_n}p")"
        eval "_fp_expected=\${$_fp_n}"
        if [ "$_fp_from_fp" != "$_fp_expected" ]; then
            _fp_err "рассогласование '$_fp_name': fingerprint='$_fp_from_fp', свойство='$_fp_expected'"
            _fp_rc=1
        fi
    done

    return $_fp_rc
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
    _fp_id="${1:-}"; _fp_patch="${2:-}"     # _fp_patch в формате YYYY-MM-DD

    _fp_stamp="$(printf '%s' "$_fp_id" | sed -n 's/^[A-Z0-9]\{4\}\.\([0-9]\{6\}\)\..*$/\1/p')"
    [ -n "$_fp_stamp" ] || return 0      # нестандартный id — проверять нечего

    _fp_build_y="20$(printf '%s' "$_fp_stamp" | cut -c1-2)"
    _fp_build_m="$(printf '%s' "$_fp_stamp" | cut -c3-4)"

    _fp_patch_y="$(printf '%s' "$_fp_patch" | cut -d- -f1)"
    _fp_patch_m="$(printf '%s' "$_fp_patch" | cut -d- -f2)"

    case "$_fp_patch_y$_fp_patch_m" in
        ''|*[!0-9]*) _fp_err "security_patch '$_fp_patch' не в формате YYYY-MM-DD"; return 1 ;;
    esac

    _fp_build_n=$((_fp_build_y * 12 + _fp_build_m))
    _fp_patch_n=$((_fp_patch_y * 12 + _fp_patch_m))

    # Патч старше сборки более чем на 2 месяца — почти наверняка ошибка профиля.
    if [ "$_fp_patch_n" -lt $((_fp_build_n - 2)) ]; then
        _fp_err "security_patch ($_fp_patch) сильно старше даты сборки из build id ($_fp_build_y-$_fp_build_m)"
        return 1
    fi
    return 0
}

fp_errors() { printf '%s' "$FP_ERRORS"; }
fp_reset_errors() { FP_ERRORS=''; }
