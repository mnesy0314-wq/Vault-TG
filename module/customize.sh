#!/system/bin/sh
#
# customize.sh — выполняется установщиком Magisk один раз, при установке.
# После установки удаляется, так что библиотекой времени выполнения быть
# не может. Доступны: MODPATH, TMPDIR, ARCH, API, IS64BIT, BOOTMODE,
# ui_print, abort, set_perm, set_perm_recursive.
#
# Задача: не пустить модуль на устройство, где он сломает загрузку, и
# снять снимок исходных свойств ДО того, как что-либо изменится.

SKIPUNZIP=0
CONF=/data/adb/coherence

ui_print ""
ui_print "  Coherence - device identity"
ui_print "  ============================"
ui_print ""

# --- Предполётные проверки --------------------------------------------------

# Установка из recovery не годится: конфигурация живёт в /data, а в recovery
# раздел может быть не смонтирован или зашифрован.
if [ "$BOOTMODE" != "true" ]; then
    abort "  ! Ставить только из приложения Magisk, не из recovery."
fi

# resetprop нужен инструментам модуля. system.prop свойства применит и без
# него, но spoofctl без resetprop бесполезен.
if ! command -v resetprop >/dev/null 2>&1 && [ ! -x /data/adb/magisk/resetprop ]; then
    ui_print "  ! resetprop не найден в PATH."
    ui_print "    Свойства применятся через system.prop, но диагностика"
    ui_print "    (spoofctl status) работать не будет."
fi

# Android Go и мало памяти — это не препятствие, но пользователь должен
# понимать, что класс устройства подменой не скрывается.
LOW_RAM="$(getprop ro.config.low_ram)"
PLATFORM="$(getprop ro.board.platform)"
SOC="$(getprop ro.soc.model)"
MEM="$(grep -i '^MemTotal' /proc/meminfo 2>/dev/null | awk '{print $2}')"

ui_print "  Устройство:"
ui_print "    модель     : $(getprop ro.product.model)"
ui_print "    платформа  : $PLATFORM"
ui_print "    SoC        : $SOC $(getprop ro.soc.manufacturer)"
ui_print "    Android    : $(getprop ro.build.version.release) (SDK $API)"
ui_print "    память     : ${MEM} kB   low_ram=$LOW_RAM"
ui_print ""

# --- Снимок исходного состояния ---------------------------------------------
#
# Делается ДО любых изменений. Единственный источник правды для отката,
# если что-то пойдёт не так.

mkdir -p "$CONF" 2>/dev/null
chmod 700 "$CONF" 2>/dev/null

if [ ! -f "$CONF/baseline.prop" ]; then
    getprop > "$CONF/baseline.prop" 2>/dev/null
    chmod 600 "$CONF/baseline.prop" 2>/dev/null
    ui_print "  + снимок исходных свойств: $CONF/baseline.prop"
    ui_print "    ($(grep -c . "$CONF/baseline.prop" 2>/dev/null) строк)"
else
    ui_print "  = снимок уже существует, оставлен как есть"
    ui_print "    (перезапись стёрла бы настоящие исходные значения)"
fi

# Модуль ставится ИНЕРТНЫМ. Профиля нет, system.prop нет, свойства не
# меняются. Это намеренно: профиль по умолчанию, одинаковый у всех
# пользователей модуля, создал бы когорту "пользователи этого модуля" -
# маленькую и коррелирующую с root, то есть новый идентификатор.
rm -f "$MODPATH/system.prop" 2>/dev/null

set_perm_recursive "$MODPATH" 0 0 0755 0644
for s in post-fs-data.sh service.sh uninstall.sh; do
    [ -f "$MODPATH/$s" ] && set_perm "$MODPATH/$s" 0 0 0755
done
[ -f "$MODPATH/system/bin/spoofctl" ] && set_perm "$MODPATH/system/bin/spoofctl" 0 0 0755

# --- Что дальше -------------------------------------------------------------

ui_print ""
ui_print "  Модуль установлен ПУСТЫМ - профиля нет, свойства не изменены."
ui_print ""
ui_print "  Сначала, до всякой подмены:"
ui_print "     wm size reset && wm density reset"
ui_print "  Активный override экрана выдаёт устройство сильнее модели."
ui_print ""
ui_print "  Затем:"
ui_print "     spoofctl status         - что видно сейчас"
ui_print "     spoofctl import <файл>  - проверить и принять профиль"
ui_print "     spoofctl apply          - применить (нужна перезагрузка)"
ui_print "     spoofctl revert         - снять профиль"
ui_print ""
ui_print "  Если телефон не загрузится:"
ui_print "    модуль сам отключится после ДВУХ незавершённых загрузок подряд."
ui_print "    Принудительно: держи Volume Down с самого начала загрузки,"
ui_print "    ДО заставки - Magisk стартует раньше, чем появляется анимация."
ui_print "    С компьютера: adb wait-for-device shell magisk --remove-modules"
ui_print "    Компьютер должен быть авторизован в adb ЗАРАНЕЕ."
ui_print ""
ui_print "  Прочти README: Build.* стоит единицы бит против реального"
ui_print "  трекинга. Рекламный ID и SSAID весят несопоставимо больше."
ui_print ""
