#!/bin/bash
# Статус-строка Claude Code: «29% до 13:10 · 94% до 16:00 12.10» (5ч · 7д) + данные для usage-guard.sh.
# Настройка через окружение (значения по умолчанию в скобках; <cfg> = $CLAUDE_CONFIG_DIR или ~/.claude):
#   USAGE_GUARD_DATA       файл с последними лимитами (<cfg>/rate_limits.json)
#   USAGE_GUARD_STATE_DIR  служебные файлы (<cfg>/state)
#   USAGE_GUARD_SHARED_DIR каталог, общий для нескольких машин (например в Dropbox); если задан, туда пишется
#                          rate_limits.host-<пользователь>-<машина>.json – один писатель на файл, без конфликтных копий
# saved_at окна = момент, когда сессия ВПЕРВЫЕ увидела это значение; окно записывается, только если оно не
# старее уже записанного: простаивающая сессия, перерисовавшись со старыми данными, не затирает свежие.
umask 077
cfg=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
f=${USAGE_GUARD_DATA:-$cfg/rate_limits.json}
state=${USAGE_GUARD_STATE_DIR:-$cfg/state}
shared=${USAGE_GUARD_SHARED_DIR:-}
hf=; [ -n "$shared" ] && hf=$shared/rate_limits.host-${USER:-u}-${HOSTNAME%%.*}.json
in=$(cat)
sid=x; [[ $in =~ \"session_id\"[[:space:]]*:[[:space:]]*\"([A-Za-z0-9_-]+)\" ]] && sid=${BASH_REMATCH[1]:0:100}
seenf=$state/statusline-$sid
cur=; [ -n "$hf" ] && [ -f "$hf" ] && cur=$(<"$hf")
loc=; [ -f "$f" ] && loc=$(<"$f")
seen=; if [ -f "$seenf" ]; then seen=$(<"$seenf"); else find "$state" -maxdepth 1 -name 'statusline-*' -mtime +7 -delete 2>/dev/null; fi
out=$(jq -r --arg cur "$cur" --arg loc "$loc" --arg seen "$seen" '
  def ok: type=="object" and (.used_percentage|type)=="number" and (.resets_at|type)=="number" and .resets_at > 1e9 and .resets_at < 1e10;   # unix-секунды
  def win: if type=="object" then with_entries(select((.key=="five_hour" or .key=="seven_day") and (.value|ok))) else {} end;
  def key: with_entries(.value |= [.resets_at, (.used_percentage|floor)]);
  def newer($m): reduce ($m|to_entries[]) as $e (.; if ((.[$e.key].saved_at // 0) <= $e.value.saved_at) then .[$e.key] = $e.value else . end);
  (now|floor) as $t
  | ($cur | try fromjson catch {} | win) as $c
  | ($loc | try fromjson catch {} | win) as $l
  | ($seen | try fromjson catch {} | if type=="object" then . else {} end) as $sn
  | (.rate_limits | win) as $rl
  | ($rl | with_entries(.key as $w | .value |= (. + {saved_at: (if ($sn[$w].v // null) == [.resets_at,.used_percentage] then $sn[$w].at else $t end)}))) as $m
  | ($l | newer($m)) as $l2 | ($c | newer($m)) as $c2
  | (if $l2 != $l then ($l2|tojson) else "" end),
    (if ($c2|key) != ($c|key) then ($c2|tojson) else "" end),
    ($m | with_entries(.value |= {v:[.resets_at,.used_percentage], at:.saved_at}) | if . != $sn and length>0 then tojson else "" end),
    ([ (.model.display_name // empty),
       ($rl.five_hour // empty | "\(.used_percentage|floor)% до \(.resets_at|strflocaltime("%H:%M"))"),
       ($rl.seven_day // empty | "\(.used_percentage|floor)% до \(.resets_at|strflocaltime("%H:%M %d.%m"))") ] | join(" · "))
' <<< "$in" 2>/dev/null) || { echo "statusline: jq error"; exit 0; }
{ IFS= read -r rl; IFS= read -r shr; IFS= read -r sn; IFS= read -r line; } <<< "$out"
w(){ tmp="$1.$$"; printf '%s\n' "$2" > "$tmp" 2>/dev/null && mv -f "$tmp" "$1" 2>/dev/null || rm -f "$tmp" 2>/dev/null; }
[ -n "$rl" ] && { mkdir -p "${f%/*}" 2>/dev/null; w "$f" "$rl"; }
[ -n "$shr" ] && [ -d "$shared" ] && w "$hf" "$shr"
[ -n "$sn" ] && mkdir -p "$state" 2>/dev/null && w "$seenf" "$sn"
printf '%s\n' "${line:- }"
