#!/usr/bin/env bash
# Проверка простого скрипта: делает ли он то, что обещает, и понятно ли пишет.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$ROOT/tools/fix-privacy.sh"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
P=0; F=0
ok()  { P=$((P+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { F=$((F+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

STUB="$W/bin"; mkdir -p "$STUB"; LOG="$W/log"
cat > "$STUB/wm" <<EOF
#!/usr/bin/env bash
echo "wm \$*" >> "$LOG"
if [ -f "$W/clean" ]; then
  case "\${1:-}" in size) echo "Physical size: 720x1600";; density) echo "Physical density: 320";; esac
else
  case "\${1:-}" in
    size) echo "Physical size: 720x1600"; echo "Override size: 540x1209";;
    density) echo "Physical density: 320"; echo "Override density: 240";;
  esac
fi
[ "\${2:-}" = "reset" ] && touch "$W/clean"
exit 0
EOF
printf '#!/usr/bin/env bash\necho "am $*" >> "%s"\nexit 0\n' "$LOG" > "$STUB/am"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/getprop"
chmod +x "$STUB"/*

run() { PATH="$STUB:$PATH" sh "$S" "$@" 2>&1; }

echo "== чинит экран сам =="
rm -f "$W/clean" "$LOG"
out="$(run)"
grep -q 'wm size reset' "$LOG" && ok "сбросил размер экрана" || bad "не сбросил размер"
grep -q 'wm density reset' "$LOG" && ok "сбросил плотность" || bad "не сбросил плотность"
printf '%s' "$out" | grep -q 'Готово' && ok "сообщил, что готово" || bad "не сообщил результат"
printf '%s' "$out" | grep -q 'станет чуть мельче' && ok "предупредил о видимом эффекте" || bad "не предупредил"

echo
echo "== если экран уже в порядке =="
touch "$W/clean"; : > "$LOG"
out="$(run)"
grep -q 'reset' "$LOG" && bad "трогает экран без нужды" || ok "не трогает, если всё в порядке"
printf '%s' "$out" | grep -q 'Уже в порядке' && ok "так и говорит" || bad "молчит"

echo
echo "== рекламный номер =="
: > "$LOG"; out="$(run)"
grep -q 'am start' "$LOG" && ok "открыл настройки рекламы" || bad "не открыл настройки"
printf '%s' "$out" | grep -q 'Удалить рекламный идентификатор' && ok "назвал кнопку дословно" || bad "не назвал кнопку"

echo
echo "== понятность: без технического жаргона =="
out="$(run)"
for word in fingerprint SSAID resetprop PROP_VALUE_MAX ro.product Build.MODEL bionic zygote; do
    printf '%s' "$out" | grep -q "$word" && bad "в выводе есть жаргон: $word" || ok "нет жаргона: $word"
done

echo
echo "== итог и следующий шаг =="
printf '%s' "$out" | grep -q 'Итог' && ok "печатает итог" || bad "нет итога"
printf '%s' "$out" | grep -q 'Главное' && ok "называет главное действие" || bad "не выделено главное"

out="$(run --sbros-nomerov)"
printf '%s' "$out" | grep -q 'разлогинит' && ok "предупреждает о разлогине" || bad "не предупреждает"
printf '%s' "$out" | grep -q 'privacy-actions.sh ssaid' && ok "даёт точную команду" || bad "нет команды"

printf '\nПройдено: %d, провалено: %d\n' "$P" "$F"
[ "$F" -eq 0 ] || exit 1
