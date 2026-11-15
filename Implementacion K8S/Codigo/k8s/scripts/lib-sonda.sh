#!/bin/bash
# Funciones comunes para medir disponibilidad desde DENTRO del clúster.
#
# La sonda es un pod con curl que pide en loop una lista de URLs a través de
# los Services (pasa por kube-proxy, igual que el tráfico real entre pods).
# No se mide por port-forward: "kubectl port-forward svc/..." se ata a UN pod
# y se corta cuando ese pod se reemplaza, lo que daría falsos negativos.
#
# Se usa con "source" desde verificar-despliegue-seguro.sh y
# verificar-autocuracion.sh. Compatible con el bash 3.2 de macOS.

NS="${NS:-pharmago}"
CURL_IMAGE="${CURL_IMAGE:-curlimages/curl:8.10.1}"
# Pausa entre requests. Con 5 URLs y 0.2 s salen ~5 req/s en total; solo
# /api/roles/ping y /api/unitmeasures cuentan para el rate limit (~120/min,
# debajo de 300/min para GET). /test-health* está en la whitelist.
INTERVALO="${INTERVALO:-0.2}"
GW_URL="http://pharmago-api-gateway"
URLS="${URLS:-$GW_URL/test-health $GW_URL/test-health/pharmacy $GW_URL/api/roles/ping $GW_URL/api/unitmeasures http://pharmago-ui/}"
SONDA="sonda-disp-$(date +%s)"

ahora() {
    python3 -c 'import time; print("%.1f" % time.time())' 2>/dev/null || date +%s
}

restar() {
    awk -v a="$1" -v b="$2" 'BEGIN { printf "%.1f", a - b }'
}

verificar_kubectl() {
    if ! kubectl get ns "$NS" >/dev/null 2>&1; then
        echo "Error: kubectl no llega al clúster o no existe el namespace $NS." >&2
        exit 2
    fi
}

sonda_iniciar() {
    echo "Iniciando sonda $SONDA ($CURL_IMAGE, intervalo ${INTERVALO}s)"
    echo "URLs: $URLS"
    # Cada línea de salida: <epoch> <código HTTP> <url>. 000 = sin respuesta.
    local loop='while true; do for u in $URLS; do c=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "$u"); echo "$(date +%s) $c $u"; sleep $INTERVALO; done; done'
    kubectl run "$SONDA" -n "$NS" --image="$CURL_IMAGE" --restart=Never \
        --labels=app=sonda-disponibilidad \
        --env="URLS=$URLS" --env="INTERVALO=$INTERVALO" \
        --command -- sh -c "$loop" >/dev/null
    if ! kubectl wait -n "$NS" --for=condition=Ready "pod/$SONDA" --timeout=120s >/dev/null; then
        echo "Error: la sonda no llegó a Ready (¿se pudo bajar $CURL_IMAGE?)." >&2
        sonda_borrar
        exit 2
    fi
}

sonda_recolectar() {
    kubectl logs -n "$NS" "$SONDA" > "$1" 2>/dev/null
}

sonda_borrar() {
    kubectl delete pod -n "$NS" "$SONDA" --wait=false --ignore-not-found >/dev/null 2>&1
}

# sonda_resumen <archivo> <epoch_inicio_accion>
# Imprime totales, fallas por código y URL, y la ventana de fallas.
# Devuelve 0 si no hubo respuestas fuera de 2xx/3xx.
sonda_resumen() {
    local archivo="$1" desde="${2:-0}"
    awk -v desde="$desde" '
        NF >= 3 {
            total++
            c = $2
            if (c ~ /^[23][0-9][0-9]$/) { ok++; next }
            if ($1 < desde) { previas++ }
            if (c == "429") { limitadas++ } else { fallas++ }
            if (primera == "") primera = $1
            ultima = $1
            detalle[c " " $3]++
        }
        END {
            printf "Requests totales:          %d\n", total
            printf "Respuestas 2xx/3xx:        %d\n", ok
            printf "Fallas (no 2xx/3xx):       %d\n", fallas + limitadas
            if (limitadas > 0)
                printf "  de las cuales 429:       %d (rate limit: subir INTERVALO, no es caída)\n", limitadas
            if (previas > 0)
                printf "  antes de la acción:      %d (el sistema ya fallaba antes de empezar)\n", previas
            if (total > 0)
                printf "Disponibilidad observada:  %.2f %%\n", 100 * ok / total
            if (fallas + limitadas > 0) {
                printf "Ventana con fallas:        %d s (de %d a %d)\n", ultima - primera + 1, primera, ultima
                print "Detalle (cantidad código url):"
                for (k in detalle) printf "  %5d %s\n", detalle[k], k
            }
            exit ((fallas + limitadas) > 0 ? 1 : 0)
        }' "$archivo"
}
