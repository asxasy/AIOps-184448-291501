#!/usr/bin/env bash
# Wrapper de compatibilidad. Uso: ./ram-spike.sh [deployment] [MB] [segundos]
# Equivale a: ./chaos.sh ram --target <deploy> --mb <MB> --duration <seg>
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$DIR/chaos.sh" ram --target "${1:-pharmago-api-gateway}" --mb "${2:-250}" --duration "${3:-30}"
