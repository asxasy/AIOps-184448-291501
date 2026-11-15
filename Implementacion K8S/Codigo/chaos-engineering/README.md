# Chaos Engineering

Punto de entrada unico: `./chaos.sh <experimento> [opciones]` (bash 3.2 compatible, probado con `--dry-run`).

Requisitos: app en K8s (namespace `pharmago`), `kubectl` con acceso al cluster, `k8s/port-forward.sh` activo
(para `requests` y para la sonda del Gateway que se imprime cada 5 s).

| Experimento | Comando | Que hace |
|---|---|---|
| Requests | `./chaos.sh requests --duration 60 --workers 30` | Carga concurrente por el Gateway (POST `/api/login`, o `--path /api/drug` para pegar en pharmacy y la DB); resumen de codigos HTTP y latencias |
| CPU | `./chaos.sh cpu --target gateway --duration 60` | Procesos que queman CPU en el pod (throttling contra el limite de 500m) |
| RAM | `./chaos.sh ram --target users --mb 300 --duration 45` | Retiene memoria en el pod (limite 384Mi) |
| Storage | `./chaos.sh storage --target gateway --mb 800 --duration 60` | Escribe en el disco efimero del contenedor (= disco del nodo) |
| Red | `./chaos.sh network --target users --mode delay\|loss\|partition\|svc-cut` | `tc netem` via `kubectl debug --profile=netadmin`, o corte del selector del Service |
| Desconexion | `./chaos.sh disconnect --target pharmacy` / `--mode kill` | `scale --replicas=0` por N segundos, o borrado del pod |
| Panico | `./chaos.sh restore-all` | Deshace todo en todos los componentes |

Opciones comunes: `--target gateway|users|pharmacy|db|ui`, `--duration N`, `--mode`, `--restore`, `--dry-run`, `--force`.
Ver `./chaos.sh --help`.

Cada corrida imprime con timestamp: hipotesis de estado estable, que se rompe, blast radius, señales y alertas
esperadas, el estado de los Deployments y una sonda al Gateway cada 5 s, y cuando termina. Antes de inyectar
verifica que el namespace y el target existan y que todo este sano (condicion de aborto: si no, no inyecta;
`--force` lo ignora). Durante la falla aborta y restaura si la DB cae sin ser el objetivo. La restauracion es
automatica (`trap` en EXIT/INT/TERM) y `--restore` es idempotente.

## Wrappers de los scripts originales

`cpu-spike.sh`, `ram-spike.sh`, `volume-spike.sh` y `load-requests.sh` conservan su interfaz y delegan en `chaos.sh`.

## Red: por que no NetworkPolicy

El CNI por defecto de Minikube no aplica `NetworkPolicy`, asi que no cortaria nada. Se usa un contenedor efimero
`nicolaka/netshoot` que comparte el namespace de red del pod y ejecuta `tc qdisc ... netem` sobre `eth0`.
La regla queda en el pod aunque el contenedor efimero termine: `--restore` la borra (o `kubectl delete pod`).
`netem` afecta el trafico que **sale** del pod. La imagen debe estar en Minikube: `minikube image pull nicolaka/netshoot`.

Ver impacto: Grafana, dashboards "PharmaGo - Infra" (CPU, memoria, disco por pod) y "PharmaGo - Overview"
(throughput, latencia, status codes, tasa de error); Kibana para los logs del Gateway.

## Limitaciones conocidas

- `/api/login` con credenciales invalidas responde 404 y el rate limit (10 por minuto por IP) da 429 en casi todo: ese modo mide el rate limit. Para carga real usar `--path /api/drug`.
- `network --mode svc-cut` no corta el trafico del Gateway: YARP reutiliza conexiones keep-alive abiertas hacia el pod y el selector solo afecta las nuevas. El script lo advierte; la tecnica recomendada es `partition`.
