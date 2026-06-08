#!/usr/bin/env python3
"""
Tingen "Hero" Asset Generator — gpt-image-1 (OpenAI Images API)
===============================================================
Generates the *important figures* — named/NPC characters, dialogue portraits and
scene backgrounds — at high quality via gpt-image-1, conditioned on the canon
Lord-of-the-Mysteries reference art in asset-gen/ref/.

Why a second generator (vs generate_tingen_assets.py / Retro Diffusion):
  RD pixel art is great for props / tiles / UI / VFX, but the *hero* assets read
  too low-detail.  gpt-image-1 + reference images gives canon-faithful characters
  and richly painted scenes.  Props/tiles/UI/VFX stay on the RD pipeline.

LOCKED art direction (decided with Mark, see STYLE_GUIDE.md):
  - CHARACTERS  = crisp anime / manhua illustration faithful to the canon art,
                  recipe: canon ref (cropped) + input_fidelity=high + a prompt that
                  tells the model to MATCH THE REFERENCE'S STYLE.  Proven on
                  player_detective_HIFI.png — close to klein1, not the painterly drift.
  - BACKGROUNDS = painterly illustrated scenes (match the painted location refs),
                  split into 6 EYE-LEVEL establishing scenes + 8 INCLINED TOP-DOWN
                  (Stardew) walkable maps.
  - CAST        = 19 characters (17 base + Audrey Hall + Goddess of Darkness),
                  9 dialogue portraits, 4 enemies (Beyonder creatures / cultists).
  - ENEMIES     = same crisp anime rendering as the cast (style anchor, no canon ref),
                  but monstrous/eldritch occult-horror designs.

Endpoint:
  POST https://api.openai.com/v1/images/edits   (multipart; accepts image[] refs)
  Falls back to /v1/images/generations only for items with NO usable ref.

Key levers:
  size (1024x1024 | 1024x1536 | 1536x1024), quality (low|medium|high),
  background (transparent|opaque), output_format, input_fidelity (low|high),
  and — crucially, since gpt-image-1 has NO seed — one or more reference images.

Token:
  Reads OPENAI_API_KEY from the environment, else from --env-file
  (default: the Yumina repo .env).  The key value is never printed.

Usage:
  python3 generate_tingen_image2.py --dry-run                 # plan only, no API
  python3 generate_tingen_image2.py --only player_detective   # single item
  python3 generate_tingen_image2.py --category characters     # one category
  python3 generate_tingen_image2.py --category backgrounds --treatment topdown
  python3 generate_tingen_image2.py                           # the whole hero set
  python3 generate_tingen_image2.py --quality medium          # cheaper draft pass

Cost (gpt-image-1, approx): low ~$0.02, medium ~$0.05, high ~$0.25 / image.
  Full hero set (19 + 9 + 14 = 42) at high ≈ ~$10.

Requires: pip install requests pillow
"""
from __future__ import annotations

import os
import sys
import json
import time
import base64
import argparse
from pathlib import Path

import requests
from PIL import Image

HERE = Path(__file__).resolve().parent
REF_DIR = HERE / "ref"
OUT_DIR = HERE / "out_image2"
PREP_DIR = OUT_DIR / "_refprep"          # cropped (de-framed) reference images
MANIFEST_PATH = OUT_DIR / "manifest_image2.json"
DEFAULT_ENV_FILE = Path("/Users/markma/Desktop/Yumina/.env")

API_EDITS = "https://api.openai.com/v1/images/edits"
API_GEN = "https://api.openai.com/v1/images/generations"

OPENAI_API_KEY: str | None = None        # set in main()

# ── Reference crop boxes (fractions: left, top, right, bottom) ────────────────
# Canon refs carry title cartouches / ornate frame borders / corner watermarks.
# We crop those off once so the model conditions on the figure/scene, not chrome.
REF_CROPS: dict = {
    "klein1": (0.10, 0.00, 1.00, 1.00),   # left vertical title strip (克莱恩·莫雷蒂)
    "audrey1": (0.07, 0.06, 0.93, 0.96),
    "audrey2": (0.07, 0.06, 0.93, 0.96),
    "goddess_of_darkness": (0.06, 0.05, 0.94, 0.97),
}
FRAME_INSET = (0.065, 0.075, 0.935, 0.925)  # default for framed location refs

# Painterly samples we already made — reused as STYLE anchors where no canon
# location ref exists (keeps the palette/treatment consistent across the set).
STYLE_INTERIOR = OUT_DIR / "klein_bedroom_TEST.png"
STYLE_EXTERIOR = OUT_DIR / "iron_cross_street_day_TEST.png"
# Character style anchor for no-canon-ref NPCs (a clean anime full-body in our look).
STYLE_CHAR = OUT_DIR / "player_detective_HIFI.png"

# ── Prompt scaffolds ──────────────────────────────────────────────────────────
LOTM = ("late-Victorian gaslamp-fantasy occult-detective world of Lord of the Mysteries "
        "(Tingen City, the Loen Empire which is like Victorian Britain)")

# Characters: crisp anime/manhua illustration, faithful to canon official art.
CHAR_STYLE = (f"crisp clean anime manhua illustration in the exact art style of the official "
              f"Lord of the Mysteries character artwork, cel-shaded with clean linework and flat "
              f"stylized shading, anime-stylized facial features, NOT photorealistic, NOT a 3D render, "
              f"NOT a muddy oil painting, {LOTM}, pale fair-skinned European, muted desaturated "
              f"palette with warm gaslight accents, dramatic key lighting")
CHAR_SUFFIX = ("full-body video game character sprite, single character, idle stance, the "
               "figure fills the frame, clean isolated transparent background, no text, no logo, "
               "no frame, no border")
PORTRAIT_SUFFIX = ("chest-up character portrait, dialogue avatar, looking toward the viewer, "
                   "clean isolated transparent background, no text, no logo, no frame")

# Enemies: same crisp anime/manhua rendering as the cast, but monstrous/eldritch
# occult-horror designs (no "human European" trait) so they sit beside the cast.
ENEMY_STYLE = (f"crisp clean anime manhua illustration in the exact art style of the official "
               f"Lord of the Mysteries artwork, cel-shaded with clean linework and flat stylized "
               f"shading, NOT photorealistic, NOT a 3D render, NOT a muddy oil painting, {LOTM}, "
               f"eerie menacing occult-horror creature design, muted desaturated palette with a "
               f"single saturated occult accent, dramatic ominous key lighting")
ENEMY_SUFFIX = ("full-body video game enemy sprite, single creature, menacing pose, the figure "
                "fills the frame, clean isolated transparent background, no text, no logo, no "
                "frame, no border")

# Backgrounds: painterly illustrated scenes (match the painted location refs).
BG_ESTABLISH = (f"detailed painterly illustrated environment art, eye-level cinematic establishing "
                f"shot, {LOTM}, muted desaturated fog-gray palette with warm gaslight accents, "
                f"volumetric fog, moody atmospheric lighting, no text, no frame, no border, no people")
BG_TOPDOWN = (f"detailed painterly illustrated RPG game map, inclined three-quarter top-down "
              f"perspective like Stardew Valley, the scene seen from an elevated overhead angle with "
              f"buildings and objects drawn upright facing the camera, NO eye-level horizon, NO sky "
              f"vista, walkable ground fills the frame, {LOTM}, muted desaturated fog-gray palette "
              f"with warm gaslight accents, no text, no frame, no border, no people")


# ── Cast / scenes (descriptions track STYLE_GUIDE.md + LotM canon) ────────────
# Each item: prompt description, plus optional "ref" (canon content reference key).
# Items with a canon ref use input_fidelity=high to lock likeness; ref-less items
# pass a STYLE anchor (loose) and a "different person/place" instruction.

CHARACTERS: dict = {
    "player_detective": {
        "ref": "klein1",
        "prompt": ("Klein Moretti, a pale young European man in his early twenties, black hair swept "
                   "back, luminous glowing gold eyes, a charcoal-black caped Inverness overcoat with a "
                   "deep-violet flaring lining, white high-collar shirt and dark cravat, dark waistcoat "
                   "with a pocket-watch chain, a brown leather shoulder-holster with a revolver, holding "
                   "a black cane with an ornate silver handle and a black top hat, calm composed idle stance"),
    },
    "audrey_hall": {
        "ref": "audrey1",
        "prompt": ("Audrey Hall, an elegant young aristocratic Loen noblewoman, golden-blonde hair styled "
                   "up, bright blue eyes, a refined high-collar Victorian day dress in muted cream and "
                   "soft blue, white gloves, poised graceful bearing, gentle confident expression"),
    },
    "goddess_darkness": {
        "ref": "goddess_of_darkness",
        "prompt": ("the Goddess of Darkness / Night, a serene otherworldly divine woman, long flowing black "
                   "hair, a star-strewn midnight-black gown, faint silver-violet celestial glow, calm "
                   "transcendent expression, occult majesty"),
    },
    "nighthawk_captain": {"prompt": "a stern Nighthawk investigator captain, long dark double-breasted Inverness coat, brass badge, leather gloves, a brass oil lantern, top hat, authoritative bearing"},
    "archivist": {"prompt": "an elderly university archivist, round brass spectacles, an ink-stained scholar's frock coat and waistcoat, clutching an old leather tome, kindly wary"},
    "suspect_bieber": {"prompt": "a gaunt obsessed ritual scholar, wild bloodshot eyes, a dishevelled Victorian suit and waistcoat, gripping a cursed leather notebook, sweating"},
    "informant": {"prompt": "a shifty tavern informant, flat cap, worn wool coat and waistcoat, a sly knowing grin"},
    "priest": {"prompt": "a gaunt cathedral priest, bareheaded with thinning grey hair, a clearly visible pale gaunt face, a dark grey clerical cassock with a white clerical collar, a silver cross pendant, solemn weary expression"},
    "witness_widow": {"prompt": "a grieving widow in a dark grey Victorian mourning gown and lace veil, holding a parasol, sorrowful dignified bearing"},
    "lady_genteel": {"prompt": "a Loen gentlewoman in a faded muted sage-green and cream Victorian bustle gown, white gloves, holding a parasol, brown hair in an updo, dignified"},
    "npc_investigator": {"prompt": "a plainclothes Nighthawk investigator, a dark overcoat and waistcoat, top hat, a notebook in hand"},
    "npc_civilian_man": {"prompt": "an ordinary working-class Loen townsman, flat cap, waistcoat, rolled shirtsleeves"},
    "npc_civilian_woman": {"prompt": "an ordinary Loen townswoman, a long skirt, a shawl and bonnet, plain and weary"},
    "npc_laborer": {"prompt": "a weary dockside laborer, rough wool clothes, rolled sleeves, heavy boots"},
    "npc_constable": {"prompt": "a uniformed Loen city constable, a tall custodian helmet, a caped greatcoat, a truncheon"},
    "npc_dockworker": {"prompt": "a burly dockworker, an oilskin coat and cap, a coil of rope over the shoulder"},
    "npc_drunkard": {"prompt": "a stumbling drunkard in shabby Victorian clothes, a bottle in hand, dishevelled"},
    "npc_street_urchin": {"prompt": "a ragged street-urchin child, an oversized patched coat, a flat cap, barefoot"},
    "npc_cultist_hidden": {"prompt": "an ordinary Loen citizen with a faint unsettling stare, a concealed cultist, a plain coat"},
}

PORTRAITS: dict = {
    "portrait_player": {"ref": "klein1", "prompt": "Klein Moretti, a pale composed scholarly face, black hair swept back, striking bright gold eyes, a charcoal-black high-collar overcoat with deep-violet lining, white collar and dark cravat, brooding controlled expression"},
    "portrait_audrey": {"ref": "audrey1", "prompt": "Audrey Hall, a graceful young noblewoman, golden-blonde hair styled up, bright blue eyes, a cream-and-soft-blue high-collar Victorian dress, poised gentle expression"},
    "portrait_goddess": {"ref": "goddess_of_darkness", "prompt": "the Goddess of Darkness, a serene divine woman, long black hair, faint silver-violet celestial glow, calm transcendent expression"},
    "portrait_captain": {"prompt": "a stern Nighthawk captain, a weathered face, a brass-badged dark coat, a top hat"},
    "portrait_archivist": {"prompt": "an elderly archivist, round spectacles, a kindly wary expression, an ink-stained collar"},
    "portrait_suspect": {"prompt": "a gaunt obsessed scholar, wild bloodshot eyes, sweating, a dishevelled collar"},
    "portrait_priest": {"prompt": "a gaunt cathedral priest, hollow solemn eyes, a silver cross, a black cassock with a white collar"},
    "portrait_widow": {"prompt": "a grieving widow, a black lace mourning veil, sorrowful eyes"},
    "portrait_lady": {"prompt": "a Loen gentlewoman, brown hair in an updo, green eyes, a faded muted sage-green high-collar gown, a composed expression"},
}

# Enemies — Beyonder creatures / cultists (no canon ref → render via style anchor only).
ENEMIES: dict = {
    "cultist_robed": {"prompt": "a hooded occult cultist, a deep-hooded dark ritual robe with the face lost in shadow, clutching a ceremonial occult dagger, a faint glowing crimson sigil on the chest, a menacing cultic stance"},
    "bieber_monster": {"prompt": "a hulking ritual-warped horror, a man caught mid-transformation into a monster, a torn bloodstained Victorian suit, distended muscle and bony occult growths, too many clawed limbs, one eerie glowing-red eye, hunched and menacing"},
    "wraith_shadow": {"prompt": "a translucent shadow wraith, a ghostly spectral figure of drifting black smoke and tattered floating burial robes, hollow glowing pale-blue eyes, a half-incorporeal body, eerie and weightless"},
    "descent_horror": {"prompt": "an eldritch partial-Descent horror, a writhing mass of impossible non-Euclidean geometry and dark tendrils, scattered glowing crimson eyes across its form, oppressive otherworldly dread, a single saturated crimson accent glow"},
}

# Backgrounds carry a "treatment": "establish" (eye-level) or "topdown" (Stardew).
BACKGROUNDS: dict = {
    # ── establishing (eye-level painterly scenes; key story beats) ──
    "klein_bedroom": {"treatment": "establish", "ref": "kleinroom",
        "prompt": "Klein Moretti's warm cozy middle-class bedroom, an ornate carved-wood bed with a quilt, a writing desk and chair, a bookshelf, a wardrobe and dresser, a patterned rug, warm amber lamplight, rain on the window, lived-in"},
    "klein_parlor": {"treatment": "establish", "ref": "kleinhouse",
        "prompt": "a cozy middle-class Victorian parlor, a patterned rug, a cream sofa and armchairs, a round tea table with flowers, a fireplace, bookshelves, warm lamplight"},
    "ritual_chamber": {"treatment": "establish", "ref": "goddess_of_darkness",
        "prompt": "a hidden occult ritual chamber, a large chalk summoning circle on a dark stone floor, black candles, silver sigils, a blood-red glow, oppressive dread"},
    "iron_cross_street_bloodmoon": {"treatment": "establish", "ref": "ironcrossstreet",
        "prompt": "the Iron Cross Street slum at night under a blood-red moon, a dark crimson-lit muddy lane, leaning derelict brick and half-timber buildings, deep shadows, occult horror"},
    "backlund_skyline": {"treatment": "establish", "ref": "beckland",
        "prompt": "the industrial capital Backlund at dusk, brick factories with smokestacks, canals and iron bridges, dock cranes, a grand skyline under heavy smog and grime"},
    "warehouse_interior": {"treatment": "establish", "ref": None,
        "prompt": "a dockside warehouse interior, stacked wooden crates and barrels, hanging chains, support pillars, a cold cracked-concrete floor, shafts of fog and dim light"},
    # ── topdown (inclined 3/4 walkable maps; explorable hubs) ──
    "iron_cross_street_day": {"treatment": "topdown", "ref": "ironcrossstreet2",
        "prompt": "the Iron Cross Street slum market block by day, a narrow muddy lane, ramshackle leaning brick and half-timber buildings, market stalls and awnings, washing lines, crates, weathered grime"},
    "cathedral_plaza": {"treatment": "topdown", "ref": "St-SelenaChurchTingen",
        "prompt": "the plaza before Saint Selena's Cathedral, a large cobblestone square, a central stone fountain, the grand cream-stone Gothic cathedral along one side, benches and lamp posts"},
    "university_quad": {"treatment": "topdown", "ref": "uni",
        "prompt": "the Tingen University quad, a green lawn courtyard, stone paths, benches and trees, ringed by red-brick collegiate Gothic buildings and gas lamps"},
    "raphael_cemetery": {"treatment": "topdown", "ref": "graveyard",
        "prompt": "Raphael Cemetery grounds at night, rows of weathered headstones, winding stone paths, a central stone obelisk, mausoleums, cypress trees, cold blue-grey fog, lantern light"},
    "oldtown_street": {"treatment": "topdown", "ref": "tingen_view",
        "prompt": "a foggy cobblestone Tingen old-town street block, red-brick and timber buildings lining the lane, gas street lamps, wrought-iron rails, market crates"},
    "hq_interior": {"treatment": "topdown", "ref": None,
        "prompt": "the Nighthawks investigators headquarters office floor, wooden desks and chairs, an evidence board, filing cabinets, brass oil lamps, a plank floor, gaslit"},
    "library_archive": {"treatment": "topdown", "ref": None,
        "prompt": "a vast university archive hall floor, long rows of towering bookshelves, reading desks, carpet runners, candlelight, dim and dusty"},
    "tavern_interior": {"treatment": "topdown", "ref": None,
        "prompt": "a cozy gaslit Loen tavern floor, wooden tables and benches, a long bar counter, a fireplace, a plank floor, warm amber light"},
}

CATEGORY_DEFAULTS: dict = {
    "characters": {"items": CHARACTERS, "size": "1024x1536", "background": "transparent",
                   "suffix": CHAR_SUFFIX, "style": CHAR_STYLE, "style_anchor": STYLE_CHAR},
    "portraits":  {"items": PORTRAITS, "size": "1024x1024", "background": "transparent",
                   "suffix": PORTRAIT_SUFFIX, "style": CHAR_STYLE, "style_anchor": STYLE_CHAR},
    "enemies":    {"items": ENEMIES, "size": "1024x1536", "background": "transparent",
                   "suffix": ENEMY_SUFFIX, "style": ENEMY_STYLE, "style_anchor": STYLE_CHAR},
    "backgrounds": {"items": BACKGROUNDS, "size": "1536x1024", "background": "opaque",
                    "suffix": "", "style": None, "style_anchor": None},  # per-item below
}


# ── Reference prep (crop frames/text once) ────────────────────────────────────
def prep_ref(key: str) -> Path | None:
    """Return a path to a de-framed copy of ref/<key>.png (cached in _refprep)."""
    src = REF_DIR / f"{key}.png"
    if not src.exists():
        print(f"    WARN: ref not found: {src}")
        return None
    dst = PREP_DIR / f"{key}.png"
    if dst.exists():
        return dst
    PREP_DIR.mkdir(parents=True, exist_ok=True)
    im = Image.open(src).convert("RGB")
    w, h = im.size
    l, t, r, b = REF_CROPS.get(key, FRAME_INSET)
    im.crop((int(w * l), int(h * t), int(w * r), int(h * b))).save(dst)
    return dst


def resolve_refs(cat: str, name: str, spec: dict) -> tuple[list[Path], bool]:
    """Return (ref_paths, high_fidelity). Canon ref -> high fidelity (lock likeness).
    No canon ref -> a loose STYLE anchor (keep look, NOT identity)."""
    ref_key = spec.get("ref")
    if ref_key:
        p = prep_ref(ref_key)
        # Top-down backgrounds keep fidelity LOW: the canon location refs are
        # eye-level, and high fidelity would override the required inclined
        # top-down reframing.  The ref still informs architecture + palette.
        hi = not (cat == "backgrounds" and spec.get("treatment") == "topdown")
        return ([p] if p else []), hi
    # ref-less: choose a style anchor
    if cat == "backgrounds":
        anchor = STYLE_INTERIOR if spec.get("treatment") == "establish" else STYLE_EXTERIOR
        # interiors vs exteriors: hq/library/tavern/warehouse are interiors
        if name in ("hq_interior", "library_archive", "tavern_interior", "warehouse_interior"):
            anchor = STYLE_INTERIOR
    else:
        anchor = STYLE_CHAR
    return ([anchor] if anchor and Path(anchor).exists() else []), False


def build_prompt(cat: str, name: str, spec: dict, has_canon_ref: bool) -> str:
    desc = spec["prompt"]
    if cat == "backgrounds":
        style = BG_ESTABLISH if spec.get("treatment") == "establish" else BG_TOPDOWN
        if has_canon_ref:
            lead = "Reimagine the place in the reference image as: "
            tail = ("Match the painted illustration style and palette of the reference. "
                    if spec.get("treatment") == "establish"
                    else "Keep the architecture and palette of the reference but redraw it from the "
                         "inclined top-down map angle described. ")
        else:
            lead = ""
            tail = "Match the painted illustration style and palette of the reference image. "
        return f"{lead}{desc}. {tail}{style}."
    # characters / portraits
    base = CATEGORY_DEFAULTS[cat]
    if has_canon_ref:
        lead = "This exact person from the reference image: "
        tail = "Match the art style of the reference exactly. "
    else:
        lead = ("A menacing enemy figure (NOT the person in the reference image): "
                if cat == "enemies"
                else "A distinct individual (NOT the person in the reference image): ")
        tail = ("Copy ONLY the rendering style, line quality and color palette of the reference "
                "image — never its face, hair or clothing. Render with the same crisp cel-shaded "
                "anime illustration style and clean linework as the reference, NOT painterly or "
                "photorealistic. ")
    return f"{lead}{desc}. {tail}{base['style']}. {base['suffix']}."


# ── Token loading (never printed) ─────────────────────────────────────────────
def load_key(env_file: Path) -> str | None:
    k = os.environ.get("OPENAI_API_KEY")
    if k:
        return k.strip()
    try:
        for line in env_file.read_text().splitlines():
            line = line.strip()
            if line.startswith("#") or "=" not in line:
                continue
            key, _, val = line.partition("=")
            if key.strip() == "OPENAI_API_KEY":
                return val.strip().strip('"').strip("'")
    except OSError as e:
        print(f"ERROR: could not read env file {env_file}: {e}")
    return None


# ── API call ──────────────────────────────────────────────────────────────────
def generate(prompt: str, size: str, background: str, quality: str,
             ref_paths: list[Path], high_fidelity: bool) -> bytes | None:
    data = {
        "model": "gpt-image-1",
        "prompt": prompt,
        "size": size,
        "quality": quality,
        "background": background,
        "output_format": "png",
        "n": "1",
    }
    for attempt in range(4):
        try:
            if ref_paths:
                files = [("image[]", (p.name, p.read_bytes(), "image/png")) for p in ref_paths]
                d = dict(data)
                if high_fidelity:
                    d["input_fidelity"] = "high"
                resp = requests.post(API_EDITS, headers={"Authorization": f"Bearer {OPENAI_API_KEY}"},
                                     files=files, data=d, timeout=400)
            else:
                resp = requests.post(API_GEN, headers={"Authorization": f"Bearer {OPENAI_API_KEY}",
                                                        "Content-Type": "application/json"},
                                     json=data, timeout=400)
        except (requests.ConnectionError, requests.Timeout) as e:
            wait = 5 * (attempt + 1)
            print(f"    network error ({e}) — waiting {wait}s")
            time.sleep(wait)
            continue

        if resp.status_code == 429:
            wait = 15 * (attempt + 1)
            print(f"    rate limited — waiting {wait}s")
            time.sleep(wait)
            continue
        if resp.status_code != 200:
            print(f"    ERROR {resp.status_code}: {resp.text[:300]}")
            if resp.status_code >= 500:
                time.sleep(5 * (attempt + 1))
                continue
            return None
        try:
            b64 = resp.json()["data"][0]["b64_json"]
        except (KeyError, IndexError, ValueError) as e:
            print(f"    ERROR parsing response: {e}")
            return None
        return base64.b64decode(b64)
    print("    ERROR: retries exhausted")
    return None


# ── Runner ────────────────────────────────────────────────────────────────────
def iter_jobs(active: dict, only: str | None, treatment: str | None, limit: int | None):
    for cat, base in active.items():
        items = list(base["items"].items())
        if limit:
            items = items[:limit]
        for name, spec in items:
            if only and name != only:
                continue
            if treatment and cat == "backgrounds" and spec.get("treatment") != treatment:
                continue
            yield cat, base, name, spec


def cost_of(quality: str) -> float:
    return {"low": 0.02, "medium": 0.05, "high": 0.25}.get(quality, 0.25)


def main():
    global OPENAI_API_KEY
    ap = argparse.ArgumentParser(description="Generate Tingen hero assets via gpt-image-1")
    ap.add_argument("--dry-run", action="store_true", help="print plan, no API calls")
    ap.add_argument("--force", action="store_true", help="regenerate even if output exists")
    ap.add_argument("--category", choices=list(CATEGORY_DEFAULTS), help="only this category")
    ap.add_argument("--only", type=str, help="only this item name")
    ap.add_argument("--treatment", choices=["establish", "topdown"], help="backgrounds: only this treatment")
    ap.add_argument("--limit", type=int, help="cap items per category (testing)")
    ap.add_argument("--quality", choices=["low", "medium", "high"], default="high")
    ap.add_argument("--env-file", type=Path, default=DEFAULT_ENV_FILE)
    args = ap.parse_args()

    active = CATEGORY_DEFAULTS
    if args.category:
        active = {args.category: CATEGORY_DEFAULTS[args.category]}

    jobs = list(iter_jobs(active, args.only, args.treatment, args.limit))
    est = len(jobs) * cost_of(args.quality)
    print("Tingen Hero Asset Generator (gpt-image-1)")
    print(f"  output : {OUT_DIR}")
    print(f"  jobs   : {len(jobs)} images @ {args.quality}")
    print(f"  est.   : ${est:.2f}")
    print(f"  mode   : {'DRY RUN' if args.dry_run else 'LIVE'}")

    if not args.dry_run:
        OPENAI_API_KEY = load_key(args.env_file)
        if not OPENAI_API_KEY:
            print(f"ERROR: OPENAI_API_KEY not found (env or {args.env_file})")
            sys.exit(1)
        print(f"  key    : loaded ({len(OPENAI_API_KEY)} chars)")

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    manifest = json.loads(MANIFEST_PATH.read_text()) if MANIFEST_PATH.exists() else {"assets": []}

    done = skip = fail = 0
    for i, (cat, base, name, spec) in enumerate(jobs, 1):
        out_dir = OUT_DIR / cat
        out_dir.mkdir(parents=True, exist_ok=True)
        fpath = out_dir / f"{name}.png"
        if fpath.exists() and not args.force:
            skip += 1
            continue

        ref_paths, high_fidelity = resolve_refs(cat, name, spec)
        has_canon = bool(spec.get("ref"))
        prompt = build_prompt(cat, name, spec, has_canon)
        size = base["size"]
        background = base["background"]
        treat = spec.get("treatment", "")
        tag = f"{cat}/{name}" + (f" [{treat}]" if treat else "")
        refnote = (f"refs={[p.name for p in ref_paths]} fid={'high' if high_fidelity else 'low'}"
                   if ref_paths else "no-ref (generations)")

        if args.dry_run:
            print(f"  [{i}/{len(jobs)}] {tag} ({size}, {background}) {refnote}")
            print(f"        {prompt[:150]}...")
            continue

        print(f"  [{i}/{len(jobs)}] {tag} ({size}, {background}, {args.quality}) {refnote}")
        t0 = time.time()
        img = generate(prompt, size, background, args.quality, ref_paths, high_fidelity)
        if img:
            fpath.write_bytes(img)
            manifest["assets"] = [e for e in manifest["assets"]
                                  if not (e["category"] == cat and e["name"] == name)]
            manifest["assets"].append({
                "category": cat, "name": name, "path": f"out_image2/{cat}/{name}.png",
                "prompt": prompt, "size": size, "background": background, "quality": args.quality,
                "refs": [p.name for p in ref_paths], "input_fidelity": "high" if high_fidelity else "low",
                "treatment": treat, "endpoint": "edits" if ref_paths else "generations",
            })
            MANIFEST_PATH.write_text(json.dumps(manifest, indent=2))
            done += 1
            print(f"    OK ({len(img)//1024}KB, {round(time.time()-t0)}s)")
        else:
            fail += 1
        time.sleep(0.3)

    print(f"\nDone: {done} generated, {skip} existing, {fail} failed")
    if not args.dry_run:
        print(f"Manifest: {MANIFEST_PATH}")


if __name__ == "__main__":
    main()
