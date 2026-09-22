#!/system/bin/sh
#
# uninstall.sh — вызывается Magisk при удалении модуля.
#
# Снимаем только рабочее состояние. Снимок исходных свойств и журнал
# остаются в /data/adb/coherence намеренно: если что-то пошло не так,
# именно они нужны для разбора, а удаление модуля — типичный первый шаг
# при разборе. Удалить полностью: rm -rf /data/adb/coherence

CONF=${COHERENCE_CONF:-/data/adb/coherence}
rm -f "$CONF/pending-boot" "$CONF/strikes" 2>/dev/null
exit 0
