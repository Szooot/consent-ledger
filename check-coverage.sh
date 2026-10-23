#!/bin/bash

set -euo pipefail

report="$(forge coverage --report summary --no-match-coverage "(test|script|lib)")"
echo "$report"

echo "$report" | awk -F'|' '
  $2 ~ /^ *Total *$/ {
    found = 1
    for (i = 3; i <= 6; i++) {
      if ($i !~ /^ *100\.00% /) bad = 1
    }
  }
  END {
    if (!found) { print "Could not read the coverage summary."; exit 1 }
    if (bad) { print "Coverage must be 100% for lines, statements, branches and functions."; exit 1 }
    print "Coverage is 100%."
  }
'
