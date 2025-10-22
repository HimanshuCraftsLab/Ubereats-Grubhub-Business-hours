-- UberEats vs Grubhub — Business Hours Comparison (BigQuery + JS UDF)
-- Parameterized, diagnosable version with sample outputs per step

-- =========================
-- 0) PARAMETERS (edit here)
-- =========================
DECLARE ds STRING DEFAULT "arboreal-vision-339901.take_home_v2";  -- dataset
DECLARE tbl_gh STRING DEFAULT CONCAT(ds, ".virtual_kitchen_grubhub_hours");
DECLARE tbl_ue STRING DEFAULT CONCAT(ds, ".virtual_kitchen_ubereats_hours");
DECLARE tolerance_min INT64 DEFAULT 5;  -- near-match tolerance in minutes

-- =========================
-- 1) JS UDF (UberEats regular hours → flat rows)
-- =========================
CREATE TEMP FUNCTION regularHours(response JSON)
RETURNS ARRAY<STRUCT<start_time STRING, end_time STRING, day STRING>>
LANGUAGE js AS """
    function getDayFromIndex(index) {
        const days = ['Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday'];
        return days[index];
    }
    let out = [];
    if (response && response.data && response.data.menus) {
        const menus = response.data.menus;
        Object.keys(menus).forEach(k => {
            const menu = menus[k];
            if (menu.sections && menu.sections.length) {
                menu.sections.forEach(section => {
                    if (section.regularHours) {
                        section.regularHours.forEach(h => {
                            if (h.startTime && h.endTime && Array.isArray(h.daysBitArray)) {
                                h.daysBitArray.forEach((active, idx) => {
                                    if (active) {
                                        out.push({ start_time: h.startTime, end_time: h.endTime, day: getDayFromIndex(idx) });
                                    }
                                });
                            }
                        });
                    }
                });
            }
        });
    }
    return out;
""";

-- Helper to normalize any of: HH:MM:SS, HH:MM → HH:MM
CREATE TEMP FUNCTION to_hhmm(t STRING) AS (
  COALESCE(
    REGEXP_SUBSTR(t, r"^(\d{2}:\d{2})"),
    SAFE.SUBSTR(t,1,5)
  )
);

-- =========================
-- 2) STEP A — Grubhub hours extraction
-- =========================
WITH grubhub_hours AS (
  SELECT
    b_name AS grubhub_slug,
    vb_name AS virtual_restaurant_name,
    LOWER(JSON_EXTRACT_SCALAR(rule, '$.days_of_week[0]')) AS day,
    to_hhmm(JSON_EXTRACT_SCALAR(rule, '$.from')) AS gh_open_time,
    to_hhmm(JSON_EXTRACT_SCALAR(rule, '$.to'))   AS gh_close_time
  FROM `arboreal-vision-339901.take_home_v2.virtual_kitchen_grubhub_hours`,
  UNNEST(JSON_EXTRACT_ARRAY(response, '$.availability_by_catalog.STANDARD_DELIVERY.schedule_rules')) AS rule
)
SELECT * FROM grubhub_hours
ORDER BY virtual_restaurant_name, day
LIMIT 20;
-- SAMPLE OUTPUT (first rows):
-- grubhub_slug | virtual_restaurant_name | day     | gh_open_time | gh_close_time
-- -------------+-------------------------+---------+--------------+--------------
-- abc-slug     | Cloud Kitchen X         | monday  | 10:00        | 22:00
-- abc-slug     | Cloud Kitchen X         | tuesday | 10:00        | 22:00


-- =========================
-- 3) STEP B — UberEats hours extraction via UDF
-- =========================
WITH ubereats_hours AS (
  SELECT
    b_name AS ubereats_slug,
    vb_name AS virtual_restaurant_name,
    LOWER(win.day) AS day,
    to_hhmm(win.start_time) AS ue_open_time,
    to_hhmm(win.end_time)   AS ue_close_time
  FROM `arboreal-vision-339901.take_home_v2.virtual_kitchen_ubereats_hours`,
  UNNEST(regularHours(response)) AS win
)
SELECT * FROM ubereats_hours
ORDER BY virtual_restaurant_name, day
LIMIT 20;
-- SAMPLE OUTPUT (first rows):
-- ubereats_slug | virtual_restaurant_name | day     | ue_open_time | ue_close_time
-- --------------+-------------------------+---------+--------------+--------------
-- abc-slug      | Cloud Kitchen X         | monday  | 10:00        | 22:00
-- abc-slug      | Cloud Kitchen X         | tuesday | 10:00        | 22:00


-- =========================
-- 4) STEP C — Merge & diagnose differences
-- =========================
WITH grubhub_hours AS (
  SELECT
    b_name AS grubhub_slug,
    vb_name AS virtual_restaurant_name,
    LOWER(JSON_EXTRACT_SCALAR(rule, '$.days_of_week[0]')) AS day,
    to_hhmm(JSON_EXTRACT_SCALAR(rule, '$.from')) AS gh_open_time,
    to_hhmm(JSON_EXTRACT_SCALAR(rule, '$.to'))   AS gh_close_time
  FROM `arboreal-vision-339901.take_home_v2.virtual_kitchen_grubhub_hours`,
  UNNEST(JSON_EXTRACT_ARRAY(response, '$.availability_by_catalog.STANDARD_DELIVERY.schedule_rules')) AS rule
),
ubereats_hours AS (
  SELECT
    b_name AS ubereats_slug,
    vb_name AS virtual_restaurant_name,
    LOWER(win.day) AS day,
    to_hhmm(win.start_time) AS ue_open_time,
    to_hhmm(win.end_time)   AS ue_close_time
  FROM `arboreal-vision-339901.take_home_v2.virtual_kitchen_ubereats_hours`,
  UNNEST(regularHours(response)) AS win
),
merged AS (
  SELECT
    COALESCE(gh.grubhub_slug, ue.ubereats_slug) AS grubhub_slug,
    COALESCE(gh.virtual_restaurant_name, ue.virtual_restaurant_name) AS virtual_restaurant_name,
    COALESCE(ue.ubereats_slug, gh.grubhub_slug) AS ubereats_slug,
    COALESCE(gh.day, ue.day) AS day,
    gh.gh_open_time,
    gh.gh_close_time,
    ue.ue_open_time,
    ue.ue_close_time,
    -- numeric diagnostics (minutes)
    SAFE.ABS(TIMESTAMP_DIFF(PARSE_TIMESTAMP('%H:%M', gh.gh_open_time), PARSE_TIMESTAMP('%H:%M', ue.ue_open_time), MINUTE))   AS minutes_diff_open,
    SAFE.ABS(TIMESTAMP_DIFF(PARSE_TIMESTAMP('%H:%M', gh.gh_close_time), PARSE_TIMESTAMP('%H:%M', ue.ue_close_time), MINUTE)) AS minutes_diff_close
  FROM ubereats_hours ue
  FULL OUTER JOIN grubhub_hours gh
    ON LOWER(gh.virtual_restaurant_name) = LOWER(ue.virtual_restaurant_name)
   AND gh.grubhub_slug = ue.ubereats_slug
   AND LOWER(gh.day) = LOWER(ue.day)
)
SELECT
  grubhub_slug,
  virtual_restaurant_name,
  ubereats_slug,
  day,
  gh_open_time, gh_close_time,
  ue_open_time, ue_close_time,
  minutes_diff_open, minutes_diff_close,
  CASE
    WHEN gh_open_time = ue_open_time AND gh_close_time = ue_close_time THEN 'exact'
    WHEN (minutes_diff_open <= tolerance_min OR minutes_diff_open IS NULL)
      AND (minutes_diff_close <= tolerance_min OR minutes_diff_close IS NULL) THEN 'near'
    ELSE 'mismatch'
  END AS comparison_label
FROM merged
ORDER BY virtual_restaurant_name, day
LIMIT 20;
-- SAMPLE OUTPUT (first rows):
-- grubhub_slug | virtual_restaurant_name | ubereats_slug | day     | gh_open | gh_close | ue_open | ue_close | diff_open | diff_close | comparison_label
-- -------------+-------------------------+---------------+---------+---------+----------+---------+----------+-----------+------------+------------------
-- abc-slug     | Cloud Kitchen X         | abc-slug      | monday  | 10:00   | 22:00    | 10:00   | 22:00    | 0         | 0          | exact
-- abc-slug     | Cloud Kitchen X         | abc-slug      | tuesday | 10:00   | 22:00    | 10:05   | 22:00    | 5         | 0          | near
-- abc-slug     | Cloud Kitchen X         | abc-slug      | wed     | 10:00   | 22:00    | 11:00   | 23:00    | 60        | 60         | mismatch

-- =========================
-- 5) OPTIONAL — write to a table (uncomment and set a target table)
-- =========================
-- CREATE OR REPLACE TABLE `your_project.your_ds.ubereats_grubhub_hours_report` AS
-- SELECT * FROM (
--   <paste the final SELECT above without LIMIT>
-- );
