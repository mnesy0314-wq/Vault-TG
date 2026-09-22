#!/usr/bin/env bash
#
# Интеграционные тесты spoofctl на подставном устройстве.
# Реальные значения взяты из docs/device-baseline.md (TECNO KL4).
#
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

MOD="$WORK/modules/coherence"; CONF="$WORK/conf"
mkdir -p "$MOD/common" "$MOD/system/bin" "$CONF"
cp "$ROOT/module/common/"*.sh "$MOD/common/"
cp "$ROOT/module/system/bin/spoofctl" "$MOD/system/bin/"

STUB="$WORK/bin"; mkdir -p "$STUB"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/getprop"; chmod +x "$STUB/getprop"

# Замеры реального TECNO KL4.
cat > "$WORK/dev-real.sh" <<'EOF'
dev_platform() { echo ums9230; }
dev_soc()      { echo T615; }
dev_low_ram()  { echo true; }
dev_release()  { echo 14; }
dev_density()  { echo 320; }
dev_abilist()  { echo 'arm64-v8a,armeabi-v7a,armeabi'; }
dev_cores()    { echo 8; }
dev_ram_kb()   { echo 2855468; }
dev_display()  { echo 720x1600; }
dev_override() { :; }
EOF

# То же, но с активным override экрана.
sed 's/^dev_override() { :; }/dev_override() { echo "размер=540x1209"; echo "плотность=240"; }/' \
    "$WORK/dev-real.sh" > "$WORK/dev-override.sh"

sc() {
    COHERENCE_MODDIR="$MOD" COHERENCE_CONF="$CONF" \
    COHERENCE_FAKE_DEV="${FAKE:-$WORK/dev-real.sh}" TMPDIR="$WORK" \
    PATH="$STUB:$PATH" sh "$MOD/system/bin/spoofctl" "$@" 2>&1
}
scrc() { sc "$@" >/dev/null 2>&1; echo $?; }

# Согласованный профиль: то же железо, другая региональная SKU.
mk_profile() {
    cat > "$1" <<'EOF'
@platform=ums9230
@soc_model=T615
@core_count=8
@ram_kb=2855468
@display=720x1600
@density=320
@low_ram=true
@release=14
@abilist=arm64-v8a,armeabi-v7a,armeabi
@source_sha256=0000000000000000000000000000000000000000000000000000000000000000
ro.product.model=TECNO KL4
ro.product.brand=TECNO
ro.product.manufacturer=TECNO
ro.product.device=TECNO-KL4
ro.product.name=KL4-H
ro.build.fingerprint=TECNO/KL4-H/TECNO-KL4:14/UP1A.231005.007/260414V512:user/release-keys
ro.build.id=UP1A.231005.007
ro.build.version.incremental=260414V512
ro.build.type=user
ro.build.tags=release-keys
ro.build.version.security_patch=2026-05-01
EOF
}

echo "== согласованный профиль =="
mk_profile "$WORK/good.conf"
out="$(sc check "$WORK/good.conf")"
if [ "$(scrc check "$WORK/good.conf")" = "0" ]; then ok "принят"; else bad "отвергнут:"; echo "$out" | sed 's/^/       /'; fi
printf '%s' "$out" | grep -q 'все 8 полей сходятся' && ok "когерентность fingerprint подтверждена" || bad "нет подтверждения когерентности"
printf '%s' "$out" | grep -q 'в пределах 25%' && ok "память сверена с допуском" || bad "память не сверена"

echo
echo "== предусловие: override экрана =="
out="$(FAKE="$WORK/dev-override.sh" sc check "$WORK/good.conf")"
if [ "$(FAKE="$WORK/dev-override.sh" scrc check "$WORK/good.conf")" != "0" ]; then ok "профиль отвергнут при активном override"; else bad "override не заблокировал профиль"; fi
printf '%s' "$out" | grep -q 'wm size reset' && ok "подсказано, как исправить" || bad "нет подсказки"

echo
echo "== запрещённые свойства =="
mk_profile "$WORK/deny.conf"; cat >> "$WORK/deny.conf" <<'EOF'
ro.hardware=zuma
ro.product.cpu.abilist=arm64-v8a
EOF
out="$(sc check "$WORK/deny.conf")"
[ "$(scrc check "$WORK/deny.conf")" != "0" ] && ok "профиль с ro.hardware отвергнут" || bad "ro.hardware пропущен"
printf '%s' "$out" | grep -q 'ЗАПРЕЩЕНО.*ro.hardware' && ok "названо конкретное свойство" || bad "свойство не названо"

echo
echo "== несогласованный fingerprint =="
mk_profile "$WORK/incoh.conf"
sed -i 's/^ro.product.brand=TECNO/ro.product.brand=samsung/' "$WORK/incoh.conf"
out="$(sc check "$WORK/incoh.conf")"
[ "$(scrc check "$WORK/incoh.conf")" != "0" ] && ok "brand, не совпавший с fingerprint, отвергнут" || bad "рассогласование пропущено"
printf '%s' "$out" | grep -q "рассогласование 'brand'" && ok "названо конкретное поле" || bad "поле не названо"
printf '%s' "$out" | grep -q 'Build.FINGERPRINT.startsWith' && ok "показано, как это вскрывается" || bad "нет пояснения"

echo
echo "== несовместимость с железом =="
for case_ in "platform:mt6768:платформа" "soc_model:T612:SoC" "core_count:4:ядра" \
             "display:1080x2400:панель" "low_ram:false:low_ram" "release:15:Android"; do
    key="${case_%%:*}"; rest="${case_#*:}"; val="${rest%%:*}"; label="${rest##*:}"
    mk_profile "$WORK/hw.conf"
    sed -i "s|^@${key}=.*|@${key}=${val}|" "$WORK/hw.conf"
    if [ "$(scrc check "$WORK/hw.conf")" != "0" ]; then ok "отвергнут: $label заявлен как $val"; else bad "пропущено расхождение: $label=$val"; fi
done

echo
echo "== память: допуск 25% =="
mk_profile "$WORK/ram.conf"; sed -i 's/^@ram_kb=.*/@ram_kb=3000000/' "$WORK/ram.conf"
[ "$(scrc check "$WORK/ram.conf")" = "0" ] && ok "3000000 kB против 2855468 — принято (в допуске)" || bad "отвергнуто в пределах допуска"
mk_profile "$WORK/ram2.conf"; sed -i 's/^@ram_kb=.*/@ram_kb=8000000/' "$WORK/ram2.conf"
[ "$(scrc check "$WORK/ram2.conf")" != "0" ] && ok "8000000 kB отвергнуто (вне допуска)" || bad "8 ГБ принято на телефоне с 2.7 ГБ"

echo
echo "== флагманский профиль отвергается по нескольким основаниям =="
cat > "$WORK/pixel.conf" <<'EOF'
@platform=zuma
@soc_model=Tensor G4
@core_count=8
@ram_kb=12000000
@display=1080x2424
@density=420
@low_ram=false
@release=14
ro.product.model=Pixel 9
ro.product.brand=google
ro.product.manufacturer=Google
ro.product.device=tokay
ro.product.name=tokay
ro.build.fingerprint=google/tokay/tokay:14/AD1A.240905.004/12120705:user/release-keys
ro.build.id=AD1A.240905.004
ro.build.version.incremental=12120705
ro.build.type=user
ro.build.tags=release-keys
EOF
out="$(sc check "$WORK/pixel.conf")"
[ "$(scrc check "$WORK/pixel.conf")" != "0" ] && ok "профиль Pixel 9 отвергнут" || bad "Pixel 9 принят на Unisoc T615"
n="$(printf '%s' "$out" | grep -c '✗\|устройство —')"
[ "$n" -ge 4 ] && ok "названо несколько оснований отказа ($n)" || bad "оснований отказа: $n"

echo
echo "== отсутствующий fingerprint =="
grep -v '^ro.build.fingerprint=' "$WORK/good.conf" > "$WORK/nofp.conf"
[ "$(scrc check "$WORK/nofp.conf")" != "0" ] && ok "профиль без fingerprint отвергнут" || bad "профиль без fingerprint принят"

echo
echo "== происхождение =="
grep -v '^@source_sha256=' "$WORK/good.conf" > "$WORK/nosrc.conf"
out="$(sc check "$WORK/nosrc.conf")"
printf '%s' "$out" | grep -q 'супер-кукис' && ok "предупреждение о выдуманном профиле показано" || bad "нет предупреждения о происхождении"

echo
echo "== import / apply / revert =="
[ "$(scrc import "$WORK/good.conf")" = "0" ] && ok "import принял валидный профиль" || bad "import отверг валидный профиль"
[ -f "$CONF/profile.conf" ] && ok "профиль сохранён" || bad "профиль не сохранён"
[ "$(scrc import "$WORK/deny.conf")" != "0" ] && ok "import отверг невалидный профиль" || bad "import принял невалидный"

[ "$(scrc apply)" = "0" ] && ok "apply отработал" || bad "apply упал"
[ -f "$MOD/system.prop" ] && ok "system.prop создан" || bad "system.prop не создан"
if [ -f "$MOD/system.prop" ]; then
    grep -q '^@' "$MOD/system.prop" && bad "строки @ попали в system.prop" || ok "строки @ в system.prop не попали"
    grep -q '^ro.product.model=TECNO KL4' "$MOD/system.prop" && ok "свойства записаны" || bad "свойства не записаны"
fi

# apply обязан перепроверять: override могли включить после import.
rm -f "$MOD/system.prop"
[ "$(FAKE="$WORK/dev-override.sh" scrc apply)" != "0" ] && ok "apply перепроверяет условия (override появился после import)" || bad "apply применил профиль при активном override"
[ ! -f "$MOD/system.prop" ] && ok "system.prop не создан при отказе" || bad "system.prop создан несмотря на отказ"

sc apply >/dev/null 2>&1
[ "$(scrc revert)" = "0" ] && ok "revert отработал" || bad "revert упал"
[ ! -f "$MOD/system.prop" ] && ok "system.prop удалён" || bad "system.prop остался"

echo
echo "== status =="
out="$(sc status)"
printf '%s' "$out" | grep -q 'Неизменяемое' && ok "status показывает неизменяемое железо" || bad "status без раздела железа"
out="$(FAKE="$WORK/dev-override.sh" sc status)"
printf '%s' "$out" | grep -q 'АКТИВЕН OVERRIDE' && ok "status предупреждает об override" || bad "status молчит об override"

echo
echo "== неизвестная команда =="
[ "$(scrc bogus)" != "0" ] && ok "неизвестная команда -> ошибка" || bad "неизвестная команда принята"
sc --help | grep -q 'spoofctl status' && ok "--help печатает справку" || bad "нет справки"

printf '\nПройдено: %d, провалено: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
