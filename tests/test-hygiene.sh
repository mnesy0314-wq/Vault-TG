#!/usr/bin/env bash
#
# Гигиена переменных.
#
# В POSIX sh нет локальных переменных: присваивание внутри функции —
# глобальное. Библиотечная функция, использующая _file, затирает _file
# вызывающего кода. Этот баг тихий: вызывающий читает уже не тот файл и
# отвергает профиль по выдуманной причине.
#
# Лечится дисциплиной имён, а дисциплина держится тестом.
#
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

# --- статическая проверка префиксов -----------------------------------------
#
# Все присваивания в библиотеке должны быть либо в её пространстве имён,
# либо в явно объявленном публичном API.
check_prefixes() { # <файл> <префикс> <публичные имена через пробел>
    local file="$1" prefix="$2" public="$3" offenders=""
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        case " $public " in *" $name "*) continue ;; esac
        case "$name" in "$prefix"*) continue ;; esac
        offenders="$offenders $name"
    done < <(grep -oE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=' "$file" \
             | sed 's/[[:space:]]*//; s/=$//' | sort -u)
    if [ -z "$offenders" ]; then
        ok "$(basename "$file"): все присваивания в пространстве $prefix*"
    else
        bad "$(basename "$file"): переменные вне пространства имён:$offenders"
    fi
}

echo "== пространства имён =="
check_prefixes "$ROOT/module/common/fingerprint.sh" "_fp_" "FP_ERRORS"
check_prefixes "$ROOT/module/common/denylist.sh"    "_dl_" ""

echo
echo "== библиотеки не затирают переменные вызывающего =="

mkdir -p "$WORK"
cat > "$WORK/p.conf" <<'EOF'
ro.product.model=X
EOF

# Имитируем реальный сценарий: у вызывающего есть свои _file/_key/_n,
# он вызывает библиотечную функцию и продолжает ими пользоваться.
probe() { # <библиотека> <вызов>
    sh -c "
        . '$1'
        _file=ЗНАЧЕНИЕ_ВЫЗЫВАЮЩЕГО
        _key=КЛЮЧ
        _n=42
        _rc=7
        _line=СТРОКА
        $2 >/dev/null 2>&1
        echo \"\$_file|\$_key|\$_n|\$_rc|\$_line\"
    " 2>/dev/null
}

r="$(probe "$ROOT/module/common/denylist.sh" "deny_scan_profile '$WORK/p.conf'")"
[ "$r" = "ЗНАЧЕНИЕ_ВЫЗЫВАЮЩЕГО|КЛЮЧ|42|7|СТРОКА" ] \
    && ok "deny_scan_profile не тронул переменные вызывающего" \
    || bad "deny_scan_profile затёр переменные: $r"

r="$(probe "$ROOT/module/common/denylist.sh" "deny_reason ro.hardware")"
[ "$r" = "ЗНАЧЕНИЕ_ВЫЗЫВАЮЩЕГО|КЛЮЧ|42|7|СТРОКА" ] \
    && ok "deny_reason не тронул переменные вызывающего" \
    || bad "deny_reason затёр переменные: $r"

FP='TECNO/KL4-RU/TECNO-KL4:14/UP1A.231005.007/260414V512:user/release-keys'
r="$(probe "$ROOT/module/common/fingerprint.sh" "fp_parse '$FP'")"
[ "$r" = "ЗНАЧЕНИЕ_ВЫЗЫВАЮЩЕГО|КЛЮЧ|42|7|СТРОКА" ] \
    && ok "fp_parse не тронул переменные вызывающего" \
    || bad "fp_parse затёр переменные: $r"

r="$(probe "$ROOT/module/common/fingerprint.sh" "fp_validate_syntax '$FP'")"
[ "$r" = "ЗНАЧЕНИЕ_ВЫЗЫВАЮЩЕГО|КЛЮЧ|42|7|СТРОКА" ] \
    && ok "fp_validate_syntax не тронул переменные вызывающего" \
    || bad "fp_validate_syntax затёр переменные: $r"

r="$(probe "$ROOT/module/common/fingerprint.sh" "fp_validate_coherence '$FP' TECNO KL4-RU TECNO-KL4 14 UP1A.231005.007 260414V512 user release-keys")"
[ "$r" = "ЗНАЧЕНИЕ_ВЫЗЫВАЮЩЕГО|КЛЮЧ|42|7|СТРОКА" ] \
    && ok "fp_validate_coherence не тронул переменные вызывающего" \
    || bad "fp_validate_coherence затёр переменные: $r"

echo
echo "== две библиотеки не конфликтуют друг с другом =="
r="$(sh -c "
    . '$ROOT/module/common/fingerprint.sh'
    . '$ROOT/module/common/denylist.sh'
    fp_parse '$FP' >/dev/null
    deny_scan_profile '$WORK/p.conf' >/dev/null
    fp_validate_syntax '$FP' >/dev/null && echo OK
" 2>/dev/null)"
[ "$r" = "OK" ] && ok "совместное использование работает" || bad "библиотеки конфликтуют"

echo
echo "== spoofctl: validate не затирает аргументы команд =="
# Конкретная регрессия: validate использовал _sc_src для хеша дампа и
# затирал им путь к файлу в cmd_import, который её и вызвал.
grep -q '_sc_prov=' "$ROOT/module/system/bin/spoofctl" \
    && ok "переменная происхождения переименована (_sc_prov)" \
    || bad "validate снова использует _sc_src — конфликт с cmd_import"

printf '\nПройдено: %d, провалено: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
