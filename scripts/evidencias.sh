#!/usr/bin/env bash
# Recorre los pasos 2, 3, 6 y 7 del taller y guarda las salidas en la carpeta evidencias/.
# Se detiene en cada momento en que hay que tomar una captura de pantalla.
#
# Requisitos: el stack arriba (docker compose up -d --build) y Git Bash, macOS o Linux.
# Uso, desde la raíz del repositorio:
#   bash scripts/evidencias.sh
#
# k6 se lanza en segundo plano durante 12 minutos para que haya tráfico en todos los pasos.

set -u
PROM=http://localhost:9090
OUT=evidencias
mkdir -p "$OUT"

pausa() {
  echo
  echo ">>> CAPTURA: $1"
  read -r -p "    Pulsa Enter cuando la hayas tomado... " _
}

promql() {  # $1 = nombre del archivo, $2 = consulta
  curl -s -G "$PROM/api/v1/query" --data-urlencode "query=$2" > "$OUT/$1.json"
  echo "  - $1: $(head -c 400 "$OUT/$1.json")"
}

esperar_alerta() {  # $1 = nombre de la alerta, $2 = estado (pending|firing|inactive)
  echo "Esperando a que $1 esté en '$2' (puede tardar 1-2 minutos)..."
  # La serie ALERTS existe mientras una alerta está en pending o firing.
  if [ "$2" = "inactive" ]; then filtro="ALERTS{alertname=\"$1\"}"; else filtro="ALERTS{alertname=\"$1\",alertstate=\"$2\"}"; fi
  for _ in $(seq 1 60); do
    if curl -s -G "$PROM/api/v1/query" --data-urlencode "query=$filtro" | grep -q '"result":\[\]'; then
      vacia=si
    else
      vacia=no
    fi
    if [ "$2" = "inactive" ] && [ "$vacia" = si ]; then echo "  $1 inactiva"; return; fi
    if [ "$2" != "inactive" ] && [ "$vacia" = no ]; then echo "  $1 -> $2"; return; fi
    sleep 5
  done
  echo "  (tiempo de espera agotado; revisa http://localhost:9090/alerts)"
}

echo "== Paso 2: pruebas manuales =="
{
  echo '$ curl -s http://localhost:8082/api/inventario/teclado'
  curl -s http://localhost:8082/api/inventario/teclado; echo
  for p in teclado portatil tablet; do
    echo "\$ POST /api/pedidos {\"producto\":\"$p\"}"
    curl -s -X POST http://localhost:8081/api/pedidos -H "Content-Type: application/json" -d "{\"producto\":\"$p\",\"cantidad\":1}"; echo
  done
  echo '$ curl -s http://localhost:8081/api/pedidos/1'
  curl -s http://localhost:8081/api/pedidos/1; echo
  echo '$ curl -s http://localhost:8081/actuator/prometheus | grep pedidos_total'
  curl -s http://localhost:8081/actuator/prometheus | grep pedidos_total
} | tee "$OUT/paso2-pruebas.txt"

echo
echo "== Lanzando k6 en segundo plano (12 minutos) =="
docker compose run --rm -T -e DURACION=12m k6 > "$OUT/k6-resumen.txt" 2>&1 &
K6_PID=$!
echo "Esperando 90 segundos para que se acumulen datos..."
sleep 90

echo "== Paso 3: consultas PromQL =="
promql consulta1-up 'up{job="tienda"}'
promql consulta3-rate 'sum by (application) (rate(http_server_requests_seconds_count{uri!~"/actuator.*"}[1m]))'
promql consulta4-status 'sum by (application, status) (rate(http_server_requests_seconds_count{uri!~"/actuator.*"}[1m]))'
promql consulta6-p95 'histogram_quantile(0.95, sum by (application, le) (rate(http_server_requests_seconds_bucket{uri!~"/actuator.*"}[1m])))'
promql consulta7-pedidos 'sum by (resultado) (increase(pedidos_total[5m]))'
promql consulta8-stock 'inventario_stock'
pausa "http://localhost:9090/targets con pedidos e inventario en UP  -> img/targets-up.png"
pausa "Consultas 3, 6 y 7 en http://localhost:9090/query (pestaña Graph) -> img/consulta3.png, img/consulta6.png, img/consulta7.png"
pausa "Dashboard completo en http://localhost:3000 con tráfico, incluida la fila 'Paneles del equipo Zero Day' -> img/dashboard.png"
pausa "Traza normal en Jaeger (Service pedidos, http post /api/pedidos) -> img/traza-normal.png"
pausa "Alertas en Inactive en http://localhost:9090/alerts -> img/alertas-inactive.png"

echo
echo "== Paso 6a: errores (tasaError=0.3) =="
curl -s -X POST "http://localhost:8082/api/fallas?tasaError=0.3"; echo
esperar_alerta TasaDeErroresAlta pending
pausa "TasaDeErroresAlta en Pending -> img/errores-pending.png"
esperar_alerta TasaDeErroresAlta firing
promql consulta5-errores 'sum by (application) (rate(http_server_requests_seconds_count{uri!~"/actuator.*", status=~"5.."}[1m])) / sum by (application) (rate(http_server_requests_seconds_count{uri!~"/actuator.*"}[1m]))'
promql errores-por-excepcion 'sum by (application, status, exception) (rate(http_server_requests_seconds_count{status=~"5.."}[1m]))'
pausa "TasaDeErroresAlta en Firing -> img/errores-firing.png, consulta 5 en /query -> img/consulta5.png, y panel 'Tasa de errores 5xx' en Grafana -> img/panel-errores.png"

echo
echo "== Paso 7: correlación log -> traza (con errores activos) =="
LINEA=$(docker compose logs pedidos 2>/dev/null | grep ERROR | tail -1)
TRACE=$(echo "$LINEA" | grep -o '\[[0-9a-f]\{32\}-[0-9a-f]\{16\}\]' | head -1 | cut -c2-33)
{
  echo "Log de pedidos:";    echo "$LINEA"
  echo; echo "traceId: $TRACE"
  echo; echo "Log de inventario con el mismo traceId:"
  docker compose logs inventario 2>/dev/null | grep "$TRACE"
  echo; echo "Traza: http://localhost:16686/trace/$TRACE"
} | tee "$OUT/paso7-correlacion.txt"
pausa "La traza con error abierta en http://localhost:16686/trace/$TRACE (spans en rojo, excepción visible) -> img/traza-error.png"

echo
echo "== Paso 6b: latencia (latenciaMs=800) =="
curl -s -X POST "http://localhost:8082/api/fallas?latenciaMs=800"; echo
esperar_alerta LatenciaP95Alta firing
promql consulta6-p95-lenta 'histogram_quantile(0.95, sum by (application, le) (rate(http_server_requests_seconds_bucket{uri!~"/actuator.*"}[1m])))'
pausa "LatenciaP95Alta en Firing -> img/latencia-firing.png  y panel 'Latencia p95' -> img/panel-latencia.png"
pausa "Traza lenta en Jaeger: el tiempo se va en el span de inventario -> img/traza-lenta.png"

echo
echo "== Regreso a la normalidad =="
curl -s -X DELETE http://localhost:8082/api/fallas; echo
esperar_alerta TasaDeErroresAlta inactive
esperar_alerta LatenciaP95Alta inactive
pausa "Alertas otra vez en Inactive -> img/alertas-inactive-final.png"

echo
echo "Esperando a que k6 termine..."
wait $K6_PID 2>/dev/null
echo "Listo. Salidas guardadas en $OUT/"
