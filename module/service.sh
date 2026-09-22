#!/system/bin/sh
#
# service.sh — стадия late_start, уже после zygote.
#
# ЗДЕСЬ НЕЛЬЗЯ ПИСАТЬ СВОЙСТВА ИДЕНТИЧНОСТИ. android.os.Build и
# android.os.Build$VERSION входят в preloaded-classes: zygote выполняет их
# статические инициализаторы один раз при старте, и каждое приложение
# наследует замороженные значения через copy-on-write. Свойство, записанное
# на этой стадии, даст getprop одно, а Build.MODEL другое — расхождение,
# которое само по себе является признаком подмены.
#
# Единственная задача: снять маркер сторожа, когда загрузка дошла до конца.

MODDIR=${0%/*}
CONF=${COHERENCE_CONF:-/data/adb/coherence}
MARKER="$CONF/pending-boot"
STRIKES="$CONF/strikes"
LOG="$CONF/boot.log"

[ -f "$MODDIR/system.prop" ] || exit 0

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)] $1" >> "$LOG" 2>/dev/null; }

# Ждём окончания загрузки. resetprop -w блокируется до изменения свойства
# (Magisk v27+). Если флага нет — ограниченный опрос, не бесконечный:
# стадия неблокирующая, но висеть вечно всё равно незачем.
if ! resetprop -w sys.boot_completed 0 >/dev/null 2>&1; then
    i=0
    while [ "$(getprop sys.boot_completed)" != "1" ] && [ "$i" -lt 120 ]; do
        sleep 1
        i=$((i + 1))
    done
fi

if [ "$(getprop sys.boot_completed)" = "1" ]; then
    rm -f "$MARKER" 2>/dev/null
    echo 0 > "$STRIKES" 2>/dev/null
    log "загрузка завершена, счётчик нарушений сброшен"
fi
exit 0
