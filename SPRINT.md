# SPRINT — okay-mlx

Queue, in order (the owner, 2026-11-14: "делай всё по порядку"). Design: specs/desktop-panel.md §3.
`[~]` in progress, `[x]` done (with the commit and the outcome).

- [x] **hf-search** — find models on Hugging Face in the Models tab (spec §3.1). New `desktop/Catalog.swift`
  (search request, size from `safetensors.parameters`, arch filter), a search field + results list in
  `ModelsView.swift` above "Downloaded models"; Download reuses `InstallModel.model`. Done when: searching "Qwen3.5"
  lists mlx-community models with size, context-free, a fit badge, "downloaded" on the ones there; non-Qwen results
  are left out.
  OUTCOME 2026-11-14: Models tab → "Find on Hugging Face" (Catalog.swift, one request with config+safetensors
  expanded). HF counts quantized U32 two ways by repo (logical weights or packed words); the BF16/U32 ratio picks
  the formula — sizes exact within 0.2% (35B-A3B-4bit 20.39 vs 20.43 GB on disk; 4B both repos 3.03 GB).
- [ ] **menu-bar** — `MenuBarExtra` (spec §3.2). Move `PanelModel`/`LibraryModel`/`InstallModel` to the `App`
  struct, pass them in; menu: state, model in memory, switch list, Unload, Open panel, Open OpenChamber. Done when:
  closing the window keeps the menu, switching from the menu loads the model (status shows it).
- [ ] **live-work** — running generations in `/admin/status` and on the Overview (spec §3.3). Server: `Main` sets a
  `ThreadLocal` client from `User-Agent`; `Switching.Running` keeps client, prompt tokens, tokens, start. App: a
  list under the model in memory. Done when: a curl generation shows up with its client and growing tokens.
- [ ] **chamber-closer** — OpenChamber: reload without restart if it can, default model, iPhone pairing QR (spec
  §3.4). First investigate OpenChamber 2.5.3 / opencode 2.2.5 routes (npm -g @openchamber/web sources).
- [ ] **chamber-env** — clean OpenChamber's LaunchAgent environment, backup, restart once (spec §3.5).
- [ ] **release** — rebuild + re-upload v0.1.1 server archive and app zip, move the tag (spec §3.6).
