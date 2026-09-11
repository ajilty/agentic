# Description template: surface + "load before the first call" + user-utterance cues.
# Symptom strings (errors, field names, response shapes) belong in the body.
CAP=400
for f in "$HERE"/../skills/working-with-*/SKILL.md; do
  d=$(awk '/^---$/{c++; next} c==1 && /^description:/{sub(/^description:[ ]*/,""); print}' "$f")
  d=${d#\"}; d=${d%\"}; d=${d//\\\"/\"}
  n=${#d}
  [ "$n" -le "$CAP" ] && pass || fail "$(basename "$(dirname "$f")"): description is $n chars (cap $CAP)"
  case "$d" in *'`'*) fail "$(basename "$(dirname "$f")"): description carries a backtick token (symptom strings go in the body)" ;; *) pass ;; esac
  case "$d" in *"Load "*) pass ;; *) fail "$(basename "$(dirname "$f")"): description lacks a 'Load before/when ...' trigger sentence" ;; esac
done
