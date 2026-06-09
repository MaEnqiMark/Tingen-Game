import generate_tingen_anim as g


def test_cast_has_four_characters():
    assert set(g.ANIM_CAST) == {
        "player_detective", "nighthawk_captain", "priest", "bieber_monster"}


def test_sheet_counts_per_character():
    # design spec §6: 12 / 8 / 8 / 8 action sheets.
    def n(ch):
        return sum(len(v) for v in g.SHEETS[ch].values())
    assert n("player_detective") == 12
    assert n("nighthawk_captain") == 8
    assert n("priest") == 8
    assert n("bieber_monster") == 8


def test_total_jobs_all_stages():
    jobs = list(g.iter_anim_jobs("all", None))
    design = [j for j in jobs if j[0] == "design"]
    action = [j for j in jobs if j[0] == "action"]
    assert len(design) == 4
    assert len(action) == 36
    assert len(jobs) == 40


def test_stage_filter():
    assert len(list(g.iter_anim_jobs("design", None))) == 4
    assert len(list(g.iter_anim_jobs("action", None))) == 36


def test_character_filter():
    jobs = list(g.iter_anim_jobs("all", "player_detective"))
    assert all(j[1] == "player_detective" for j in jobs)
    assert len(jobs) == 13  # 1 design + 12 action
