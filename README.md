# UberEats vs Grubhub — Business Hours Comparison (BigQuery + JS UDF)

[![BigQuery](https://img.shields.io/badge/Google%20BigQuery-SQL-4285F4?logo=google-cloud&logoColor=white)](#)
[![JavaScript](https://img.shields.io/badge/UDF-JavaScript-F7DF1E?logo=javascript&logoColor=black)](#)
[![Data Engineering](https://img.shields.io/badge/Focus-Data%20Engineering-4CAF50)](#)

This project reconciles virtual kitchen business hours between **UberEats** and **Grubhub** using **Google BigQuery**. It includes a reusable **JavaScript UDF** for UberEats JSON, robust joins, and a tolerant comparison logic (≤ 5 minutes) with helpful diagnostics.

---

## 📁 Project Structure

```
Ubereats-Grubhub-Business-hours/
├── SQL CODE FOR UBEREATS VS GRUBHUB/
│   ├── UBEREATS_GRUBHUB.sql             # Original script
│   ├── UBEREATS_GRUBHUB_enhanced.sql    # Parameterized, diagnosable version with samples
│   ├── UBEREATS_DATA.md                 # Notes on UberEats JSON schema
│   └── GRUBHUB_DATA.md                  # Notes on Grubhub JSON schema
└── README.md                            # Documentation
```

## 🧠 Problem Statement

Platforms encode hours differently (bitmasks vs rule arrays). We extract hours from both sources, normalize to `HH:MM`, and determine if they match exactly, are near (≤ 5 minutes), or mismatch.

## ▶️ How to Run

1) Open BigQuery Console

2) Use the enhanced script (recommended):
- File: `SQL CODE FOR UBEREATS VS GRUBHUB/UBEREATS_GRUBHUB_enhanced.sql`
- Edit the parameters at the top if needed:
  - `ds` — dataset
  - `tbl_gh`, `tbl_ue` — table names
  - `tolerance_min` — near-match threshold (minutes)

3) Run step-by-step
- The script is split into 3 query sections (A/B/C) with a `SELECT ... LIMIT 20` preview and a commented sample output illustrating expected rows.

## 🔧 What Each Step Produces (with examples)

- Step A — Grubhub hours extraction:
  - Columns: `grubhub_slug`, `virtual_restaurant_name`, `day`, `gh_open_time`, `gh_close_time`
  - Example rows:
    - `abc-slug | Cloud Kitchen X | monday  | 10:00 | 22:00`
    - `abc-slug | Cloud Kitchen X | tuesday | 10:00 | 22:00`

- Step B — UberEats hours via UDF:
  - Columns: `ubereats_slug`, `virtual_restaurant_name`, `day`, `ue_open_time`, `ue_close_time`
  - Example rows:
    - `abc-slug | Cloud Kitchen X | monday  | 10:00 | 22:00`
    - `abc-slug | Cloud Kitchen X | tuesday | 10:00 | 22:00`

- Step C — Merged diagnostics and comparison:
  - Columns: `... minutes_diff_open, minutes_diff_close, comparison_label`
  - Example rows:
    - `exact`    → diff_open=0,  diff_close=0  (times match exactly)
    - `near`     → diff_open=5,  diff_close=0  (within tolerance)
    - `mismatch` → diff_open=60, diff_close=60 (material discrepancy)

## 🧩 Modeling & Logic Notes

- UberEats: `menus[*].sections[*].regularHours[*]` with `daysBitArray` → expanded to weekday names via UDF
- Grubhub: `availability_by_catalog.STANDARD_DELIVERY.schedule_rules` → extract `from`/`to`
- Normalization: `to_hhmm()` coerces `HH:MM:SS` or `HH:MM` → `HH:MM`
- Tolerance: `tolerance_min` controls the “near” boundary (default 5 minutes)

## 📈 Optional Enhancements

- Overnight windows handling (22:00–02:00) by splitting intervals
- Window compaction to merge contiguous windows per day
- Write results to a BigQuery table and build a Looker Studio dashboard
- Convert to dbt models with tests for maintainability

## 🙌 Author

Mandan Mishra ([@HimanshuCraftsLab](https://github.com/HimanshuCraftsLab)) — Data Science & Analytics
