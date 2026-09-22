#!/system/bin/sh
#
# collect-device-info.sh — read-only разведка устройства.
#
# Ничего не меняет. Только читает свойства и пишет отчёт.
# Нужен, чтобы построить КОГЕРЕНТНЫЙ профиль подмены: спуф, который
# противоречит железу, делает устройство более уникальным, а не менее.
#
# Запуск (Termux или adb shell):
#     su -c 'sh /sdcard/collect-device-info.sh'
#
# Чувствительные значения (serial, IMEI, MAC, Android ID) по умолчанию
# НЕ выводятся в открытом виде — вместо них короткий хеш, чтобы отчёт
# можно было переслать. Полные значения: --raw
#
set -u

REDACT=1
OUT=""

while [ $# -gt 0 ]; do
    case "$1" in
        --raw)    REDACT=0 ;;
        --out)    shift; OUT="${1:-}" ;;
        -h|--help)
            sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "Неизвестный аргумент: $1" >&2; exit 2 ;;
    esac
    shift
done

if [ -z "$OUT" ]; then
    for d in /sdcard /storage/emulated/0 /data/local/tmp .; do
        if [ -d "$d" ] && [ -w "$d" ]; then OUT="$d/device-info.txt"; break; fi
    done
fi
[ -n "$OUT" ] || OUT="./device-info.txt"

# ---------------------------------------------------------------- helpers ---

# Короткий стабильный хеш — позволяет сравнивать значения "до/после"
# без раскрытия самого значения.
hash_val() {
    _v="${1:-}"
    [ -n "$_v" ] || { echo "<пусто>"; return; }
    if command -v sha256sum >/dev/null 2>&1; then
        printf '%s' "$_v" | sha256sum | cut -c1-12
    elif command -v md5sum >/dev/null 2>&1; then
        printf '%s' "$_v" | md5sum | cut -c1-12
    else
        echo "<хеш недоступен>"
    fi
}

# Печатает "имя = значение"; пустые свойства помечает явно, чтобы было
# видно разницу между "нет такого свойства" и "пустая строка".
p() {
    _name="$1"
    _val="$(getprop "$_name" 2>/dev/null)"
    if [ -z "$_val" ]; then
        printf '  %-52s = <нет>\n' "$_name"
    else
        printf '  %-52s = %s\n' "$_name" "$_val"
    fi
}

# То же, но значение скрывается при REDACT=1.
p_secret() {
    _name="$1"
    _val="$(getprop "$_name" 2>/dev/null)"
    if [ -z "$_val" ]; then
        printf '  %-52s = <нет>\n' "$_name"
    elif [ "$REDACT" -eq 1 ]; then
        printf '  %-52s = sha256:%s (скрыто)\n' "$_name" "$(hash_val "$_val")"
    else
        printf '  %-52s = %s\n' "$_name" "$_val"
    fi
}

section() { printf '\n== %s ==\n' "$1"; }

# Перебирает свойство по всем партициям Android 10+.
# Порядок важен: именно так его резолвит init.
# init принимает как источник ТОЛЬКО {odm, product, system_ext, system, vendor}
# (property_service.cpp, RO_PRODUCT_PROPS_ALLOWED_SOURCES). Остальные
# перечислены потому, что их всё равно читает getprop из приложения:
# уцелевшее ro.product.bootimage.model рядом с подменённым базовым —
# сигнал громче исходной модели.
PARTITIONS='system system_ext product odm vendor vendor_dlkm odm_dlkm system_dlkm bootimage'
per_partition() {
    _key="$1"
    p "ro.product.$_key"
    for _part in $PARTITIONS; do
        p "ro.product.$_part.$_key"
    done
}

# ----------------------------------------------------------------- отчёт ---

collect() {

printf 'device-info · отчёт разведки\n'
printf 'сгенерирован: %s\n' "$(date 2>/dev/null || echo '<date недоступен>')"
printf 'режим: %s\n' "$([ "$REDACT" -eq 1 ] && echo 'скрытый (--raw для полных значений)' || echo 'ПОЛНЫЙ — содержит идентификаторы!')"

section 'Root / Magisk'
if [ "$(id -u 2>/dev/null)" = "0" ]; then
    printf '  uid                                                  = 0 (root есть)\n'
else
    printf '  uid                                                  = %s (ROOT НЕТ — запусти через su)\n' "$(id -u 2>/dev/null)"
fi
if command -v magisk >/dev/null 2>&1; then
    printf '  magisk -c (версия)                                   = %s\n' "$(magisk -c 2>/dev/null)"
    printf '  magisk -V (versionCode)                              = %s\n' "$(magisk -V 2>/dev/null)"
    printf '  resetprop                                            = %s\n' "$(command -v resetprop 2>/dev/null || echo '<нет в PATH>')"
else
    printf '  magisk                                               = <не найден в PATH>\n'
fi
printf '  /data/adb/modules                                    = %s\n' \
    "$([ -d /data/adb/modules ] && echo 'есть' || echo 'НЕТ')"
if [ -d /data/adb/modules ]; then
    printf '  установленные модули:\n'
    for _m in /data/adb/modules/*/; do
        [ -d "$_m" ] || continue
        printf '    - %s\n' "$(basename "$_m")"
    done
fi

section 'Идентичность устройства (то, что видит Build.*)'
per_partition model
printf '\n'
per_partition brand
printf '\n'
per_partition manufacturer
printf '\n'
per_partition device
printf '\n'
per_partition name
printf '\n'
p ro.product.property_source_order

section 'Fingerprint и сборка'
p ro.build.fingerprint
for _part in system system_ext product odm vendor bootimage; do
    p "ro.$_part.build.fingerprint"
done
printf '\n'
p ro.build.description
p ro.build.flavor
p ro.build.id
p ro.build.display.id
p ro.build.type
p ro.build.tags
p ro.build.user
p ro.build.host
p ro.build.date
p ro.build.date.utc
p ro.build.version.incremental

section 'Версия Android (НИКОГДА не подменять — ломает приложения)'
p ro.build.version.release
p ro.build.version.sdk
p ro.build.version.security_patch
p ro.build.version.preview_sdk
p ro.vndk.version
p ro.treble.enabled

section 'Железо (НИКОГДА не подменять — ломает HAL/драйверы)'
p ro.hardware
p ro.board.platform
p ro.soc.model
p ro.soc.manufacturer
p ro.revision
p ro.bootloader
p ro.boot.hardware
p ro.product.cpu.abi
p ro.product.cpu.abilist
p ro.product.cpu.abilist32
p ro.product.cpu.abilist64

section 'Android Go / класс устройства'
p ro.config.low_ram
p ro.config.medium_ram
p ro.lmk.critical
p ro.sf.lcd_density
p ro.vendor.qti.va_aosp.support
printf '  MemTotal                                             = %s\n' \
    "$(grep -i '^MemTotal' /proc/meminfo 2>/dev/null | awk '{print $2 " " $3}' || echo '<нет доступа>')"
printf '  ядер CPU (/proc/cpuinfo)                             = %s\n' \
    "$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo '<нет доступа>')"
printf '  CPU part/implementer                                 = %s\n' \
    "$(grep -m1 -i 'Hardware\|model name' /proc/cpuinfo 2>/dev/null | sed 's/^[^:]*: *//' || echo '<нет>')"

section 'Экран (должен совпадать с заявленной моделью)'
printf '  wm size                                              = %s\n' \
    "$(wm size 2>/dev/null | tr '\n' ' ' || echo '<нет доступа>')"
printf '  wm density                                           = %s\n' \
    "$(wm density 2>/dev/null | tr '\n' ' ' || echo '<нет доступа>')"

section 'Transsion / HiOS (вендорные свойства)'
_tran="$(getprop 2>/dev/null | grep -i -E '^\[ro\.(tran|hios|os_|itel|infinix)' | head -40)"
if [ -n "$_tran" ]; then
    printf '%s\n' "$_tran" | sed 's/^/  /'
else
    printf '  <вендорных ro.tran*/ro.hios*/ro.os_* свойств не найдено>\n'
fi

section 'Чувствительные идентификаторы (скрыты по умолчанию)'
p_secret ro.serialno
p_secret ro.boot.serialno
p_secret ro.boot.cid
p_secret ro.ril.oem.imei
_aid="$(settings get secure android_id 2>/dev/null)"
if [ -n "$_aid" ] && [ "$_aid" != "null" ]; then
    if [ "$REDACT" -eq 1 ]; then
        printf '  %-52s = sha256:%s (скрыто)\n' 'settings secure android_id' "$(hash_val "$_aid")"
    else
        printf '  %-52s = %s\n' 'settings secure android_id' "$_aid"
    fi
else
    printf '  %-52s = <недоступно>\n' 'settings secure android_id'
fi
printf '  %-52s = %s\n' '/data/system/users/0/settings_ssaid.xml' \
    "$([ -f /data/system/users/0/settings_ssaid.xml ] && echo 'есть' || echo 'НЕТ / нет доступа')"

section 'Итого свойств'
printf '  всего ro.* свойств                                   = %s\n' \
    "$(getprop 2>/dev/null | grep -c '^\[ro\.' || echo '?')"

printf '\n-- конец отчёта --\n'

}

collect > "$OUT" 2>&1
_rc=$?

if [ $_rc -ne 0 ] || [ ! -s "$OUT" ]; then
    echo "ОШИБКА: не удалось записать отчёт в $OUT" >&2
    exit 1
fi

echo "Отчёт сохранён: $OUT"
echo
if [ "$REDACT" -eq 1 ]; then
    echo "Чувствительные значения скрыты — файл безопасно переслать."
else
    echo "ВНИМАНИЕ: --raw, файл содержит реальные идентификаторы. Не выкладывай публично."
fi
echo
echo "Посмотреть:  cat $OUT"
