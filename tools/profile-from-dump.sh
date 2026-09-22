#!/system/bin/sh
#
# profile-from-dump.sh — делает профиль из дампа реального устройства.
#
# Вход: вывод `getprop` ([ключ]: [значение]) или файл build.prop (ключ=значение)
#       с ДРУГОГО, настоящего телефона.
# Выход: файл профиля для `spoofctl import`.
#
# Главное правило: инструмент ничего не придумывает. Он только копирует и
# отбрасывает. Если в дампе нет нужного значения — он говорит, чего нет, и
# не подставляет ничего взамен.
#
# Почему так строго: выдуманный fingerprint создаёт конфигурацию, которой
# никогда не существовало. Такая конфигурация уникальна по построению и
# переживает переустановку приложений и сброс рекламного ID — то есть
# работает как постоянная метка, ровно наоборот от цели.

set -u

SELF_DIR="$(dirname "$0")"
LIB_DIR="${COHERENCE_LIB:-$SELF_DIR/../module/common}"

G=''; R=''; Y=''; N=''
if [ -t 1 ]; then G=$(printf '\033[32m'); R=$(printf '\033[31m'); Y=$(printf '\033[33m'); N=$(printf '\033[0m'); fi
ok()   { echo "${G}✓${N} $1"; }
err()  { echo "${R}✗${N} $1"; }
warn() { echo "${Y}!${N} $1"; }

DUMP=""
OUT=""
SAME_HW=0
CORES=""
RAM_KB=""
DISPLAY=""

while [ $# -gt 0 ]; do
    case "$1" in
        -o|--out)      shift; OUT="${1:-}" ;;
        --same-hardware) SAME_HW=1 ;;
        --cores)       shift; CORES="${1:-}" ;;
        --ram-kb)      shift; RAM_KB="${1:-}" ;;
        --display)     shift; DISPLAY="${1:-}" ;;
        -h|--help)
            cat <<'EOF'
profile-from-dump.sh — профиль из дампа реального устройства

  profile-from-dump.sh <дамп> [-o профиль.conf] [опции]

Дамп — вывод `getprop` или файл build.prop С ДРУГОГО ТЕЛЕФОНА.
Снять на том телефоне:   getprop > /sdcard/dump.txt

Опции:
  -o, --out <файл>     куда записать профиль (по умолчанию <дамп>.profile.conf)
  --same-hardware      взять число ядер, объём памяти и разрешение с ЭТОГО
                       телефона. Годится, только если ты уверен, что железо
                       того же класса: эти три значения в дампе свойств
                       отсутствуют, а совпадать обязаны.
  --cores <N>          число ядер целевого устройства
  --ram-kb <N>         MemTotal целевого устройства в kB
  --display <ШxВ>      физическое разрешение целевого устройства

Инструмент ничего не придумывает. Чего нет в дампе — того не будет в профиле.
EOF
            exit 0 ;;
        -*) err "неизвестная опция: $1"; exit 2 ;;
        *)  [ -z "$DUMP" ] && DUMP="$1" || { err "лишний аргумент: $1"; exit 2; } ;;
    esac
    shift
done

[ -n "$DUMP" ] || { err "укажи файл дампа (--help для справки)"; exit 2; }
[ -f "$DUMP" ] || { err "файл не найден: $DUMP"; exit 1; }
[ -n "$OUT" ] || OUT="${DUMP}.profile.conf"

. "$LIB_DIR/fingerprint.sh" 2>/dev/null || { err "нет $LIB_DIR/fingerprint.sh"; exit 1; }
. "$LIB_DIR/denylist.sh"    2>/dev/null || { err "нет $LIB_DIR/denylist.sh"; exit 1; }

TMP="${TMPDIR:-/tmp}/pfd.$$"
trap 'rm -f "$TMP" "$TMP.props"' EXIT

# --------------------------------------------------- 1. нормализация формата ---
#
# getprop печатает "[ключ]: [значение]", build.prop — "ключ=значение".
# Приводим к одному виду. Значение берём как есть, включая пробелы.

if grep -qE '^\[[^]]+\]: \[' "$DUMP"; then
    FORMAT="getprop"
    sed -n 's/^\[\([^]]*\)\]: \[\(.*\)\]$/\1=\2/p' "$DUMP" > "$TMP"
elif grep -qE '^[a-zA-Z0-9_.]+=' "$DUMP"; then
    FORMAT="build.prop"
    grep -E '^[a-zA-Z0-9_.]+=' "$DUMP" | grep -v '^#' > "$TMP"
else
    err "не похоже ни на вывод getprop, ни на build.prop"
    echo "  Ожидается либо '[ro.product.model]: [значение]', либо 'ro.product.model=значение'"
    exit 1
fi

LINES=$(grep -c . "$TMP" 2>/dev/null || echo 0)
ok "формат: $FORMAT, свойств в дампе: $LINES"

get() { sed -n "s/^${1}=//p" "$TMP" | head -1; }

# ------------------------------------------------------ 2. обязательные поля ---

FP="$(get ro.build.fingerprint)"
if [ -z "$FP" ]; then
    err "в дампе нет ro.build.fingerprint — профиль построить невозможно"
    echo "  Это не то, что можно дособрать из остальных полей: строка должна"
    echo "  быть скопирована с устройства целиком."
    exit 1
fi
ok "fingerprint: $FP"

MISSING=""
for k in ro.product.model ro.product.brand ro.product.manufacturer \
         ro.product.device ro.product.name ro.build.id \
         ro.build.version.incremental ro.build.type ro.build.tags; do
    [ -n "$(get "$k")" ] || MISSING="$MISSING $k"
done
if [ -n "$MISSING" ]; then
    err "в дампе не хватает обязательных свойств:$MISSING"
    echo "  Снять полный дамп:  getprop > /sdcard/dump.txt"
    exit 1
fi
ok "все обязательные свойства на месте"

# -------------------------------------------------------- 3. отбор свойств ---
#
# Берём только то, что модулю разрешено писать. Всё остальное из дампа
# отбрасывается молча: чужие вендорные свойства в профиле не нужны и опасны.

: > "$TMP.props"
TAKEN=0; SKIPPED=0
while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    key="${line%%=*}"
    if deny_check "$key"; then SKIPPED=$((SKIPPED + 1)); continue; fi
    if allow_check "$key"; then
        printf '%s\n' "$line" >> "$TMP.props"
        TAKEN=$((TAKEN + 1))
    else
        SKIPPED=$((SKIPPED + 1))
    fi
done < "$TMP"
ok "отобрано свойств: $TAKEN (отброшено $SKIPPED)"

# -------------------------------------------------------- 4. метаданные ---
#
# Описывают железо, которое ДОЛЖНО совпасть с реальным. spoofctl сверит их
# с этим телефоном перед применением.

META_PLATFORM="$(get ro.board.platform)"
META_SOC="$(get ro.soc.model)"
META_LOWRAM="$(get ro.config.low_ram)"
META_RELEASE="$(get ro.build.version.release)"
META_ABILIST="$(get ro.product.cpu.abilist)"
META_DENSITY="$(get ro.sf.lcd_density)"

# Число ядер, память и физическое разрешение в свойствах не хранятся.
if [ "$SAME_HW" = "1" ]; then
    [ -n "$CORES" ]   || CORES="$(nproc --all 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null)"
    [ -n "$RAM_KB" ]  || RAM_KB="$(awk '/^MemTotal/{print $2; exit}' /proc/meminfo 2>/dev/null)"
    [ -n "$DISPLAY" ] || DISPLAY="$(wm size 2>/dev/null | sed -n 's/^Physical size: *\([0-9]*x[0-9]*\).*/\1/p' | head -1)"
    warn "ядра/память/экран взяты с ЭТОГО телефона (--same-hardware)"
    echo "  Проверка на совпадение станет формальной. Годится, только если"
    echo "  целевое устройство действительно того же класса железа."
fi

SHA=""
if command -v sha256sum >/dev/null 2>&1; then
    SHA="$(sha256sum "$DUMP" | cut -d' ' -f1)"
fi

# --------------------------------------------------------- 5. запись ---

{
    echo "# Профиль собран из дампа: $DUMP"
    echo "# Значения скопированы как есть. Ничего не достроено."
    echo "#"
    echo "# Строки @ — требования к железу. Проверяются, не записываются."
    echo
    [ -n "$META_PLATFORM" ] && echo "@platform=$META_PLATFORM"
    [ -n "$META_SOC" ]      && echo "@soc_model=$META_SOC"
    [ -n "$META_RELEASE" ]  && echo "@release=$META_RELEASE"
    [ -n "$META_ABILIST" ]  && echo "@abilist=$META_ABILIST"
    [ -n "$META_LOWRAM" ]   && echo "@low_ram=$META_LOWRAM"
    [ -n "$META_DENSITY" ]  && echo "@density=$META_DENSITY"
    [ -n "$CORES" ]         && echo "@core_count=$CORES"
    [ -n "$RAM_KB" ]        && echo "@ram_kb=$RAM_KB"
    [ -n "$DISPLAY" ]       && echo "@display=$DISPLAY"
    [ -n "$SHA" ]           && echo "@source_sha256=$SHA"
    echo
    cat "$TMP.props"
} > "$OUT"

ok "записано: $OUT"

# --------------------------------------------------------- 6. проверка ---

echo
echo "Проверка получившегося профиля:"
FAIL=0

fp_reset_errors
if fp_validate_syntax "$FP"; then
    ok "структура fingerprint верна"
else
    err "структура fingerprint неверна"; fp_errors | sed 's/^/   /'; FAIL=1
fi

fp_reset_errors
if fp_validate_coherence "$FP" \
    "$(get ro.product.brand)" "$(get ro.product.name)" "$(get ro.product.device)" \
    "$(get ro.build.version.release)" "$(get ro.build.id)" \
    "$(get ro.build.version.incremental)" "$(get ro.build.type)" "$(get ro.build.tags)"
then
    ok "fingerprint сходится со свойствами дампа"
else
    err "fingerprint не сходится со свойствами ЭТОГО ЖЕ дампа"
    fp_errors | sed 's/^/   /'
    echo "   Дамп либо неполный, либо собран из двух разных устройств."
    echo "   Такой профиль применять нельзя."
    FAIL=1
fi

LEN=$(printf '%s' "$FP" | wc -c)
if [ "$LEN" -le 91 ]; then
    ok "длина fingerprint $LEN байт"
else
    err "длина fingerprint $LEN байт — больше предела в 91"; FAIL=1
fi

for m in platform soc_model release abilist low_ram density core_count ram_kb display; do
    grep -q "^@${m}=" "$OUT" || warn "не заполнено: @${m} (spoofctl не сможет это сверить)"
done
[ -n "$SHA" ] || warn "не посчитан @source_sha256 (нет sha256sum)"

echo
if [ "$FAIL" = "0" ]; then
    ok "профиль готов"
    echo
    echo "Дальше на телефоне:"
    echo "   su -c 'spoofctl check $OUT'"
    echo "   su -c 'spoofctl import $OUT'"
    echo "   su -c 'spoofctl apply' && reboot"
else
    err "профиль непригоден — см. ошибки выше"
    exit 1
fi
