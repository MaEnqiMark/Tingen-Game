#!/usr/bin/env python3
"""
Tingen Character Animation Sheet Generator — gpt-image-1
========================================================
Turns each of a small cast into (A) a design/model sheet and (B) a set of
8-frame action strips, drawn as a top-down 3/4 RPG character, for later slicing
into Godot SpriteFrames.

Two stages (gpt-image-1 has NO seed; refs + input_fidelity are the only
consistency levers — see the design spec, §2):
  Stage A (design): ref = the approved hero sprite, input_fidelity=high.
  Stage B (action): ref = the character's Stage-A design sheet, high — so every
                    action is on-model and consistent across actions.

Each action sheet is ONE image = one horizontal row of 8 equal cells, on a flat
neutral background with dividers (robust to slice later).

Reuses generate_tingen_image2.py's proven key-loading + retry/backoff API call.

Usage:
  python3 generate_tingen_anim.py --dry-run                       # plan only
  python3 generate_tingen_anim.py --character player_detective    # Klein, both stages
  python3 generate_tingen_anim.py --stage design                  # all design sheets
  python3 generate_tingen_anim.py --stage action --character priest
  python3 generate_tingen_anim.py                                 # the whole set (40)

Cost (gpt-image-1 high ≈ $0.25/image): 4 design + 36 action = 40 ≈ $10.
"""
from __future__ import annotations

import sys
import json
import time
import argparse
from pathlib import Path

import generate_tingen_image2 as hero  # reuse load_key + generate (no import side effects)

HERE = Path(__file__).resolve().parent
OUT_DIR = HERE / "out_image2"
ANIM_DIR = OUT_DIR / "anim"
MANIFEST_PATH = OUT_DIR / "manifest_anim.json"
DEFAULT_ENV_FILE = hero.DEFAULT_ENV_FILE

# All sheets are wide strips (8 cells in a row). gpt-image-1's only landscape size.
SHEET_SIZE = "1536x1024"
# Flat background so dividers/cells survive for slicing (transparency is unreliable
# for strips; we matte later if needed).
SHEET_BG = "opaque"

# Shared look — the cool painterly recipe proven on the hero cast (no sepia/yellow).
ANIM_LOOK = (
    "Richly detailed painterly anime / manhua illustration in the official Lord of the "
    "Mysteries art style, semi-realistic, polished volumetric cel-shading, muted COOL "
    "desaturated palette of neutral grays and cool tones with small restrained warm "
    "gaslight accents — NO sepia, NO yellow / amber color cast. Crisp, on-model, "
    "consistent character design across every cell."
)

# ── Cast (4). ref is relative to out_image2/. desc is a short identity line. ──
ANIM_CAST: dict = {
    "player_detective": {
        "ref": "characters/player_detective.png",
        "desc": ("Klein Moretti, a pale young European man in a charcoal-black caped "
                 "Inverness overcoat with deep-violet lining, white high-collar shirt and "
                 "dark cravat, black hair swept back, glowing gold eyes"),
    },
    "nighthawk_captain": {
        "ref": "characters/nighthawk_captain.png",
        "desc": ("a stern Nighthawk captain in a long dark double-breasted Inverness coat, "
                 "a brass badge, leather gloves and a top hat"),
    },
    "priest": {
        "ref": "characters/priest.png",
        "desc": ("a gaunt cathedral priest in a dark grey clerical cassock with a white "
                 "collar and a silver cross pendant, thinning grey hair"),
    },
    "bieber_monster": {
        "ref": "enemies/bieber_monster.png",
        "desc": ("a hulking ritual-warped Beyonder horror in a torn bloodstained Victorian "
                 "suit, distended muscle and bony growths, extra clawed limbs, one glowing-"
                 "red eye"),
    },
}

# ── Actions: the 8-frame keyframe intent + whether the strip loops. ──
ACTIONS: dict = {
    "idle": {"loop": True, "keyframes": (
        "a subtle idle breathing and weight-shift loop — NEUTRAL stance, a slow inhale "
        "rising, a slight sway, settle, a slow exhale falling, easing back to the NEUTRAL "
        "start pose")},
    "walk": {"loop": True, "keyframes": (
        "a seamless walk cycle of two strides — contact, passing, contact, passing across "
        "the 8 frames, arms and legs swinging naturally, returning to the start pose")},
    "examine": {"loop": False, "keyframes": (
        "NEUTRAL, reach and kneel down toward the ground, inspect closely (held), begin to "
        "rise, and RETURN to the neutral stance")},
    "talk": {"loop": True, "keyframes": (
        "a small talking-gesture loop — NEUTRAL, a gentle head-and-hand gesture outward, a "
        "second beat, and back to NEUTRAL")},
    "revolver_fire": {"loop": False, "keyframes": (
        "NEUTRAL, draw the revolver, raise and aim, FIRE with a muzzle flash, recoil kick, "
        "follow-through, recover, and RETURN to neutral")},
    "paper_charm": {"loop": False, "keyframes": (
        "NEUTRAL, reach for a paper charm, raise it overhead, CAST it with a glowing glyph, "
        "release, recover, and RETURN to neutral")},
    "hurt": {"loop": False, "keyframes": (
        "NEUTRAL, a sharp impact flinch, stagger backward, begin to recover, and RETURN to "
        "neutral")},
    "death": {"loop": False, "keyframes": (
        "NEUTRAL, take a hit, buckle at the knees, fall, and collapse — the final frame "
        "holds the collapsed pose")},
    "attack": {"loop": False, "keyframes": (
        "NEUTRAL, wind up, lunge forward, STRIKE at the moment of impact, follow-through, "
        "and recover")},
}

# ── Sheet matrix (design spec §6): character -> action -> facings to generate. ──
SHEETS: dict = {
    "player_detective": {
        "idle": ["down", "up", "side"], "walk": ["down", "up", "side"],
        "examine": ["down"], "talk": ["down"],
        "revolver_fire": ["side"], "paper_charm": ["side"], "hurt": ["down"], "death": ["down"],
    },
    "nighthawk_captain": {
        "idle": ["down", "up", "side"], "walk": ["down", "up", "side"],
        "examine": ["down"], "talk": ["down"],
    },
    "priest": {
        "idle": ["down", "up", "side"], "walk": ["down", "up", "side"],
        "examine": ["down"], "talk": ["down"],
    },
    "bieber_monster": {
        "idle": ["down", "side"], "walk": ["down", "up", "side"],
        "attack": ["side"], "hurt": ["down"], "death": ["down"],
    },
}

FACING_TEXT: dict = {
    "down": "facing toward the camera (facing down the screen)",
    "up": "seen from behind, facing away from the camera (facing up the screen)",
    "side": "in right-facing side profile (left is mirrored in-engine)",
}


# ── Job iterator ──────────────────────────────────────────────────────────────
def iter_anim_jobs(stage: str, character: str | None):
    """Yield (kind, char, action, facing). kind is 'design' or 'action'.

    stage in {'design', 'action', 'all'}. character filters to one cast key.
    """
    chars = [character] if character else list(ANIM_CAST)
    for ch in chars:
        if stage in ("design", "all"):
            yield ("design", ch, None, None)
        if stage in ("action", "all"):
            for action, facings in SHEETS[ch].items():
                for facing in facings:
                    yield ("action", ch, action, facing)
