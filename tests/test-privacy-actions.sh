#!/usr/bin/env bash
# Тесты privacy-actions.sh в песочнице. Правка SSAID проверяется особенно
# внимательно: её отказ невозможно откатить отключением модуля.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/tools/privacy-actions.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

CONF="$WORK/conf"; mkdir -p "$CONF"
STUB="$WORK/bin"; mkdir -p "$STUB"
LOGF="$WORK/calls.log"

cat > "$STUB/wm" <<EOF
#!/usr/bin/env bash
echo "wm \$*" >> "$LOGF"
if [ -f "$WORK/no-override" ]; then
  case "\${1:-}" in
    size)    echo "Physical size: 720x1600" ;;
    density) echo "Physical density: 320" ;;
  esac
else
  case "\${1:-}" in
    size)    echo "Physical size: 720x1600"; echo "Override size: 540x1209" ;;
    density) echo "Physical density: 320"; echo "Override density: 240" ;;
  esac
fi
[ "\${2:-}" = "reset" ] && touch "$WORK/no-override"
exit 0
EOF
printf '#!/usr/bin/env bash\necho "getprop $*" >> "%s"\nexit 0\n' "$LOGF" > "$STUB/getprop"
printf '#!/usr/bin/env bash\necho "stop" >> "%s"\n' "$LOGF" > "$STUB/stop"
printf '#!/usr/bin/env bash\necho "start" >> "%s"\n' "$LOGF" > "$STUB/start"
printf '#!/usr/bin/env bash\necho "am $*" >> "%s"\nexit 0\n' "$LOGF" > "$STUB/am"
printf '#!/usr/bin/env bash\necho "restorecon $*" >> "%s"\n' "$LOGF" > "$STUB/restorecon"
chmod +x "$STUB"/*

SSAID="$WORK/settings_ssaid.xml"
mk_ssaid() {
cat > "$SSAID" <<'EOF'
<?xml version='1.0' encoding='utf-8' standalone='yes' ?>
<settings version="1">
  <setting id="1" name="userkey" value="ffffffffffffffff" package="android" />
  <setting id="2" name="10123" value="a1b2c3d4e5f60718" package="com.example.one" />
  <setting id="3" name="10124" value="b2c3d4e5f6071829" package="com.example.two" />
  <setting id="4" name="10125" value="c3d4e5f607182930" package="com.bank.app" />
</settings>
EOF
}

pa() { COHERENCE_CONF="$CONF" COHERENCE_SSAID_XML="$SSAID" PATH="$STUB:$PATH" sh "$SCRIPT" "$@" 2>&1; }
parc() { pa "$@" >/dev/null 2>&1; echo $?; }

echo "== display =="
rm -f "$WORK/no-override"
out="$(pa display)"
printf '%s' "$out" | grep -q 'override активен' && ok "override обнаружен" || bad "override не обнаружен"
printf '%s' "$out" | grep -q 'getPhysicalWidth' && ok "объяснено, как это вскрывается" || bad "нет объяснения"
[ "$(parc display)" != "0" ] && ok "ненулевой код при активном override" || bad "код 0 при активном override"

: > "$LOGF"
pa display --apply >/dev/null 2>&1
grep -q 'wm size reset' "$LOGF" && ok "--apply вызывает wm size reset" || bad "wm size reset не вызван"
grep -q 'wm density reset' "$LOGF" && ok "--apply вызывает wm density reset" || bad "wm density reset не вызван"
out="$(pa display)"
printf '%s' "$out" | grep -q 'override нет' && ok "после сброса override отсутствует" || bad "override остался"

echo
echo "== adid =="
out="$(pa adid)"
printf '%s' "$out" | grep -q '32 бита' && ok "объяснён вес рекламного ID" || bad "нет объяснения веса"
printf '%s' "$out" | grep -q 'сам по себе метка' && ok "честная оговорка про обнулённый ID" || bad "нет оговорки"
: > "$LOGF"; pa adid --open >/dev/null 2>&1
grep -q 'am start' "$LOGF" && ok "--open открывает настройки" || bad "настройки не открыты"

echo
echo "== ssaid list =="
mk_ssaid
out="$(pa ssaid list)"
printf '%s' "$out" | grep -q 'com.example.one' && ok "перечисляет пакеты" || bad "пакеты не перечислены"

echo
echo "== ssaid: пробный прогон ничего не меняет =="
mk_ssaid; before="$(md5sum "$SSAID" | cut -d' ' -f1)"
out="$(pa ssaid com.example.one)"
after="$(md5sum "$SSAID" | cut -d' ' -f1)"
[ "$before" = "$after" ] && ok "файл не изменён без --apply" || bad "файл изменён в пробном прогоне"
printf '%s' "$out" | grep -q 'пробный прогон' && ok "сказано, что это пробный прогон" || bad "не сказано про пробный прогон"
printf '%s' "$out" | grep -q 'разлогинит' && ok "предупреждение о разлогине" || bad "нет предупреждения"

echo
echo "== ssaid: удаление одного пакета =="
mk_ssaid; : > "$LOGF"
pa ssaid com.example.one --apply >/dev/null 2>&1
grep -q 'com.example.one' "$SSAID" && bad "запись не удалена" || ok "запись удалена"
grep -q 'com.example.two' "$SSAID" && ok "прочие записи сохранены" || bad "удалены лишние записи"
grep -q '</settings>' "$SSAID" && ok "XML остался закрытым" || bad "корневой элемент потерян"
ls "$CONF/backup"/settings_ssaid.xml.* >/dev/null 2>&1 && ok "резервная копия создана" || bad "резервной копии нет"
grep -q '^stop$' "$LOGF" && ok "фреймворк остановлен перед правкой" || bad "фреймворк не остановлен"
grep -q '^start$' "$LOGF" && ok "фреймворк запущен обратно" || bad "фреймворк не запущен"
grep -q 'restorecon' "$LOGF" && ok "контекст SELinux восстановлен" || bad "restorecon не вызван"

echo
echo "== ssaid --all: userkey сохраняется =="
mk_ssaid
pa ssaid --all --apply >/dev/null 2>&1
grep -q 'name="userkey"' "$SSAID" && ok "запись userkey не удалена" || bad "userkey удалён — из него выводятся остальные значения"
grep -q 'package="com.bank.app"' "$SSAID" && bad "записи приложений остались" || ok "записи приложений удалены"
grep -q '</settings>' "$SSAID" && ok "XML цел" || bad "XML повреждён"

echo
echo "== ssaid: отказ при неожиданной структуре =="
cat > "$SSAID" <<'EOF'
<settings version="1">
  <setting id="2" package="com.example.one">
    <value>a1b2c3d4</value>
  </setting>
</settings>
EOF
before="$(md5sum "$SSAID" | cut -d' ' -f1)"
out="$(pa ssaid com.example.one --apply)"
after="$(md5sum "$SSAID" | cut -d' ' -f1)"
[ "$before" = "$after" ] && ok "файл с не-самозакрытыми элементами не тронут" || bad "файл изменён при неожиданной структуре"
printf '%s' "$out" | grep -q 'Ничего не сделано' && ok "отказ объяснён" || bad "отказ не объяснён"

echo
echo "== ssaid: нет совпадений =="
mk_ssaid
[ "$(parc ssaid com.nonexistent.app --apply)" != "0" ] && ok "отсутствующий пакет -> ошибка" || bad "отсутствующий пакет принят"
# Считаем по '<setting' + пробел: корневой тег <settings ...> содержит
# ту же подстроку и испортил бы счёт (ровно этот баг был в самом скрипте).
[ "$(grep -cE '<setting[[:space:]]' "$SSAID")" = "4" ] && ok "файл не тронут" || bad "файл изменён"

echo
echo "== audit =="
mkdir -p "$WORK/fakemods/mod-a" "$WORK/fakemods/mod-b"
out="$(pa audit)"
printf '%s' "$out" | grep -q 'Transsion' && ok "audit упоминает вендорные свойства" || bad "нет раздела вендорных свойств"
printf '%s' "$out" | grep -q '__system_property_foreach' && ok "объяснён механизм обхода свойств" || bad "механизм не объяснён"

echo
echo "== status =="
out="$(pa status)"
printf '%s' "$out" | grep -q '2-4 бита' && ok "status честно оценивает подмену Build.*" || bad "нет честной оценки"
printf '%s' "$out" | grep -q '\[1\] Рекламный ID' && ok "рекламный ID на первом месте" || bad "приоритет не тот"

echo
echo "== боевая безопасность =="
grep -qE 'post-fs-data|service\.sh' "$SCRIPT" && bad "инструмент ссылается на загрузочные стадии" || ok "не связан с загрузкой"
[ "$(parc bogus)" != "0" ] && ok "неизвестная команда -> ошибка" || bad "неизвестная команда принята"

printf '\nПройдено: %d, провалено: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
