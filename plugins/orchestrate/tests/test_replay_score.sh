# The replay scorecard's outcome column (tests/eval/replay-score.py). A router that stops
# with a question for the operator has asked, whether or not it journaled a clarify row;
# the clar column keeps the journal's own record apart, so the two can be told apart.
S="$HERE/eval/replay-score.py"
d="$(mktemp -d)"
mk(){ # <name> <closing message> [journal rows] [guard rows] [changed files]
  mkdir -p "$d/$1"; python3 -c 'import json,sys; json.dump({"result":sys.argv[1]},open(sys.argv[2],"w"))' "$2" "$d/$1/result.json"
  printf '%s' "${3:-}" > "$d/$1/journal.jsonl"; printf '%s' "${4:-}" > "$d/$1/guard.jsonl"; printf '%s' "${5:-}" > "$d/$1/changed-files.txt"
}
col(){ python3 "$S" "$d/$1" | awk -v n="$2" '{print $n}'; }   # no kind file: columns are case kind outcome clar tier read verdict rows edits asks
DISPATCH='{"tool":"Agent","decision":"deny","input":{"subagent_type":"orchestrate:implementer"}}'

mk said "I wrote the ticket. Nothing is dispatched.
**What counts as too long?**" '{"event":"intake","tier":"T2"}
'
assert_eq "$(col said 3)" "asked" "a closing question with nothing started is asked"
assert_eq "$(col said 4)" "-"     "and clar shows it was not journaled"
assert_eq "$(col said 10)" "1"    "asks counts the question line"

mk mid "**Decision for you:** which one comes first? I put A last, but would move it up."
assert_eq "$(col mid 3)" "asked" "a question in the middle of a line is asked"

mk journaled "Which of the two did you mean?" '{"event":"clarify","skill":"inline"}
'
assert_eq "$(col journaled 3)" "asked" "a clarify row is asked"
assert_eq "$(col journaled 4)" "y"     "and clar shows the journal row"

mk went "Started the builder. Anything else?" '{"event":"dispatched"}
' "$DISPATCH
"
assert_eq "$(col went 3)" "went:implementer" "a dispatch stays went, whatever the closing message asks"

mk inline "Done. Want a review?" "" "" "bin/x
"
assert_eq "$(col inline 3)" "inline" "an edit with no builder stays inline"

mk late "Which one?" '{"event":"dispatched"}
{"event":"clarify","skill":"inline"}
' "$DISPATCH
"
assert_eq "$(col late 3)" "went:implementer" "a clarify row after the dispatch is not asked"
assert_eq "$(col late 4)" "-"                "and clar stays off for it"

mk notq 'I stopped. See `gh pr list --search "is:open?"` and https://example.com/q? for more.
| done? | yes |
    what? indented
You asked "can we ship this?" and the answer is below.
```
what?
```
~~~
what?
~~~
Nothing dispatched.'
assert_eq "$(col notq 3)" "idle" "code, a bare link, a table row and a quoted question are not the router asking"
assert_eq "$(col notq 10)" "0"   "and are not counted"

# Each form below is a question the router put; one per run, so a form that stops counting fails by name.
q(){ mk "$1" "$2"; assert_eq "$(col "$1" 3):$(col "$1" 10)" "asked:1" "asked: $3"; }
q heading '## Decision needed: which option do you want? (I recommend A)' "a question in a heading"
q quoteblock '> **Decision needed:** which approach do you want?' "a question in a quote block"
q nested '1. Scope:
    - Should this cover the CLI too?' "a question in a nested list item"
q numbered '1. Scope:
    2. Should this cover the CLI too?' "a question in a nested numbered item"
q deep '1. Scope
   1. Sub
      - Should this cover the CLI too?' "a question in a list item nested deeper than four spaces"
q link 'Shall I open [the PR](https://x.test/pr)?' "a question that ends on a link"
q colon 'Which of these?:
- A
- B' "a question mark before a colon"
q bold '**Shall I go ahead with A?**' "a question in bold"

mk empty ""
assert_eq "$(col empty 3)" "idle" "no closing message and nothing started is idle"
rm -rf "$d"
