#!/usr/bin/env bash
set -euo pipefail
SIM_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SIM_GODOT="${GODOT_BIN:-}"
if [[ -z "$SIM_GODOT" ]]; then
  for candidate in godot godot4; do
    if command -v "$candidate" >/dev/null 2>&1; then
      SIM_GODOT="$(command -v "$candidate")"
      break
    fi
  done
fi
if [[ -z "$SIM_GODOT" && -x "$SIM_ROOT/.tools/godot" ]]; then
  SIM_GODOT="$SIM_ROOT/.tools/godot"
fi
if [[ -z "$SIM_GODOT" || ! -x "$SIM_GODOT" ]]; then
  printf '%s\n' 'Godot not found. Set GODOT_BIN=/absolute/path/to/godot or install Godot 4.7.2.' >&2
  exit 1
fi
exec "$SIM_GODOT" --path "$SIM_ROOT" "$@"
