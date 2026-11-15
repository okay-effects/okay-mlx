# BACKLOG — okay-mlx

- **The decode port** (operator, 2026-11-03): a per-step decoding hook in the gateway (mask / force / bias): tool
  calls by the schema's grammar, secrets that cannot be printed, identifiers from symdex. okay-agent
  specs/in-generation.md, stage 2.
- **KV snapshots and forks**: snapshot, fork (copy-on-write), save/load a session's KV cache. Stage 3 there.
- **Drafts in the usage**: accepted drafts (FreeToken's `draft_n`, `draft_n_accepted`) in okay-llm's timing/usage,
  not only the log.
- **Runtime memory knobs**: `OKAY_MLX_CACHE_GB` / `OKAY_MLX_PREFIX_GB` changeable through a control route without a
  restart (FreeToken's elastic re-allocation, `server/control_api.py`); pools' occupancy in a stats route.
- **Panel: downloads queued** — several downloads at once, a queue view, pause; now one at a time.
- **Panel: per-client default model** — which model each client (Claude Code, opencode) gets when it names none;
  now the one in memory. Needs the client known in `Switching.wanted` (see SPRINT live-work's ThreadLocal).
- **Panel: notarized build** — the app is ad-hoc signed; a Developer ID + notarization would remove the Gatekeeper
  prompt (needs the owner's Apple account).
- **For okay-desk's line, when it asks** (okay-desk specs/phone.md; 2026-11-15): okay-desk's benches read through
  mlx-scala directly (`FrameRead`, `QwenReading`), so none of these blocks its phone work — they make the gateway
  useful to the line and to other clients:
  `POST /v1/score {model, prompt, options[]}` (each option's log-probability, one packed forward, as okay-llm's
  `Qwen3Compute.score`) — routers and frame lines over HTTP; OpenAI `logprobs`/`top_logprobs`; a request's grammar
  (`response_format: json_schema`) for clients that write JSON; `POST /admin/batch` (a JSONL of requests, results to
  a file, resumable) for the teacher's overnight corpora on the 35B.
