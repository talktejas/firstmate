. as $req | {model: "stand-in", answers: (.questions | to_entries | map(.key as $q | (.value.criteria | keys) as $k |
  (if env.YES_RE != null and ($req.state.functions[$q]? != null)
   then (if ($req.state.functions[$q].code | test(env.YES_RE)) then "yes" else "no" end)
   else (env["CHOICE_" + $q] // env.CHOICE) end) as $c | (env.CONF | tonumber) as $p |
  {key: $q, value: {choice: $c, confidence: $p, probabilities: ($k | map({key: ., value: (if . == $c then $p else ((1 - $p) / (($k | length) - 1)) end)}) | from_entries)}}) | from_entries)}
