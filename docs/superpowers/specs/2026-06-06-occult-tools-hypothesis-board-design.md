# Occult Tools + Gray-Fog Hypothesis Board — Design Spec

**Date:** 2026-06-06
**Status:** Approved design, ready for implementation planning
**Engine:** Godot 4.6 (GDScript, autoload singletons + data-driven JSON)
**Scope:** The four occult investigation tools (GDD §12.2) and the Gray-Fog inference
layer of the Investigation Board. The Ritual-Night endgame + light combat is a **separate,
later spec** and is explicitly out of scope here.

---

## 1. Intent

Give the player the *Seer-pathway* (占卜家途径) toolkit the GDD promises, without letting
those tools skip the detective game. Per GDD §12.3, occult abilities should make the player
**ask better questions, not bypass investigation**. Every tool returns a *lead* or a *new
clue*, never a verdict. The Gray-Fog board helps the player **organize** what they have found
and **occasionally highlights a direction** — it never names the answer and there is **no
"submit a conclusion" step**. The player must physically find and stop the cult; how
thorough their investigation was will (in the later endgame spec) set how weak the cult is.

---

## 2. Architecture (Approach C — confirmed)

Three new code units, split by lifetime:

| Unit | Kind | Responsibility |
|------|------|----------------|
| `OccultTools` | autoload | The **transient verbs**: three one-shot actions (Divination / Residue Sight / Dream Fragments) plus the entry point into Gray-Fog reconstruction. Owns cooldowns + per-run use counts. |
| `HypothesisBoard` | autoload | The **persistent inference model**: open questions, candidate answers, clue→candidate links, derived confidence, directional leads. Serializes via `to_dict()`/`from_dict()`. |
| `OccultRisk` | shared static helper (`class_name`, not an autoload) | Pure functions that apply the **fatigue/attention cost** and **corruption-driven noise/misleading** for any tool, using a seeded RNG tied to `WorldManager.seed_value`. |

**Why split (vs. a single `OccultManager`):** one-shot actions and long-lived save/load
state have different lifetimes and test surfaces; mixing them in one autoload (rejected
Approach A) makes save/load and corruption-noise logic harder to reason about. Per-tool
scene nodes (rejected Approach B) multiply files and make shared cost/corruption logic
awkward. See `DESIGN_DECISIONS.md` → "Code architecture?".

New autoloads register in `project.godot` `[autoload]` after the existing eight, before
`DevConsole`:

```
OccultTools="*res://src/OccultTools.gd"
HypothesisBoard="*res://src/HypothesisBoard.gd"
```

(`OccultRisk` is a plain `class_name OccultRisk` static utility — no autoload entry.)

---

## 3. The open questions = WorldManager slots

The board's "open questions" are exactly the existing seeded director slots
(`WorldManager.SLOT_DEFS`), so the inference model never invents its own truth — it always
points at the same hidden answer the director already rolled:

| Slot (open question) | Candidates (current data) | Resolved at |
|----------------------|---------------------------|-------------|
| `primary_ritual_site` | `iron_cross_warehouse`, `st_selena_crypt`, `harbor_customs_house` | world-start |
| `decoy_courier` | `lamplighter_orin`, `fishwife_dalia`, `clerk_voss` | world-start |
| `first_corrupted_civilian` | `dockhand_pell`, `widow_carrow`, `boy_tomas` | stage-enter:awakening |

The board reads `WorldManager.slots` to know the **true** answer (used only to bias which
real clues *support* it — never shown to the player) and reads `SLOT_DEFS` to enumerate the
**candidate set** it lets the player reason over.

---

## 4. Data model

### 4.1 `data/occult_tools.json`
One entry per tool: cost, cooldown, per-run uses, output shaping. Example shape:

```json
{
  "divination": {
    "name": "Divination",
    "fatigue_cost": 8.0,
    "attention_cost": 4.0,
    "cooldown_refreshes": 1,
    "uses_per_run": -1,
    "hint_pool": "divination_hints"
  },
  "residue_sight": {
    "name": "Residue Sight",
    "fatigue_cost": 6.0,
    "attention_cost": 2.0,
    "cooldown_refreshes": 0,
    "uses_per_run": -1
  },
  "dream_fragments": {
    "name": "Dream Fragments",
    "fatigue_cost": 12.0,
    "attention_cost": 0.0,
    "cooldown_refreshes": 2,
    "uses_per_run": -1,
    "hint_pool": "dream_hints"
  },
  "gray_fog": {
    "name": "Gray-Fog Reconstruction",
    "fatigue_cost": 15.0,
    "attention_cost": 8.0,
    "cooldown_refreshes": 1,
    "uses_per_run": 3
  }
}
```

`uses_per_run: -1` = unlimited (gated only by cost + cooldown). Gray-Fog is the one
hard-capped tool (3 uses) so its directional lead stays precious.

### 4.2 `clues.json` — new `supports` field
Each clue may declare which candidate(s) it argues for and how strongly. Optional; clues
without it never feed the board.

```json
"supports": [
  { "slot": "primary_ritual_site", "candidate": "iron_cross_warehouse", "weight": 2.0 }
]
```

A clue can support multiple candidates (including across slots) — that is how *ambiguous*
evidence is modeled. Weights are positive floats; the board normalizes per slot.

### 4.3 Hidden clues on Interactables (for Residue Sight)
Residue Sight reveals occult clues that are not visible to ordinary examination. An
Interactable in a scene may carry a `hidden_clue_id` (string, optional) that only surfaces
when Residue Sight is used in that scene. Until then `ClueDB` does not know about it.

### 4.4 Hint pools
`divination_hints` / `dream_hints` are arrays of templated lines keyed by stage and/or slot,
e.g. `"The water remembers iron and rust."` → biases toward the harbor/iron-cross districts
without naming a site. Stored in `occult_tools.json` or a sibling `occult_hints.json`
(implementer's call; keep them out of `clues.json`).

---

## 5. The four tools

All four route their cost + corruption roll through `OccultRisk` before producing output.

### 5.1 Divination (占卜)
- **Input:** none (reads current stage + `WorldManager.slots`).
- **Output:** one vague **directional** hint line from `divination_hints`, biased toward the
  district/region that actually contains the true `primary_ritual_site`.
- **Corruption effect:** at high `corruption`, the bias can flip toward a *wrong* district
  (misleading), and/or the line is drawn from a noise sub-pool. Determined by `OccultRisk`.
- **Cost:** fatigue + small attention.

### 5.2 Residue Sight / Spirit Vision (灵视)
- **Input:** current scene.
- **Output:** reveals the scene's `hidden_clue_id` (if any) by calling `ClueDB.collect(id)`;
  if none present, returns a "no residue here" result (still costs, still can mislead).
- **Corruption effect:** high corruption can produce a **false positive** — surface a noise
  clue or claim residue where there is none. `OccultRisk` decides.
- **Cost:** fatigue + tiny attention (it is a quiet, local act).

### 5.3 Dream Fragments (梦境碎片)
- **Input:** none (reads collected clues + slots).
- **Output:** a soft **cross-clue association** — names a *district or object category* that
  ties two otherwise-unconnected collected clues together, nudging toward a slot candidate.
- **Corruption effect:** high corruption can associate the wrong pair / point at a decoy.
- **Cost:** high fatigue, **zero attention** (it happens in sleep — the trade is exhaustion,
  not exposure).

### 5.4 Gray-Fog Reconstruction (灰雾重构)
Not a separate window — a **costed "inference" mode layered on the existing Investigation
Board** (decision confirmed in brainstorm; see §7). When invoked (max 3×/run):
1. Auto-links every collected clue that has a `supports` entry to its candidate(s).
2. Scores per-candidate **confidence** per slot (normalized support weights).
3. Surfaces the **weakest-but-most-critical gap** as a single **directional lead** — i.e.
   the open question with the least separation between its top candidates, phrased as a
   direction to investigate ("You still cannot tell harbor from cathedral — look where the
   couriers cross"), never as the answer.
- **Corruption effect:** high corruption injects a noise link or perturbs confidence so the
  surfaced gap/lead can be wrong. `OccultRisk`, seeded.
- **Cost:** highest fatigue + attention; hard-capped uses.

---

## 6. HypothesisBoard model

```
open_questions : Array[String]          # slot ids, from WorldManager.SLOT_DEFS
candidates     : { slot_id -> Array[String] }   # candidate ids per slot
links          : { slot_id -> { candidate_id -> float } }  # accumulated support weight
player_links   : Array of {clue_id, slot, candidate}       # manually added/removed by player
flags          : { slot_id -> bool }    # player-flagged "uncertain"
```

Derived (computed, not stored):
- `confidence(slot)` → normalized weights over that slot's candidates.
- `readiness` / `impede_score` → an **implicit, internal** measure of how thoroughly the
  player has investigated (coverage of slots that have a clear leading candidate backed by
  real clues). **Never shown as a percentage**; it exists so the later endgame spec can read
  it to scale cult strength. The player only ever sees *directional leads*, not this number.

**Auto-link + edit (hybrid):** the board auto-links collected clues via their `supports`
field; the player may additionally **add** a link, **remove** an auto-link they distrust, or
**flag** a question as uncertain. Player edits live in `player_links` / `flags` and are
folded into the confidence calc alongside auto-links.

**Directional leads** are emitted via the existing signal bus — `WorldState.set_lead(text)`
and/or `WorldState.thought_requested` → surfaced through `Toasts`. The board **never** writes
a site name into a lead.

**No submission.** There is no commit/confirm button and no "you were right/wrong" moment at
board time. The board is an organizer + occasional direction-giver. Correctness is judged
only later, physically, in the endgame.

---

## 7. UI

- New input action `toggle_occult` (suggest **Q**) opens `OccultPanel.tscn` (a `Control`
  scene mirroring the existing `DistrictMap.tscn` / HUD conventions): three buttons for the
  one-shot tools + a button that enters Gray-Fog inference mode on the Investigation Board.
- **Gray-Fog inference mode** is rendered *inside the existing Investigation Board* as a
  costed overlay state (auto-links drawn, confidence bars per slot, the one directional lead
  banner) — **not** a new window. Toggling it consumes a Gray-Fog use.
- Results from the one-shot tools surface as `Toasts` + a `WorldState` lead/thought line, the
  same channels the rest of the game already uses.

---

## 8. OccultRisk (shared helper) contract

```
static func roll(tool_id: String, rng: RandomNumberGenerator,
                 corruption: float) -> { mislead: bool, noise: float }
static func apply_cost(tool_id: String) -> void   # deduct fatigue/attention via WorldState.adjust
```

- The RNG is seeded from `WorldManager.seed_value` (+ a per-call salt like use-count) so a
  given run is **deterministic and testable**.
- `mislead` probability scales with `corruption` (e.g. 0 below a floor, rising past ~60).
- Costs are read from `occult_tools.json` and applied to `fatigue` / `attention` through
  `WorldState.adjust`.

---

## 9. Save / load

- `HypothesisBoard.to_dict()/from_dict()` persists `player_links` and `flags` (auto-links and
  candidates are re-derived from `SLOT_DEFS` + `ClueDB` on load, so they are not stored).
- `OccultTools.to_dict()/from_dict()` persists per-tool cooldown timers and remaining
  Gray-Fog uses.
- Both are added to `SaveManager`'s payload (`occult_tools`, `hypothesis_board` keys) and its
  load path, following the existing `to_dict()/from_dict()` contract used by every subsystem.

---

## 10. Tests (headless, extend `tingen/tests/run_tests.gd`)

1. **Confidence calc** — given a fixed set of collected clues with `supports`, the board
   produces the expected normalized confidence per slot.
2. **Corruption-noise determinism** — same seed + same corruption ⇒ identical `mislead`/noise
   roll; raising corruption raises mislead frequency over N rolls.
3. **Cost deduction** — using a tool reduces `fatigue`/`attention` by the JSON-declared amount.
4. **Gray-Fog use limit** — the 4th Gray-Fog invocation in a run is refused.
5. **Save/load round-trip** — `to_dict()`→`from_dict()` restores player links, flags, and
   remaining Gray-Fog uses exactly.
6. **No-name guarantee** — a directional lead string never equals/contains the true slot's
   resolved candidate id/name (guards the "never names the site" rule).

---

## 11. Out of scope (separate later spec)

- Ritual-Night endgame, the physical confrontation, and the light party-of-2 combat.
- How `impede_score` maps to cult strength at the ritual.
- Rumor propagation, cutscenes, offscreen district resolution (already in TODO "later bets").

---

## 12. Decision references

All choices below are logged in `DESIGN_DECISIONS.md` →
"Decision log — Occult Tools + Hypothesis Board (2026-06-06 brainstorm)":
build all four tools fully; tools degrade with corruption (mislead + cost fatigue/attention);
Gray-Fog board = hybrid auto-link + edit; **no submission** — organizer + occasional
direction only; board **never names the site**, directional hints only; **architecture =
Approach C**.
