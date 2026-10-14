#!/bin/bash
# Lado BENCHMARK (máquina remota con Docker): corre el benchmark y se conecta al
# model server del clúster a través del túnel SSH ya abierto. El modelo NO corre
# aquí; vive en el clúster (ver scripts/model_server.sbatch).
#
# Requisitos en ESTA máquina:
#   - Docker + NVIDIA Container Toolkit (para render en GPU)
#   - este repo clonado + `uv sync --python 3.11 --all-extras --dev`
#   - el túnel SSH abierto hacia el model server, p.ej.:
#       ssh -L localhost:8000:<nodo-del-cluster>:8000 kraken
#     (el job del modelo imprime esta línea ya resuelta en su log)
#
# Uso:   scripts/run_benchmark.sh
#        PORT=8000 BENCH_CFG=configs/benchmarks/libero/smoke_test.yaml scripts/run_benchmark.sh

set -euo pipefail

# Ejecutar siempre desde la raíz del repo (para que las rutas de config funcionen).
cd "$(dirname "$0")/.."

# --- Parámetros (configurables por entorno) ----------------------------------
PORT="${PORT:-8000}"
BENCH_CFG="${BENCH_CFG:-configs/benchmarks/libero/smoke_test.yaml}"
SERVER_URL="ws://localhost:${PORT}"

# --- Verificar que el túnel está arriba antes de arrancar Docker -------------
echo "Comprobando el model server en http://localhost:${PORT}/health ..."
if ! curl -s --max-time 3 "http://localhost:${PORT}/health" >/dev/null; then
  echo "ERROR: nadie responde en localhost:${PORT}." >&2
  echo "       ¿Está abierto el túnel SSH y vivo el model server en el clúster?" >&2
  echo "       Túnel esperado:  ssh -L localhost:${PORT}:<nodo-del-cluster>:${PORT} kraken" >&2
  exit 1
fi
echo "OK: model server alcanzable en ${SERVER_URL}."

# --- Correr el benchmark (en Docker, --network host) -------------------------
# --server-url apunta al extremo local del túnel; --yes evita el prompt del docker pull.
echo "Corriendo benchmark: ${BENCH_CFG}"
uv run vla-eval run -c "${BENCH_CFG}" --server-url "${SERVER_URL}" --yes
