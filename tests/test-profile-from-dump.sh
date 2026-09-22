#!/usr/bin/env bash
# Тесты импортёра. Главное, что проверяется: он НИЧЕГО не придумывает.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$ROOT/tools/profile-from-dump.sh"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
P=0; F=0
ok()  { P=$((P+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { F=$((F+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
run()  { COHERENCE_LIB="$ROOT/module/common" TMPDIR="$W" sh "$S" "$@" 2>&1; }
rc()   { COHERENCE_LIB="$ROOT/module/common" TMPDIR="$W" sh "$S" "$@" >/dev/null 2>&1; echo $?; }

# Дамп в формате getprop. Значения внутренне согласованы.
cat > "$W/getprop.txt" <<'EOF'
[ro.product.model]: [realme Note 50]
[ro.product.brand]: [realme]
[ro.product.manufacturer]: [realme]
[ro.product.device]: [RE58C6]
[ro.product.name]: [RMX3834]
[ro.product.odm.model]: [realme Note 50]
[ro.product.vendor.brand]: [realme]
[ro.build.fingerprint]: [realme/RMX3834/RE58C6:14/UP1A.231005.007/T.R4T2.1691917416:user/release-keys]
[ro.build.id]: [UP1A.231005.007]
[ro.build.version.incremental]: [T.R4T2.1691917416]
[ro.build.version.release]: [14]
[ro.build.version.sdk]: [34]
[ro.build.type]: [user]
[ro.build.tags]: [release-keys]
[ro.build.version.security_patch]: [2024-07-05]
[ro.build.display.id]: [RMX3834_11.C.65]
[ro.board.platform]: [ums9230]
[ro.soc.model]: [T612]
[ro.config.low_ram]: [true]
[ro.product.cpu.abilist]: [arm64-v8a,armeabi-v7a,armeabi]
[ro.sf.lcd_density]: [320]
[ro.hardware]: [ums9230_hulk]
[ro.oplus.something]: [1]
EOF

echo "== формат getprop =="
out="$(run "$W/getprop.txt" -o "$W/p1.conf")"
[ "$(rc "$W/getprop.txt" -o "$W/p1.conf")" = "0" ] && ok "дамп принят" || { bad "дамп отвергнут"; echo "$out" | sed 's/^/     /'; }
printf '%s' "$out" | grep -q 'формат: getprop' && ok "формат распознан" || bad "формат не распознан"
[ -f "$W/p1.conf" ] && ok "профиль создан" || bad "профиль не создан"

echo
echo "== копирует дословно, не переписывает =="
grep -q '^ro.build.fingerprint=realme/RMX3834/RE58C6:14/UP1A.231005.007/T.R4T2.1691917416:user/release-keys$' "$W/p1.conf" \
    && ok "fingerprint скопирован побайтово" || bad "fingerprint изменён"
grep -q '^ro.product.model=realme Note 50$' "$W/p1.conf" \
    && ok "значение с пробелом сохранено целиком" || bad "значение с пробелом потеряно"

echo
echo "== отбрасывает запрещённое и чужое =="
grep -q 'ro.hardware=' "$W/p1.conf" && bad "ro.hardware попал в профиль" || ok "ro.hardware отброшен"
grep -q 'ro.build.version.sdk' "$W/p1.conf" && bad "ro.build.version.sdk попал в профиль" || ok "ro.build.version.sdk отброшен"
grep -q 'ro.board.platform=' "$W/p1.conf" && bad "ro.board.platform попал в свойства" || ok "ro.board.platform не среди свойств"
grep -q 'ro.oplus' "$W/p1.conf" && bad "чужое вендорное свойство попало в профиль" || ok "чужое вендорное свойство отброшено"

echo
echo "== метаданные берутся из дампа =="
grep -q '^@platform=ums9230$'  "$W/p1.conf" && ok "@platform из дампа" || bad "@platform не извлечён"
grep -q '^@soc_model=T612$'    "$W/p1.conf" && ok "@soc_model из дампа" || bad "@soc_model не извлечён"
grep -q '^@release=14$'        "$W/p1.conf" && ok "@release из дампа" || bad "@release не извлечён"
grep -q '^@low_ram=true$'      "$W/p1.conf" && ok "@low_ram из дампа" || bad "@low_ram не извлечён"
grep -q '^@density=320$'       "$W/p1.conf" && ok "@density из дампа" || bad "@density не извлечён"
grep -q '^@source_sha256=[0-9a-f]\{64\}$' "$W/p1.conf" && ok "хеш дампа посчитан" || bad "хеш не посчитан"

echo
echo "== чего нет в дампе, того нет в профиле =="
grep -q '^@core_count=' "$W/p1.conf" && bad "@core_count выдуман (в свойствах его нет)" || ok "@core_count не выдуман"
grep -q '^@ram_kb='     "$W/p1.conf" && bad "@ram_kb выдуман" || ok "@ram_kb не выдуман"
grep -q '^@display='    "$W/p1.conf" && bad "@display выдуман" || ok "@display не выдуман"
printf '%s' "$out" | grep -q 'не заполнено: @core_count' && ok "сообщил, чего не хватает" || bad "промолчал о нехватке"

echo
echo "== флаги дозаполнения =="
run "$W/getprop.txt" -o "$W/p2.conf" --cores 8 --ram-kb 2855468 --display 720x1600 >/dev/null 2>&1
grep -q '^@core_count=8$'       "$W/p2.conf" && ok "--cores записан" || bad "--cores не записан"
grep -q '^@ram_kb=2855468$'     "$W/p2.conf" && ok "--ram-kb записан" || bad "--ram-kb не записан"
grep -q '^@display=720x1600$'   "$W/p2.conf" && ok "--display записан" || bad "--display не записан"

echo
echo "== формат build.prop =="
sed 's/^\[\([^]]*\)\]: \[\(.*\)\]$/\1=\2/' "$W/getprop.txt" > "$W/build.prop"
out="$(run "$W/build.prop" -o "$W/p3.conf")"
printf '%s' "$out" | grep -q 'формат: build.prop' && ok "build.prop распознан" || bad "build.prop не распознан"
grep -q '^ro.build.fingerprint=realme/RMX3834' "$W/p3.conf" && ok "свойства извлечены" || bad "свойства не извлечены"

echo
echo "== отказ без fingerprint =="
grep -v 'ro.build.fingerprint' "$W/getprop.txt" > "$W/nofp.txt"
out="$(run "$W/nofp.txt" -o "$W/p4.conf")"
[ "$(rc "$W/nofp.txt" -o "$W/p4.conf")" != "0" ] && ok "дамп без fingerprint отвергнут" || bad "дамп без fingerprint принят"
printf '%s' "$out" | grep -q 'скопирована с устройства целиком' && ok "объяснено, почему нельзя достроить" || bad "нет объяснения"

echo
echo "== отказ при неполном дампе =="
grep -v 'ro.product.device' "$W/getprop.txt" > "$W/partial.txt"
out="$(run "$W/partial.txt" -o "$W/p5.conf")"
[ "$(rc "$W/partial.txt" -o "$W/p5.conf")" != "0" ] && ok "неполный дамп отвергнут" || bad "неполный дамп принят"
printf '%s' "$out" | grep -q 'ro.product.device' && ok "названо недостающее свойство" || bad "не названо недостающее"

echo
echo "== ловит склеенный из двух устройств дамп =="
sed 's/^\[ro.product.brand\]: \[realme\]/[ro.product.brand]: [samsung]/' "$W/getprop.txt" > "$W/frank.txt"
out="$(run "$W/frank.txt" -o "$W/p6.conf")"
[ "$(rc "$W/frank.txt" -o "$W/p6.conf")" != "0" ] && ok "рассогласованный дамп отвергнут" || bad "рассогласованный дамп принят"
printf '%s' "$out" | grep -q 'из двух разных устройств' && ok "названа вероятная причина" || bad "причина не названа"

echo
echo "== мусор на входе =="
printf 'это просто текст\nникаких свойств\n' > "$W/junk.txt"
[ "$(rc "$W/junk.txt" -o "$W/p7.conf")" != "0" ] && ok "мусор отвергнут" || bad "мусор принят"
[ "$(rc "$W/нет-файла")" != "0" ] && ok "отсутствующий файл -> ошибка" || bad "отсутствующий файл принят"

echo
echo "== результат проходит spoofctl =="
# Профиль с дозаполненными метаданными должен пройти проверку модуля
# на устройстве с соответствующим железом.
MOD="$W/mod"; mkdir -p "$MOD/common"; cp "$ROOT/module/common/"*.sh "$MOD/common/"
cat > "$W/dev.sh" <<'EOF'
dev_platform() { echo ums9230; }
dev_soc()      { echo T612; }
dev_low_ram()  { echo true; }
dev_release()  { echo 14; }
dev_density()  { echo 320; }
dev_abilist()  { echo 'arm64-v8a,armeabi-v7a,armeabi'; }
dev_cores()    { echo 8; }
dev_ram_kb()   { echo 2855468; }
dev_display()  { echo 720x1600; }
dev_override() { :; }
EOF
STUB="$W/bin"; mkdir -p "$STUB"; printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/getprop"; chmod +x "$STUB/getprop"
r=$(COHERENCE_MODDIR="$MOD" COHERENCE_CONF="$W/conf" COHERENCE_FAKE_DEV="$W/dev.sh" TMPDIR="$W" \
    PATH="$STUB:$PATH" sh "$ROOT/module/system/bin/spoofctl" check "$W/p2.conf" >/dev/null 2>&1; echo $?)
[ "$r" = "0" ] && ok "профиль из импортёра принят spoofctl" || bad "spoofctl отверг профиль импортёра"

printf '\nПройдено: %d, провалено: %d\n' "$P" "$F"
[ "$F" -eq 0 ] || exit 1
