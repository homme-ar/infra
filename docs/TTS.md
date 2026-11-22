# TTS.md — Qwen3-TTS Service Runbook (`voice` namespace)

Qwen3-TTS is a neural text-to-speech service consumed over HTTP by the
`live-tarot` app. It runs vLLM-Omni with the `Qwen/Qwen3-TTS-12Hz-0.6B-Base`
checkpoint and exposes an OpenAI-compatible Speech API on the LAN.

It is **not** a replacement for Piper (`piper.voice:10200`), which stays in
service for Home Assistant. Nothing in this runbook touches Piper.

## Components

| Resource | File | Notes |
|---|---|---|
| Deployment | `cluster/apps/iot/voice/qwen3-tts-deployment.yaml` | vLLM-Omni `v0.32.0`, `runtimeClassName: nvidia` |
| Service | `cluster/apps/iot/voice/qwen3-tts-service.yaml` | Cilium `LoadBalancer` on `${LB_QWEN3_TTS_IP}:8091`, LAN-only |
| Models PVC | `cluster/apps/iot/voice/qwen3-tts-pvc-models.yaml` | 25 Gi, HuggingFace cache, regenerable |
| Voices PVC | `cluster/apps/iot/voice/qwen3-tts-pvc-voices.yaml` | 2 Gi, uploaded voices, backed up |

- **Model**: `Qwen/Qwen3-TTS-12Hz-0.6B-Base`. The 1.7B variant does not fit
  alongside Ollama on the RTX A2000 (see [VRAM](#vram)).
- **Ports**: `8091` container/service. `GET /health`, `GET /v1/models`,
  `GET/POST/DELETE /v1/audio/voices`, `POST /v1/audio/speech`.
- **Output**: WAV 24 kHz, mono, PCM16.
- **Exposure**: LAN only. Do not add an `HTTPRoute` and do not port-forward
  `8091` on the router. The service has no authentication.

## Access

```bash
export KUBECONFIG=talos/clusterconfig/kubeconfig

# In-cluster
#   http://qwen3-tts.voice.svc.cluster.local:8091

# From the LAN
export BASE_URL="http://$(kubectl -n voice get svc qwen3-tts \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}'):8091"
echo "$BASE_URL"

# From a workstation without LAN routing
kubectl -n voice port-forward svc/qwen3-tts 8091:8091
export BASE_URL=http://127.0.0.1:8091
```

## Deploy and verify

Changes are applied by Flux; never `kubectl apply` or `helm install`.

```bash
kustomize build cluster/apps/iot/voice      # local render check
git add cluster/apps/iot/voice cluster/cluster-vars-private-secret.yaml
git commit -m "voice: add Qwen3-TTS service"
git push

export KUBECONFIG=talos/clusterconfig/kubeconfig
flux reconcile source git flux-system -n flux-system
flux reconcile kustomization cluster-apps -n flux-system
kubectl -n voice rollout status deploy/qwen3-tts --timeout=40m
kubectl -n voice get deploy,svc,pvc,pod -l app.kubernetes.io/name=qwen3-tts
```

The first start pulls a ~10 GiB image (before the container starts) and then
downloads the checkpoint. Measured on 2026-11-22:

| Stage | Time |
|---|---|
| Image pull (9.96 GB) | 17m45s |
| Checkpoint download (~2.3 GiB) | 44s |
| Engine init with image and weights cached | 2m14s from container start to Ready |
| First request after start | ~4.5s |
| Warm request, short sentence | ~1.4-1.7s |

The `startupProbe` and `progressDeadlineSeconds` both tolerate 30 minutes.

```bash
curl -fsS "$BASE_URL/health"
curl -fsS "$BASE_URL/v1/models"
```

## Uploading the voice (`bruja`)

The reference WAV is **not** stored in this repository. Keep it outside the
repo (for example `~/.local/voice-auditions/qwen-c-teatral.wav`) and upload it
once after the service is healthy. The upload is idempotent: re-posting the
same `name` overwrites the previous artifacts.

### 1. Clean the reference clip

Only trim leading silence and normalize loudness; do not remove internal
pauses (they are part of the theatrical delivery).

```bash
ffmpeg -y -i qwen-c-teatral.wav \
  -af "silenceremove=start_periods=1:start_threshold=-45dB,loudnorm=I=-16:TP=-1.5:LRA=7" \
  -ar 24000 -ac 1 -c:a pcm_s16le bruja-ref-clean.wav
```

### 2. Register the voice

```bash
curl -fsS -X POST "$BASE_URL/v1/audio/voices" \
  -F "audio_sample=@bruja-ref-clean.wav" \
  -F "consent=synthetic-qwen3tts-bruja" \
  -F "name=bruja" \
  -F "ref_text=Acercate un poco más, mi amor... El Sol ilumina tu camino y te invita a confiar en lo que ya sabés." \
  -F "speaker_description=old theatrical witch, deep cracked voice, slow dramatic pauses"

curl -fsS "$BASE_URL/v1/audio/voices" | jq
```

The list must include `bruja` in `voices` (and in `uploaded_voices`).

### 3. Confirm persistence

```bash
kubectl -n voice rollout restart deploy/qwen3-tts
kubectl -n voice rollout status deploy/qwen3-tts --timeout=40m
curl -fsS "$BASE_URL/v1/audio/voices" | jq '.uploaded_voices[].name'
```

Uploaded voices live in `SPEAKER_SAMPLES_DIR=/voices`, backed by the
`qwen3-tts-voices` Longhorn PVC. If that PVC is lost, repeat steps 1-2 from the
original WAV.

## Speech API

```bash
curl -fsS -D /tmp/headers.txt -X POST "$BASE_URL/v1/audio/speech" \
  -H 'content-type: application/json' \
  -d '{
    "model": "Qwen/Qwen3-TTS-12Hz-0.6B-Base",
    "input": "El Sol ilumina tu camino y te invita a confiar en lo que ya sabés.",
    "voice": "bruja",
    "task_type": "Base",
    "language": "Spanish",
    "response_format": "wav",
    "stream": false
  }' -o /tmp/bruja.wav

ffprobe -v error -show_entries stream=codec_name,sample_rate,channels,duration \
  -of default=nw=1 /tmp/bruja.wav
grep -i 'x-audio' /tmp/headers.txt
```

Streaming is available with `"stream": true, "stream_format": "audio",
"response_format": "pcm"` (raw PCM, 24 kHz) or `"stream_format": "sse"`.

## VRAM

The A2000 has 12.3 GiB usable. Ollama holds ~5.9 GiB (`OLLAMA_KEEP_ALIVE=-1`),
leaving ~6.3 GiB for this service. The bundled `qwen3_tts.yaml` requests 0.3 of
the GPU for each of the two stages (0.6 total, ~7.4 GiB), which would OOM, so
the Deployment overrides both stages:

```text
--stage-overrides '{"0": {"gpu_memory_utilization": 0.28, "max_num_seqs": 8}, "1": {"gpu_memory_utilization": 0.15, "max_num_seqs": 4}}'
```

That is 0.43 total (~5.3 GiB). Measured after 25 requests: ~10.9 GiB used of
12.3 GiB (including Ollama), ~1.4 GiB free, 0 restarts.

Stage 0 at 0.2 is too low: vLLM fails at startup with `ValueError: No
available memory for the cache blocks`. If the engine needs more room:

1. Lower `max_num_seqs` further before touching the utilization fractions.
2. Lower stage 1 toward 0.12; keep stage 0 at or above 0.28.
3. Or free VRAM by scaling Ollama to 0 — this breaks Lingarr and any other
   in-cluster LLM client while the TTS service runs. Do not do it silently.
4. The 1.7B checkpoint needs a larger stage 0 and does not fit next to Ollama;
   use it only with Ollama stopped or on a dedicated GPU.

## Monitoring and acceptance

```bash
kubectl -n voice logs deploy/qwen3-tts --tail=200
kubectl -n voice get pod -l app.kubernetes.io/name=qwen3-tts \
  -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}'
```

Acceptance status (2026-11-22; voice-quality items still pending the `bruja`
upload):

- [x] `/health` returns 200 and `/v1/models` lists the checkpoint.
- [ ] `/v1/audio/voices` lists `bruja`; it survives a `rollout restart`.
- [x] Output is WAV 24 kHz mono PCM16; the API returns 200.
- [ ] Five consecutive requests produce the same voice.
- [ ] TTFP p50 <= 800 ms with `stream: true`; E2E p50 <= 2.5 s for a
  15-word sentence; RTF p50 <= 0.6.
- [x] 25 consecutive requests without OOM, 0 failures, VRAM stable at
  ~10.9/12.3 GiB. Repeat up to 50 with the real voice.
- [x] Reachable only from the LAN (`10.0.22.8:8091`).
- [x] Cold start measured (see above).

## Rollback

Piper and Home Assistant are independent of this service; stopping Qwen3-TTS
does not affect them.

```bash
# Stop the service but keep the PVCs and the uploaded voice:
# commit `replicas: 0` in qwen3-tts-deployment.yaml, then push and reconcile.
flux reconcile kustomization cluster-apps -n flux-system

# Remove it entirely:
# delete the four qwen3-tts-* entries from
# cluster/apps/iot/voice/kustomization.yaml, push, and let Flux prune them.
# The PVCs are pruned too; the voices PVC is in the Longhorn NAS backups.
```

Do not use `kubectl scale` for routine operations; the Deployment replicas in
git are the source of truth.
