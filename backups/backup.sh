#!/bin/bash
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

# With no subcommand, create and upload a backup set.
if [ "$#" -eq 0 ]; then
  set -- run
fi
exec python3 "$SCRIPT_DIR/manager.py" "$@"
