#!/bin/bash
# Smoke test de extremo a extremo: X-VLA (0.9B) + LIBERO-Spatial, 1 tarea / 1 episodio.
# Levanta el model server y el benchmark (Docker) en el MISMO nodo.
#
# Uso:   sbatch scripts/smoke_xvla_libero.sbatch
# Logs:  slurm/logs/vla-smoke.log          (job)
#        slurm/logs/vla-smoke.server.log   (model server)
#
# Nota sobre la GPU: yodaxico tiene GTX 1080 Ti (11 GB). X-VLA (0.9B, Florence-2)
# cabe de sobra; OpenVLA-7B / CogACT NO caben en 11 GB (por eso no se usan aquí).

#SBATCH --job-name=vla-smoke
#SBATCH --comment="Smoke test vla-evaluation-harness: X-VLA sobre LIBERO-Spatial, 1 episodio, para validar el pipeline modelo+benchmark"
#SBATCH --mail-type=END,FAIL
#SBATCH --mail-user=diego.toledo@uc.cl
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=24gb
#SBATCH --partition=ialab-low-unlimit     # verifica que yodaxico esté en esta partición: sinfo -N -l
#SBATCH --qos=debug
#SBATCH --gres=gpu:1                       # alternativa tipada si el clúster lo exige: gpu:1080_ti:1
#SBATCH --nodelist=yodaxico
#SBATCH --output=slurm/logs/%x.log
#SBATCH --time=1:00:00

set -euo pipefail

REPO=/mnt-homes/wapol/asoto/diegoftpxd/vla-evaluation-harness
cd "$REPO"

# uv debe estar en el PATH (instalado en ~/.local/bin por el instalador oficial).
[ -f "$HOME/.local/bin/env" ] && source "$HOME/.local/bin/env"
export PATH="$HOME/.local/bin:$PATH"

MODEL_CFG=configs/model_servers/xvla/libero.yaml
BENCH_CFG=configs/benchmarks/libero/smoke_test.yaml
SERVER_LOG="slurm/logs/${SLURM_JOB_NAME}.server.log"

echo "[$(date)] Nodo: $(hostname)"
nvidia-smi --query-gpu=name,memory.total --format=csv,noheader || true

# El benchmark corre dentro de Docker: sin Docker no hay forma de ejecutarlo.
if ! docker info >/dev/null 2>&1; then
  echo "[$(date)] ERROR: Docker no está disponible en $(hostname)."
  echo "            Si el clúster usa Apptainer/Singularity en vez de Docker, avísame y adaptamos el flujo."
  exit 1
fi
echo "[$(date)] Docker OK"

# 1) Model server (X-VLA) en background, escuchando en 0.0.0.0:8000.
echo "[$(date)] Iniciando model server (X-VLA 0.9B) -> $SERVER_LOG"
uv run vla-eval serve -c "$MODEL_CFG" --address 0.0.0.0:8000 -v >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!

# Asegura que el server se detiene al terminar (éxito, error o timeout).
cleanup() {
  echo "[$(date)] Deteniendo model server (pid $SERVER_PID)"
  kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
}
trap cleanup EXIT

# 2) Esperar a que el server responda (hasta ~15 min por la 1ª descarga del checkpoint de HF).
echo "[$(date)] Esperando al model server en http://localhost:8000/config ..."
for i in $(seq 1 180); do
  if curl -s --max-time 2 http://localhost:8000/config >/dev/null; then
    echo "[$(date)] Server listo."
    break
  fi
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "[$(date)] ERROR: el model server murió durante el arranque. Últimas líneas:"
    tail -n 50 "$SERVER_LOG" || true
    exit 1
  fi
  if [ "$i" -eq 180 ]; then
    echo "[$(date)] ERROR: timeout esperando al model server. Últimas líneas:"
    tail -n 50 "$SERVER_LOG" || true
    exit 1
  fi
  sleep 5
done

# 3) Smoke test: 1 tarea / 1 episodio de LIBERO-Spatial (benchmark en Docker, --network host).
#    --yes evita el prompt de confirmación del docker pull.
echo "[$(date)] Corriendo smoke test (1 tarea / 1 episodio)"
uv run vla-eval run -c "$BENCH_CFG" --yes

echo "[$(date)] Listo. Revisa el recording en: $REPO/results/recording-*.sqlite"
