# Plan de contención de incidentes operacionales de PharmaGo

> Documento del ítem 6 de la rúbrica (plan de contención de incidentes operacionales). Los playbooks se ensayan con `Implementacion K8S/Codigo/chaos-engineering/chaos.sh` (`./chaos.sh --help` lista los experimentos).

## 1. Propósito y alcance

Este plan define cómo preparamos, detectamos, respondemos, recuperamos y aprendemos de los incidentes operacionales de PharmaGo, siguiendo las cinco etapas del ciclo de vida de gestión de incidentes de Atlassian visto en clase [1]. Para este plan, un incidente es una interrupción o degradación del servicio que afecta la experiencia de los usuarios y requiere respuesta inmediata, como el incumplimiento de un SLA. Un bug que no exige respuesta inmediata no se considera un incidente.

El alcance comprende los componentes desplegados en el namespace pharmago: gateway, users-service, pharmacy-service, UI, base de datos y stack de observabilidad. Cada etapa incluye el documento sugerido por el docente: plan de incidentes con severidades, roles y playbooks; alertas accionables; registro de incidente; checklist de recuperación y post-mortem. Los playbooks corresponden a los escenarios que simulan los scripts de caos, por lo que el plan puede ensayarse.

## 2. Preparación

La etapa de preparación comprende las acciones previas a un incidente que permiten responder sin improvisar: definir los servicios críticos, los niveles de severidad con su tiempo de respuesta, la cantidad de personas y los criterios de escalado, los roles y la guardia, los canales de comunicación y los playbooks para incidentes conocidos. En PharmaGo, la criticidad de cada componente se determina por su impacto en el negocio: el gateway es la única entrada a la API; sin users no es posible iniciar sesión; sin pharmacy no hay ventas ni manejo de stock, y la base de datos es un punto único de falla que afecta a ambos servicios. Dado que los mecanismos de alta disponibilidad (réplicas, probes, circuit breaker y rate limit) resuelven muchas fallas de forma automática, varias se clasifican con severidad media, y la tarea del equipo consiste en confirmar que la automatización funcionó.

### 2.1. Servicios críticos

**Tabla 1: Servicios de PharmaGo, impacto en el negocio y protección.**

| Componente | Función | Impacto si cae | Qué lo protege |
|---|---|---|---|
| API Gateway (YARP) | Única entrada a la API | Toda la API deja de responder: SEV1 | 2 réplicas, probes, rolling update, PDB |
| users-service | Login, usuarios, roles e invitaciones | Nadie puede iniciar sesión: SEV1 | 2 réplicas, probes, breaker en el gateway |
| pharmacy-service | Medicamentos, compras, stock y farmacias | No hay ventas ni manejo de stock: SEV2 | 2 réplicas, probes, breaker en el gateway |
| Base de datos (SQL Server) | Persistencia de users y pharmacy | Caen users y pharmacy: SEV1 | 1 réplica (punto único de falla), volumen persistente |
| UI (Angular y nginx) | Frontend de la aplicación | Los usuarios no acceden a la aplicación: SEV1 | 2 réplicas, probes, PDB |
| Prometheus y Grafana | Métricas, dashboards y alertas | Se pierde la detección: SEV3 | Volumen persistente; Grafana alerta si Prometheus no responde |
| Collector, Jaeger, Fluent Bit, Elasticsearch y Kibana | Trazas y logs | Se pierde visibilidad, sin impacto en usuarios: SEV4 | Reinicio automático de Kubernetes |

### 2.2. Niveles de severidad

**Tabla 2: Niveles de severidad, tiempo de respuesta, personas y comunicación.**

| Nivel | Criterio y ejemplos en PharmaGo | Primera respuesta | Quiénes | Comunicación |
|---|---|---|---|---|
| SEV1 | La aplicación no se puede usar o hay riesgo de perder datos: gateway sin réplicas, base de datos caída, users caído, UI caída | 5 min, a cualquier hora | Incident commander y todos los responders | Stakeholders cada 15 min |
| SEV2 | Una funcionalidad central caída o degradada para muchos usuarios: pharmacy caído, más de 5 % de errores 5xx, latencia p95 mayor a 1 s sostenida | 15 min, a cualquier hora | Incident commander y el responder del área | Stakeholders cada 30 min |
| SEV3 | Falla contenida por los mecanismos de alta disponibilidad: un pod caído con la otra réplica atendiendo, CPU o memoria saturadas en un pod, consumo anómalo de disco, rate limit activo | 1 h, en horario hábil | Persona de guardia | Resumen al cierre |
| SEV4 | Sin impacto en usuarios: falla de la telemetría, alerta ruidosa | Siguiente día hábil | Persona de guardia | Ticket |

Escalado: un incidente sube un nivel si la mitigación no surte efecto en el doble del tiempo de primera respuesta o si el impacto crece (por ejemplo, un pod caído de SEV3 que entra en CrashLoopBackOff en las dos réplicas pasa a SEV1 o SEV2, según el servicio). Bajar de nivel lo decide el incident commander.

### 2.3. Roles, guardia y canales

**Tabla 3: Roles durante un incidente.**

| Rol | Responsabilidad |
|---|---|
| Persona de guardia | Recibe la alerta, confirma si es un incidente y asigna la severidad |
| Incident commander | Declara el incidente, coordina, decide y comunica; no ejecuta comandos |
| Responder de plataforma | Diagnostica y mitiga con kubectl: pods, réplicas, rollout, rollback |
| Responder de observabilidad | Confirma el diagnóstico y la recuperación con Grafana, Jaeger y Kibana |
| Escriba | Lleva el registro de incidente y la cronología |
| Stakeholders | Reciben el estado: dueños de farmacias, soporte |

La guardia rota una vez por semana según un calendario publicado, con un relevo documentado (incidentes abiertos, alertas ruidosas, cambios desplegados). Cada incidente de severidad 1 o 2 abre un canal único en Teams con el formato inc-AAAAMMDD-servicio, que es el único lugar donde se coordina y se informa el estado. Las notificaciones de Grafana van a un webhook que las indexa en Elasticsearch (historial consultable en Kibana); en un despliegue productivo se sumaría una herramienta de paging como las vistas en clase (Opsgenie o PagerDuty) para despertar a la guardia.

### 2.4. Playbooks

Cada playbook corresponde a un escenario conocido y a un experimento de chaos.sh con el que se puede ensayar. Quién lo ejecuta surge de su severidad (Tabla 2): la persona de guardia en SEV3 y SEV4; el incident commander con el responder del área en SEV2, y con todos los responders en SEV1. Todos los comandos se ejecutan en el namespace pharmago.

**Tabla 4: Playbook P1, falla de un pod (crash, OOMKilled o borrado).**

| Campo | Contenido |
|---|---|
| Disparador | Pod 0/1 o reinicios que suben en `kubectl get pods -w`; alerta de memoria si fue un OOMKill. Normalmente sin alerta de servicio, porque la otra réplica atiende |
| Severidad | SEV3 |
| Diagnóstico | `kubectl describe pod` (eventos y Last State: Error u OOMKilled); `kubectl logs --previous` |
| Mitigación | Automática: el kubelet reinicia el contenedor y el ReplicaSet recrea el pod. Si entra en CrashLoopBackOff después de un despliegue: `kubectl rollout undo` |
| Verificación | Deployment en 2/2 READY y sin 5xx en Golden Signals |
| Ensayo | `chaos.sh disconnect --target users --mode kill` |

**Tabla 5: Playbook P2, microservicio caído entero (users o pharmacy sin réplicas listas).**

| Campo | Contenido |
|---|---|
| Disparador | Alertas Servicio caído (up = 0) y Errores 5xx del Gateway |
| Severidad | SEV1 si es users; SEV2 si es pharmacy |
| Comportamiento esperado | El breaker del gateway se abre a los 8 s y esas rutas responden 503 al instante; el resto de la aplicación sigue funcionando (degradación controlada) |
| Diagnóstico | `kubectl get deploy,pods` y eventos; log del gateway con el destino marcado como no sano; traza con error en Jaeger |
| Mitigación | Restaurar réplicas (`kubectl scale deployment <servicio> --replicas=2`); quitar una regla de red (`chaos.sh network --target <servicio> --restore`); `kubectl rollout undo` si coincide con un despliegue |
| Verificación | `/test-health` (users) o `/test-health/pharmacy` responde 200, sin 503 durante 5 min y alertas en Normal |
| Ensayo | `chaos.sh disconnect --target pharmacy --duration 60` |

**Tabla 6: Playbook P3, base de datos caída.**

| Campo | Contenido |
|---|---|
| Disparador | Alertas Errores 5xx del Gateway y Latencia p95 del Gateway |
| Severidad | SEV1 |
| Comportamiento esperado | users y pharmacy siguen Ready (su liveness no depende de la base, a propósito), pero sus requests fallan: 504 a los 5 s y después 503 inmediatos por el breaker |
| Diagnóstico | `kubectl get pods -l app=pharmago-db`, logs de SQL Server y spans SQL con error en Jaeger |
| Mitigación | Esperar el reinicio automático (35 s medidos); si no vuelve, revisar el volumen persistente y los eventos. No reiniciar los microservicios: no arregla la base |
| Verificación | Login y `/api/drug` responden 200 y sus trazas muestran spans SQL sin error |
| Ensayo | `chaos.sh disconnect --target db --mode kill` |

**Tabla 7: Playbook P4, sobrecarga de CPU.**

| Campo | Contenido |
|---|---|
| Disparador | Alerta CPU del contenedor saturada (throttling); puede sumarse la de latencia p95 |
| Severidad | SEV3; SEV2 si la latencia p95 supera 1 s |
| Diagnóstico | Panel de saturación de Golden Signals (CPU contra límite y throttling); `kubectl exec` en el pod para ver los procesos |
| Mitigación | Cortar el proceso que consume. Si la carga es legítima, escalar réplicas o subir el límite de CPU con un despliegue |
| Verificación | Throttling por debajo de 3 períodos por segundo y p95 menor a 1 s durante 5 min |
| Ensayo | `chaos.sh cpu --target gateway --duration 90` |

**Tabla 8: Playbook P5, presión de memoria.**

| Campo | Contenido |
|---|---|
| Disparador | Alerta Memoria del contenedor (más de 80 % del límite) |
| Severidad | SEV3 |
| Diagnóstico | Panel de memoria contra límite; `kubectl describe pod` para ver OOMKilled y reinicios |
| Mitigación | Borrar el pod afectado antes del OOMKill (la otra réplica atiende); si se repite, buscar la fuga y subir el límite |
| Verificación | Memoria por debajo de 80 % y sin reinicios nuevos |
| Ensayo | `chaos.sh ram --target users --mb 300 --duration 45` |

**Tabla 9: Playbook P6, consumo anómalo de disco.**

| Campo | Contenido |
|---|---|
| Disparador | Alerta Consumo anómalo de disco del nodo |
| Severidad | SEV3; SEV2 si el nodo entra en DiskPressure y empieza a desalojar pods |
| Diagnóstico | Panel de escrituras por pod (dashboard Infra); `kubectl exec` con du en el pod; `kubectl describe node` |
| Mitigación | Borrar el archivo o reiniciar el pod, que libera su disco efímero; si es la base, revisar el volumen |
| Verificación | La alerta se resuelve sola a los 2 min y el espacio libre queda estable |
| Ensayo | `chaos.sh storage --target gateway --mb 400 --duration 60` |

**Tabla 10: Playbook P7, red degradada (latencia o pérdida de paquetes).**

| Campo | Contenido |
|---|---|
| Disparador | Alerta Latencia p95 del Gateway; Errores 5xx si hay timeouts |
| Severidad | SEV2 |
| Diagnóstico | En Jaeger, qué tramo tarda (gateway hacia qué servicio y qué réplica); readiness NotReady en el pod afectado |
| Mitigación | Quitar la regla (`chaos.sh network --target <servicio> --restore`) o borrar el pod afectado. El timeout de 5 s y el breaker acotan el impacto mientras tanto |
| Verificación | p95 menor a 1 s durante 5 min |
| Ensayo | `chaos.sh network --target users --mode delay --delay-ms 800 --duration 60` |

**Tabla 11: Playbook P8, inyección de requests o abuso.**

| Campo | Contenido |
|---|---|
| Disparador | Alertas Rate limiting activo (429) y Pico de tráfico |
| Severidad | SEV3; SEV2 si afecta a usuarios legítimos |
| Diagnóstico | Endpoint y origen en los logs del gateway en Kibana; distribución de códigos en Golden Signals |
| Mitigación | El rate limit ya devuelve 429. Si es abuso, bloquear el origen; si es tráfico legítimo, escalar el gateway y revisar los límites |
| Verificación | Cesan los 429, el tráfico vuelve a la línea base y la latencia p95 es normal |
| Ensayo | `chaos.sh requests --duration 60 --workers 30` |

## 3. Detección

El objetivo de la etapa de detección es reducir el MTTD, es decir, el tiempo hasta que el equipo se entera de un incidente, mediante alertas accionables y el monitoreo de métricas de infraestructura y de aplicación. Para ello nos apoyamos en lo ya construido: nueve alertas en Grafana sobre métricas de Prometheus, el dashboard de golden signals, las trazas en Jaeger y los logs en Kibana. Los reportes de usuarios que llegan a soporte son un segundo canal de detección: la persona de guardia los contrasta con los mismos paneles y, si se confirman, abre el registro de incidente igual que ante una alerta. Cada alerta tiene una severidad asignada y un playbook asociado; una alerta que no conduce a una acción concreta es ruido. Las alertas pasan por un período de confirmación (for) de 15 a 30 s para no reaccionar a picos de un solo instante, y ese período forma parte del MTTD; la de disco no lo necesita, porque ya mira una ventana de 2 minutos. Los SLO se derivan de los umbrales de clase y de las alertas.

**Tabla 12: Alertas, severidad y playbook.**

| Alerta de Grafana | Etiqueta | Severidad | Playbook |
|---|---|---|---|
| Servicio caído (up = 0) | critical | SEV1 o SEV2 según el servicio; SEV4 si es telemetría | P2 |
| Tasa de errores 5xx del Gateway (más de 5 %) | critical | SEV2 | P2, P3 |
| Latencia p95 del Gateway (más de 1 s) | warning | SEV2 | P3, P4, P7 |
| Pico de tráfico (3 veces la línea base) | warning | SEV3 | P8 |
| Rate limiting activo (429) | warning | SEV3 | P8 |
| Caída brusca de tráfico | warning | SEV2 | P2 (verificar que los clientes lleguen al gateway) |
| CPU del contenedor saturada (throttling) | warning | SEV3 | P4 |
| Memoria del contenedor (más de 80 %) | warning | SEV3 | P5 |
| Consumo anómalo de disco en el nodo | warning | SEV3 | P6 |

**Tabla 13: Indicadores (SLI) y objetivos (SLO).**

| Indicador (SLI) | Cómo se mide | Objetivo (SLO) |
|---|---|---|
| Tasa de errores 5xx del gateway | Panel de errores de Golden Signals y alerta | Menos de 5 % por minuto |
| Latencia p95 del gateway | Panel de latencia y alerta | Menor a 1 s |
| Disponibilidad ante la caída de un pod | Sonda dentro del clúster (verificar-autocuracion.sh) | 0 requests fallidos: MTTRestore del servicio dentro de los 5 s del escenario de clase; pod reemplazado en menos de 10 s (medido: 3,2 a 5,7 s) |
| Disponibilidad durante un despliegue | Sonda dentro del clúster (verificar-despliegue-seguro.sh) | 0 requests fallidos (medido: 0 de 342) |
| MTTD | Registro de incidente: hora de la alerta menos hora de inicio | Menos de 1 min (objetivo, no medido) |
| MTTRepair en SEV1 y SEV2 | Registro de incidente | 30 min, como en el escenario de reparabilidad de clase |

## 4. Respuesta

Ante la activación de una alerta, la persona de guardia confirma si se trata de un incidente o de una falsa alarma y asigna la severidad según la Tabla 2. Si la severidad es 1 o 2, declara el incidente y convoca el war room. El incident commander coordina y toma decisiones, sin ejecutar comandos; los responders diagnostican y mitigan, mientras que los stakeholders reciben información sobre el estado.

El war room es una reunión ad hoc con un único canal para centralizar y comunicar el estado. Todo se documenta en el registro de incidente, y las decisiones se basan en hechos observados en la telemetría, evitando contrafactuales. La prioridad es mitigar para restaurar el servicio y, después, buscar la causa raíz. El registro de incidente conserva los timestamps que permiten calcular el MTTD y el MTTRestore.

**Tabla 14: Plantilla de registro de incidente.**

| Campo | Contenido |
|---|---|
| Identificador y título | INC-AAAAMMDD-N y una descripción corta |
| Severidad y estado | SEV1 a SEV4; investigando, mitigado o resuelto |
| Inicio | Hora del primer síntoma, tomada del panel o de la alerta |
| Detección y declaración | Hora de la alerta o del reporte de usuario y hora en que se declaró el incidente (para el MTTD) |
| Roles | Incident commander, responders y escriba |
| Servicios afectados | Componentes y rutas de la API |
| Descripción e impacto | Qué ven los usuarios y qué SLO se está consumiendo |
| Cronología de acciones | Hora, quién, acción y resultado; solo hechos, sin contrafactuales |
| Mitigación y resolución | Hora de la mitigación y de la resolución (para el MTTRestore) |
| Evidencia | Enlaces al panel, a la traza en Jaeger y a la consulta en Kibana |

## 5. Recuperación

La recuperación consiste en devolver el servicio a un estado estable y comprobarlo con datos: hay que descartar un falso positivo de recuperación, definir las condiciones de recuperación y medirlas. Entre las mitigaciones vistas en clase se encuentran el rollback, la degradación controlada para reducir el blast radius y el circuit breaker. En PharmaGo, el breaker ya aplica una degradación controlada: si pharmacy cae, sus rutas responden 503 al instante y el resto de la aplicación sigue funcionando. Sin embargo, un 200 aislado no confirma estabilidad: al volver un servicio, el breaker pasa a semiabierto y deja pasar requests de prueba, pero el primer pod puede estar frío y una respuesta lenta puede reabrirlo. Por eso, el checklist de clase se traduce en condiciones medibles con la telemetría durante una ventana de 5 minutos.

**Tabla 15: Checklist de recuperación.**

| Pregunta de la clase | Condición medible en PharmaGo |
|---|---|
| ¿Volvió a funcionar de forma consistente? | Todos los deployments en 2/2 READY (la base en 1/1); un login y un GET a `/api/drug` de prueba responden 200 y sus trazas en Jaeger no tienen spans con error |
| ¿Se mantiene estable? | Errores 5xx por debajo de 5 % y p95 menor a 1 s durante 5 min seguidos; alertas en Normal; sin reinicios nuevos; sin rebotes del breaker |
| ¿Los usuarios siguen reportando errores? | Sin logs nuevos de nivel Error en Kibana desde la mitigación; sin 503 ni 429 inesperados; sin reportes de soporte |

## 6. Aprendizaje

El aprendizaje se realiza mediante un post-mortem sin culpables, unos días o hasta una semana después del incidente. El análisis documenta qué ocurrió, cuál fue el impacto, la cronología, la causa raíz y las acciones correctivas, formuladas con un verbo, como "reducir" o "eliminar". Su objetivo es evitar que el incidente se repita, no asignar responsabilidades. También se distinguen las correcciones, que mitigan los efectos, de las acciones correctivas, que atacan las causas.

**Tabla 16: Plantilla de post-mortem.**

| Sección | Contenido |
|---|---|
| Resumen | Qué pasó, en dos o tres oraciones |
| Impacto | Duración, usuarios y funcionalidades afectadas, SLO consumido |
| Cronología | Inicio, detección, declaración, mitigación y resolución, tomadas del registro de incidente |
| Causa raíz | Cadena de causas hasta la que, si se elimina, evita la recurrencia |
| Qué funcionó y qué no | Mecanismos, alertas y playbooks que ayudaron o faltaron |
| Correcciones | Lo que se hizo para restaurar el servicio (mitiga efectos) |
| Acciones correctivas | Con verbo, responsable y fecha (atacan las causas) |

### 6.1. Post-mortem de un incidente real: disco lleno durante la construcción de imágenes

El 6/11/2026, durante la construcción de las imágenes de la aplicación, se llenó el disco de la máquina de desarrollo. El sistema de archivos interno de la máquina virtual de Docker presentó errores de escritura, se volvió a montar en solo lectura y Docker quedó colgado. Tras liberar espacio y reiniciar Docker, los servicios .NET fallaban dentro del clúster con "exec format error", aunque la imagen era de la arquitectura correcta y arrancaba fuera del clúster. El síntoma apuntaba a una causa falsa, la arquitectura, que descartamos con evidencia. La causa real fue que la capa base de la imagen se había cargado en Minikube durante los errores de disco y quedó corrupta; como containerd reutiliza las capas por su hash, recargar la imagen no alcanzaba. Se resolvió recreando Minikube desde cero y verificando con un pod de prueba que .NET arrancara dentro del nodo antes de desplegar. No hubo impacto en usuarios, porque era el entorno de desarrollo, pero el equipo quedó sin clúster.

**Tabla 17: Post-mortem del incidente de disco lleno.**

| Sección | Contenido |
|---|---|
| Impacto | Entorno de desarrollo sin clúster utilizable; sin impacto en usuarios |
| Causa raíz | El disco del host se quedó sin margen durante el build. Los errores de escritura dejaron en solo lectura el sistema de archivos de la máquina virtual de Docker y corrompieron la capa base cargada en el containerd de Minikube, que reutiliza capas por hash |
| Qué funcionó | Leer los logs de la máquina virtual de Docker; descartar la arquitectura con evidencia (el binario era ARM y la imagen arrancaba fuera del clúster) |
| Qué no funcionó | Recargar la imagen, porque containerd reutilizaba la capa dañada |
| Correcciones | Liberar espacio; reiniciar Docker cerrando el proceso colgado; recrear Minikube; verificar con un pod de prueba que .NET arranca dentro del nodo |
| Acciones correctivas | Verificar que haya al menos 15 GB libres en el host antes de construir imágenes. Verificar dentro del nodo, con un pod de prueba, que la imagen base ejecuta antes de desplegar después de cualquier error de almacenamiento. Reconstruir el clúster desde un estado conocido ante errores de almacenamiento, en lugar de repararlo pieza por pieza. Alertar el consumo anómalo de disco en el nodo del clúster (implementado como alerta de Grafana; el disco del host se sigue controlando a mano) |

### 6.2. Aprendizajes de los experimentos de caos

Los experimentos de caos funcionan como incidentes ensayados. Cada hallazgo se trató como un mini post-mortem, con su causa y su acción correctiva.

**Tabla 18: Hallazgos de los experimentos y acciones correctivas.**

| Experimento | Hallazgo | Causa | Acción correctiva y resultado |
|---|---|---|---|
| Caída total de pharmacy | El breaker se reabría en el estado semiabierto | Requests colgados hasta 10 s terminaban con error después de abrirse el breaker | Reducir el timeout por request a 5 s: el servicio se estabiliza 7 s antes |
| Ráfaga de logins | 15 de 15 logins pasaban rotando el header X-Real-IP | El rate limit confiaba en un header que controla el cliente | Usar la IP de la conexión: el intento 11 recibe 429 |
| Corte de red cambiando el selector del Service | El tráfico seguía llegando al pod | El gateway reutiliza conexiones keep-alive ya abiertas | Eliminar esa técnica del script como corte de red y usar tc netem |
| Falla de una réplica medida desde el host | Todos los requests daban 200 | Kubernetes balancea por conexión y el tráfico iba a la otra réplica | Medir con una sonda dentro del clúster que abre una conexión por request |
| Verificación de logs | Los logs llegaban a Elasticsearch sin parsear | containerd escribe en formato CRI y Fluent Bit esperaba el de Docker | Configurar Fluent Bit para ambos formatos: los campos se filtran con KQL |

## Referencias bibliográficas

[1] Atlassian, "Incident response lifecycle: stages and best practices." [En línea]. Disponible: https://www.atlassian.com/incident-management/incident-response/lifecycle. [Accedido: 7-nov-2026].  
