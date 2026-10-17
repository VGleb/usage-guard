#!/bin/bash
# Тесты usage-guard. Всё в изолированном HOME. Запуск: bash tests/run.sh
D=$(cd "$(dirname "$0")/.." && pwd); SC=$D/scripts
T=$(mktemp -d) && [ -d "$T" ] || { echo "mktemp не сработал"; exit 1; }
H="$T/home dir"; mkdir -p "$H/.claude" "$T/shared" || exit 1
export HOME="$H"; unset CLAUDE_CONFIG_DIR CLAUDE_PLUGIN_ROOT CLAUDE_CODE_SESSION_ID USAGE_GUARD_CONFIG USAGE_GUARD_DATA USAGE_GUARD_STATE_DIR USAGE_GUARD_SHARED_DIR
cd "$H" || exit 1; NOW=$(date +%s); R=$((NOW+86400)); R5=$((NOW+3600)); PASS=0; FAILN=0
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
ok "$(GU s8 ag1 | grep -c субагент)" 1 "текст субагента"; ok "$(fire "$(GU s8 ag1)")" n "субагент: повтор молчит"; echo "{}" > .claude/state/statusline-s8; ok "$(GU s8 | grep -c "Не начинай новых больших шагов")" 1 "основной: свой текст"

# гонка
dbl=0; for i in $(seq 15); do rm -rf .claude/state/ug-r*; n=$( (for j in 1 2 3 4 5 6 7 8; do GU r$i & done; wait) | grep -c USAGE); [ "$n" = 1 ] || dbl=$((dbl+1)); done
ok "$dbl" 0 "параллельные хуки: ровно одно сообщение"

# выключено
rm .claude/usage-guard.json; ok "$(GU off1)" "" "нет конфига – тишина"

# копия статус-строки по стабильному пути
SS(){ bash $SC/session.sh <<<"{\"hook_event_name\":\"$1\",\"session_id\":\"$2\",\"${3%%=*}\":\"${3#*=}\"}"; }
export CLAUDE_PLUGIN_ROOT="$D"; SS SessionStart z1 source=startup; cmp -s .claude/usage-statusline.sh "$D/scripts/statusline.sh"; ok $? 0 "копия создана"
[ -L .claude/usage-statusline.sh ]; ok $? 1 "это не симлинк"
mkdir -p "$T/v2/scripts"; echo '#!/bin/bash
echo v2' > "$T/v2/scripts/statusline.sh"
export CLAUDE_PLUGIN_ROOT="$T/v2"; SS SessionStart z1 source=resume; rm -rf "$T/v2"
ok "$(.claude/usage-statusline.sh </dev/null)" v2 "после удаления каталога версии копия работает"
export CLAUDE_PLUGIN_ROOT="$D"; SS SessionStart z1 source=startup
unset CLAUDE_PLUGIN_ROOT; SS SessionStart z1 source=startup; ok "$?" 0 "без CLAUDE_PLUGIN_ROOT – тихо"

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
m=$(GU w1); ok "$(echo "$m" | grep -c 'five_hour 60%.*seven_day 70%')" 1 "два окна в одном сообщении"; ok "$(echo "$m" | grep -c "сброс $(fmt $R "%Y-%m-%d %H:%M")")" 1 "сброс последнего окна"
ok "$(fire "$(GU w1)")" n "второго сообщения нет"
# пороги вне диапазона и мусор
for thr in 0 -5 101 '"80"' null true '[]'; do echo "{\"seven_day\":$thr}" > .claude/usage-guard.json; rm -rf .claude/state; ok "$(fire "$(GU th)")" n "порог $thr игнорируется"; done
# недоступный каталог состояния – сообщение всё равно приходит
echo '{"seven_day":50}' > .claude/usage-guard.json; touch "$T/notadir"
ok "$(fire "$(USAGE_GUARD_STATE_DIR="$T/notadir/x" GU ro1)")" y "каталог состояния недоступен – сообщение есть"
# очень длинный session_id
ok "$(fire "$(GU "$(printf 'a%.0s' $(seq 400))")")" y "длинный session_id"
# отсутствие jq: статус-строка не падает молча, link-хук предупреждает
ok "$(PATH=/nonexistent /bin/bash $SC/session.sh <<<'{"hook_event_name":"SessionStart"}' | grep -c 'jq не найден')" 1 "нет jq – предупреждение"
# бит исполнения, манифесты
for s in usage-guard statusline session; do [ -x "$SC/$s.sh" ]; ok $? 0 "+x $s"; done
jq -e '.hooks|keys|length==5' "$D/hooks/hooks.json" >/dev/null; ok $? 0 "hooks.json"
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

# большой вход хука (весь вывод инструмента) не отключает защиту и не тормозит
rm -rf .claude/state/ug-big*; SL big mac1 0 96 >/dev/null
bigin='{"hook_event_name":"PostToolUse","session_id":"big","tool_response":{"stdout":"'$(head -c 1200000 /dev/zero | tr '\0' a)'"}}'
s0=$(date +%s); r=$(bash $SC/usage-guard.sh <<<"$bigin" | jq -r '.hookSpecificOutput.additionalContext // empty'); s1=$(date +%s)
ok "$(fire "$r")" y "вход 1,2 МБ – сообщение есть"; [ $((s1-s0)) -lt 2 ]; ok $? 0 "вход 1,2 МБ – быстро"
# близкий сброс: cron не раньше чем через 10 минут
rm -rf .claude/state/ug-near*; echo "{}" > .claude/state/statusline-near
echo "{\"seven_day\":{\"used_percentage\":99,\"resets_at\":$((NOW+30)),\"saved_at\":$NOW}}" > .claude/rate_limits.json
t0=$(date +%s); m=$(GU near); cr=$(sed -n 's/.*выражением `\([^`]*\)`.*/\1/p' <<<"$m"); w1=$(( (t0+600+59)/60*60 ))
[ "$cr" = "$(fmt $w1 "%-M %-H %-d %-m *")" ] || [ "$cr" = "$(fmt $((w1+60)) "%-M %-H %-d %-m *")" ]; ok $? 0 "близкий сброс – cron через 10 минут ($cr)"
# далёкий сброс: спросить, без cron
rm -rf .claude/state/ug-far*; echo "{}" > .claude/state/statusline-far
echo "{\"seven_day\":{\"used_percentage\":99,\"resets_at\":$((NOW+3*86400)),\"saved_at\":$NOW}}" > .claude/rate_limits.json
m=$(GU far); ok "$(grep -c 'больше 12 часов' <<<"$m")$(grep -c 'выражением' <<<"$m")" 10 "сброс через 3 дня – спросить, без cron"
ok "$(grep -c CronDelete <<<"$m")" 0 "без указания удалять задания при далёком сбросе"
# без статус-строки у сессии (claude -p) – без расписания
rm -rf .claude/state/ug-nosl*; m=$(GU nosl); ok "$(grep -c 'нет статус-строки' <<<"$m")" 1 "сессия без статус-строки – без CronCreate"
# уборка не трогает пороги сессий младше 30 дней
echo '{"seven_day":50}' > .claude/state/ug-limit-oldsess.json; touch -t 202001010000 .claude/state/ug-limit-oldsess.json
echo '{"seven_day":50}' > .claude/state/ug-limit-midsess.json; touch -t "$(fmt $((NOW-10*86400)) %Y%m%d%H%M)" .claude/state/ug-limit-midsess.json
rm -rf .claude/state/ug-cl*; SL cl mac1 0 96 >/dev/null; GU cl >/dev/null
ok "$([ -f .claude/state/ug-limit-midsess.json ] && echo y)$([ -f .claude/state/ug-limit-oldsess.json ] && echo y)" y "уборка: 10 дней остаётся, старше 30 удаляется"
# null в пороге сессии выключает окно при общем пороге
echo '{"seven_day":50}' > .claude/usage-guard.json; echo '{"seven_day":null}' > .claude/state/ug-limit-nul1.json
rm -rf .claude/state/ug-nul1*; SL nul1 mac1 0 96 >/dev/null; ok "$(fire "$(GU nul1)")" n "null в пороге сессии выключает общий"
# шаблон скила целиком: порог сессии и выключение
TPL(){ ( export CLAUDE_CODE_SESSION_ID=tpl1; W=$1 V=$2 SCOPE=$3; umask 077
  cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"; d="${USAGE_GUARD_STATE_DIR:-$cfg/state}"
  if [ "$SCOPE" = all ]; then f="${USAGE_GUARD_CONFIG:-$cfg/usage-guard.json}"
  else [ -n "$CLAUDE_CODE_SESSION_ID" ] || { echo "нет id сессии"; exit 1; }; f="$d/ug-limit-${CLAUDE_CODE_SESSION_ID:0:100}.json"; fi
  mkdir -p "$(dirname "$f")"; [ -s "$f" ] || echo '{}' > "$f"
  jq --arg w "$W" --argjson v "$V" '.[$w]=$v' "$f" > "$f.tmp" && cat "$f.tmp" > "$f"; rm -f "$f.tmp" ) >/dev/null; }
TPL five_hour 60 session; TPL seven_day null session
ok "$(jq -c . .claude/state/ug-limit-tpl1.json)" '{"five_hour":60,"seven_day":null}' "шаблон скила: порог и выключение"
ok "$(stat -c %a .claude/state/ug-limit-tpl1.json 2>/dev/null || stat -f %Lp .claude/state/ug-limit-tpl1.json)" 600 "шаблон скила: права 600"
rm -rf .claude/state/ug-perm*; SL perm mac1 0 96 >/dev/null; GU perm >/dev/null
ok "$(stat -c %a .claude/state/ug-perm 2>/dev/null || stat -f %Lp .claude/state/ug-perm)" 700 "каталог состояния хука – 700"
# /clear переносит порог в новую сессию
echo '{"five_hour":70}' > .claude/state/ug-limit-cA.json
SS SessionEnd cA reason=clear; SS SessionStart cB source=clear
ok "$(cat .claude/state/ug-limit-cB.json 2>/dev/null)$([ -f .claude/state/ug-limit-cA.json ] && echo old)" '{"five_hour":70}' "/clear переносит порог"
SS SessionEnd cC reason=prompt_input_exit; SS SessionStart cD source=startup; ok "$([ -f .claude/state/ug-limit-cD.json ] && echo y)" "" "обычный старт порог не забирает"
# сжатие контекста: напоминание заново
rm -rf .claude/state/ug-cmp*; SL cmp mac1 0 96 >/dev/null; GU cmp >/dev/null; ok "$(fire "$(GU cmp)")" n "до сжатия повтор молчит"
ok "$(bash $SC/usage-guard.sh <<<'{"hook_event_name":"SessionStart","source":"compact","session_id":"cmp"}' | jq -r .hookSpecificOutput.hookEventName)" SessionStart "после сжатия напоминание снова"
# порог чужой сессии не подхватывается, даже если bash и jq разобрали id по-разному
echo '{"seven_day":50}' > .claude/state/ug-limit-evil.json; rm -f .claude/usage-guard.json
ok "$(fire "$(bash $SC/usage-guard.sh <<<'{"tool_response":"\"session_id\":\"evil\"","session_id":"good"}')")" n "id из tool_response не даёт чужой порог"
# испорченное окно не гасит соседнее в статус-строке
ok "$(echo "{\"session_id\":\"bad\",\"rate_limits\":{\"five_hour\":{\"used_percentage\":5,\"resets_at\":1e30},\"seven_day\":{\"used_percentage\":7,\"resets_at\":$R}}}" | bash $SC/statusline.sh)" "7% до $(fmt $R "%H:%M %d.%m")" "resets_at=1e30 в одном окне"
echo '{"seven_day":50}' > .claude/usage-guard.json

# скорость
echo '{"seven_day":50}' > .claude/usage-guard.json
s=$(date +%s); for i in $(seq 100); do bash $SC/usage-guard.sh <<<'{"session_id":"p"}' >/dev/null; done; e=$(date +%s)
[ $((e-s)) -lt 10 ] && PASS=$((PASS+1)) || { FAILN=$((FAILN+1)); echo "FAIL скорость хука: $((e-s)) с на 100 вызовов"; }
rm -rf "$T"; echo "пройдено: $PASS, провалено: $FAILN"; [ "$FAILN" = 0 ]
