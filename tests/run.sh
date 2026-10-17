#!/bin/bash
# Тесты usage-guard. Всё в изолированном HOME. Запуск: bash tests/run.sh
D=$(cd "$(dirname "$0")/.." && pwd); SC=$D/scripts
T=$(mktemp -d); H="$T/home dir"; mkdir -p "$H/.claude" "$T/shared"
export HOME="$H"; unset USAGE_GUARD_CONFIG USAGE_GUARD_DATA USAGE_GUARD_STATE_DIR USAGE_GUARD_SHARED_DIR
cd "$H"; NOW=$(date +%s); R=$((NOW+86400)); R5=$((NOW+3600)); PASS=0; FAILN=0
SL(){ echo "{\"session_id\":\"$1\",\"model\":{\"display_name\":\"Opus\"},\"rate_limits\":{\"five_hour\":{\"used_percentage\":$3,\"resets_at\":$R5},\"seven_day\":{\"used_percentage\":$4,\"resets_at\":${5:-$R}}}}" | HOSTNAME=$2 bash $SC/statusline.sh; }
GU(){ local p='{"hook_event_name":"PostToolUse","session_id":"'$1'"'${2:+,\"agent_id\":\"$2\"}'}'; bash $SC/usage-guard.sh <<<"$p" | jq -r '.hookSpecificOutput.additionalContext // empty'; }
fmt(){ date -r "$1" "+$2" 2>/dev/null || date -d "@$1" "+$2"; }
ok(){ if [ "$1" = "$2" ]; then PASS=$((PASS+1)); else FAILN=$((FAILN+1)); echo "FAIL $3: got [$1] want [$2]"; fi; }
fire(){ [ -n "$1" ] && echo y || echo n; }
echo '{"seven_day":95}' > "$H/.claude/usage-guard.json"

ok "$(SL a mac1 29 94)" "Opus · 29% до $(fmt $R5 %H:%M) · 94% до $(fmt $R "%H:%M %d.%m")" "формат строки"
ok "$(ls "$T/shared" | wc -l | tr -d ' ')" 0 "без SHARED_DIR общий каталог не трогаем"
SL a mac1 30 95 >/dev/null; ok "$(fire "$(GU s1)")" y "95% срабатывает"; ok "$(fire "$(GU s1)")" n "повтор молчит"
SL a mac1 30 99 >/dev/null; ok "$(fire "$(GU s1)")" n "99% тот же шаг молчит"
SL a mac1 30 100 >/dev/null; ok "$(fire "$(GU s1)")" y "100% новый шаг"
SL a mac1 0 0 >/dev/null; ok "$(fire "$(GU s1)")" n "после сброса молчит"
SL a mac1 0 96 >/dev/null; ok "$(fire "$(GU s1)")" y "после сброса снова срабатывает"
ok "$(GU s1 | cut -c1-1)" "" "повтор после срабатывания молчит"

# простаивающая сессия со старыми данными не затирает свежие
rm -rf .claude/state/*; SL a mac1 0 97 >/dev/null
echo "{\"seven_day\":{\"v\":[$R,90],\"at\":$((NOW-600))}}" > .claude/state/statusline-old
SL old mac1 0 90 >/dev/null
ok "$(jq .seven_day.used_percentage .claude/rate_limits.json)" 97 "старая сессия не затирает локальный файл"

# окружение: свои пути
export USAGE_GUARD_CONFIG="$T/cfg.json" USAGE_GUARD_DATA="$T/data.json" USAGE_GUARD_STATE_DIR="$T/st"
echo '{"five_hour":50}' > "$T/cfg.json"; SL e mac1 60 1 >/dev/null
ok "$(jq .five_hour.used_percentage "$T/data.json")" 60 "USAGE_GUARD_DATA"
ok "$(fire "$(GU e1)")" y "USAGE_GUARD_CONFIG и STATE_DIR"; ok "$(ls "$T/st" | grep -c '^ug-e1$')" 1 "STATE_DIR используется"
unset USAGE_GUARD_CONFIG USAGE_GUARD_DATA USAGE_GUARD_STATE_DIR

# два компьютера через SHARED_DIR
export USAGE_GUARD_SHARED_DIR="$T/shared"; rm -f .claude/rate_limits.json; rm -rf .claude/state/*
echo "{\"seven_day\":{\"used_percentage\":10,\"resets_at\":$R,\"saved_at\":$((NOW-100))}}" > "$T/shared/rate_limits.host-mac1.json"
echo "{\"seven_day\":{\"used_percentage\":96,\"resets_at\":$R,\"saved_at\":$((NOW-5))}}" > "$T/shared/rate_limits.host-mac2.json"
ok "$(fire "$(GU m1)")" y "свежие данные другого компьютера"
cp "$T/shared/rate_limits.host-mac1.json" "$T/shared/rate_limits.host-mac1 (conflicted copy).json"
ok "$(fire "$(GU m2)")" y "конфликтная копия не мешает"; rm "$T/shared"/rate_limits.host-*
SL h mac7 1 50 >/dev/null; ok "$(ls "$T/shared")" "rate_limits.host-${USER:-u}-mac7.json" "файл компьютера в SHARED_DIR"
ok "$(echo "{\"seven_day\":{\"used_percentage\":96,\"resets_at\":$R,\"saved_at\":$((NOW+3600))}}" > "$T/shared/rate_limits.host-fut.json"; fire "$(GU m3)")" y "saved_at из будущего обрезается до now"
unset USAGE_GUARD_SHARED_DIR

# битые файлы
for bad in '{bad' 'null' '"s"' '[]' '{"seven_day":null}' '{"seven_day":{"used_percentage":"x"}}'; do
  printf '%s' "$bad" > .claude/rate_limits.json
  ok "$(SL z mac1 1 50)" "Opus · 1% до $(fmt $R5 %H:%M) · 50% до $(fmt $R "%H:%M %d.%m")" "строка при $bad"
done
printf '{bad' > .claude/usage-guard.json; ok "$(GU q1)" "" "битый порог – тишина"; echo '{"seven_day":95}' > .claude/usage-guard.json
ok "$(echo '' | bash $SC/statusline.sh)" " " "пустой stdin"
ok "$(echo '{bad' | bash $SC/statusline.sh)" "statusline: jq error" "битый stdin"
ok "$(echo '{"rate_limits":{"spend_limit":{"used_percentage":5}}}' | bash $SC/statusline.sh)" " " "без окон и модели"

# субагент
rm -rf .claude/state/ug-*; SL a mac1 0 97 >/dev/null
ok "$(GU s8 ag1 | grep -c субагент)" 1 "текст субагента"; ok "$(fire "$(GU s8 ag1)")" n "субагент: повтор молчит"; ok "$(GU s8 | grep -c CronList)" 1 "основной: про CronList"

# гонка
dbl=0; for i in $(seq 15); do rm -rf .claude/state/ug-r*; n=$( (for j in 1 2 3 4 5 6 7 8; do GU r$i & done; wait) | grep -c USAGE); [ "$n" = 1 ] || dbl=$((dbl+1)); done
ok "$dbl" 0 "параллельные хуки: ровно одно сообщение"

# выключено
rm .claude/usage-guard.json; ok "$(GU off1)" "" "нет конфига – тишина"

# симлинк статус-строки
export CLAUDE_PLUGIN_ROOT="$D"; bash $SC/link-statusline.sh; ok "$(readlink .claude/usage-statusline.sh)" "$D/scripts/statusline.sh" "симлинк создан"
export CLAUDE_PLUGIN_ROOT="$T/v2"; mkdir -p "$T/v2/scripts"; bash $SC/link-statusline.sh; ok "$(readlink .claude/usage-statusline.sh)" "$T/v2/scripts/statusline.sh" "симлинк обновлён"
unset CLAUDE_PLUGIN_ROOT; bash $SC/link-statusline.sh; ok "$?" 0 "без CLAUDE_PLUGIN_ROOT – тихо"

# сброс в прошлом игнорируется
echo '{"seven_day":95}' > .claude/usage-guard.json; rm -rf .claude/state
echo "{\"seven_day\":{\"used_percentage\":99,\"resets_at\":$((NOW-10)),\"saved_at\":$NOW}}" > .claude/rate_limits.json
ok "$(fire "$(GU st1)")" n "сброс в прошлом – тишина"
# огромный resets_at не отключает защиту и не ломает соседнее окно
echo "{\"five_hour\":{\"used_percentage\":99,\"resets_at\":1e30,\"saved_at\":$NOW},\"seven_day\":{\"used_percentage\":99,\"resets_at\":$R,\"saved_at\":$NOW}}" > .claude/rate_limits.json
ok "$(fire "$(GU st2)")" y "resets_at=1e30 игнорируется, соседнее окно работает"
# имя события
ok "$(bash $SC/usage-guard.sh <<<'{"hook_event_name":"UserPromptSubmit","session_id":"u1"}' | jq -r .hookSpecificOutput.hookEventName)" UserPromptSubmit "имя события"
# новый запрос в той же сессии напоминает снова (возобновление по cron)
GU u2 >/dev/null; ok "$(fire "$(GU u2)")" n "тот же PostToolUse молчит"
ok "$(fire "$(bash $SC/usage-guard.sh <<<'{"hook_event_name":"UserPromptSubmit","session_id":"u2"}')")" y "UserPromptSubmit напоминает заново"
# два окна выше порога – одно сообщение, время сброса последнего
echo '{"five_hour":50,"seven_day":50}' > .claude/usage-guard.json; rm -rf .claude/state
echo "{\"five_hour\":{\"used_percentage\":60,\"resets_at\":$R5,\"saved_at\":$NOW},\"seven_day\":{\"used_percentage\":70,\"resets_at\":$R,\"saved_at\":$NOW}}" > .claude/rate_limits.json
m=$(GU w1); ok "$(echo "$m" | grep -c 'five_hour 60%.*seven_day 70%')" 1 "два окна в одном сообщении"; ok "$(echo "$m" | grep -c "unix $R")" 1 "сброс последнего окна"
ok "$(fire "$(GU w1)")" n "второго сообщения нет"
# пороги вне диапазона и мусор
for thr in 0 -5 101 '"80"' null true '[]'; do echo "{\"seven_day\":$thr}" > .claude/usage-guard.json; rm -rf .claude/state; ok "$(fire "$(GU th)")" n "порог $thr игнорируется"; done
# недоступный каталог состояния – сообщение всё равно приходит
echo '{"seven_day":50}' > .claude/usage-guard.json; touch "$T/notadir"
ok "$(fire "$(USAGE_GUARD_STATE_DIR="$T/notadir/x" GU ro1)")" y "каталог состояния недоступен – сообщение есть"
# очень длинный session_id
ok "$(fire "$(GU "$(printf 'a%.0s' $(seq 400))")")" y "длинный session_id"
# отсутствие jq: статус-строка не падает молча, link-хук предупреждает
ok "$(PATH=/nonexistent /bin/bash $SC/link-statusline.sh | grep -c 'jq не найден')" 1 "нет jq – предупреждение"
# бит исполнения, манифесты
for s in usage-guard statusline link-statusline; do [ -x "$SC/$s.sh" ]; ok $? 0 "+x $s"; done
jq -e '.hooks|keys|length==3' "$D/hooks/hooks.json" >/dev/null; ok $? 0 "hooks.json"
jq -e '.name=="usage-guard"' "$D/.claude-plugin/plugin.json" >/dev/null; ok $? 0 "plugin.json"
# пустой файл порога не ломает правку (шаблон скила)
f="$T/empty.json"; : > "$f"; [ -s "$f" ] || echo '{}' > "$f"; jq --argjson v 80 '.five_hour=$v' "$f" > "$f.tmp" && cat "$f.tmp" > "$f"; rm -f "$f.tmp"
ok "$(jq -c . "$f")" '{"five_hour":80}' "шаблон скила на пустом файле"
# шаблон скила на симлинке сохраняет симлинк
echo '{}' > "$T/real.json"; ln -s "$T/real.json" "$T/link.json"; f="$T/link.json"; jq --argjson v 90 '.seven_day=$v' "$f" > "$f.tmp" && cat "$f.tmp" > "$f"; rm -f "$f.tmp"
ok "$([ -L "$T/link.json" ] && jq -c . "$T/real.json")" '{"seven_day":90}' "шаблон скила сохраняет симлинк"
# CLAUDE_CONFIG_DIR
mkdir -p "$T/cc"; echo '{"seven_day":50}' > "$T/cc/usage-guard.json"
SLC(){ echo "{\"session_id\":\"c\",\"rate_limits\":{\"seven_day\":{\"used_percentage\":80,\"resets_at\":$R}}}" | CLAUDE_CONFIG_DIR="$T/cc" bash $SC/statusline.sh >/dev/null; }
SLC; ok "$(CLAUDE_CONFIG_DIR="$T/cc" bash $SC/usage-guard.sh <<<'{"session_id":"c1"}' | jq -r '.hookSpecificOutput.hookEventName')" PostToolUse "CLAUDE_CONFIG_DIR"

# порог одной сессии: чужие сессии молчат, субагенты наследуют
rm -f "$H/.claude/usage-guard.json"; echo '{"seven_day":50}' > "$H/.claude/state/ug-limit-own1.json"
ok "$(fire "$(GU own1)")" y "порог сессии – своя сессия получает"
ok "$(fire "$(GU other1)")" n "порог сессии – чужая сессия молчит"
ok "$(fire "$(GU own1 ag1)")" y "порог сессии – субагент наследует"
echo '{"seven_day":50}' > "$H/.claude/usage-guard.json"

# скорость
echo '{"seven_day":50}' > .claude/usage-guard.json
s=$(date +%s); for i in $(seq 100); do bash $SC/usage-guard.sh <<<'{"session_id":"p"}' >/dev/null; done; e=$(date +%s)
[ $((e-s)) -lt 10 ] && PASS=$((PASS+1)) || { FAILN=$((FAILN+1)); echo "FAIL скорость хука: $((e-s)) с на 100 вызовов"; }
rm -rf "$T"; echo "пройдено: $PASS, провалено: $FAILN"; [ "$FAILN" = 0 ]
