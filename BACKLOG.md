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
- **Speed, by expected gain** (2026-11-15; one request is already at mlx_lm's: 35B-A3B 105 vs 109 tok/s, 27B 18.8 vs
  19.4 — bench/history.tsv):
  1. **Batched decode across requests**: requests now take turns on the one MLX thread a token at a time, so N agents
     share one stream's throughput. Decode is bound by reading the weights; one step for B sequences reads them once
     — throughput near-linear in B for a few sequences, each one barely slower. Needs per-sequence KV caches stacked
     (padding or ragged attention), the hybrid models' linear states per row, the prefix cache per sequence.
     Measure: 2 and 4 concurrent Claude Code / opencode sessions, total and per-session tok/s.
  2. **A draft model for the dense 27B** (no MTP layer of its own): Qwen3.5-0.8B or 2B with the same tokenizer drafts,
     the 27B verifies in one pass — exact; measure the acceptance and tok/s on code and on prose.
  3. **KV cache in 8 bits** for long agent contexts: half the memory, less paging; exactness checked against bf16
     on the 35B's answers (greedy, 256 tokens).
  4. **The first request after a restart** — CHECKED 2026-11-16: the system prompt's prefix is found in the disk store
     after a process restart (4B, 6.8k tokens: 90 ms against 6.5 s cold) — the idle restart costs no prefill.
  6. **Batched prefill across requests** — MEASURED 2026-11-16, NOT WORTH IT NOW: prefill is compute-bound at ~1050
     tok/s on 4B and 35B once a chunk is 128 (4B) or 512 (35B) tokens; batching gains only on short concurrent
     chunks (~20% for two 128-token ones), at the cost of ragged attention over the hybrid models' states.
  5. **Forced runs under a client's JSON schema**: where one continuation is allowed, fed as one step (with the
     grammar item above).
