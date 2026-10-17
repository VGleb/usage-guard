#!/bin/bash
# SessionStart: держит симлинк <cfg>/usage-statusline.sh на актуальную копию скрипта в плагине
# (путь плагина содержит версию и меняется при обновлении, а statusLine в settings.json нужен стабильный).
# Без jq защита не работает – предупреждаем в начале сессии.
command -v jq >/dev/null || echo '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"usage-guard: jq не найден, защита от лимитов не работает (brew install jq)."}}'
[ -n "$CLAUDE_PLUGIN_ROOT" ] || exit 0
cfg=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
src="$CLAUDE_PLUGIN_ROOT/scripts/statusline.sh"
dst="$cfg/usage-statusline.sh"
[ "$(readlink "$dst" 2>/dev/null)" = "$src" ] && exit 0
mkdir -p "$cfg" && ln -s "$src" "$dst.$$" && mv -f "$dst.$$" "$dst" || rm -f "$dst.$$"
exit 0
