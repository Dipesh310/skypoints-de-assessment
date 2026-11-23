# SkyPoints Data Engineer Technical Assessment

End-to-end data pipeline for **SkyPoints**, a global airline loyalty program, designed to ingest daily member profile flat files and partner airline JSON redemption feeds, validate data quality, and route members into country-specific target tables at billion-row scale.

## Architecture & Scaling Strategy (Billions of Records/Day)

To handle billions of daily records reliably and cost-effectively in **Snowflake**:
- **Raw Landing First (ELT):** Land flat files as raw strings (`raw_members`) and JSON feeds natively as `VARIANT` (`raw_redemptions`) using Snowpipe / `COPY INTO` so malformed rows never crash ingestion.
- **Quarantine Pattern:** Route structurally broken or invalid rows to `quarantine_members` for investigation instead of failing the pipeline.
- **Micro-Partition Pruning:** Cluster staging and country target tables by `member_id` (and `fact_redemptions` by `member_id, txn_date`) so daily `MERGE` and `DELETE` operations avoid full-table scans.
- **Latest Record Wins:** Deduplicate staging records using `QUALIFY ROW_NUMBER()` and remove relocated members from their previous country table before upserting into the new country table.

## Repository Structure

```text
skypoints-de-assessment/
├── data/
│   ├── members.txt              # Sample pipe-delimited member profile feed
│   └── redemptions.json         # Sample semi-structured partner JSON feed
├── sql/
│   └── snowflake_solution.sql   # All 5 deliverables in production Snowflake SQL
├── src/
│   └── demo.py                  # Lightweight Python + SQLite runner for local demo
├── tests/
│   └── test_demo.py             # Pytest suite covering quarantine, relocation, and JSON parsing
└── README.md