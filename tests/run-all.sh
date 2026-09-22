#!/usr/bin/env bash
# Прогоняет все тесты. Ни один не требует устройства.
set -uo pipefail
cd "$(dirname "$0")"
RC=0
for t in test-*.sh; do
    printf '\n\033[1m--- %s ---\033[0m\n' "$t"
    bash "$t" || RC=1
done
printf '\n'
[ $RC -eq 0 ] && echo "ВСЕ ТЕСТЫ ПРОЙДЕНЫ" || echo "ЕСТЬ ПАДЕНИЯ"
exit $RC
