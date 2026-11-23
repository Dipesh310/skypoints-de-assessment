import json
import sqlite3
from datetime import date, datetime
from pathlib import Path

COUNTRY_MAP = {"USA": "USA", "IND": "IND", "AU": "AUS", "AUS": "AUS", "CAN": "CAN", "PHIL": "PHL", "PHL": "PHL"}
TABLES = {"USA": "Table_USA", "IND": "Table_India", "AUS": "Table_Australia", "CAN": "Table_Canada", "PHL": "Table_Philippines"}

def init_db(db_path=":memory:"):
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    conn.execute("CREATE TABLE IF NOT EXISTS quarantine (raw_line TEXT, reason TEXT)")
    conn.execute("CREATE TABLE IF NOT EXISTS fact_redemptions (txn_id TEXT PRIMARY KEY, member_id TEXT, partner TEXT, miles INTEGER, status TEXT)")
    for tbl in TABLES.values():
        conn.execute(f"""
            CREATE TABLE IF NOT EXISTS {tbl} (
                member_id TEXT PRIMARY KEY, member_name TEXT, enrollment_date TEXT,
                last_flight_date TEXT, tier_code TEXT, country TEXT, dob TEXT, age INT, stale_member INT
            )
        """)
    return conn

def load_members(conn, file_path: Path, today=date(2024, 1, 15)):
    for line in file_path.read_text().splitlines():
        cols = [c.strip() for c in line.strip().strip("|").split("|")]
        if not cols or cols[0].upper() == "H":
            continue
        if len(cols) != 11:
            conn.execute("INSERT INTO quarantine VALUES (?, ?)", (line, "BAD_COLUMN_COUNT"))
            continue

        _, name, mid, enroll_s, flight_s, tier, _, _, ctry_s, dob_s, _ = cols
        ctry = COUNTRY_MAP.get(ctry_s.upper())
        if not (name and mid and ctry):
            conn.execute("INSERT INTO quarantine VALUES (?, ?)", (line, "MISSING_MANDATORY_FIELD"))
            continue

        enroll_dt = datetime.strptime(enroll_s, "%Y%m%d").date()
        flight_dt = datetime.strptime(flight_s, "%Y%m%d").date() if flight_s else None
        dob_dt = datetime.strptime(dob_s.zfill(8), "%d%m%Y").date()
        age = today.year - dob_dt.year - ((today.month, today.day) < (dob_dt.month, dob_dt.day))
        stale = 1 if (not flight_dt or (today - flight_dt).days > 90) else 0

        # Latest record wins: delete member from all other country tables first
        for code, tbl in TABLES.items():
            if code != ctry:
                conn.execute(f"DELETE FROM {tbl} WHERE member_id = ?", (mid,))

        conn.execute(
            f"INSERT OR REPLACE INTO {TABLES[ctry]} VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (mid, name, enroll_dt.isoformat(), flight_dt.isoformat() if flight_dt else None, tier, ctry, dob_dt.isoformat(), age, stale),
        )
    conn.commit()

def load_redemptions(conn, json_path: Path):
    data = json.loads(json_path.read_text())
    records = data if isinstance(data, list) else [data]
    for item in records:
        mid = str(item.get("member id", "")).strip()
        for r in item.get("redemptions", []):
            conn.execute(
                "INSERT OR REPLACE INTO fact_redemptions VALUES (?, ?, ?, ?, ?)",
                (r["txn_id"], mid, r["partner"], r["miles_redeemed"], r["status"]),
            )
    conn.commit()

if __name__ == "__main__":
    db = init_db("skypoints.db")
    load_members(db, Path("data/members.txt"))
    load_redemptions(db, Path("data/redemptions.json"))
    print("USA:", [dict(r) for r in db.execute("SELECT * FROM Table_USA")])
    print("Quarantined:", [dict(r) for r in db.execute("SELECT * FROM quarantine")])
    print("Redemptions:", [dict(r) for r in db.execute("SELECT * FROM fact_redemptions")])