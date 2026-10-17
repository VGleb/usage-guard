#!/bin/bash
# SessionStart / SessionEnd.
# 1. Держит копию статус-строки по стабильному пути <cfg>/usage-statusline.sh: путь плагина содержит версию,
#    а старый каталог версии удаляется после обновления – симлинк на него повис бы, копия не виснет.
# 2. Переносит порог сессии через /clear: у очищенной сессии новый session_id, и без переноса защита
#    молча выключилась бы. SessionEnd(clear) откладывает порог, SessionStart(clear) в течение минуты забирает.
# 3. Без jq защита не работает – предупреждает в начале сессии.
umask 077
cfg=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
dir=${USAGE_GUARD_STATE_DIR:-$cfg/state}
in=$(</dev/stdin)
ev=; [[ $in =~ \"hook_event_name\"[[:space:]]*:[[:space:]]*\"([A-Za-z]+)\" ]] && ev=${BASH_REMATCH[1]}
why=; [[ $in =~ \"(source|reason)\"[[:space:]]*:[[:space:]]*\"([a-z_]+)\" ]] && why=${BASH_REMATCH[2]}
sid=; [[ $in =~ \"session_id\"[[:space:]]*:[[:space:]]*\"([A-Za-z0-9_-]+)\" ]] && sid=${BASH_REMATCH[1]:0:100}
pend="$dir/ug-limit-pending-clear.json"
if [ "$ev" = SessionEnd ]; then
  [ "$why" = clear ] && [ -n "$sid" ] && [ -f "$dir/ug-limit-$sid.json" ] &&
    mv -f "$dir/ug-limit-$sid.json" "$pend" 2>/dev/null && touch "$pend"
  exit 0
fi
command -v jq >/dev/null || echo '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"usage-guard: jq не найден, защита от лимитов не работает (brew install jq)."}}'
if [ "$why" = clear ] && [ -n "$sid" ] && [ -f "$pend" ] && [ -n "$(find "$pend" -mmin -1 2>/dev/null)" ]; then
  mv -f "$pend" "$dir/ug-limit-$sid.json" 2>/dev/null
fi
[ -n "$CLAUDE_PLUGIN_ROOT" ] || exit 0
src="$CLAUDE_PLUGIN_ROOT/scripts/statusline.sh"
dst="$cfg/usage-statusline.sh"
[ -f "$src" ] || exit 0
[ -f "$dst" ] && [ ! -L "$dst" ] && cmp -s "$src" "$dst" && exit 0
mkdir -p "$cfg" && cp "$src" "$dst.$$" && chmod 755 "$dst.$$" && mv -f "$dst.$$" "$dst" || rm -f "$dst.$$"
exit 0
