#!/usr/bin/env bash
#
# Собирает флешируемый zip модуля.
#
# Содержимое упаковывается ИЗ КОРНЯ каталога module/, без объемлющей папки:
# установщик Magisk ожидает module.prop в корне архива.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/module"
OUT="${1:-$ROOT/dist}"

[ -f "$SRC/module.prop" ] || { echo "нет $SRC/module.prop" >&2; exit 1; }

ID="$(sed -n 's/^id=//p' "$SRC/module.prop" | head -1)"
VER="$(sed -n 's/^version=//p' "$SRC/module.prop" | head -1)"
[ -n "$ID" ] || { echo "в module.prop не задан id" >&2; exit 1; }

mkdir -p "$OUT"
ZIP="$OUT/${ID}-${VER}.zip"
rm -f "$ZIP"

# --- проверки перед упаковкой -----------------------------------------------

fail=0
need() { [ -e "$SRC/$1" ] || { echo "ОТСУТСТВУЕТ: $1" >&2; fail=1; }; }
need module.prop
need META-INF/com/google/android/update-binary
need META-INF/com/google/android/updater-script
need customize.sh
need post-fs-data.sh
need service.sh
need common/fingerprint.sh
need common/denylist.sh
need system/bin/spoofctl

# updater-script обязан содержать ровно '#MAGISK' — это требование
# установщика Magisk на v26.4-v28.1 и TWRP всегда.
if [ "$(tr -d '\r\n' < "$SRC/META-INF/com/google/android/updater-script")" != "#MAGISK" ]; then
    echo "updater-script должен содержать ровно '#MAGISK'" >&2
    fail=1
fi

# module.prop: ключи обязательны, хвостовые пробелы ломают разбор.
for k in id name version versionCode author description; do
    grep -q "^${k}=" "$SRC/module.prop" || { echo "в module.prop нет ключа: $k" >&2; fail=1; }
done
if grep -qE '[[:space:]]$' "$SRC/module.prop"; then
    echo "в module.prop есть строки с хвостовыми пробелами" >&2
    fail=1
fi
if ! grep -qE '^versionCode=[0-9]+$' "$SRC/module.prop"; then
    echo "versionCode должен быть целым числом" >&2
    fail=1
fi

# Модуль обязан поставляться БЕЗ профиля: общий для всех пользователей
# профиль создал бы когорту «пользователи этого модуля».
if [ -f "$SRC/system.prop" ]; then
    echo "в исходниках есть system.prop — модуль должен ставиться инертным" >&2
    fail=1
fi

# Синтаксис всех shell-скриптов.
while IFS= read -r f; do
    sh -n "$f" 2>/dev/null || { echo "синтаксическая ошибка: ${f#$SRC/}" >&2; fail=1; }
done < <(find "$SRC" -type f \( -name '*.sh' -o -name 'spoofctl' \))

[ "$fail" -eq 0 ] || { echo >&2; echo "сборка прервана" >&2; exit 1; }

# --- упаковка ---------------------------------------------------------------

if command -v zip >/dev/null 2>&1; then
    ( cd "$SRC" && zip -qr9 "$ZIP" . -x '.*' )
else
    # zip есть не везде; результат идентичен.
    python3 - "$SRC" "$ZIP" <<'PY'
import os, sys, zipfile, stat
src, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for root, dirs, files in os.walk(src):
        dirs[:] = [d for d in dirs if not d.startswith('.')]
        for name in sorted(files):
            if name.startswith('.'):
                continue
            full = os.path.join(root, name)
            rel = os.path.relpath(full, src)
            info = zipfile.ZipInfo(rel.replace(os.sep, '/'))
            mode = os.stat(full).st_mode
            info.external_attr = (mode & 0xFFFF) << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            with open(full, 'rb') as f:
                z.writestr(info, f.read())
PY
fi

echo "Собрано: $ZIP  ($(du -h "$ZIP" | cut -f1))"
echo
echo "Содержимое:"
if command -v unzip >/dev/null 2>&1; then
    unzip -l "$ZIP" | sed -n '4,$p' | head -20
else
    python3 -c "
import zipfile,sys
for n in sorted(zipfile.ZipFile(sys.argv[1]).namelist()): print('   ', n)
" "$ZIP"
fi
echo
echo "Установка: приложение Magisk -> Модули -> Установить из хранилища"
