#!/bin/bash
# Verifica el despliegue sin cortes (ítem 3 de la rúbrica).
#
# Lanza una sonda dentro del clúster que pide en loop al gateway y a la UI,
# hace "kubectl rollout restart" de cada Deployment (en secuencia) y cuenta
# las respuestas que no son 2xx/3xx. Resultado esperado: 0 fallas.
#
# Uso:
#   ./verificar-despliegue-seguro.sh                       # los 4 deployments
#   ./verificar-despliegue-seguro.sh pharmago-users-service
#
# Variables opcionales: INTERVALO (0.2), LINEA_BASE (5), COLA (10),
# URLS, CURL_IMAGE, NS (pharmago).
#
# Requiere la imagen del gateway con la ruta /test-health/pharmacy
# (appsettings.json de la rama obl/plataforma-ha).

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib-sonda.sh"

LINEA_BASE="${LINEA_BASE:-5}"
COLA="${COLA:-10}"
if [ $# -gt 0 ]; then
    DEPLOYS="$*"
else
    DEPLOYS="pharmago-api-gateway pharmago-users-service pharmago-pharmacy-service pharmago-ui"
fi

verificar_kubectl
for d in $DEPLOYS; do
    if ! kubectl get deployment "$d" -n "$NS" >/dev/null 2>&1; then
        echo "Error: no existe el deployment $d en $NS." >&2
        exit 2
    fi
done

echo "=== Estado inicial ==="
kubectl get deployment $DEPLOYS -n "$NS" \
    -o custom-columns='DEPLOYMENT:.metadata.name,LISTAS:.status.readyReplicas,DESEADAS:.spec.replicas,ESTRATEGIA:.spec.strategy.type,MAX_SURGE:.spec.strategy.rollingUpdate.maxSurge,MAX_UNAVAIL:.spec.strategy.rollingUpdate.maxUnavailable'
echo

trap sonda_borrar EXIT INT TERM
sonda_iniciar
echo "Línea base de ${LINEA_BASE}s..."
sleep "$LINEA_BASE"

INICIO=$(date +%s)
for d in $DEPLOYS; do
    echo
    echo "=== rollout restart $d ==="
    t0=$(ahora)
    kubectl get pods -n "$NS" -l app="$d" -o custom-columns='POD:.metadata.name,FASE:.status.phase' --no-headers | sed 's/^/  antes: /'
    kubectl rollout restart deployment/"$d" -n "$NS" >/dev/null
    if ! kubectl rollout status deployment/"$d" -n "$NS" --timeout=300s; then
        echo "ATENCIÓN: el rollout de $d no terminó en 300 s." >&2
    fi
    echo "  duración del rollout: $(restar "$(ahora)" "$t0") s"
    kubectl get pods -n "$NS" -l app="$d" -o custom-columns='POD:.metadata.name,FASE:.status.phase' --no-headers | sed 's/^/  después: /'
done

echo
echo "Cola de ${COLA}s para registrar el apagado de los pods viejos..."
sleep "$COLA"

LOG="$(mktemp "${TMPDIR:-/tmp}/sonda-despliegue.XXXXXX")"
sonda_recolectar "$LOG"
sonda_borrar
trap - EXIT INT TERM

echo
echo "=== Resultado (log completo en $LOG) ==="
if sonda_resumen "$LOG" "$INICIO"; then
    echo "OK: 0 respuestas fallidas durante el reemplazo de: $DEPLOYS"
    exit 0
else
    echo "FALLÓ: hubo respuestas fuera de 2xx/3xx (ver detalle arriba)."
    exit 1
fi
