-- BigQuery job: Write final merged diagnostics to a table for dashboards
-- Usage: Update project/dataset/table below, then run end-to-end.

-- =========================
-- PARAMETERS (edit here)
-- =========================
DECLARE project_id STRING DEFAULT "your-project-id";                -- e.g., arboreal-vision-339901
DECLARE dataset_id STRING DEFAULT "analytics";                      -- target dataset for reporting
DECLARE table_id   STRING DEFAULT "ubereats_grubhub_hours_report";  -- target table name
DECLARE ds_src     STRING DEFAULT "arboreal-vision-339901.take_home_v2"; -- source dataset for raw tables
DECLARE tolerance_min INT64 DEFAULT 5;  -- near-match tolerance

-- Compose fully-qualified names
DECLARE target_table STRING DEFAULT CONCAT(project_id, ".", dataset_id, ".", table_id);
DECLARE tbl_gh_src STRING DEFAULT CONCAT(ds_src, ".virtual_kitchen_grubhub_hours");
DECLARE tbl_ue_src STRING DEFAULT CONCAT(ds_src, ".virtual_kitchen_ubereats_hours");

-- Create dataset if it doesn't exist (run separately if needed)
-- CREATE SCHEMA IF NOT EXISTS `your-project-id.analytics` OPTIONS(location="US");

-- =========================
-- UDFs & helpers
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

CREATE TEMP FUNCTION to_hhmm(t STRING) AS (
  COALESCE(
    REGEXP_SUBSTR(t, r"^(\d{2}:\d{2})"),
    SAFE.SUBSTR(t,1,5)
  )
);

-- =========================
-- FINAL WRITE (creates or overwrites table)
-- =========================
CREATE OR REPLACE TABLE `${project_id}.${dataset_id}.${table_id}`
PARTITION BY DATE(_loaded_at)
CLUSTER BY virtual_restaurant_name, day AS
WITH grubhub_hours AS (
  SELECT
    b_name AS grubhub_slug,
    vb_name AS virtual_restaurant_name,
    LOWER(JSON_EXTRACT_SCALAR(rule, '$.days_of_week[0]')) AS day,
    to_hhmm(JSON_EXTRACT_SCALAR(rule, '$.from')) AS gh_open_time,
    to_hhmm(JSON_EXTRACT_SCALAR(rule, '$.to'))   AS gh_close_time
  FROM `${tbl_gh_src}`,
  UNNEST(JSON_EXTRACT_ARRAY(response, '$.availability_by_catalog.STANDARD_DELIVERY.schedule_rules')) AS rule
),
ubereats_hours AS (
  SELECT
    b_name AS ubereats_slug,
    vb_name AS virtual_restaurant_name,
    LOWER(win.day) AS day,
    to_hhmm(win.start_time) AS ue_open_time,
    to_hhmm(win.end_time)   AS ue_close_time
  FROM `${tbl_ue_src}`,
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
  gh_open_time,
  gh_close_time,
  ue_open_time,
  ue_close_time,
  minutes_diff_open,
  minutes_diff_close,
  CASE
    WHEN gh_open_time = ue_open_time AND gh_close_time = ue_close_time THEN 'exact'
    WHEN (minutes_diff_open <= tolerance_min OR minutes_diff_open IS NULL)
     AND (minutes_diff_close <= tolerance_min OR minutes_diff_close IS NULL) THEN 'near'
    ELSE 'mismatch'
  END AS comparison_label,
  CURRENT_TIMESTAMP() AS _loaded_at
FROM merged;

-- =========================
-- DASHBOARD-READY SCHEMA (reference)
-- =========================
-- Column                Type        Description
-- ---------------------------------------------------------------
-- grubhub_slug          STRING      Grubhub business slug
-- virtual_restaurant_name STRING    Kitchen name (normalized)
-- ubereats_slug         STRING      UberEats business slug
-- day                   STRING      Weekday (lowercase)
-- gh_open_time          STRING      Grubhub open HH:MM
-- gh_close_time         STRING      Grubhub close HH:MM
-- ue_open_time          STRING      UberEats open HH:MM
-- ue_close_time         STRING      UberEats close HH:MM
-- minutes_diff_open     INT64       Absolute diff (minutes) of open time
-- minutes_diff_close    INT64       Absolute diff (minutes) of close time
-- comparison_label      STRING      exact | near | mismatch
-- _loaded_at            TIMESTAMP   Load time for partitioning

-- Recommended Looker Studio/BI visuals:
-- - KPI: % exact, % near, % mismatch
-- - Table: name/day with diffs and label
-- - Heatmap: mismatch counts by weekday
-- - Trend: daily mismatch volume (by _loaded_at)
