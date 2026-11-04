# BACKLOG — okay-mlx

- **The decode port** (operator, 2026-11-03): a per-step decoding hook in the gateway (mask / force / bias): tool
  calls by the schema's grammar, secrets that cannot be printed, identifiers from symdex. okay-agent
  specs/in-generation.md, stage 2.
- **KV snapshots and forks**: snapshot, fork (copy-on-write), save/load a session's KV cache. Stage 3 there.
- **Drafts in the usage**: accepted drafts (FreeToken's `draft_n`, `draft_n_accepted`) in okay-llm's timing/usage,
  not only the log.
- **Runtime memory knobs**: `OKAY_MLX_CACHE_GB` / `OKAY_MLX_PREFIX_GB` changeable through a control route without a
  restart (FreeToken's elastic re-allocation, `server/control_api.py`); pools' occupancy in a stats route.
