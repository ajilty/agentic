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

# Body size: not a failure (a body is budgeted by review, not by count), only the signal
# that a skill is due a diet; the author diets a skill it touches past this line (CONTRIBUTING).
DIET_BYTES=16384
for f in "$HERE"/../skills/working-with-*/SKILL.md; do
  n=$(wc -c < "$f" | tr -d ' ')
  [ "$n" -gt "$DIET_BYTES" ] && printf 'NOTE: %s is %s bytes (diet line %s): diet it on next touch\n' \
    "$(basename "$(dirname "$f")")" "$n" "$DIET_BYTES" >&2
done
pass
