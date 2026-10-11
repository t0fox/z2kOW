#!/bin/sh
# Сохранить прежнее имя набора; проверки используют адаптер на базе dnsproxy.
exec sh "$(dirname "$0")/test_ow_dnsproxy.sh" "$@"
