-- Step 1: Define the UDF to extract regular hours from JSON (UberEats)
CREATE TEMP FUNCTION regularHours(response JSON)
RETURNS ARRAY<STRUCT<start_time STRING, end_time STRING, day STRING>>
LANGUAGE js AS """
    // Helper function to map index to day of the week
    function getDayFromIndex(index) {
        const daysOfWeek = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
        return daysOfWeek[index];
    }
   
    // Initialize an empty array to store the results
    let timeWindowArray = [];


    // Check if menus and sections exist
    if (response.data && response.data.menus) {
        const menus = response.data.menus;
       
        Object.keys(menus).forEach(menuKey => {
            const menu = menus[menuKey];
            if (menu.sections && menu.sections.length > 0) {
                menu.sections.forEach(section => {
                    if (section.regularHours) {
                        // Loop through regularHours array (if it exists)
                        section.regularHours.forEach(hourBlock => {
                            if (hourBlock.startTime && hourBlock.endTime && hourBlock.daysBitArray) {
                                // Loop through daysBitArray and extract applicable days
                                hourBlock.daysBitArray.forEach((isDayActive, index) => {
                                    if (isDayActive) {
                                        timeWindowArray.push({
                                            start_time: hourBlock.startTime,
                                            end_time: hourBlock.endTime,
                                            day: getDayFromIndex(index)
                                        });
                                    }
                                });
                            }
                        });
                    }
                });
            }
        });
    }
   
    return timeWindowArray;
""";


-- Step 2: Extract Grubhub Hours
WITH grubhub_hours AS (
  SELECT
    b_name AS grubhub_slug,
    vb_name AS virtual_restaurant_name,
    LOWER(JSON_EXTRACT_SCALAR(value, '$.days_of_week[0]')) AS day,
    SUBSTR(JSON_EXTRACT_SCALAR(value, '$.from'), 0, 5) AS gh_open_time,  -- Extract HH:MM
    SUBSTR(JSON_EXTRACT_SCALAR(value, '$.to'), 0, 5) AS gh_close_time   -- Extract HH:MM
  FROM `arboreal-vision-339901.take_home_v2.virtual_kitchen_grubhub_hours`,
  UNNEST(JSON_EXTRACT_ARRAY(response, '$.availability_by_catalog.STANDARD_DELIVERY.schedule_rules')) AS value
),


-- Step 3: Extract UberEats Hours Using the UDF
ubereats_hours AS (
  SELECT
    b_name AS ubereats_slug,
    vb_name AS virtual_restaurant_name,
    LOWER(time_window.day) AS day,
    SUBSTR(time_window.start_time, 0, 5) AS ue_open_time,  -- Extract HH:MM
    SUBSTR(time_window.end_time, 0, 5) AS ue_close_time   -- Extract HH:MM
  FROM `arboreal-vision-339901.take_home_v2.virtual_kitchen_ubereats_hours`,
  UNNEST(regularHours(response)) AS time_window
),


-- Step 4: Full Outer Join to Capture Mismatches
merged_hours AS (
  SELECT
    COALESCE(gh.grubhub_slug, ue.ubereats_slug) AS grubhub_slug,
    COALESCE(gh.virtual_restaurant_name, ue.virtual_restaurant_name) AS virtual_restaurant_name,
    COALESCE(ue.ubereats_slug, gh.grubhub_slug) AS ubereats_slug,
    COALESCE(gh.day, ue.day) AS day,
    gh.gh_open_time,
    gh.gh_close_time,
    ue.ue_open_time,
    ue.ue_close_time,
    -- Compare time ranges and calculate difference
    CASE
      WHEN gh.gh_open_time = ue.ue_open_time AND gh.gh_close_time = ue.ue_close_time THEN 'In Range'
      WHEN gh.gh_open_time != ue.ue_open_time OR gh.gh_close_time != ue.ue_close_time THEN
        CASE
          WHEN ABS(TIMESTAMP_DIFF(PARSE_TIMESTAMP('%H:%M', gh.gh_open_time), PARSE_TIMESTAMP('%H:%M', ue.ue_open_time), MINUTE)) <= 5
               AND ABS(TIMESTAMP_DIFF(PARSE_TIMESTAMP('%H:%M', gh.gh_close_time), PARSE_TIMESTAMP('%H:%M', ue.ue_close_time), MINUTE)) <= 5 THEN
            'Out of Range with 5 mins difference'
          ELSE 'Out of Range'
        END
      ELSE 'Unknown'
    END AS is_out_of_range
  FROM ubereats_hours ue
  FULL OUTER JOIN grubhub_hours gh
  ON LOWER(gh.virtual_restaurant_name) = LOWER(ue.virtual_restaurant_name)
  AND gh.grubhub_slug = ue.ubereats_slug
  AND LOWER(gh.day) = LOWER(ue.day)
)


-- Step 5: Final Output Showing the Business Hours Mismatch
SELECT
  grubhub_slug,
  virtual_restaurant_name,
  ubereats_slug,
  day,
  gh_open_time,
  gh_close_time,
  ue_open_time,
  ue_close_time,
  is_out_of_range
FROM merged_hours
ORDER BY virtual_restaurant_name, day;
