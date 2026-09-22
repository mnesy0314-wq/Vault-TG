#!/usr/bin/env bash
# Тесты denylist/allowlist и сканера профиля.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/module/common/denylist.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
rc()  { sh -c ". '$LIB'; $1" >/dev/null 2>&1; echo $?; }
run() { sh -c ". '$LIB'; $1" 2>&1; }

echo "== denylist: опасное запрещено =="
for k in \
    ro.hardware ro.hardware.gps ro.boot.hardware ro.boot.serialno ro.bootloader ro.revision \
    ro.board.platform ro.product.board ro.arch ro.crypto.state ro.zygote dalvik.vm.heapsize \
    ro.build.version.sdk ro.build.version.release ro.build.version.release_or_codename \
    ro.build.version.codename ro.build.version.preview_sdk ro.system.build.version.sdk \
    ro.product.first_api_level ro.board.api_level ro.vendor.api_level \
    ro.product.cpu.abi ro.product.cpu.abilist ro.product.cpu.abilist64 ro.vendor.product.cpu.abilist \
    ro.soc.model ro.soc.manufacturer \
    ro.config.low_ram ro.config.medium_ram ro.lmk.critical \
    ro.sf.lcd_density ro.vndk.version ro.product.vndk.version ro.treble.enabled ro.apex.updatable \
    ro.product.property_source_order ro.serialno ro.debuggable ro.secure ro.build.characteristics \
    ro.product.model_for_attestation ro.product.brand_for_attestation \
    ro.os_dynamicbar_support ro.tranos.version ro.transsion.foo ro.sys.tran.bar \
    ro.vendor.os_baz ro.itel_style.icon_size_five_column \
    persist.sys.locale persist.vendor.radio.foo ; do
    if [ "$(rc "deny_check '$k'")" = "0" ]; then ok "запрещено: $k"; else bad "НЕ запрещено: $k"; fi
done

echo
echo "== каждый запрет объясняет причину =="
missing=0
for k in ro.hardware ro.product.board ro.soc.model ro.serialno persist.sys.x ro.os_foo; do
    why="$(run "deny_reason '$k'")"
    [ "${#why}" -ge 40 ] || { bad "причина для $k слишком короткая: $why"; missing=1; }
done
[ "$missing" -eq 0 ] && ok "все проверенные запреты дают содержательную причину"

echo
echo "== allowlist: нужное разрешено =="
for k in \
    ro.product.model ro.product.brand ro.product.manufacturer ro.product.device ro.product.name \
    ro.product.odm.model ro.product.vendor.brand ro.product.system_ext.device \
    ro.product.bootimage.model ro.product.vendor_dlkm.name ro.product.odm_dlkm.model \
    ro.product.system_dlkm.brand \
    ro.build.fingerprint ro.build.id ro.build.display.id ro.build.description ro.build.flavor \
    ro.build.type ro.build.tags ro.build.date ro.build.date.utc \
    ro.build.version.incremental ro.build.version.security_patch \
    ro.system.build.fingerprint ro.vendor.build.fingerprint ro.odm.build.fingerprint \
    ro.bootimage.build.fingerprint ; do
    if [ "$(rc "allow_check '$k'")" = "0" ]; then ok "разрешено: $k"; else bad "НЕ разрешено: $k"; fi
done

echo
echo "== allowlist НЕ захватывает опасное (проверка на глоб) =="
# Смысл всего теста: если allow_check когда-нибудь станет глобом
# ro.product.*, эти проверки упадут.
for k in ro.product.cpu.abilist ro.product.board ro.product.first_api_level \
         ro.product.property_source_order ro.product.vndk.version \
         ro.product.model_for_attestation ro.system.build.version.sdk ; do
    if [ "$(rc "allow_check '$k'")" != "0" ]; then ok "НЕ в allowlist: $k"; else bad "allowlist захватил опасное: $k"; fi
done

echo
echo "== deny имеет приоритет над allow =="
# ro.product.board выглядит как поле идентичности (Build.BOARD), но это
# селектор HAL. Он обязан быть запрещён и не разрешён одновременно.
if [ "$(rc "deny_check ro.product.board")" = "0" ] && [ "$(rc "allow_check ro.product.board")" != "0" ]; then
    ok "ro.product.board запрещён и не входит в allowlist"
else
    bad "ro.product.board обработан неверно"
fi

echo
echo "== deny_scan_profile =="

cat > "$WORK/good.conf" <<'EOF'
# нормальный профиль
ro.product.model=realme Note 50
ro.product.brand=realme
ro.product.manufacturer=realme
ro.product.device=RE58C6
ro.product.name=RMX3834
ro.build.fingerprint=realme/RMX3834/RE58C6:14/UP1A.231005.007/T.R4T2.1691917416:user/release-keys
ro.build.id=UP1A.231005.007
EOF
if [ "$(rc "deny_scan_profile '$WORK/good.conf'")" = "0" ]; then ok "корректный профиль принят"; else bad "корректный профиль отвергнут: $(run "deny_scan_profile '$WORK/good.conf'")"; fi

cat > "$WORK/danger.conf" <<'EOF'
ro.product.model=Pixel 9
ro.hardware=zuma
ro.product.cpu.abilist=arm64-v8a
ro.build.version.sdk=35
EOF
out="$(run "deny_scan_profile '$WORK/danger.conf'")"
if [ "$(rc "deny_scan_profile '$WORK/danger.conf'")" != "0" ]; then ok "профиль с опасными ключами отвергнут"; else bad "опасный профиль принят"; fi
n="$(printf '%s' "$out" | grep -c 'ЗАПРЕЩЕНО')"
if [ "$n" -eq 3 ]; then ok "сообщает обо ВСЕХ 3 запрещённых ключах"; else bad "найдено $n запрещённых ключей вместо 3"; fi

# Лимит 91 байт — ключевое правило, проверяем ровно на границе.
python3 -c "
v='x'*91
print('ro.build.display.id='+v)
" > "$WORK/len91.conf"
if [ "$(rc "deny_scan_profile '$WORK/len91.conf'")" = "0" ]; then ok "91 байт принят (граница)"; else bad "91 байт отвергнут"; fi

python3 -c "
v='x'*92
print('ro.build.display.id='+v)
" > "$WORK/len92.conf"
out="$(run "deny_scan_profile '$WORK/len92.conf'")"
if [ "$(rc "deny_scan_profile '$WORK/len92.conf'")" != "0" ] && printf '%s' "$out" | grep -q 'СЛИШКОМ ДЛИННО'; then
    ok "92 байта отвергнуты (PROP_VALUE_MAX)"
else
    bad "92 байта приняты: $out"
fi

# Длина считается в БАЙТАХ, не в символах: кириллица — 2 байта на символ.
python3 -c "
v='я'*50   # 50 символов, 100 байт
print('ro.build.display.id='+v)
" > "$WORK/utf8.conf"
if [ "$(rc "deny_scan_profile '$WORK/utf8.conf'")" != "0" ]; then
    ok "50 UTF-8 символов = 100 байт отвергнуты (счёт в байтах, не символах)"
else
    bad "UTF-8 длина посчитана в символах, а не байтах"
fi

printf 'not-a-kv-line\n' > "$WORK/bad.conf"
if [ "$(rc "deny_scan_profile '$WORK/bad.conf'")" != "0" ]; then ok "строка не вида ключ=значение отвергнута"; else bad "битая строка принята"; fi

cat > "$WORK/unknown.conf" <<'EOF'
ro.product.model=X
ro.some.typo.here=Y
EOF
out="$(run "deny_scan_profile '$WORK/unknown.conf'")"
if [ "$(rc "deny_scan_profile '$WORK/unknown.conf'")" = "0" ] && printf '%s' "$out" | grep -q 'неизвестно'; then
    ok "неизвестный ключ = предупреждение, не отказ"
else
    bad "неизвестный ключ обработан неверно: $out"
fi

if [ "$(rc "deny_scan_profile '$WORK/нет-такого'")" != "0" ]; then ok "отсутствующий файл -> ошибка"; else bad "отсутствующий файл принят"; fi

printf '\n'
printf 'Пройдено: %d, провалено: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
