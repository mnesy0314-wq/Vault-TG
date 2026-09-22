#!/usr/bin/env bash
#
# Тесты двухстрайкового сторожа. Это логика, которая решает, загрузится
# телефон или нет, поэтому проверяется по шагам, а не на глаз.
#
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

MOD="$WORK/module"; CONF="$WORK/conf"; BOOTID="$WORK/boot_id"
STUB="$WORK/bin"; mkdir -p "$STUB"
# resetprop -w в песочнице не блокируется: возвращаем неуспех, чтобы
# service.sh пошёл по ветке опроса getprop.
printf '#!/usr/bin/env bash\nexit 1\n' > "$STUB/resetprop"
printf '#!/usr/bin/env bash\n[ "${1:-}" = "sys.boot_completed" ] && echo "${FAKE_BOOT_COMPLETED:-1}"\n' > "$STUB/getprop"
chmod +x "$STUB"/*

reset_env() {
    rm -rf "$MOD" "$CONF"; mkdir -p "$MOD" "$CONF"
    cp "$ROOT/module/post-fs-data.sh" "$ROOT/module/service.sh" "$ROOT/module/uninstall.sh" "$MOD/"
    : > "$MOD/system.prop"          # профиль применён
    new_boot
}
new_boot() { printf '%s\n' "$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')" > "$BOOTID"; }
pfd()  { COHERENCE_CONF="$CONF" COHERENCE_BOOT_ID_FILE="$BOOTID" PATH="$STUB:$PATH" sh "$MOD/post-fs-data.sh"; }
svc()  { COHERENCE_CONF="$CONF" PATH="$STUB:$PATH" sh "$MOD/service.sh"; }
strikes() { cat "$CONF/strikes" 2>/dev/null || echo 0; }
disabled() { [ -f "$MOD/disable" ]; }

echo "== нормальная загрузка =="
reset_env
pfd
[ -f "$CONF/pending-boot" ] && ok "post-fs-data ставит маркер" || bad "маркер не поставлен"
! disabled && ok "модуль не отключён" || bad "модуль отключён на нормальной загрузке"
svc
[ ! -f "$CONF/pending-boot" ] && ok "service.sh снимает маркер после boot_completed" || bad "маркер не снят"
[ "$(strikes)" = "0" ] && ok "счётчик нарушений сброшен" || bad "счётчик = $(strikes)"

echo
echo "== вторая нормальная загрузка подряд =="
new_boot; pfd; svc
! disabled && ok "модуль по-прежнему активен" || bad "модуль отключился без причины"
[ "$(strikes)" = "0" ] && ok "счётчик остался нулевым" || bad "счётчик вырос без причины"

echo
echo "== одна незавершённая загрузка =="
reset_env
pfd                      # загрузка 1: маркер поставлен
# (service.sh не вызывается — телефон не доехал до boot_completed)
new_boot; pfd            # загрузка 2: видит чужой маркер
[ "$(strikes)" = "1" ] && ok "зафиксировано нарушение 1" || bad "счётчик = $(strikes), ожидалось 1"
! disabled && ok "после ОДНОГО нарушения модуль НЕ отключён" || bad "отключился с первого раза"
[ -f "$CONF/pending-boot" ] && ok "маркер переставлен на текущую загрузку" || bad "маркер не переставлен"

echo
echo "== две незавершённые подряд -> самоотключение =="
new_boot; pfd            # загрузка 3: второе нарушение
[ "$(strikes)" = "2" ] && ok "зафиксировано нарушение 2" || bad "счётчик = $(strikes), ожидалось 2"
disabled && ok "модуль отключил себя" || bad "модуль НЕ отключился после двух нарушений"
[ ! -f "$CONF/pending-boot" ] && ok "маркер снят при отключении" || bad "маркер остался"
grep -q 'МОДУЛЬ ОТКЛЮЧЁН' "$CONF/boot.log" && ok "причина записана в журнал" || bad "журнал без причины"

echo
echo "== выздоровление: успешная загрузка сбрасывает счётчик =="
reset_env
pfd; new_boot; pfd       # одно нарушение
[ "$(strikes)" = "1" ] && ok "накоплено нарушение 1" || bad "счётчик = $(strikes)"
svc                       # загрузка дошла до конца
[ "$(strikes)" = "0" ] && ok "успешная загрузка обнулила счётчик" || bad "счётчик не сброшен: $(strikes)"
new_boot; pfd             # ставит маркер...
new_boot; pfd             # ...и эта загрузка видит его просроченным = сбой
[ "$(strikes)" = "1" ] && ok "следующий сбой считается заново с 1" || bad "счётчик = $(strikes), ожидалось 1"
! disabled && ok "модуль не отключён (нарушения не накапливаются через успех)" || bad "ложное отключение"

echo
echo "== модуль инертен без профиля =="
reset_env; rm -f "$MOD/system.prop"
pfd
[ ! -f "$CONF/pending-boot" ] && ok "без system.prop маркер не ставится" || bad "маркер поставлен без профиля"
! disabled && ok "без профиля модуль ничего не делает" || bad "модуль отключил себя без профиля"

echo
echo "== service.sh не трогает состояние, если загрузка не завершилась =="
reset_env
pfd
FAKE_BOOT_COMPLETED=0 COHERENCE_CONF="$CONF" PATH="$STUB:$PATH" timeout 8 sh "$MOD/service.sh" >/dev/null 2>&1
[ -f "$CONF/pending-boot" ] && ok "маркер сохранён при незавершённой загрузке" || bad "маркер снят преждевременно"

echo
echo "== сторож не пишет свойства =="
if grep -nE '^[^#]*\bresetprop\b' "$ROOT/module/post-fs-data.sh" | grep -v '^\s*#' | grep -q resetprop; then
    bad "post-fs-data.sh вызывает resetprop — свойства должны идти через system.prop"
else
    ok "post-fs-data.sh не вызывает resetprop"
fi
if grep -qE '^[^#]*\bsetprop\b' "$ROOT/module/post-fs-data.sh"; then
    bad "post-fs-data.sh вызывает setprop — это взаимоблокировка загрузки"
else
    ok "post-fs-data.sh не вызывает setprop"
fi
for forbidden in 'sleep' 'while' 'curl' 'wget'; do
    if grep -qE "^[^#]*\b${forbidden}\b" "$ROOT/module/post-fs-data.sh"; then
        bad "post-fs-data.sh содержит '$forbidden' — бюджет стадии 35 с"
    else
        ok "post-fs-data.sh без '$forbidden'"
    fi
done
if grep -qE '^[^#]*\bresetprop\b.*ro\.(product|build)\.' "$ROOT/module/service.sh"; then
    bad "service.sh пишет свойства идентичности — поздно, Build уже заморожен в zygote"
else
    ok "service.sh не пишет свойства идентичности"
fi

echo
echo "== журнал ограничен по размеру =="
reset_env
python3 -c "open('$CONF/boot.log','w').write('x'*100000)"
pfd
sz=$(wc -c <"$CONF/boot.log")
[ "$sz" -lt 70000 ] && ok "журнал обрезан до $sz байт" || bad "журнал не обрезан: $sz байт"

echo
echo "== uninstall.sh =="
reset_env; pfd
COHERENCE_CONF="$CONF" sh "$MOD/uninstall.sh"
[ ! -f "$CONF/pending-boot" ] && ok "рабочее состояние удалено" || bad "маркер остался"
[ -f "$CONF/boot.log" ] && ok "журнал сохранён для разбора" || bad "журнал удалён"

printf '\nПройдено: %d, провалено: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
