#!/bin/bash
# Хук PostToolUse / PostToolUseFailure / UserPromptSubmit / SessionStart(compact): когда лимит достиг порога,
# просит Claude заранее остановиться и запланировать продолжение на время сброса. Порог не задан – ничего не делает.
# Настройка через окружение (значения по умолчанию в скобках; <cfg> = $CLAUDE_CONFIG_DIR или ~/.claude):
#   USAGE_GUARD_CONFIG     общий порог для всех сессий, например {"five_hour": 80, "seven_day": 95} (<cfg>/usage-guard.json)
#   USAGE_GUARD_DATA       файл с последними лимитами, его пишет statusline.sh (<cfg>/rate_limits.json)
#   USAGE_GUARD_STATE_DIR  служебные файлы (<cfg>/state); там же порог одной сессии ug-limit-<session_id>.json,
#                          он перекрывает общий (null в ключе – окно в этой сессии выключено)
#   USAGE_GUARD_SHARED_DIR каталог, общий для нескольких машин; читаются все rate_limits.host-*.json
# Лимит – самое свежее (по saved_at окна) наблюдение. Одно сообщение на все сработавшие окна; повтор – раз на
# каждые 5 п.п. роста, на каждый новый пользовательский запрос и после сжатия контекста.
# Ниже порога память окна стирается (ручной сброс лимита). Дедупликация – файл на ключ через noclobber:
# параллельные хуки одной сессии не дают двойного сообщения. Не удалось записать состояние – лучше
# повторять сообщение, чем молчать.
umask 077
cfg=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
conf=${USAGE_GUARD_CONFIG:-$cfg/usage-guard.json}
dataf=${USAGE_GUARD_DATA:-$cfg/rate_limits.json}
dir=${USAGE_GUARD_STATE_DIR:-$cfg/state}
shared=${USAGE_GUARD_SHARED_DIR:-}
in=$(cat)
# id сессии нужен до jq, чтобы найти её порог; jq сверяет его со своим разбором входа
sid=x; [[ ${in:0:4096} =~ \"session_id\"[[:space:]]*:[[:space:]]*\"([A-Za-z0-9_-]+)\" ]] && sid=${BASH_REMATCH[1]:0:100}
lf="$dir/ug-limit-$sid.json"
[ -f "$conf" ] || [ -f "$lf" ] || exit 0
c=; [ -f "$conf" ] && c=$(<"$conf")
l=; [ -f "$lf" ] && l=$(<"$lf")
sl=0; [ -f "$dir/statusline-$sid" ] && sl=1   # у сессии есть статус-строка, значит она интерактивная
data=; [ -f "$dataf" ] && data=$(<"$dataf")
hosts=; if [ -n "$shared" ]; then for x in "$shared"/rate_limits.host-*.json; do [ -f "$x" ] && hosts+=$(<"$x")$'\n'; done; fi
[ -n "$data$hosts" ] || exit 0
# вход хука идёт через stdin, а не аргументом: в нём весь вывод инструмента, а длина argv ограничена
out=$(jq -rRs --arg c "$c" --arg l "$l" --arg lsid "$sid" --arg sl "$sl" --arg d "$data" --arg h "$hosts" '
  def obj: try fromjson catch {} | if type=="object" then . else {} end;
  now as $now
  | obj as $in
  | ($in.session_id // "x" | tostring | gsub("[^A-Za-z0-9_-]"; "_") | .[0:100]) as $base
  | (($c|obj) + (if $base == $lsid then ($l|obj) else {} end)) as $c | ($d|obj) as $d
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
      | (($rf - $now)/60 | ceil) as $mins
      # продолжение – через 2 минуты после сброса, но не раньше чем через 10 минут от сейчас:
      # иначе к моменту вызова CronCreate время уже пройдёт, а cron без года сработает только через год
      | (([$rf + 120, $now + 600] | max) / 60 | ceil * 60) as $go
      | "USAGE GUARD: лимит подписки: \($what). Сейчас \($now|strflocaltime("%Y-%m-%d %H:%M")), сброс \($rf|strflocaltime("%Y-%m-%d %H:%M")) местного времени (через \(if $mins >= 120 then "\($mins/60|floor) ч" else "\($mins) мин" end)). " as $head
      | "MSG\t\($key)\t" + ({hookSpecificOutput:{hookEventName:$ev, additionalContext:
          (if $aid != "" then
            $head + "Ты субагент: не начинай новых шагов, заверши текущий и сразу верни вызывающему агенту отчёт – что сделано, что осталось. Заданий CronCreate не создавай."
           elif $sl != "1" then
            $head + "У этой сессии нет статус-строки (похоже, неинтерактивный запуск): заверши текущий шаг, сохрани состояние работы в файл заметок (что сделано, что осталось, где файлы), сообщи об этом и остановись. Заданий CronCreate не создавай."
           else
            $head + "Не начинай новых больших шагов. Заверши текущий, сохрани состояние работы в файл заметок (что сделано, что осталось, где файлы). "
            + (if $mins > 720 then
                "До сброса больше 12 часов – расписание вряд ли доживёт: сообщи пользователю, спроси, ставить ли продолжение, и остановись."
               else
                "Проверь CronList: если продолжение уже запланировано, второе не создавай; иначе создай ОДНОРАЗОВОЕ (recurring: false) задание CronCreate с cron-выражением `\($go|strflocaltime("%-M %-H %-d %-m *"))` (это \($go|strflocaltime("%Y-%m-%d %H:%M")) местного времени) и промптом «продолжи задачу по заметкам <путь>». Если текущий запуск пришёл от повторяющегося задания: когда пользователь просил остановить его по лимиту – удали его через CronDelete, иначе ничего не создавай и не удаляй, просто заверши этот запуск. Сообщи пользователю и остановись."
               end)
           end)}} | tojson) )
' <<< "$in" 2>/dev/null) || exit 0
[ -n "$out" ] || exit 0
st=
while IFS=$'\t' read -r k v rest; do
  case $k in
    SID) st="$dir/ug-$v" ;;
    EV)  case $v in UserPromptSubmit|SessionStart) [ -d "$st" ] && rm -f "$st"/*:* 2>/dev/null ;; esac ;;  # новый запрос или сжатие – напомнить заново
    CLEAR) [ -d "$st" ] && rm -f "$st"/*"$v:"* 2>/dev/null ;;                                         # процент упал ниже порога
    MSG)
      [ -d "$st" ] || mkdir -p "$st" 2>/dev/null || { printf '%s\n' "$rest"; exit 0; }
      ( set -o noclobber; : > "$st/$v" ) 2>/dev/null || { [ -e "$st/$v" ] && exit 0; printf '%s\n' "$rest"; exit 0; }
      find "$dir" -maxdepth 1 \( \( -name "ug-*" ! -name "ug-limit-*" -o -name "statusline-*" \) -mtime +7 \
        -o -name "ug-limit-*" -mtime +30 \) -exec rm -rf {} + 2>/dev/null
      printf '%s\n' "$rest"; exit 0 ;;
  esac
done <<< "$out"
exit 0
