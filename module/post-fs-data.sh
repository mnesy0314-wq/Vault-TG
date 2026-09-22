#!/system/bin/sh
#
# post-fs-data.sh — ТОЛЬКО сторож. Свойства здесь не пишутся.
#
# Почему свойства не здесь. Magisk на каждой загрузке выполняет:
#
#     collect_modules(false)
#       -> exec_module_scripts("post-fs-data")   <- мы здесь
#     collect_modules(true)                      <- перечитывает файл disable
#       -> apply_modules                         <- читает system.prop
#
# Проверка файла `disable` живёт в collect_modules, а загрузка system.prop —
# в apply_modules. Значит `touch $MODDIR/disable` из этого скрипта отменяет
# применение свойств НА ЭТОЙ ЖЕ загрузке. Если бы свойства писал resetprop
# прямо отсюда, сторожу было бы нечего отменять — записи уже произошли бы.
#
# Ограничения этой стадии, нарушать нельзя:
#   * стадия блокирующая, общий бюджет 35 с (POST_FS_DATA_SCRIPT_MAX_TIME)
#     на /data/adb/post-fs-data.d/* и скрипты ВСЕХ модулей. Переполнение не
#     прерывает загрузку, а молча переводит остаток в неблокирующий режим:
#     свойства приедут после zygote и подмена применится наполовину, без
#     единой ошибки. Поэтому здесь нет ни sleep, ни циклов, ни сети.
#   * setprop вызывать нельзя — property_service init'а заблокирован на
#     триггере post-fs-data, будет взаимоблокировка.
#   * ui_print, abort, MODPATH, ARCH, API недоступны — это не customize.sh.

MODDIR=${0%/*}

# Пути вынесены в переменные ТОЛЬКО ради тестируемости: логика сторожа
# решает, загрузится телефон или нет, и обязана проверяться автотестами,
# а не глазами. В реальной загрузке Magisk этих переменных нет и
# подставляются значения по умолчанию.
CONF=${COHERENCE_CONF:-/data/adb/coherence}
BOOT_ID_FILE=${COHERENCE_BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}
LOG="$CONF/boot.log"
MARKER="$CONF/pending-boot"
STRIKES="$CONF/strikes"

# Профиль не применён — модуль инертен, сторожить нечего.
[ -f "$MODDIR/system.prop" ] || exit 0

[ -d "$CONF" ] || mkdir -p "$CONF" 2>/dev/null
chmod 700 "$CONF" 2>/dev/null

# Журнал ограничен по размеру: раздел /data не должен расти из-за модуля.
if [ -f "$LOG" ] && [ "$(wc -c <"$LOG" 2>/dev/null || echo 0)" -gt 65536 ]; then
    tail -c 16384 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG" 2>/dev/null
fi

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)] $1" >> "$LOG" 2>/dev/null; }

# Идентификатор загрузки. Ядро выдаёт новый UUID на каждую загрузку, так что
# маркер, оставшийся от прошлой, отличим от только что созданного.
BOOT_ID="$(cat "$BOOT_ID_FILE" 2>/dev/null || echo unknown)"

if [ -f "$MARKER" ]; then
    # Маркер прошлой загрузки уцелел: service.sh его не снял, то есть
    # sys.boot_completed не наступил. Загрузка не дошла до конца.
    OLD="$(cat "$MARKER" 2>/dev/null)"
    N="$(cat "$STRIKES" 2>/dev/null || echo 0)"
    case "$N" in ''|*[!0-9]*) N=0 ;; esac
    N=$((N + 1))
    echo "$N" > "$STRIKES" 2>/dev/null

    log "загрузка не завершилась (маркер от $OLD), нарушение $N из 2"

    if [ "$N" -ge 2 ]; then
        # Второе подряд. Отключаем себя до того, как apply_modules
        # прочитает system.prop на этой же загрузке.
        : > "$MODDIR/disable" 2>/dev/null
        log "МОДУЛЬ ОТКЛЮЧЁН: две незавершённые загрузки подряд."
        log "Свойства на этой загрузке не применяются. Профиль остался в $CONF,"
        log "разбор: spoofctl status. Включить обратно — в приложении Magisk."
        rm -f "$MARKER" 2>/dev/null
        exit 0
    fi
fi

# Ставим маркер текущей загрузки. Снимет его service.sh после boot_completed.
echo "$BOOT_ID" > "$MARKER" 2>/dev/null

# Запись на каждой загрузке, а не только при сбое: без неё журнала аудита
# при штатной работе не существует, и разбирать нечего именно тогда, когда
# разбор нужен — когда пользователь не уверен, применился профиль или нет.
log "загрузка начата, профиль активен (нарушений подряд: $(cat "$STRIKES" 2>/dev/null || echo 0))"
exit 0
