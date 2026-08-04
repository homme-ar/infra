# AI Subtitle Pipeline — Configuration Guide

Step-by-step guide to configure the AI subtitle pipeline
(`subarr` + `subgen` + `lingarr` + `ollama`) after deployment.
Infrastructure is already deployed via GitOps; this guide covers the
one-time, UI-level configuration that cannot be managed declaratively.

Overview of the flow:

```
Sonarr/Radarr/Bazarr ─→ Subarr (finds real gaps, queues work)
                            └─→ Subgen (Whisper, writes .<lang>.srt next to media)
                                     └─→ Lingarr (translates to .es.srt via Ollama aya:8b)
```

Bazarr never talks to Subgen — Subarr is the only Subgen client.

## 1. Collect the API keys

You need four keys for Subarr and two for Lingarr (the same Sonarr/Radarr
keys are reused):

| Key | Where to get it |
|---|---|
| `SONARR_API_KEY` | Sonarr → Settings → General → Security → API Key |
| `RADARR_API_KEY` | Radarr → Settings → General → Security → API Key |
| `BAZARR_API_KEY` | Bazarr → Settings → General → Security → API Key |
| `JELLYFIN_API_KEY` | Jellyfin → Dashboard → API Keys → `+` (name it e.g. `subarr`) |

## 2. Fill the SOPS secrets

```bash
sops cluster/apps/media/subarr/secret.yaml    # replace all four CHANGE_ME
sops cluster/apps/media/lingarr/secret.yaml   # replace both CHANGE_ME
```

Commit, push, and reconcile:

```bash
git add cluster/apps/media/subarr/secret.yaml cluster/apps/media/lingarr/secret.yaml
git commit -m "chore(media): set api keys for subarr and lingarr"
git push
flux --kubeconfig=talos/clusterconfig/kubeconfig reconcile source git flux-system -n flux-system
flux --kubeconfig=talos/clusterconfig/kubeconfig reconcile kustomization cluster-apps -n flux-system
```

The keys are injected as env vars, so restart the pods once to pick them up:

```bash
kubectl --kubeconfig talos/clusterconfig/kubeconfig rollout restart -n subarr deploy/subarr
kubectl --kubeconfig talos/clusterconfig/kubeconfig rollout restart -n lingarr deploy/lingarr
```

## 3. Verify Ollama (already done at deploy time)

The `aya:8b` model was pulled during deployment and persists on the
`ollama-models` Longhorn PVC. Sanity check:

```bash
kubectl --kubeconfig talos/clusterconfig/kubeconfig exec -n ollama deploy/ollama -- ollama list
# Expected: aya:8b listed
```

Nothing else to configure: `OLLAMA_KEEP_ALIVE=-1` keeps `aya:8b` resident in
VRAM (~5.2GB of the A2000's 12GB). Do NOT lower this to a short TTL: Ollama
returns HTTP 200 with an empty response for requests that arrive while the
model loads/unloads (ollama/ollama#16326), and Lingarr aborts the whole job on
the first empty response. `OLLAMA_MAX_LOADED_MODELS=1` keeps a single model
resident at a time.

## 4. Verify Subgen

Subgen is fully configured via env vars (Whisper `large-v3-turbo`, CUDA,
frees VRAM when the queue drains). There is no UI. Checks:

```bash
kubectl --kubeconfig talos/clusterconfig/kubeconfig logs -n subgen deploy/subgen --tail=20
kubectl --kubeconfig talos/clusterconfig/kubeconfig exec -n subgen deploy/subgen -- nvidia-smi
```

Note: the **first** transcription downloads the `large-v3-turbo` model (~3GB)
into the `subgen-models` PVC — expect the first job to be slow, subsequent
ones fast. Generated subtitles are named `.<lang>.subgen.large-v3-turbo.srt`
with 2-letter language codes (`.en.`, `.es.`) so Bazarr and Lingarr detect
them correctly.

## 5. Subarr onboarding

Open `https://subarr-apps.homme.ar` (behind Authelia; Subarr's own auth is
disabled on purpose).

1. The onboarding wizard auto-detects the integrations. All of them are set
   via env vars and appear **read-only**: Subgen
   (`http://subgen.subgen.svc.cluster.local:9000`), Sonarr, Radarr, Bazarr
   and Jellyfin. Confirm each shows online/healthy (Settings → Integrations).
2. Open the **Coverage** tab and start the first library walk. Subarr probes
   every file (audio tracks, embedded/external subs) before marking anything
   as a gap — un-probed files sit in "Analyzing". The first walk takes a
   while on a large library; later walks are incremental.
3. Optional but recommended — **Rules** tab: create an auto-queue rule so
   verified gaps are sent to Subgen automatically (e.g. score threshold +
   language filter). Without a rule you queue files manually from Coverage
   or Library.
4. Optional — scheduler: configure scheduled walks so new imports are
   picked up automatically (Dashboard shows the next scheduled run).

## 6. Lingarr configuration

Open `https://lingarr-apps.homme.ar` (behind Authelia).

Everything functional is already set via env vars:

- Radarr/Sonarr URLs + API keys (from the secret)
- Translation service: `localai` → `http://ollama.ollama.svc.cluster.local:11434/v1`,
  model `aya:8b`
- Source language: English (`en`); Target language: Spanish (`es`)
- SQLite DB on the Longhorn PVC at `/app/config`

In the UI:

1. Confirm Radarr and Sonarr show as connected.
2. Confirm the `localai` translation service reports healthy (it will load
   `aya:8b` into VRAM on first use — the first translation is slow while the
   model loads; afterwards it stays resident).
3. Review the automation/schedule settings so Lingarr periodically picks up
   new `.en` subtitles found by Radarr/Sonarr and translates them to `es`.

## 7. End-to-end test

1. Pick one episode/movie with no subtitles at all.
2. In Subarr → Coverage (or Library), queue it for transcription.
3. Watch Subarr → Queue: the job moves Processing → Recently done.
4. On the NAS, next to the video you should see
   `<video>.en.subgen.large-v3-turbo.srt` (or the audio's language).
5. Within Lingarr's next run, a `<video>.es.srt` should appear.
6. In Jellyfin, open the item — Subarr triggers a targeted refresh, so both
   subtitles show up without a library scan.

## Troubleshooting

| Symptom | Where to look |
|---|---|
| Subarr job fails / "Issues" bucket | Subarr → Queue → row details; `kubectl logs -n subgen deploy/subgen` |
| Subgen slow on first job | Model download (~3GB) into `subgen-models` PVC — happens once |
| VRAM pressure (A2000 12GB shared) | `kubectl exec -n jellyfin deploy/jellyfin -- nvidia-smi`; subgen frees VRAM when idle, Ollama keeps aya resident (~5.2GB) on purpose |
| Lingarr "Invalid or empty response from generate API" | Ollama race when a request lands while the model loads/unloads (ollama/ollama#16326) — keep `OLLAMA_KEEP_ALIVE=-1`; requeue the failed job from the Lingarr UI |
| Lingarr translation errors | Lingarr UI jobs page; verify Ollama: `kubectl exec -n ollama deploy/ollama -- ollama list` |
| Subtitle has 3-letter code (`.eng.`) | Leftover from before `SUBTITLE_LANGUAGE_NAMING_TYPE=ISO_639_1`; safe to rename or delete |
| Bazarr still "wanted" for Spanish | Normal until Lingarr delivers the `.es.srt`; Bazarr provider downloads simply upgrade over the AI sub |
