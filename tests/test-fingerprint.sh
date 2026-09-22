#!/usr/bin/env bash
#
# Тесты разбора и проверки fingerprint. Чистые функции — устройство не нужно.
#
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

# Запускает функцию в отдельном sh, печатает stdout, возвращает её код.
run() { sh -c ". '$ROOT/module/common/fingerprint.sh'; $1" 2>&1; }
rc()  { sh -c ". '$ROOT/module/common/fingerprint.sh'; $1" >/dev/null 2>&1; echo $?; }

eq() { # eq <описание> <ожидаемое> <фактическое>
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1"; printf '       ожидалось: %s\n       получено:  %s\n' "$2" "$3"; fi
}

REAL='TECNO/KL4-RU/TECNO-KL4:14/UP1A.231005.007/260414V512:user/release-keys'

echo "== fp_parse =="

eq "разбирает реальный fingerprint устройства" \
   "$(printf 'TECNO\nKL4-RU\nTECNO-KL4\n14\nUP1A.231005.007\n260414V512\nuser\nrelease-keys')" \
   "$(run "fp_parse '$REAL'")"

eq "вендорный fingerprint (Android 13)" \
   "$(printf 'TECNO\nKL4-RU\nTECNO-KL4\n13\nTP1A.220624.014\n260414V512\nuser\nrelease-keys')" \
   "$(run "fp_parse 'TECNO/KL4-RU/TECNO-KL4:13/TP1A.220624.014/260414V512:user/release-keys'")"

eq "Pixel-подобный fingerprint" \
   "$(printf 'google\nshiba\nshiba\n14\nAP1A.240405.002\n11480754\nuser\nrelease-keys')" \
   "$(run "fp_parse 'google/shiba/shiba:14/AP1A.240405.002/11480754:user/release-keys'")"

eq "версия с точками (8.1.0)" "8.1.0" \
   "$(run "fp_field 'x/y/z:8.1.0/OPM1.171019.011/4448085:user/release-keys' release")"

echo
echo "== fp_parse: отклонение мусора =="
for bogus in \
    "" \
    "not-a-fingerprint" \
    "TECNO/KL4-RU/TECNO-KL4:14/UP1A.231005.007/260414V512" \
    "TECNO/KL4-RU:14/UP1A.231005.007/260414V512:user/release-keys" \
    "TECNO/KL4-RU/TECNO-KL4/EXTRA:14/UP1A.231005.007/260414V512:user/release-keys" \
    "TECNO/KL4-RU/TECNO-KL4:14/UP1A.231005.007:user/release-keys" \
    "TECNO/KL4-RU/TECNO-KL4:14/UP1A.231005.007/260414V512:user" \
    "/KL4-RU/TECNO-KL4:14/UP1A.231005.007/260414V512:user/release-keys" \
    ; do
    if [ "$(rc "fp_parse '$bogus'")" != "0" ]; then
        ok "отклонён: '${bogus:0:52}'"
    else
        bad "ПРИНЯТ мусор: '$bogus'"
    fi
done

echo
echo "== fp_field =="
eq "brand"       "TECNO"           "$(run "fp_field '$REAL' brand")"
eq "product"     "KL4-RU"          "$(run "fp_field '$REAL' product")"
eq "device"      "TECNO-KL4"       "$(run "fp_field '$REAL' device")"
eq "id"          "UP1A.231005.007" "$(run "fp_field '$REAL' id")"
eq "incremental" "260414V512"      "$(run "fp_field '$REAL' incremental")"
eq "tags"        "release-keys"    "$(run "fp_field '$REAL' tags")"
[ "$(rc "fp_field '$REAL' nosuchfield")" != "0" ] \
    && ok "неизвестное поле -> ошибка" || bad "неизвестное поле принято"

echo
echo "== fp_build =="
eq "сборка обратно даёт исходную строку" "$REAL" \
   "$(run "fp_build TECNO KL4-RU TECNO-KL4 14 UP1A.231005.007 260414V512 user release-keys")"
eq "round-trip: parse -> build" "$REAL" \
   "$(run "fp_build \$(fp_parse '$REAL' | tr '\n' ' ')")"
[ "$(rc "fp_build a b c d e f g")" != "0" ] && ok "7 аргументов -> ошибка" || bad "7 аргументов принято"
[ "$(rc "fp_build a b 'c/d' e f g h i")" != "0" ] \
    && ok "поле с '/' отклонено" || bad "поле с '/' принято (строка не разберётся обратно)"
[ "$(rc "fp_build a b 'c:d' e f g h i")" != "0" ] \
    && ok "поле с ':' отклонено" || bad "поле с ':' принято"

echo
echo "== fp_validate_syntax =="
[ "$(rc "fp_validate_syntax '$REAL'")" = "0" ] \
    && ok "реальный fingerprint проходит" || bad "реальный fingerprint не прошёл: $(run "fp_validate_syntax '$REAL'; fp_errors")"

[ "$(rc "fp_validate_syntax 'x/y/z:14/UP1A.231005.007/1:eng/release-keys'")" != "0" ] \
    && ok "type=eng + release-keys отклонено" || bad "type=eng + release-keys принято"

[ "$(rc "fp_validate_syntax 'x/y/z:14/UP1A.231005.007/1:user/test-keys'")" != "0" ] \
    && ok "user + test-keys отклонено (розница всегда release-keys)" \
    || bad "user + test-keys принято"

[ "$(rc "fp_validate_syntax 'x/y/z:14/UP1A.231005.007/1:bogus/release-keys'")" != "0" ] \
    && ok "неизвестный build type отклонён" || bad "неизвестный build type принят"

# Матрица type x tags: реально существующие комбинации должны проходить.
for combo in userdebug/release-keys userdebug/test-keys userdebug/dev-keys \
             eng/test-keys eng/dev-keys user/release-keys; do
    if [ "$(rc "fp_validate_syntax 'x/y/z:14/UP1A.231005.007/1:$combo'")" = "0" ]; then
        ok "существующая комбинация принята: $combo"
    else
        bad "существующая комбинация отклонена: $combo"
    fi
done

# ...а несуществующие — отклоняться.
for combo in eng/release-keys user/test-keys user/dev-keys; do
    if [ "$(rc "fp_validate_syntax 'x/y/z:14/UP1A.231005.007/1:$combo'")" != "0" ]; then
        ok "невозможная комбинация отклонена: $combo"
    else
        bad "невозможная комбинация ПРИНЯТА: $combo"
    fi
done

[ "$(rc "fp_validate_syntax 'x/y/z:14/UP1A.231005.007/1:user/custom-keys'")" != "0" ] \
    && ok "нестандартные tags отклонены" || bad "нестандартные tags приняты"

[ "$(rc "fp_validate_syntax 'x/y/z:НЕВЕРНО/UP1A.231005.007/1:user/release-keys'")" != "0" ] \
    && ok "нечисловой release отклонён" || bad "нечисловой release принят"

# Нестандартный build id должен предупреждать, но НЕ валить проверку.
out="$(run "fp_validate_syntax 'x/y/z:14/WEIRDBUILD/1:user/release-keys'; fp_errors")"
if [ "$(rc "fp_validate_syntax 'x/y/z:14/WEIRDBUILD/1:user/release-keys'")" = "0" ] \
   && printf '%s' "$out" | grep -q 'ПРЕДУПРЕЖДЕНИЕ'; then
    ok "нестандартный build id -> предупреждение, не отказ"
else
    bad "нестандартный build id обработан неверно: rc=$(rc "fp_validate_syntax 'x/y/z:14/WEIRDBUILD/1:user/release-keys'") out=$out"
fi

echo
echo "== fp_validate_coherence =="
[ "$(rc "fp_validate_coherence '$REAL' TECNO KL4-RU TECNO-KL4 14 UP1A.231005.007 260414V512 user release-keys")" = "0" ] \
    && ok "согласованный набор проходит" || bad "согласованный набор не прошёл"

# Классическая ошибка «спуферов»: подменили model/brand, fingerprint забыли.
out="$(run "fp_validate_coherence '$REAL' samsung KL4-RU TECNO-KL4 14 UP1A.231005.007 260414V512 user release-keys; fp_errors")"
if [ "$(rc "fp_validate_coherence '$REAL' samsung KL4-RU TECNO-KL4 14 UP1A.231005.007 260414V512 user release-keys")" != "0" ] \
   && printf '%s' "$out" | grep -q "рассогласование 'brand'"; then
    ok "ловит brand, не совпавший с fingerprint"
else
    bad "не поймано рассогласование brand"
fi

out="$(run "fp_validate_coherence '$REAL' TECNO KL4-RU TECNO-KL4 13 UP1A.231005.007 260414V512 user release-keys; fp_errors")"
printf '%s' "$out" | grep -q "рассогласование 'release'" \
    && ok "ловит release, не совпавший с fingerprint" || bad "не поймано рассогласование release"

out="$(run "fp_validate_coherence '$REAL' nope nope nope 13 nope nope userdebug dev-keys; fp_errors")"
n="$(printf '%s' "$out" | grep -c 'рассогласование')"
eq "сообщает обо ВСЕХ 8 рассогласованиях, а не только о первом" "8" "$n"

[ "$(rc "fp_validate_coherence '$REAL' TECNO KL4-RU")" != "0" ] \
    && ok "неверное число аргументов -> ошибка" || bad "неверное число аргументов принято"

echo
echo "== fp_validate_patch_date =="
[ "$(rc "fp_validate_patch_date 'UP1A.231005.007' '2026-05-01'")" = "0" ] \
    && ok "реальная пара (тег 2023-10, патч 2026-05) проходит" || bad "реальная пара отклонена"

[ "$(rc "fp_validate_patch_date 'UP1A.231005.007' '2023-11-05'")" = "0" ] \
    && ok "патч сразу после тега проходит" || bad "патч сразу после тега отклонён"

[ "$(rc "fp_validate_patch_date 'UP1A.231005.007' '2022-01-05'")" != "0" ] \
    && ok "патч СТАРШЕ релиза платформы отклонён (физически невозможен)" \
    || bad "патч из прошлого принят"

[ "$(rc "fp_validate_patch_date 'UP1A.231005.007' 'мусор'")" != "0" ] \
    && ok "кривой формат патча отклонён" || bad "кривой формат патча принят"

[ "$(rc "fp_validate_patch_date 'WEIRDBUILD' '2020-01-01'")" = "0" ] \
    && ok "нестандартный build id -> проверка пропускается" || bad "нестандартный build id уронил проверку"

echo
echo "== накопление ошибок =="
out="$(run "fp_validate_syntax 'bad'; fp_reset_errors; fp_errors")"
eq "fp_reset_errors очищает список" "" "$out"

echo
printf 'Пройдено: %d, провалено: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
