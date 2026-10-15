# Guía: modelo en el clúster + benchmark en local (vía túnel SSH)

Montaje de este fork para correr evaluaciones **sin Docker en el clúster**:

- El **model server** corre en el clúster (GPU del nodo), nativo, con `vla-eval serve`.
- El **benchmark** corre en otra máquina con Docker (tu notebook Windows + Docker Desktop,
  o un servidor Linux), y se conecta al modelo por **WebSocket a través de un túnel SSH**.

```
  [Notebook Windows / servidor Linux]            [Clúster]
   benchmark (Docker)  --WebSocket-->  túnel SSH  -->  model server (GPU)
                                       vía kraken        nodo (p.ej. ventress)
```

El benchmark es el **cliente**: marca hacia el model server. Por eso el modelo tiene que
quedar alcanzable desde la máquina del benchmark, y para eso está el túnel.

---

## 1) Cómo usar los dos scripts

### Parte 1 — modelo en el clúster: `scripts/model_server.sbatch`

Desde el repo en el clúster:

```bash
sbatch scripts/model_server.sbatch
tail -f slurm/logs/vla-model.log      # espera a "Server listo." y anota el NODO (p.ej. ventress)
```

El job levanta el `serve` en `0.0.0.0:$PORT` y, cuando está listo, imprime en el log el
comando de túnel ya resuelto. La **primera vez** tarda (descarga torch + deps + checkpoint
de HuggingFace, varios GB); todo queda cacheado en `~/.cache`, así que los arranques
siguientes son de ~1-2 min.

Overrides por entorno:

```bash
PORT=8001 MODEL_CFG=configs/model_servers/oft/libero_spatial.yaml sbatch scripts/model_server.sbatch
```

Detener el modelo: `scancel <jobid>` (el jobid sale en el log / `squeue -u $USER`).

### Parte 2 — benchmark en local

**En Windows (Docker Desktop):** `scripts/run_benchmark.ps1`

```powershell
.\scripts\run_benchmark.ps1 -ClusterNode ventress
.\scripts\run_benchmark.ps1 -ClusterNode ventress -BenchCfg configs/benchmarks/libero/spatial_video.yaml
```

El `.ps1` abre el túnel solo, espera a que el modelo responda, corre el benchmark y cierra
el túnel al terminar. Parámetros: `-BenchCfg`, `-Port`, `-ClusterNode`, `-LoginNode`.
Cualquier argumento extra se reenvía a `vla-eval run` (p.ej. `--record-video`).

> Requisitos Windows (una vez): Docker Desktop con backend **WSL2 + GPU**, `uv`
> (`winget install astral-sh.uv`), repo clonado con `uv sync`, y `ssh kraken` funcionando.

**En un servidor Linux:** `scripts/run_benchmark.sh`

```bash
CLUSTER_NODE=ventress scripts/run_benchmark.sh                                   # abre el túnel solo
CLUSTER_NODE=ventress BENCH_CFG=configs/benchmarks/libero/spatial.yaml scripts/run_benchmark.sh
scripts/run_benchmark.sh                                                         # si ya tienes un túnel abierto aparte
```

---

## 2) Cómo cambiar de benchmark / modelo

No se tocan los scripts: se cambia **qué YAML de config** usa cada lado.

### Cambiar el benchmark

Es el archivo que pasas con `-BenchCfg` (Windows) o `BENCH_CFG=` (Linux). Están en
`configs/benchmarks/<benchmark>/`.

```powershell
# LIBERO-Spatial oficial (10 tareas x 50 ep)
.\scripts\run_benchmark.ps1 -ClusterNode ventress -BenchCfg configs/benchmarks/libero/spatial.yaml
# Otro suite de LIBERO
.\scripts\run_benchmark.ps1 -ClusterNode ventress -BenchCfg configs/benchmarks/libero/object.yaml
```

Dentro de un YAML de benchmark, lo que más vas a tocar:

| Clave | Qué controla |
|---|---|
| `episodes_per_task` | repeticiones de cada tarea (cada una con un estado inicial distinto) |
| `max_tasks` | limita cuántas tareas corre (bórrala para todas) |
| `params.suite` | subconjunto del benchmark (p.ej. `libero_spatial`, `libero_object`) |
| `recording.record_video` | `true` para guardar un mp4 por episodio |
| `recording.video_fps` | fps del video |

> Episodios totales = `episodes_per_task` x nº de tareas. Para ver **tareas distintas**,
> sube el nº de tareas (quita `max_tasks`); subir `episodes_per_task` repite la misma tarea.

### Cambiar el modelo

Es el YAML que usa la Parte 1, con `MODEL_CFG=`. Están en `configs/model_servers/<modelo>/`.

```bash
MODEL_CFG=configs/model_servers/openvla/libero_spatial.yaml sbatch scripts/model_server.sbatch
```

**Importante — compatibilidad y GPU:**

- El modelo y el benchmark deben coincidir en el dominio (un config de modelo para LIBERO
  con un benchmark de LIBERO). Mira el nombre del YAML (`.../xvla/libero.yaml`).
- El nodo del clúster (p.ej. GTX 1080 Ti, 11 GB) tiene que tener VRAM suficiente. X-VLA
  (0.9B) cabe; OpenVLA-7B / CogACT NO caben en 11 GB.
- Si usas otro puerto, pásalo en **ambos** lados (`PORT=` en el sbatch y `-Port`/`PORT=`
  en el benchmark).

---

## 3) Pasos para agregar un modelo nuevo

Un "model server" es un **uv script de un solo archivo** en `src/vla_eval/model_servers/`
que carga tu checkpoint y responde observación -> acción. Pasos:

1. **Crea el script del server** en `src/vla_eval/model_servers/mimodelo.py`, copiando uno
   existente como plantilla (`xvla.py` es buen ejemplo). Debe tener:
   - El bloque de dependencias uv al inicio (`# /// script ... # ///`) con tus libs y
     `vla-eval` como dependencia editable.
   - Una clase que herede de `ModelServer` (ver `src/vla_eval/model_servers/base.py`) e
     implemente la inferencia: recibe la observación (imágenes + estado + instrucción) y
     devuelve la acción en el formato que espera el benchmark (p.ej. 7-D para LIBERO:
     `[pos3, axisangle3, gripper]`).

2. **Crea el/los config(s)** en `configs/model_servers/mimodelo/`:
   - `_base.yaml` con `script: "src/vla_eval/model_servers/mimodelo.py"` y los `args:`
     comunes (incluye `port: 8000`).
   - Un config por dominio (p.ej. `libero.yaml`) con `extends: _base.yaml` y los `args`
     específicos: `model_path`, `chunk_size`, etc.

3. **Pruébalo localmente** (valida configs y, si tienes GPU + pesos, el server):
   ```bash
   vla-eval test -c configs/model_servers/mimodelo/libero.yaml   # valida el config
   vla-eval test --server -c configs/model_servers/mimodelo/libero.yaml
   ```

4. **Correlo en el clúster** con el flujo normal:
   ```bash
   MODEL_CFG=configs/model_servers/mimodelo/libero.yaml sbatch scripts/model_server.sbatch
   ```
   La primera vez bajará las deps del uv script + el checkpoint (cacheado en `~/.cache`).

5. **Verifica la paridad**: corre un smoke de 1 episodio contra un benchmark del mismo
   dominio y revisa que el episodio complete y el formato de acción sea el correcto.

> Para la guía detallada (ciclo de vida de la sesión, estado entre pasos, formatos de
> acción por benchmark, validación), usa la skill **`add-model-server`** o lee
> `CONTRIBUTING.md`. Esta sección es el resumen operativo para este montaje remoto.

---

## Checklist rápido

```
[ ] Clúster:  sbatch scripts/model_server.sbatch   -> espera "Server listo." + anota el nodo
[ ] Local:    .\scripts\run_benchmark.ps1 -ClusterNode <nodo> -BenchCfg <config>
[ ] Resultados en  results\recording-*.sqlite  (+ mp4 si record_video: true)
[ ] Exportar:  uv run vla-eval export results\recording-<eval_id>.sqlite
```
