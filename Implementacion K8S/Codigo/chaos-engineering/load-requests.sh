#!/usr/bin/env bash
# Wrapper de compatibilidad. Uso: ./load-requests.sh [cantidad] [url]
# Equivale a: ./chaos.sh requests --requests <N> --url <url>. Requiere port-forward.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -n "${2:-}" ]; then
  exec "$DIR/chaos.sh" requests --requests "${1:-500}" --url "$2"
fi
exec "$DIR/chaos.sh" requests --requests "${1:-500}"
