#!/bin/bash
# Runs abx's checks: syntax, ShellCheck (when installed), shell scenario tests and Python tests.
#   tests/run.sh            everything
#   tests/run.sh bedrock    only tests whose file or function name contains "bedrock"
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_DIR="$(cd "$TESTS_DIR/.." && pwd -P)"
FILTER="${1:-}"
passed=0 failed=0 skipped=0 failures=""

echo "── syntax"
for f in "$REPO_DIR"/abx.sh "$REPO_DIR"/lib/*.sh "$REPO_DIR"/examples/*.sh "$REPO_DIR"/resources/*.sh "$TESTS_DIR"/stubs/* "$TESTS_DIR"/lib/*.sh "$TESTS_DIR"/shell/*.sh; do
  if bash -n "$f"; then passed=$((passed + 1)); else failed=$((failed + 1)); failures="$failures syntax:$f"; fi
done
for f in "$REPO_DIR"/resources/*.py "$TESTS_DIR"/python/*.py; do
  if python3 -m py_compile "$f"; then passed=$((passed + 1)); else failed=$((failed + 1)); failures="$failures syntax:$f"; fi
done
if command -v shellcheck >/dev/null 2>&1; then
  echo "── shellcheck"
  if shellcheck -S error "$REPO_DIR"/abx.sh "$REPO_DIR"/lib/*.sh "$REPO_DIR"/resources/*.sh; then passed=$((passed + 1)); else failed=$((failed + 1)); failures="$failures shellcheck"; fi
fi

for file in "$TESTS_DIR"/shell/test_*.sh; do
  echo "── $(basename "$file" .sh)"
  for fn in $(bash -c "source '$file'; declare -F" | awk '{print $3}' | grep '^test_'); do
    case "$(basename "$file")$fn" in *"$FILTER"*) ;; *) continue ;; esac
    output="$(bash -c "source '$TESTS_DIR/lib/harness.sh'; source '$file'; setup; ( $fn ); rc=\$?; teardown; exit \$rc" 2>&1)"
    rc=$?
    if [ $rc = 0 ]; then
      passed=$((passed + 1)); echo "  ok    $fn"
    elif [ $rc = 77 ]; then
      skipped=$((skipped + 1)); echo "  skip  $fn"; printf '%s\n' "$output" | grep SKIPPED
    else
      failed=$((failed + 1)); failures="$failures $fn"; echo "  FAIL  $fn"; printf '%s\n' "$output"
    fi
  done
done

case "python test_signer" in
  *"$FILTER"*)
    echo "── python"
    if (cd "$TESTS_DIR/python" && python3 -m unittest -q 2>&1 | sed 's/^/  /'; exit "${PIPESTATUS[0]}"); then
      passed=$((passed + 1)); echo "  ok    python unit tests"
    else
      failed=$((failed + 1)); failures="$failures python"
    fi ;;
esac

echo ""
echo "$passed passed, $failed failed, $skipped skipped"
[ $failed = 0 ] || { echo "Failures:$failures"; exit 1; }
