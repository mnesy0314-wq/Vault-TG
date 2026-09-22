#!/usr/bin/env bash
#
# Прогоняет tools/collect-device-info.sh в песочнице с подставными
# android-утилитами (getprop / settings / wm / magisk), чтобы поймать
# runtime-ошибки без реального телефона.
#
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/tools/collect-device-info.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAILED=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILED=1; }

# --- песочница: подставные android-бинарники --------------------------------
STUB="$WORK/bin"
mkdir -p "$STUB"

cat > "$STUB/getprop" <<'EOF'
#!/usr/bin/env bash
declare -A P=(
  [ro.product.model]="Spark Go 1"
  [ro.product.system.model]="Spark Go 1"
  [ro.product.brand]="TECNO"
  [ro.product.system.brand]="TECNO"
  [ro.product.manufacturer]="TECNO"
  [ro.product.device]="TECNO-KL4"
  [ro.product.name]="KL4-GL"
  [ro.product.property_source_order]="odm,vendor,product,system_ext,system"
  [ro.build.fingerprint]="TECNO/KL4-GL/TECNO-KL4:14/UP1A.231005.007/240101V123:user/release-keys"
  [ro.build.version.release]="14"
  [ro.build.version.sdk]="34"
  [ro.build.version.security_patch]="2024-08-05"
  [ro.hardware]="mt6768"
  [ro.board.platform]="mt6768"
  [ro.product.cpu.abilist]="arm64-v8a,armeabi-v7a,armeabi"
  [ro.config.low_ram]="true"
  [ro.sf.lcd_density]="320"
  [ro.serialno]="ABCD1234SECRET"
  [ro.boot.serialno]="ABCD1234SECRET"
  [ro.tranos.version]="HiOS 14.0"
)
if [ $# -eq 0 ]; then
  for k in "${!P[@]}"; do printf '[%s]: [%s]\n' "$k" "${P[$k]}"; done
  exit 0
fi
printf '%s' "${P[$1]:-}"
EOF

cat > "$STUB/settings" <<'EOF'
#!/usr/bin/env bash
# settings get secure android_id
[ "${1:-}" = "get" ] && printf 'a1b2c3d4e5f60718'
EOF

cat > "$STUB/wm" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  size)    echo "Physical size: 720x1612" ;;
  density) echo "Physical density: 320" ;;
esac
EOF

cat > "$STUB/magisk" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  -c) echo "27.0" ;;
  -V) echo "27000" ;;
esac
EOF

cat > "$STUB/resetprop" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

chmod +x "$STUB"/*

echo "== collect-device-info.sh =="

# --- 1. исполняется без ошибок ----------------------------------------------
OUT="$WORK/report.txt"
if PATH="$STUB:$PATH" sh "$SCRIPT" --out "$OUT" >"$WORK/stdout.log" 2>"$WORK/stderr.log"; then
    ok "скрипт завершился с кодом 0"
else
    fail "скрипт завершился с ненулевым кодом; stderr:"
    sed 's/^/       /' "$WORK/stderr.log"
fi

# --- 2. отчёт непустой ------------------------------------------------------
if [ -s "$OUT" ]; then
    ok "отчёт создан и непустой ($(wc -l <"$OUT") строк)"
else
    fail "отчёт пустой или отсутствует"
fi

# --- 3. нет утечки stderr ---------------------------------------------------
if [ -s "$WORK/stderr.log" ]; then
    fail "скрипт писал в stderr:"
    sed 's/^/       /' "$WORK/stderr.log"
else
    ok "stderr чистый"
fi

# --- 4. ключевые свойства попали в отчёт ------------------------------------
for key in ro.product.model ro.build.fingerprint ro.hardware ro.config.low_ram \
           ro.product.property_source_order ro.product.system.model; do
    if grep -q "$key" "$OUT"; then
        ok "в отчёте есть $key"
    else
        fail "в отчёте НЕТ $key"
    fi
done

# --- 5. значение реально подтянулось, а не осталось <нет> -------------------
if grep -qE 'ro\.product\.model +=.*Spark Go 1' "$OUT"; then
    ok "значение свойства прочитано корректно"
else
    fail "значение ro.product.model не прочиталось"
    grep 'ro.product.model' "$OUT" | sed 's/^/       /'
fi

# --- 6. РЕДАКЦИЯ: серийник не утёк в открытом виде --------------------------
if grep -q 'ABCD1234SECRET' "$OUT"; then
    fail "УТЕЧКА: серийный номер в отчёте в открытом виде"
else
    ok "серийный номер скрыт"
fi
if grep -q 'a1b2c3d4e5f60718' "$OUT"; then
    fail "УТЕЧКА: android_id в отчёте в открытом виде"
else
    ok "android_id скрыт"
fi
if grep -q 'sha256:' "$OUT"; then
    ok "чувствительные значения заменены хешем"
else
    fail "хешированных значений в отчёте нет — редакция не сработала"
fi

# --- 7. --raw действительно раскрывает --------------------------------------
RAW="$WORK/report-raw.txt"
PATH="$STUB:$PATH" sh "$SCRIPT" --raw --out "$RAW" >/dev/null 2>&1
if grep -q 'ABCD1234SECRET' "$RAW"; then
    ok "--raw раскрывает серийный номер"
else
    fail "--raw не раскрыл серийный номер"
fi

# --- 8. вендорные свойства Transsion подхвачены -----------------------------
if grep -q 'ro.tranos.version' "$OUT"; then
    ok "вендорные ro.tran* свойства найдены"
else
    fail "вендорные ro.tran* свойства не попали в отчёт"
fi

# --- 9. неизвестный аргумент -> ошибка --------------------------------------
if PATH="$STUB:$PATH" sh "$SCRIPT" --bogus >/dev/null 2>&1; then
    fail "неизвестный аргумент не вызвал ошибку"
else
    ok "неизвестный аргумент отклонён"
fi

# --- 10. --help работает ----------------------------------------------------
if PATH="$STUB:$PATH" sh "$SCRIPT" --help 2>/dev/null | grep -q 'collect-device-info'; then
    ok "--help печатает справку"
else
    fail "--help не печатает справку"
fi

echo
if [ "$FAILED" -eq 0 ]; then
    echo "Все проверки пройдены."
else
    echo "Есть падения."
fi
exit "$FAILED"
