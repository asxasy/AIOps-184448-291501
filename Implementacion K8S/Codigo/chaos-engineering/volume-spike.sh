#!/usr/bin/env bash
# Wrapper de compatibilidad. Uso: ./volume-spike.sh [deployment] [MB] [segundos]
# Equivale a: ./chaos.sh storage --target <deploy> --mb <MB> --duration <seg>
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$DIR/chaos.sh" storage --target "${1:-pharmago-api-gateway}" --mb "${2:-300}" --duration "${3:-30}"
