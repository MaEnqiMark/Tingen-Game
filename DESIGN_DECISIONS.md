# Tingen — Design Decisions Log

Running log of the choices I made while implementing TODO tasks 1–10 in the Godot
project, plus open questions for you to review. Where I had to guess, I picked what
seemed the best default and noted it here rather than stopping to ask.

Last updated after implementing all 10 "buildable now" tasks **and validating headless**:
project imports clean, the main scene boots with zero script errors, and the
`tests/run_tests.gd` suite reports **25/25 passing**.

---

## Architecture overview

Everything is wired as **autoload singletons** (globals) plus **data-driven JSON**
in [`tingen/data/`](tingen/data/). The singletons form a dependency chain (each only
depends on the ones above it):

```
WorldState     pressure vars + signal bus + current lead          (no deps)
Clock          day / minute / phase, ticks, day-night tint        (no deps)
WorldManager   6-stage machine, pressure simulation, slots        (WorldState, Clock)
EventManager   weighted event selection                           (WorldState, WorldManager)
ClueDB          clue library + collected state + unlocked topics    (WorldState, WorldManager)
DialogueManager branching topic/clue-aware dialogue                 (ClueDB, WorldState)
NpcDB          NPC schedules + dialogue links                      (—, read by NPCs)
SaveManager    serialize/restore everything to user://save.json   (all of the above)
DevConsole     debug overlay (autoloaded CanvasLayer scene)        (all of the above)
```

UI that must live in the scene tree (not autoloads): the **Toasts** layer, the
**District Map** modal, and the **Dialogue** panel all live inside
[`ui/HUD.tscn`](tingen/ui/HUD.tscn).

**Why autoloads + JSON:** matches the GDD's "data-driven, authorable" intent and the
Yumina docs' state-store/registry pattern, and keeps every system headless-testable
and save/load-serializable without scene coupling.

---

## Decisions by task

### Canon reconciliation (prerequisite)
- Replaced the scaffold's pressure vars with the canonical five:
  `corruption, panic, fatigue, cult_readiness, attention` (all 0–100).
- **`stability` is now derived, not stored:** `100 − (corruption·0.5 + panic·0.3 +
  cult_readiness·0.2)`, clamped. The HUD "Stability" meter reads this. Rationale: the
  docs list only the five pressures as state; stability is a player-facing summary.
  - *Open Q1:* Is that the formula/weighting you want for stability, or should
    `attention`/`fatigue` factor in too? Easy to change in `WorldState.stability()`.
- Dropped `player_trust` and `cult_affinity` (not in §8.3 canon). If they were
  intentional, say so and I'll re-add as a separate "alignment" sub-model (they map to
  the "corruption/alignment drift" later-bet).

### Task 3 — Clock
- 6 phases with the doc's minute boundaries. Default speed **1 real second = 1 game
  minute** (a full day = 24 real minutes); override via
  `Clock.real_seconds_per_game_minute`. Starts Day 1, 08:00 (morning).
  - *Open Q2:* The scaffold opened at "Night 02:14" (the suicide-awakening cold open).
    I default the clock to morning for general testing. Should the **intro** force the
    clock to late-night until the player leaves the room? I left a hook
    (`Clock.set_time()`) but did not force it.
- Day/night mood via a single `CanvasModulate` (`DayNightTint.gd`) that lerps tint per
  phase — zero art, matches TODO task 3.

### Task 1 — World Manager
- Stage machine advances **one stage per refresh** when the next stage's `enter_when`
  conditions pass (sequential, no skipping). Conditions supported:
  `clue_count_gte`, `pressure_gte`, `stage_duration_gte` (in refreshes).
- **Strategic refresh = 60 s** real time (GDD's number) on a `Timer`; each refresh runs
  pressure dynamics, threshold checks, stage-advance check, and the offscreen tick.
  - *Open Q3:* 60 s is slow for hands-on testing. The dev console can fast-forward
    refreshes; is a shorter default (say 15 s) better for the slice? Currently 60 s.
- Pressure dynamics per refresh (tunable constants at the top of `WorldManager.gd`):
  panic decays −1.5; corruption drifts up with stage + `cult_readiness`; `cult_readiness`
  rises by a per-stage activity coefficient; `fatigue` creeps up; `attention` tracks
  corruption. These are **placeholder curves** — flagged for balancing.
  - *Open Q4:* These numbers are guesses to make meters visibly move. Want me to derive
    them from a specific GDD pacing target (e.g. "ritual night by ~Day 5")?
- **Dynamic slots** (`primary_ritual_site`, `first_corrupted_civilian`, `decoy_courier`)
  resolved via a **seeded** `RandomNumberGenerator` from weighted candidate pools.
  Seed defaults to a random value at new-game and is **persisted** so loads are
  deterministic. Candidates are placeholder district/NPC ids.
- **Offscreen resolution** (§8.6) is a light stub: every refresh nudges `cult_readiness`
  by the current stage's coefficient. The "real" deterministic district sim is left as a
  later bet (it's flagged research-flavored in the docs).

### Task 2 — Weighted events
- `score = weight × state_match`. **As built:** every entry in an event's `conditions`
  array is a *hard gate* — all must pass or the event scores 0 (disqualified). `state_match`
  is then a soft multiplier (currently driven by an optional `prefer_stage` hint: 1.0 if it
  matches the current stage, 0.5 otherwise). `cooldown` (in refreshes) stops a beat repeating
  back-to-back.
- One eligible event is drawn **weighted-randomly** (not strictly highest-scoring) per
  strategic refresh, so the city doesn't feel deterministic. Effects: `pressure`
  (→ WorldState.adjust), `lead` (→ set lead), `collect` (→ ClueDB), and passive
  `notify` / `stage_hint` payloads the toast layer reads.
  - *Open Q5:* One event per refresh keeps the city legible. Should multiple low-weight
    "ambient" events be able to co-fire? Currently single-fire.
  - *Note:* The event RNG is seeded from `WorldManager.seed_value` so a reloaded save
    replays the same draws.
- Authored sample events live in [`data/events.json`](tingen/data/events.json) — replace
  freely; the schema is documented at the top of `EventManager.gd`.

### Task 5 — Clues + board
- Canonical `Clue` shape with `type ∈ {physical, behavioral, occult, testimony}` and
  `importance ∈ {pivotal, supporting, flavor}`. Library in
  [`data/clues.json`](tingen/data/clues.json); collected state (id → discovered-turn) in
  ClueDB and serialized by SaveManager.
- Examining an Interactable with a `clue_id` **collects** the clue and **unlocks its
  topics** (drives dialogue). The Investigation Board now renders collected clues
  dynamically grouped by type, with the open-threads list driven by the active lead.
  Drag-connect graph deferred per the docs ("ship flat gallery first").

### Task 4 — Dialogue
- Branching trees in [`data/dialogue.json`](tingen/data/dialogue.json), keyed by NPC id.
  Options support `requires_topic` / `requires_clue` gating (hidden until unlocked),
  `effects`, and a `contradiction` flag that renders the line differently (the
  "call-out known clues" mechanic). LLM dialogue intentionally **not** built (docs say
  avoid a visual dialogue tree / Ink — data + topic-gating covers it).
- Dialogue panel pauses player movement while open. No portraits (asset-gated).

### Task 6 — NPCs
- NPC is a stub `CharacterBody2D` (tinted rect) reading its schedule + dialogue link
  from [`data/npcs.json`](tingen/data/npcs.json). On `Clock.phase_changed` it re-targets
  the waypoint for the new phase and **straight-line steers** toward it.
  - *Decision:* No A* pathfinding yet — straight-line `move_toward` with wall sliding.
    Real waypoint-graph/navmesh pathfinding is a later polish item; the schedule logic
    (the interesting, art-agnostic part) is what's built. Flagged.
- Talking to an NPC opens its dialogue tree via the Task 4 system.

### Task 7 — Save / load
- One JSON blob at `user://save.json` capturing WorldState pressures + lead, Clock,
  WorldManager (stage, slots, **seed**, refresh count, threshold bookkeeping), collected
  clues + topics, and the current scene path + player position. Load restores all
  singletons then transitions to the saved scene and repositions the player.
- Round-trip is headless-testable (see Task 10 runner). The agent-sandbox
  "don't silently drop state" lesson: load fails **loudly** (push_error) on a malformed
  file rather than partially applying.

### Task 8 — Toasts
- Bottom-right queued toast stack in the HUD ([`ui/Toasts.tscn`](tingen/ui/Toasts.tscn)).
  Subscribes to `EventManager.event_fired`, `WorldManager.pressure_threshold_crossed`, and
  `WorldManager.stage_advanced`. Each card fades in, holds ~4 s, fades out and self-frees;
  at most 4 are visible (oldest evicted). **Cards are color-coded by `channel`**
  (`ambient` / `lead` / `alert` / `stage` / `system`) via a left accent bar, so severity
  is readable at a glance. The dev console can `push` a toast too (group `"toasts"`).

### Task 9 — District map
- Modal toggled with **M** ([`ui/DistrictMap.tscn`](tingen/ui/DistrictMap.tscn)). Districts
  are drawn in a custom `_draw()` (filled polygons + outlines + name labels) from
  [`data/districts.json`](tingen/data/districts.json) — **5 districts authored**. Each
  district's **risk tint** (green→red) blends its `base_risk` with the live citywide
  pressure it tracks (`risk_pressure`), so the map updates as the night degrades. Hovering
  a district shows a risk readout. (Chose hover-readout over click-select; no POI dots yet.)

### Task 10 — Dev console + tests
- **Dev console** toggled with **`** (backtick) — an autoloaded `CanvasLayer` that builds
  its own UI at runtime, so it works in any scene with no wiring. Commands: `set <p> <v>`,
  `adjust <p> <d>`, `pressures` (dump), `refresh`, `stage`, `advance` (force next stage),
  `time <h> <m>`, `event` (force a roll), `clue <id>`, `toast <msg>`, `save`, `load`,
  `help`. Output scrollback doubles as the "rule trace" log.
- **Tests: I did NOT add GUT.** GUT is an external addon and fetching it isn't reliable
  offline, so instead I wrote a dependency-free headless runner at
  [`tests/run_tests.gd`](tingen/tests/run_tests.gd) (run with
  `godot --headless -s res://tests/run_tests.gd`). It covers: pressure clamping,
  threshold crossing, event scoring, clock phase/day rollover, slot determinism (same
  seed → same slots), and save/load round-trip. Exits non-zero on failure so it can gate
  CI later.
  - *Open Q6:* Want me to swap this for real GUT once the addon can be vendored? The test
    *logic* ports directly.

---

## Cross-cutting decisions
- **Single source of truth:** pressures live only in WorldState; WorldManager mutates
  them through `WorldState.adjust` so the HUD, save, and console all stay in sync.
- **Turn/refresh counter:** I treat each 60 s strategic refresh as a "turn" for
  clue/stage timestamps (the docs use "turn" loosely). Noted in case you expect
  per-player-action turns instead.
- **No new third-party addons** were added (kept the project dependency-free).
- All new input actions added: `toggle_map` (M), `toggle_console` (backtick). Existing
  `interact`, `toggle_board`, movement unchanged.

## Open questions, collected
1. Stability formula/weighting — right?
2. Should the intro force the clock to late-night?
3. Strategic-refresh default 60 s vs shorter for testing?
4. Pressure-curve constants — balance to a specific pacing target?
5. One event per refresh vs multiple ambient co-fires?
6. Swap the headless test runner for GUT later?
7. Dropped `player_trust` / `cult_affinity` — intentional to remove, or fold into a
   later alignment model?

---

## Decision log — Occult Tools + Hypothesis Board (2026-06-06 brainstorm)

Each entry: the question asked, the choice made (**bold**), and a one-line note on the
alternatives that were rejected. (Standing rule: log every design decision this way —
chosen option + brief description of the alternatives.)

- **What to build next?** → **Occult tools + endgame** (closes the gather → act → ending
  loop). *Alts:* occult tools only; rumor-propagation system; "connective tissue" (quest
  log / cutscene / offscreen sim / NPC reactions).
- **How much of the occult toolkit in v1?** → **All four tools fully, including the full
  Gray-Fog hypothesis board with confidence scoring.** *Alts:* three tools + a lightweight
  "commit your theory" hypothesis; three tools only, defer the board to its own spec.
- **How does the endgame resolve?** → **Player must find the true ritual site and win a
  (light) combat to win; if the cult isn't stopped the ritual completes, an evil god
  descends and everyone dies; the more the player impeded the ritual, the weaker the cult
  in that final fight. Combat stays "secondary to prevention" per the story doc.** *Alts:*
  committed hypothesis alone grades the ending (no combat); pure world-state-threshold
  grade with the board as info-only.
- **How to structure the work?** → **Split into two specs: (1) Occult Tools + Hypothesis
  Board now, which produces the "impede/insight" score; (2) Ritual-Night endgame + combat
  next, consuming that score.** *Alts:* endgame/combat first with placeholder inputs; one
  combined design doc covering everything.
- **Can the occult tools mislead the player?** → **Yes — they degrade with corruption:
  vague-but-true when clean, noisier and capable of false leads as corruption/attention
  rise. Cost = fatigue per use + attention buildup.** *Alts:* always truthful but vague
  (resource-gated only); always truthful but ambiguity widens (never outright false).
- **How hands-on is the Gray-Fog board?** → **Hybrid auto-link + edit:** auto-links
  collected clues to the candidate answers they support and shows live confidence; player
  can add/remove links and flag uncertainties. *Alts:* guided (auto-scored only); manual
  (drag clue cards from scratch).
- **Does the player "submit / commit" a conclusion? (revised 2026-06-06)** → **No — there
  is no submission UI.** The board *merely organizes clues and occasionally highlights a
  next step.* The player must actually find the cult and physically go stop it; whether
  they correctly identify the true ritual site is on them, read off the organized board.
  "How much you figured out / impeded the cult" is derived **implicitly** from investigation
  state (clues found, leads resolved, pressures) and feeds the (separate) endgame's combat
  difficulty — it is not a graded quiz answer. *Alt (rejected):* commit a hypothesis per
  open question that the endgame checks for correctness.
- **Can the board name the true ritual site?** → **No — directional hints only.** The board
  organizes clues and occasionally raises a *directional* lead ("evidence is clustering in
  the harbor", "this ledger page matters") but never declares the answer or marks the site
  as an objective. The player infers the site themselves and physically goes to confront it;
  how right/thorough they were sets how weak the cult is in the endgame. *Alts (rejected):*
  name the site once pivotal clues are found; always show the current highest-confidence
  candidate with a percentage.
- **Code architecture?** → **Approach C: split the transient verbs (`OccultTools` autoload)
  from the persistent inference model (`HypothesisBoard` autoload), with a shared static
  risk helper (`OccultRisk`) that applies fatigue/attention cost and corruption-driven
  noise via a seed tied to `WorldManager.seed_value`.** *Alts (rejected):* a single
  `OccultManager` autoload that owns both verbs and state (A — simpler but mixes one-shot
  actions with long-lived save/load state); per-tool scene nodes (B — more files, awkward
  for shared cost/corruption logic and save/load).
- **Code architecture (revised 2026-06-08)?** → **OOP manager + per-tool subclasses.** An
  abstract `OccultTool` base class exposes `use()`, `compute_cost()`, `can_use()`, with a
  template-method `use()` that checks → pays cost → calls virtual `_perform()` → applies
  risk. Concrete subclasses (`DivinationTool`, `ResidueSightTool`, `DreamFragmentsTool`,
  `GrayFogTool`) own their tool-specific behavior, cost, and risk shape. An
  `OccultToolManager` autoload owns the tool roster, cooldowns, the seeded RNG (from
  `WorldManager.seed_value`), and inventory routing. `OccultRisk` is demoted to a library of
  **shared seeded-RNG primitives** the tools call (mislead/noise rolls), not the risk
  decision-maker. `HypothesisBoard` stays a separate autoload. *Supersedes the single
  `OccultTools` autoload of the prior C decision. Alts (rejected):* keep one `OccultTools`
  autoload holding all verbs + a decision-making `OccultRisk` (less extensible, risk logic
  not co-located with each tool); fully self-contained tools with no shared RNG helper
  (duplicates seeding logic, hurts deterministic testing).
- **Inventory system?** → **Build a general, data-driven inventory system; the occult tools
  are items in it, and tools may consume/produce items.** Item categories envisioned: occult
  tools, ritual ingredients (to perform rituals), sustenance (food/water), and regular tools.
  *Alts (rejected):* reuse only the clue inventory (`ClueDB`) (clues aren't carryable goods,
  no consume/produce); per-tool ad-hoc state (no shared item economy, can't support rituals).
- **Inventory build scope?** → **Inventory foundation now, ritual engine later.** Build
  `data/items.json` + an `Inventory` autoload (counts, add/remove/use, save/load) + tool-as-item
  + consume/produce now; the ritual recipe engine is designed with a later spec. *Alts
  (rejected):* inventory + basic rituals now (bigger, pulls endgame design forward); full
  inventory + rituals + crafting (largest, risks scope creep).
- **Carry limits?** → **Unlimited capacity; reagents/food stack, unique tools/key items
  don't.** Resource tension comes from ingredient scarcity, not bag space. *Alts (rejected):*
  slot/weight capacity (more survival-sim tension but more UI + balancing).
- **Item taxonomy (LotM-grounded)?** → **Categories:** `occult_tool`, `divination_focus`
  (pendulum/tarot/dowsing rod/scrying mirror — canon Seer methods), `ingredient` (chalk,
  candles, salt, incense, herbs, monster-parts), `characteristic` (rare potion main material,
  魔药特性), `medium` (belonging/name slip/relic/corpse-token, targets divination & séance),
  `sustenance` (eases `fatigue`), `tool` (lantern/lockpick), `key_item` (sealed artifacts).
  Verified against the LotM wiki (Seer divination methods; Potion System; Ritualistic Magic).
- **Ritual purpose (fiction, for later engine)?** → **Rituals are the unifying primitive for
  many LotM acts:** divination/fortune-telling, potion-brewing (魔药), questioning the dead /
  séance (通灵), prayer to deities (祈祷), gray-fog transit (上灰雾), the cult's summoning of the
  descending evil god (邪神降临, endgame), and warding/sealing (封印). A ritual = (foci +
  ingredients + place/time conditions) → effect. *Only the ingredient slots are built now; the
  ritual engine is deferred.* *Alts (rejected):* model each act as a bespoke mechanic (no shared
  ritual abstraction, more code, inconsistent).

## Decision log — Core game pivot to open-world LLM agent-sim (2026-06-08)

This pivot supersedes the detective-mystery framing. See
`docs/superpowers/specs/2026-06-08-tingen-agent-sim-vertical-slice-design.md` and the GDD
direction update (§0.1).

- **Genre / core loop?** → **Open-world, real-time immersive simulation with an AI-managed
  story** — not a fixed detective mystery. The cult genuinely intends to summon a descending
  evil god and completes it if unopposed; the story is steered, not scripted. *Alts (rejected):*
  keep the fixed-mystery detective game (no emergence, on-rails); pure sandbox with no story
  management (incoherent, no dramatic arc).
- **NPC intelligence?** → **Each NPC is an autonomous LLM agent** (intent + memory + plans) that
  perceives and interacts with other agents; a cheap schedule-based **fallback behavior** runs
  while it deliberates. *Alts (rejected):* the original heuristic "60-second strategic refresh"
  (not emergent enough); a single LLM puppeteering all NPCs (loses per-agent identity, harder to
  reason about).
- **Story management?** → **A World-AI overseer + critic.** Director can re-task an agent, cancel
  a plan, or coordinate a group beat, and enforces invariants (e.g. *cult never exposed/caught by
  chance — exposure gated on player involvement*). Critic **catches and kills** boring/incoherent/
  illegal proposed actions (legality + coherence + interestingness). *Alts (rejected):* heuristic
  storyteller only (less surprising); LLM director with no critic (boring/faulty sims slip
  through).
- **Build approach?** → **Vertical slice first** (~3–5 agents, Iron Cross Street, one summoning
  thread, end to end), then scale to the city. *Alts (rejected):* design the full city
  architecture first (slow to playable, over-specifies); substrate + overseer with stubbed agents
  first (delays seeing the emergent magic).
- **Time model?** → **Real-time immersive sim**; agents deliberate **async in the background** on
  a beat cadence (or on events), with fallback behaviors hiding latency. *Alts (rejected):*
  beat/turn-based (easier latency/testing but board-game feel); hybrid real-time + pause-for-beats
  (two time modes, seams).
- **Resolution paths?** → **Multi-path with combat as the climax:** investigate → sabotage / turn
  the waverer / fight; accumulated **impede** scales climax difficulty. *Alts (rejected):*
  combat-first (thin vs. the agent sim); combat as failure-state only (contradicts "combat is
  important").
- **LLM orchestration?** → **External Python sidecar** (HTTP/stdio); owns prompts, Claude API
  calls, batching, caching, schema validation; API keys + nondeterminism quarantined there; tests
  mock it. *Alts (rejected):* in-engine GDScript HTTPRequest (clumsy orchestration, keys/nondet in
  engine); defer the choice (leaves a load-bearing decision open).
- **Slice cast?** → **Reuse existing roster + slot candidates** (Clerk Voss leader, Dalia
  logistics, Orin scout/waverer, Dockhand Pell victim), extending `npcs.json` with intents. *Alts
  (rejected):* author a fresh dedicated cast (diverges from existing data, more content).
- **Gray-Fog Hypothesis Board?** → **Cut.** Detective deduction doesn't fit an emergent sim;
  occult tools instead give **directional perception leads**. *Alts (rejected):* keep the board
  (re-introduces fixed-mystery deduction). **NOTE — naming:** cutting this *board* does NOT
  remove **Gray Fog (灰雾) the world concept**, which is retained as lore. Canonical uses (for the
  deferred 上灰雾 / gray-fog-transit ritual): (1) above-the-gray-fog = the Tarot Club (塔罗会)
  meeting space / Fool's domain, entered by ritual, members shown only as identity-concealed
  outlines; (2) anti-divination shield + amplifier of one's own divination + shielding from
  High-Sequence Beyonders/deities; (3) object storage + send/receive relay; (4) information &
  Beyonder-ingredient/artifact exchange. In the slice this is **atmosphere only**, not a built
  mechanic.
- **Occult tools usable in combat + investigation?** → **Yes.** Tools are general-purpose verbs:
  perception/knowing information (divination/spirit-vision/dream → directional leads) AND combat
  (≥1 occult ability usable in the climax fight, more can extend the `OccultTool` hierarchy) AND
  feeding sabotage/social decisions. *Alts (rejected):* investigation-only tools (wastes the
  combat-relevant Seer abilities).
- **Occult tools + inventory specs?** → **Survive, demoted** to player **perception** (occult
  tools) and **action/economy** (inventory ingredients power sabotage). The OOP `OccultTool`
  hierarchy + manager + `OccultRisk` and the inventory foundation still apply. *Alts (rejected):*
  scrap them (lose the LotM-flavored verbs + the sabotage economy).

## Decision log — Vertical-slice implementation (6-plan build, 2026-06-08)

Decisions made while implementing Plans 1–6 (perception/commit/runtime, overseer/critic, player
verbs/combat). All landed with a green suite (189 passed, 0 failed) and two-stage review per task.

- **Autoload access from `class_name` scripts?** → **The `_al(name)` helper** —
  `(Engine.get_main_loop() as SceneTree).root.get_node("/root/" + name)` — used in every
  `class_name` lib that touches an autoload (Perception, ActionCommit, Critic, OccultTool & subs,
  Agent). In the headless `-s` harness, `class_name` scripts compile *before* autoloads register,
  so a bare global reference (`WorldState.corruption`) fails to compile with `Identifier not
  found`. *Alts (rejected):* bare autoload references (crash in the headless test harness, the
  primary CI path); converting the libs to autoloads (loses value-type/`RefCounted` semantics,
  pollutes the singleton namespace); a class-cache refresh (does not fix the compile-order issue).
- **"No exposure by chance" invariant — where enforced?** → **A single chokepoint in
  `Critic.review`**: an exposing `report` (to law/church/authorities, or naming cult/ritual/summon)
  is vetoed unless `Overseer.allows_exposure()` is true (i.e. the player is involved). Because every
  proposal funnels through the critic, the cult cannot be exposed by an unlucky autonomous beat.
  *Alts (rejected):* scatter the check across each verb's commit logic (bypassable, easy to forget
  one path); enforce it only in the sidecar/LLM prompt (non-deterministic, untestable, and the
  engine must hold the invariant regardless of the brain).
- **"World mutated only through ActionCommit" — how guaranteed?** → **`ActionCommit.commit` is the
  one place agents change world state**; the runtime never mutates agents directly and the critic
  is pure. *Alts (rejected):* let verbs apply their own effects inline at proposal time (multiple
  mutation paths, no single audit point); a generic event-sourced reducer (over-engineered for the
  slice's verb set).
- **No-name-site invariant for divination hints?** → **Enforced by a structural guard test**
  (`_test_divination_hints_never_name_site`) that asserts hint strings never contain the literal
  site name — divination gives a *direction*, never the address. *Alts (rejected):* rely on prose
  hygiene/code review only (silently regresses the moment someone edits a hint string); a
  single-RNG determinism test (proves repeatability, not the no-name promise).
- **Non-`approve` critic verdicts?** → **Fall straight back to the agent's schedule** (veto/reject
  → `tick_fallback`), logging `action_vetoed`/`action_rejected`; no synchronous re-ask. Keeps a beat
  bounded to one sidecar round-trip and keeps the world moving. *Alts (rejected):* re-ask the
  sidecar synchronously for a fresh proposal (unbounded beat latency, possible loops); freeze the
  agent until next beat (visibly inert NPCs).
- **Player verbs vs. agent actions?** → **Player verbs are first-class `EventBus` events**
  (`player_sabotage`, `player_social`, …) mirroring the agent-action shape, which is also what trips
  `Overseer.player_involved` and thus unlocks exposure. *Alts (rejected):* a separate player-input
  channel the overseer doesn't see (the exposure gate couldn't tell the player was involved); route
  player actions through the same propose→critic pipeline (the player isn't a deliberating agent;
  adds latency and pointless veto surface).
- **SummoningPlan countdown this slice?** → **Kept passive** — `countdown_beats`, `impede_score`,
  and `manifestation_strength()` are stored/queried but the countdown is **not** decremented yet;
  the forward-tick wiring is deferred to the scene-integration plan. Flagged by the integration
  reviewer (an Important finding) and accepted as a faithful, intentional slice boundary. *Alts
  (rejected):* wire the decrement to `Clock.beat_ticked` now (pulls scene-integration scope into
  the data-model slice, and the climax/manifestation consumer isn't built yet to observe it).
- **`EventBus` save/load replay?** → **`from_dict` restores the log but deliberately does NOT
  re-emit** the restored events on load — listeners (overseer, runtime) must not re-fire on a
  resumed game. *Alts (rejected):* replay events on load (double-counts `player_involved`, re-runs
  side effects, corrupts a resumed session).
- **GDScript↔Python schema parity — how tested? (Task #26)** → **A harness test runs the *real*
  sidecar code** — it imports `sidecar.py` and calls its actual `load_schema()` /
  `validate_action()` over a 16-action fixture battery (via `/usr/bin/env python3`), asserting
  identical verb sets, identical required-args per verb, and identical `(ok, reason)` verdicts
  against the engine's `ActionSchema`. Both sides read one shared `action_schema.json`, so the verb
  *data* can't drift; the real risk is the two independently hand-written *validators* diverging,
  which this locks down (verified by injecting a divergence and watching the test fail). *Alts
  (rejected):* reimplement the sidecar's validation in GDScript and compare (the copy is itself a
  new drift source); compare only the loaded JSON file (misses validator-behavior drift); defer the
  test until live-LLM wiring (drift would land silently first).
- **Parity test when no Python interpreter is present?** → **Skip loudly** — a new harness skip
  counter prints `=== N passed, M failed, K skipped ===` and a visible `SKIP` line, never failing
  the (otherwise pure-Godot) suite. *Alts (rejected):* hard-fail (breaks a Godot-only CI with no
  Python); silently pass (an unrun check masquerades as a passing one).
- **Fixtures handed to the Python helper?** → **A temp file path**, because a quote-laden JSON
  string does not survive an `OS.execute` argv intact (the double-quotes were stripped, mangling the
  JSON on the Python side). *Alts (rejected):* inline JSON arg (proved fragile in practice);
  stdin/pipe (Godot's `OS.execute` cannot feed stdin).
