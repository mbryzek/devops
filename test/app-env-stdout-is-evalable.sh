#!/bin/sh

# Regression guard for `bin/app-env --format sh`: its stdout is eval'd by the
# caller (see bin/run), so nothing but the variable assignments may land there.
# Progress banners ("==> ...") belong on stderr — when Util.run printed them to
# stdout the eval failed with "==: command not found".

set -e

DIR=$(cd "$(dirname "$0")/.." && pwd)

if [ ! -d "$DIR/../env/apps" ]; then
  echo "SKIP: no ../env/apps checkout next to $DIR"
  exit 0
fi

out=$("$DIR/bin/app-env" --app platform --env development --format sh 2>/dev/null)

# Every line of stdout must be shell we can eval; a stray banner is the failure
# this guards against.
if printf '%s\n' "$out" | grep -q '^==>'; then
  echo "FAIL: bin/app-env wrote a '==>' progress banner to stdout"
  exit 1
fi

eval "$out true"

echo "PASS: bin/app-env stdout is clean and evalable"
