import json
from pathlib import Path
from src.demo import init_db, load_members, load_redemptions

def test_quarantine_and_derived_fields(tmp_path: Path):
    f = tmp_path / "m.txt"
    f.write_text(
        "|D|Elena | 223457|20101012|20121013|GLD | Sam |CA| USA |03051985|A\n"
        "|D|Ravi 223458|20101012|20121013|SLV | Sam|TN|IND|03051985 | A\n"
    )
    db = init_db()
    load_members(db, f)
    elena = db.execute("SELECT * FROM Table_USA WHERE member_id='223457'").fetchone()
    assert elena["age"] == 38 and elena["stale_member"] == 1
    assert db.execute("SELECT COUNT(*) FROM quarantine").fetchone()[0] == 1

def test_country_relocation_latest_wins(tmp_path: Path):
    day1, day2 = tmp_path / "d1.txt", tmp_path / "d2.txt"
    day1.write_text("|D|Elena|223457|20101012|20240101|GLD|Sam|CA|USA|03051985|A\n")
    day2.write_text("|D|Elena|223457|20101012|20240110|PLT|Sam|TN|IND|03051985|A\n")
    db = init_db()
    load_members(db, day1)
    load_members(db, day2)
    assert db.execute("SELECT * FROM Table_USA WHERE member_id='223457'").fetchone() is None
    assert db.execute("SELECT * FROM Table_India WHERE member_id='223457'").fetchone()["tier_code"] == "PLT"

def test_json_redemptions(tmp_path: Path):
    j = tmp_path / "r.json"
    j.write_text(json.dumps({
        "member id": "223457", "feed_date": "20240115",
        "redemptions": [{"txn_id": "RX1", "partner": "AeroLink", "miles_redeemed": 12000, "status": "COMPLETED"}]
    }))
    db = init_db()
    load_redemptions(db, j)
    assert db.execute("SELECT miles FROM fact_redemptions WHERE txn_id='RX1'").fetchone()[0] == 12000
