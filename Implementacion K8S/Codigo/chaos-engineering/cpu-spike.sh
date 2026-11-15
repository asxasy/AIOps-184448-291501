#!/usr/bin/env bash
# Wrapper de compatibilidad. Uso: ./cpu-spike.sh [deployment] [segundos]
# Equivale a: ./chaos.sh cpu --target <deploy> --duration <seg>
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$DIR/chaos.sh" cpu --target "${1:-pharmago-api-gateway}" --duration "${2:-30}"
