#!/system/bin/sh
#
# privacy-actions.sh — то, что реально мешает отслеживанию.
#
# Запускается ЯВНО и никогда не подключается к загрузке. Причина конкретная:
# сторож модуля умеет откатывать свойства, потому что свойства живут в
# памяти и исчезают при загрузке без модуля. Повреждённый файл в /data он
# откатить не может. Битый settings_ssaid.xml роняет system_server
# исключением при чтении — телефон уходит в цикл загрузки, и отключение
# модуля ЕГО НЕ ЧИНИТ. Это худшее из возможных состояний: очевидное
# средство спасения выглядит как неработающее.
#
# Порядок по убыванию отдачи (из исследования):
#   1. удалить рекламный ID        — он один весит ~32 бита
#   2. сбросить override экрана    — бесплатно, сейчас самый заметный признак
#   3. рандомизировать SSAID       — переживает переустановку приложения
#   4. аудит утечек через свойства — чужие модули светят debug.*
#
# Подмена Build.* не входит в этот список. Она стоит 2–4 бита.

set -u

CONF="${COHERENCE_CONF:-/data/adb/coherence}"
BACKUP="$CONF/backup"
SSAID_XML="${COHERENCE_SSAID_XML:-/data/system/users/0/settings_ssaid.xml}"

RED=''; GRN=''; YLW=''; RST=''
if [ -t 1 ]; then RED=$(printf '\033[31m'); GRN=$(printf '\033[32m'); YLW=$(printf '\033[33m'); RST=$(printf '\033[0m'); fi
err()  { echo "${RED}✗${RST} $1"; }
good() { echo "${GRN}✓${RST} $1"; }
warn() { echo "${YLW}!${RST} $1"; }

need_root() {
    [ "$(id -u 2>/dev/null)" = "0" ] || { err "нужен root"; exit 1; }
}

# ------------------------------------------------------------- 1. экран ---

pa_display() {
    _pa_ov_s="$(wm size 2>/dev/null | sed -n 's/.*Override size: *\([0-9]*x[0-9]*\).*/\1/p' | head -1)"
    _pa_ov_d="$(wm density 2>/dev/null | sed -n 's/.*Override density: *\([0-9]*\).*/\1/p' | head -1)"
    _pa_ph_s="$(wm size 2>/dev/null | sed -n 's/^Physical size: *\([0-9]*x[0-9]*\).*/\1/p' | head -1)"
    _pa_ph_d="$(wm density 2>/dev/null | sed -n 's/^Physical density: *\([0-9]*\).*/\1/p' | head -1)"

    echo "Экран"
    echo "  физический : $_pa_ph_s @ $_pa_ph_d dpi"
    if [ -z "$_pa_ov_s" ] && [ -z "$_pa_ov_d" ]; then
        good "override нет — приложения видят настоящую панель"
        return 0
    fi

    echo "  override   : ${_pa_ov_s:-нет} @ ${_pa_ov_d:-нет} dpi"
    echo
    err "override активен"
    echo "  DisplayMetrics отдаёт приложению override, а"
    echo "  Display.getMode().getPhysicalWidth/Height() — физические пиксели."
    echo "  wm их НЕ подменяет (LogicalDisplay копирует только логический размер),"
    echo "  поэтому приложение видит расхождение и понимает, что запускали wm size."
    echo "  Такого разрешения нет ни у одного серийного телефона."
    echo
    if [ "${1:-}" = "--apply" ]; then
        need_root
        wm size reset 2>/dev/null && wm density reset 2>/dev/null
        good "сброшено"
        echo "  проверь: wm size && wm density"
    else
        echo "  Исправить:  $0 display --apply"
        echo "  Или вручную: wm size reset && wm density reset"
    fi
    return 1
}

# --------------------------------------------------------- 2. рекламный ID ---

pa_adid() {
    echo "Рекламный идентификатор (GAID)"
    echo
    echo "  Это единственный идентификатор, который сам по себе даёт"
    echo "  ~32 бита — ровно столько, сколько нужно, чтобы выделить один"
    echo "  телефон из всех. Он переживает переустановку приложения, и SDK"
    echo "  отправляют его В ТОМ ЖЕ пакете, где и Build.MODEL. Поэтому"
    echo "  подмена модели не разрывает связку: первичный ключ не изменился."
    echo
    echo "  С Android 12 удаление обнуляет его для всех вызывающих, а не"
    echo "  выдаёт новый."
    echo
    echo "  Настройки -> Безопасность и конфиденциальность -> Ещё ->"
    echo "  Реклама -> Удалить рекламный идентификатор"
    echo
    if [ "${1:-}" = "--open" ]; then
        if am start -a com.google.android.gms.settings.ADS_PRIVACY >/dev/null 2>&1; then
            good "открыл настройки рекламы"
        elif am start -n com.google.android.gms/.ads.settings.AdsSettingsActivity >/dev/null 2>&1; then
            good "открыл настройки рекламы (запасной путь)"
        else
            warn "не удалось открыть автоматически — пройди путь выше руками"
        fi
    else
        echo "  Открыть:  $0 adid --open"
    fi
    echo
    warn "честная оговорка: обнулённый рекламный ID сам по себе метка"
    echo "  (так сделали не все). Но обменять 32 бита на 2-6 — выгодно."
}

# --------------------------------------------------------------- 3. SSAID ---
#
# Settings.Secure.ANDROID_ID. С Android 8 он свой у каждого приложения:
# привязан к (устройство, ключ подписи, пользователь). Переживает удаление
# и переустановку приложения, и без root не сбрасывается ничем, кроме
# сброса к заводским настройкам.
#
# Работаем ТОЛЬКО удалением целых самозакрытых строк <setting ... />.
# Значения не переписываем. Так структурная целостность XML сохраняется
# по построению: удаление целого элемента не может сделать документ
# невалидным, а правка значения — может.

# Совпадает ли строка с записью SSAID приложения.
#
# Условия намеренно раздельные:
#   '<setting' + пробел  — отсекает корневой тег <settings ...>
#   package="..."        — только записи, привязанные к приложению
#   не name="userkey"    — эта запись не про приложение, а ключ, из
#                          которого SettingsProvider выводит остальные
#                          значения. Её удаление затрагивает всё сразу.
#
# Сопоставление имени пакета делается через index(), а не регулярным
# выражением: в именах пакетов есть точки, и как регулярка 'com.bank.app'
# совпала бы с 'comXbankYapp'.
SSAID_AWK_ENTRY='/<setting[ \t]/ && /package="/ && !/name="userkey"/'

ssaid_count_entries() {
    awk '/<setting[ \t]/ {n++} END{print n+0}' "$1"
}

ssaid_match_count() {
    if [ "$2" = "--all" ]; then
        awk '/<setting[ \t]/ && /package="/ && !/name="userkey"/ {n++} END{print n+0}' "$1"
    else
        awk -v pkg="$2" '/<setting[ \t]/ && index($0, "package=\"" pkg "\"") {n++} END{print n+0}' "$1"
    fi
}

# Печатает строки, которые надо СОХРАНИТЬ.
ssaid_filter() {
    if [ "$2" = "--all" ]; then
        awk '/<setting[ \t]/ && /package="/ && !/name="userkey"/ {next} {print}' "$1"
    else
        awk -v pkg="$2" '/<setting[ \t]/ && index($0, "package=\"" pkg "\"") {next} {print}' "$1"
    fi
}

pa_ssaid_list() {
    [ -f "$SSAID_XML" ] || { err "нет $SSAID_XML"; return 1; }
    echo "Записи SSAID в $SSAID_XML"
    echo
    grep -o 'package="[^"]*"' "$SSAID_XML" 2>/dev/null | sed 's/package="//; s/"//' \
        | sort -u | sed 's/^/  /'
    echo
    echo "  всего: $(ssaid_count_entries "$SSAID_XML")"
}

pa_ssaid_reset() {
    need_root
    _pa_target="${1:-}"
    _pa_apply="${2:-}"

    [ -f "$SSAID_XML" ] || { err "нет $SSAID_XML"; return 1; }
    [ -n "$_pa_target" ] || { err "укажи пакет или --all"; return 1; }

    # Структурная проверка: работаем только с файлом, где каждый элемент
    # <setting> самозакрыт. Иначе удаление строк может порвать документ.
    #
    # Считаем по '<setting' + пробельный символ: подстрока '<setting'
    # входит и в корневой тег '<settings version="1">', из-за чего
    # наивный счётчик даёт на единицу больше и бракует нормальный файл.
    _pa_settings="$(ssaid_count_entries "$SSAID_XML")"
    _pa_selfclosed="$(awk '/<setting[ \t]/ && /\/>/ {n++} END{print n+0}' "$SSAID_XML")"
    if [ "$_pa_settings" != "$_pa_selfclosed" ]; then
        err "неожиданная структура: $_pa_settings элементов <setting>, самозакрытых $_pa_selfclosed"
        echo "  Безопасное удаление строк здесь неприменимо. Ничего не сделано."
        return 1
    fi

    if [ "$_pa_target" = "--all" ]; then
        _pa_desc="все приложения"
    else
        _pa_desc="$_pa_target"
    fi

    _pa_n="$(ssaid_match_count "$SSAID_XML" "$_pa_target")"
    [ "$_pa_n" -gt 0 ] 2>/dev/null || { warn "совпадений нет: $_pa_desc"; return 1; }

    echo "SSAID: $_pa_desc — под удаление попадает записей: $_pa_n"
    echo
    echo "  После удаления SettingsProvider выдаст приложению новое значение"
    echo "  при следующем запросе — для приложения это выглядит как установка"
    echo "  на новом устройстве."
    echo
    warn "это разлогинит приложения, привязывающие сессию или лицензию к ANDROID_ID"

    if [ "$_pa_apply" != "--apply" ]; then
        echo
        echo "  Это пробный прогон. Выполнить:  $0 ssaid $_pa_target --apply"
        return 0
    fi

    mkdir -p "$BACKUP" 2>/dev/null; chmod 700 "$BACKUP" 2>/dev/null
    _pa_stamp="$(date '+%Y%m%d-%H%M%S' 2>/dev/null || echo manual)"
    _pa_bak="$BACKUP/settings_ssaid.xml.$_pa_stamp"
    cp "$SSAID_XML" "$_pa_bak" || { err "не удалось сделать резервную копию"; return 1; }
    good "резервная копия: $_pa_bak"

    # Фреймворк держит настройки в памяти и перезапишет файл при выходе,
    # поэтому его надо остановить до правки.
    echo "  останавливаю фреймворк…"
    stop 2>/dev/null

    _pa_tmp="$SSAID_XML.new"
    ssaid_filter "$SSAID_XML" "$_pa_target" > "$_pa_tmp" 2>/dev/null

    # Проверяем результат до подмены: корень на месте, файл не пуст.
    if [ ! -s "$_pa_tmp" ] || ! grep -q '</settings>' "$_pa_tmp"; then
        err "результат выглядит повреждённым — откатываю, ничего не меняю"
        rm -f "$_pa_tmp"
        start 2>/dev/null
        return 1
    fi

    # Права и владельца сохраняем: SettingsProvider не прочитает чужой файл.
    _pa_owner="$(stat -c '%u:%g' "$SSAID_XML" 2>/dev/null)"
    mv "$_pa_tmp" "$SSAID_XML"
    [ -n "$_pa_owner" ] && chown "$_pa_owner" "$SSAID_XML" 2>/dev/null
    chmod 600 "$SSAID_XML" 2>/dev/null
    restorecon "$SSAID_XML" 2>/dev/null

    good "удалено записей: $_pa_n"
    echo "  запускаю фреймворк…"
    start 2>/dev/null
    echo
    echo "  Если что-то пойдёт не так:"
    echo "    stop && cp '$_pa_bak' '$SSAID_XML' && restorecon '$SSAID_XML' && start"
}

# ---------------------------------------------------------------- 4. аудит ---

pa_audit() {
    echo "Аудит утечек через пространство свойств"
    echo
    echo "  Любое приложение может обойти всё пространство свойств через"
    echo "  __system_property_foreach(). Необычный набор читается как"
    echo "  «устройство с root и твиками» — это работает против смешивания"
    echo "  с толпой и не даёт приватности."
    echo

    _pa_dbg="$(getprop 2>/dev/null | grep -cE '^\[(debug|ro\.surface_flinger)\.')"
    echo "  свойств debug.* / ro.surface_flinger.* : $_pa_dbg"
    [ "$_pa_dbg" -gt 0 ] && getprop 2>/dev/null | grep -E '^\[(debug|ro\.surface_flinger)\.' | head -12 | sed 's/^/    /'

    _pa_tran="$(getprop 2>/dev/null | grep -cE '^\[ro\.(os_|tran|itel_style\.)')"
    echo
    echo "  вендорных свойств Transsion (ro.os_*, ro.tran*, ro.itel_style.*) : $_pa_tran"
    echo "    Они выдают Transsion независимо от ro.product.*. Кросс-брендовый"
    echo "    профиль без их зачистки — это полумаскировка, которая заметнее"
    echo "    честной строки TECNO."

    echo
    echo "  установленные модули Magisk:"
    for _pa_m in /data/adb/modules/*/; do
        [ -d "$_pa_m" ] || continue
        _pa_id="$(basename "$_pa_m")"
        if [ -f "$_pa_m/disable" ]; then
            echo "    - $_pa_id (отключён)"
        else
            echo "    - $_pa_id"
        fi
    done
    echo
    echo "    Модули, меняющие свойства графики или планировщика, добавляют"
    echo "    редкие значения в общее пространство. hosts и zygisk безвредны."
}

# ---------------------------------------------------------------- сводка ---

pa_status() {
    echo "======================================================"
    echo " Приватность: что стоит сделать, по убыванию отдачи"
    echo "======================================================"
    echo
    echo "[1] Рекламный ID — ~32 бита, столько же, сколько весь остальной"
    echo "    отпечаток вместе взятый."
    echo "    $0 adid --open"
    echo
    echo "[2] Override экрана"
    pa_display >/dev/null 2>&1 && echo "    ✓ уже в порядке" || echo "    ✗ активен — $0 display --apply"
    echo
    echo "[3] SSAID — переживает переустановку приложения."
    if [ -f "$SSAID_XML" ]; then
        echo "    записей: $(ssaid_count_entries "$SSAID_XML")"
        echo "    $0 ssaid --all           (пробный прогон)"
    else
        echo "    файл недоступен (нужен root)"
    fi
    echo
    echo "[4] Аудит свойств:  $0 audit"
    echo
    echo "[-] Подмена Build.* — 2-4 бита. Делай после пунктов выше, не вместо."
    echo
}

usage() {
    cat <<'EOF'
privacy-actions.sh — меры против отслеживания, по убыванию отдачи

  status                     что стоит сделать (начни отсюда)
  adid [--open]              рекламный ID: объяснение и переход в настройки
  display [--apply]          проверить/сбросить override экрана
  ssaid list                 показать приложения с записью SSAID
  ssaid <пакет> [--apply]    сбросить SSAID одного приложения
  ssaid --all [--apply]      сбросить SSAID всех приложений
  audit                      утечки через пространство свойств и модули

Без --apply всё работает как пробный прогон.
Перед правкой SSAID делается резервная копия в /data/adb/coherence/backup.

Этот инструмент НЕ подключается к загрузке намеренно: повреждённый
settings_ssaid.xml роняет system_server, и отключение модуля это не чинит.
EOF
}

case "${1:-}" in
    status)  shift; pa_status "$@" ;;
    adid)    shift; pa_adid "$@" ;;
    display) shift; pa_display "$@" ;;
    audit)   shift; pa_audit "$@" ;;
    ssaid)
        shift
        case "${1:-}" in
            list|'') pa_ssaid_list ;;
            *)       pa_ssaid_reset "$@" ;;
        esac ;;
    ''|-h|--help|help) usage ;;
    *) err "неизвестная команда: $1"; echo; usage; exit 2 ;;
esac
