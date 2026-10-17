#!/bin/bash
# Хук PostToolUse / UserPromptSubmit: когда лимит достиг порога, просит Claude заранее остановиться
# и запланировать продолжение на время сброса. Порог не задан – ничего не делает.
# Настройка через окружение (значения по умолчанию в скобках; <cfg> = $CLAUDE_CONFIG_DIR или ~/.claude):
#   USAGE_GUARD_CONFIG     файл с порогами, например {"five_hour": 80, "seven_day": 95} (<cfg>/usage-guard.json)
#   USAGE_GUARD_DATA       файл с последними лимитами, его пишет statusline.sh (<cfg>/rate_limits.json)
#   USAGE_GUARD_STATE_DIR  служебные файлы (<cfg>/state)
#   USAGE_GUARD_SHARED_DIR каталог, общий для нескольких машин; читаются все rate_limits.host-*.json
# Лимит – самое свежее (по saved_at окна) наблюдение. Одно сообщение на все сработавшие окна; повтор – раз на
# каждые 5 п.п. роста (страховка от потери при компактации) и на каждый новый пользовательский запрос.
# Ниже порога память окна стирается (ручной сброс лимита). Дедупликация – файл на ключ через noclobber:
# параллельные хуки одной сессии не дают двойного сообщения. Не удалось записать состояние – лучше
# повторять сообщение, чем молчать.
cfg=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
conf=${USAGE_GUARD_CONFIG:-$cfg/usage-guard.json}
dataf=${USAGE_GUARD_DATA:-$cfg/rate_limits.json}
dir=${USAGE_GUARD_STATE_DIR:-$cfg/state}
shared=${USAGE_GUARD_SHARED_DIR:-}
in=$(cat)
sid=x; [[ $in =~ \"session_id\"[[:space:]]*:[[:space:]]*\"([A-Za-z0-9_-]+)\" ]] && sid=${BASH_REMATCH[1]:0:100}
lf="$dir/ug-limit-$sid.json"   # порог этой сессии, перекрывает общий
[ -f "$conf" ] || [ -f "$lf" ] || exit 0
c=; [ -f "$conf" ] && c=$(<"$conf")
l=; [ -f "$lf" ] && l=$(<"$lf")
data=; [ -f "$dataf" ] && data=$(<"$dataf")
hosts=; if [ -n "$shared" ]; then for x in "$shared"/rate_limits.host-*.json; do [ -f "$x" ] && hosts+=$(<"$x")$'\n'; done; fi
[ -n "$data$hosts" ] || exit 0
out=$(jq -rn --arg c "$c" --arg l "$l" --arg i "$in" --arg d "$data" --arg h "$hosts" '
  def obj: try fromjson catch {} | if type=="object" then . else {} end;
  now as $now
  | ($i | try fromjson catch {}) as $in
  | (($c|obj) + ($l|obj)) as $c | ($d|obj) as $d
  | [$h | splits("\n") | select(length>0) | obj] as $hs
  | ($in.hook_event_name // "PostToolUse") as $ev
  | ($in.agent_id // "" | tostring) as $aid
  | (($in.session_id // "x" | tostring) + (if $aid != "" then "-" + $aid else "" end) | gsub("[^A-Za-z0-9_-]"; "_") | .[0:100]) as $sid
  | [ ("five_hour","seven_day") as $w
      | ($c[$w]) as $thr
      | ([($d[$w] | select(type=="object") | . + {sa: (.saved_at // $d.saved_at // 0)}),
          ($hs[] | .[$w] | select(type=="object") | . + {sa: (.saved_at // 0)})]
         | map(select((.used_percentage|type)=="number" and (.resets_at|type)=="number" and (.sa|type)=="number"
                      and .resets_at > $now and .resets_at < $now + 8*86400)
               | .sa = ([.sa, $now] | min))
         | sort_by(.sa) | last // {}) as $b
      | select(($thr|type)=="number" and $thr > 0 and $thr <= 100 and ($b.used_percentage|type)=="number")
      | {w:$w, thr:$thr, p:$b.used_percentage, r:($b.resets_at|floor), hit:($b.used_percentage >= $thr)} ] as $ws
  | "SID\t\($sid)", "EV\t\($ev)",
    ($ws[] | select(.hit|not) | "CLEAR\t\(.w)"),
    ( [$ws[] | select(.hit)] as $h | select($h|length > 0)
      | ($h | map("\(.w):\(.r):\((.p/5)|floor)") | join("+")) as $key
      | ($h | map(.r) | max) as $rf
      | ($h | map("\(.w) \(.p|floor)% (порог \(.thr)%)") | join(", ")) as $what
      | ($rf|strflocaltime("%Y-%m-%d %H:%M %Z")) as $when
      | "MSG\t\($key)\t" + ({hookSpecificOutput:{hookEventName:$ev, additionalContext:
          (if $aid != "" then
            "USAGE GUARD: лимит подписки: \($what), сброс \($when). Ты субагент: не начинай новых шагов, заверши текущий и сразу верни вызывающему агенту отчёт – что сделано, что осталось. CronCreate не вызывай."
           else
            "USAGE GUARD: лимит подписки: \($what). Сброс (последнего из сработавших окон) \($when), unix \($rf). Не начинай новых больших шагов. Заверши текущий, сохрани состояние работы в файл заметок (что сделано, что осталось, где файлы). Если до сброса больше 12 часов, расписание вряд ли переживёт ожидание: сообщи пользователю и спроси, ставить ли его. Иначе проверь CronList: если продолжение уже запланировано, второе не создавай; иначе создай ОДНОРАЗОВОЕ (recurring: false) задание CronCreate с cron-выражением `\(($rf+120)|strflocaltime("%-M %-H %-d %-m *"))` (это \(($rf+120)|strflocaltime("%Y-%m-%d %H:%M")) местного времени) и промптом «продолжи задачу по заметкам <путь>». Если задача повторяющаяся (cron-задание), вместо этого удали её через CronDelete. Сообщи пользователю и остановись."
           end)}} | tojson) )
' 2>/dev/null) || exit 0
[ -n "$out" ] || exit 0
st=
while IFS=$'\t' read -r k v rest; do
  case $k in
    SID) st="$dir/ug-$v" ;;
    EV)  [ "$v" = UserPromptSubmit ] && [ -d "$st" ] && rm -f "$st"/*:* 2>/dev/null ;;   # новый запрос – напомнить заново
    CLEAR) [ -d "$st" ] && rm -f "$st"/*"$v:"* 2>/dev/null ;;                              # процент упал ниже порога
    MSG)
      [ -d "$st" ] || mkdir -p "$st" 2>/dev/null || { printf '%s\n' "$rest"; exit 0; }
      ( set -o noclobber; : > "$st/$v" ) 2>/dev/null || { [ -e "$st/$v" ] && exit 0; printf '%s\n' "$rest"; exit 0; }
      find "$dir" -maxdepth 1 \( -name "ug-*" -o -name "statusline-*" \) -mtime +7 -exec rm -rf {} + 2>/dev/null
      printf '%s\n' "$rest"; exit 0 ;;
  esac
done <<< "$out"
exit 0
