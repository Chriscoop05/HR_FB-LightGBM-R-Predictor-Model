-- HR/FB% exploration, 2026 season only

USE statcast;



-- Sources: Wikipedia neutral-site + international game lists, MLB.com, ESPN.
-- Note the A's: 'OAK' through 2024, 'ATH' from 2025 on. If your data uses OAK for
-- 2025-26 just change the ATH rows.
DROP TABLE IF EXISTS special_games;

CREATE TABLE special_games (
  game_date DATE,
  home_team VARCHAR(5),
  note VARCHAR(120)
);

-- To properly look at HR/FB per ballpark, we are going to address the "special games" played in 3rd party locations
INSERT INTO special_games (game_date, home_team, note) VALUES
  ('2026-04-25', 'SD', 'Mexico City vs AZ'),
  ('2026-04-26', 'SD', ''),
  ('2026-06-08', 'ATH', 'Las Vegas Ballpark vs MIL'),
  ('2026-06-09', 'ATH', ''),
  ('2026-06-10', 'ATH', ''),
  ('2026-06-12', 'ATH', 'Las Vegas Ballpark vs COL'),
  ('2026-06-13', 'ATH', ''),
  ('2026-06-14', 'ATH', ''),
  ('2026-08-13', 'MIN', 'Field of Dreams vs PHI'),
  ('2026-08-23', 'MIL', 'Little League Classic vs ATL');


-- Pull every fly ball + every HR out of sc_2026 into one small table.
-- Going to sc_2026 directly because all_pitches doesn't carry balls/strikes.
DROP TABLE IF EXISTS fb_hr;

CREATE TABLE fb_hr AS
SELECT game_date, year, home_team, away_team, bat_side, pitch_type, release_speed, zone, balls, strikes, launch_speed, launch_angle, hit_coord_x, hit_coord_y, bb_type, events
FROM sc_2026
WHERE bb_type = 'fly_ball' OR events = 'home_run';

CREATE INDEX idx_fbhr_game ON fb_hr (game_date, home_team);

-- how many rows are about to get tossed
SELECT COUNT(*) AS special_game_rows
FROM fb_hr f
JOIN special_games s ON f.game_date = s.game_date AND f.home_team = s.home_team;

-- toss them
DELETE f FROM fb_hr f
JOIN special_games s ON f.game_date = s.game_date AND f.home_team = s.home_team;


-- cleaned view with all the buckets we need
-- spray angle uses the usual hc_x/hc_y conversion, flipped for lefties so negative = pull for everyone
CREATE OR REPLACE VIEW fb_hr_clean AS
SELECT
  f.*,
  (bb_type = 'fly_ball')                           AS is_fb,
  (events  = 'home_run')                           AS is_hr,     -- ALL home runs
  (events  = 'home_run' AND bb_type = 'line_drive') AS is_ld_hr, -- just for checking, not in the rate

  -- FT is the old sinker code, fold it into SI
  CASE WHEN pitch_type = 'FT' THEN 'SI' ELSE pitch_type END AS pt,

  CASE
    WHEN pitch_type IN ('FF','SI','FT','FC')            THEN 'Fastball'
    WHEN pitch_type IN ('SL','ST','SV','CU','KC')       THEN 'Breaking'
    WHEN pitch_type IN ('CH','FS','FO','SC')            THEN 'Offspeed'
    ELSE NULL     -- KN, EP, CS, FA, PO, IN, UN, AB etc. -> out
  END AS pitch_class,

  CONCAT(balls, '-', strikes) AS count_str,
  CASE
    WHEN balls = 3 AND strikes = 2                                       THEN 'Full'
    WHEN (balls, strikes) IN ((0,0),(1,1),(2,2))                         THEN 'Even'
    WHEN (balls, strikes) IN ((0,1),(0,2),(1,2))                         THEN 'Pitcher ahead'
    WHEN (balls, strikes) IN ((1,0),(2,0),(3,0),(2,1),(3,1))             THEN 'Hitter ahead'
  END AS count_leverage,

  -- park. only the A's are in a temp home in 2026 (Rays were back at the Trop by their home opener)
  CASE
    WHEN home_team IN ('OAK','ATH') THEN 'ATH (Sacramento)'
    ELSE home_team
  END AS park,

  -- 1 mph fastball bins, 90-91 ... 101-102, then 102+
  CASE
    WHEN pitch_type IN ('FF','SI','FT','FC') AND release_speed >= 102 AND release_speed <= 105 THEN '102+'
    WHEN pitch_type IN ('FF','SI','FT','FC') AND release_speed >= 90  AND release_speed < 102
      THEN CONCAT(FLOOR(release_speed), '-', FLOOR(release_speed) + 1)
  END AS fb_velo_bin,

  CASE
    WHEN hit_coord_x IS NULL OR hit_coord_y IS NULL THEN NULL
    WHEN bat_side = 'L' THEN -DEGREES(ATAN((hit_coord_x - 125.42) / (198.27 - hit_coord_y))) * 0.75
    ELSE                      DEGREES(ATAN((hit_coord_x - 125.42) / (198.27 - hit_coord_y))) * 0.75
  END AS spray_adj,

  CASE
    WHEN launch_speed >= 95  AND launch_speed < 100 THEN '95-100'
    WHEN launch_speed >= 100 AND launch_speed < 105 THEN '100-105'
    WHEN launch_speed >= 105 AND launch_speed < 110 THEN '105-110'
    WHEN launch_speed >= 110 AND launch_speed <= 120 THEN '110-120'
  END AS ev_bin
FROM fb_hr f;


-- league baseline, every other view carries this so R can draw the avg line
CREATE OR REPLACE VIEW hrfb_league AS
SELECT SUM(is_hr) AS hr, SUM(is_ld_hr) AS ld_hr, SUM(is_fb) AS fb,
       SUM(is_hr) / SUM(is_fb) AS hr_fb
FROM fb_hr_clean;

SELECT * FROM hrfb_league;


-- by zone (1-9 in the zone, 11-14 outside)
-- all HRs in the zone / all fly balls in the zone
CREATE OR REPLACE VIEW hrfb_by_zone AS
SELECT zone,
       SUM(is_hr) AS hr, SUM(is_ld_hr) AS ld_hr, SUM(is_fb) AS fb,
       SUM(is_hr) / NULLIF(SUM(is_fb), 0) AS hr_fb
FROM fb_hr_clean
WHERE zone IN (1,2,3,4,5,6,7,8,9,11,12,13,14)
GROUP BY zone;


-- by individual pitch type, misfit pitches dropped
-- all HRs off the pitch / all fly balls off the pitch
CREATE OR REPLACE VIEW hrfb_by_pitch_type AS
SELECT pt AS pitch_type, pitch_class,
       SUM(is_hr) AS hr, SUM(is_ld_hr) AS ld_hr, SUM(is_fb) AS fb,
       SUM(is_hr) / NULLIF(SUM(is_fb), 0) AS hr_fb,
       (SELECT hr_fb FROM hrfb_league) AS league_hr_fb
FROM fb_hr_clean
WHERE pitch_class IS NOT NULL
GROUP BY pt, pitch_class;


-- by pitch class
CREATE OR REPLACE VIEW hrfb_by_pitch_class AS
SELECT pitch_class,
       SUM(is_hr) AS hr, SUM(is_ld_hr) AS ld_hr, SUM(is_fb) AS fb,
       SUM(is_hr) / NULLIF(SUM(is_fb), 0) AS hr_fb,
       (SELECT hr_fb FROM hrfb_league) AS league_hr_fb
FROM fb_hr_clean
WHERE pitch_class IS NOT NULL
GROUP BY pitch_class;


-- by count + leverage bucket
-- all HRs in the count / all fly balls in the count
CREATE OR REPLACE VIEW hrfb_by_count AS
SELECT count_str, balls, strikes, count_leverage,
       SUM(is_hr) AS hr, SUM(is_ld_hr) AS ld_hr, SUM(is_fb) AS fb,
       SUM(is_hr) / NULLIF(SUM(is_fb), 0) AS hr_fb,
       (SELECT hr_fb FROM hrfb_league) AS league_hr_fb
FROM fb_hr_clean
WHERE balls BETWEEN 0 AND 3 AND strikes BETWEEN 0 AND 2
GROUP BY count_str, balls, strikes, count_leverage;

CREATE OR REPLACE VIEW hrfb_by_leverage AS
SELECT count_leverage,
       SUM(is_hr) AS hr, SUM(is_ld_hr) AS ld_hr, SUM(is_fb) AS fb,
       SUM(is_hr) / NULLIF(SUM(is_fb), 0) AS hr_fb,
       (SELECT hr_fb FROM hrfb_league) AS league_hr_fb
FROM fb_hr_clean
WHERE count_leverage IS NOT NULL
GROUP BY count_leverage;


-- by fastball velo bin
CREATE OR REPLACE VIEW hrfb_by_fb_velo AS
SELECT fb_velo_bin,
       MIN(FLOOR(release_speed)) AS bin_order,
       SUM(is_hr) AS hr, SUM(is_ld_hr) AS ld_hr, SUM(is_fb) AS fb,
       SUM(is_hr) / NULLIF(SUM(is_fb), 0) AS hr_fb,
       (SELECT hr_fb FROM hrfb_league) AS league_hr_fb
FROM fb_hr_clean
WHERE fb_velo_bin IS NOT NULL
GROUP BY fb_velo_bin;


-- by park
CREATE OR REPLACE VIEW hrfb_by_park AS
SELECT park,
       SUM(is_hr) AS hr, SUM(is_ld_hr) AS ld_hr, SUM(is_fb) AS fb,
       SUM(is_hr) / NULLIF(SUM(is_fb), 0) AS hr_fb,
       (SELECT hr_fb FROM hrfb_league) AS league_hr_fb
FROM fb_hr_clean
GROUP BY park;


-- by spray direction (negative = pull after the lefty flip)
CREATE OR REPLACE VIEW hrfb_by_spray AS
SELECT
  CASE WHEN spray_adj <= -15 THEN 'Pull'
       WHEN spray_adj >=  15 THEN 'Oppo'
       ELSE 'Straight' END AS spray_dir,
  SUM(is_hr) AS hr, SUM(is_ld_hr) AS ld_hr, SUM(is_fb) AS fb,
  SUM(is_hr) / NULLIF(SUM(is_fb), 0) AS hr_fb,
  (SELECT hr_fb FROM hrfb_league) AS league_hr_fb
FROM fb_hr_clean
WHERE spray_adj IS NOT NULL
GROUP BY spray_dir;


-- by exit velo bin
-- all HRs in the EV bin / all fly balls in the EV bin
CREATE OR REPLACE VIEW hrfb_by_ev AS
SELECT ev_bin,
       MIN(launch_speed) AS bin_order,
       SUM(is_hr) AS hr, SUM(is_ld_hr) AS ld_hr, SUM(is_fb) AS fb,
       SUM(is_hr) / NULLIF(SUM(is_fb), 0) AS hr_fb,
       (SELECT hr_fb FROM hrfb_league) AS league_hr_fb
FROM fb_hr_clean
WHERE ev_bin IS NOT NULL
GROUP BY ev_bin;


-- sanity check on the EV bins: HRs split by batted ball type
-- if hr > fb in a bin, the line_drive rows are why
SELECT ev_bin, bb_type,
       SUM(is_hr) AS hr,
       SUM(is_fb) AS fb
FROM fb_hr_clean
WHERE ev_bin IS NOT NULL
GROUP BY ev_bin, bb_type
ORDER BY MIN(launch_speed), bb_type;


-- quick peeks
SELECT * FROM hrfb_by_zone ORDER BY zone;
SELECT * FROM hrfb_by_pitch_type ORDER BY hr_fb DESC;
SELECT * FROM hrfb_by_park ORDER BY hr_fb DESC;
SELECT * FROM hrfb_by_ev ORDER BY bin_order;