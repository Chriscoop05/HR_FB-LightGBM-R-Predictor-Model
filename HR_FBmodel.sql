-- Pitcher-level features for the 2026 HR/FB LightGBM model
-- one row per pitcher, target = all HRs allowed / all fly balls allowed
-- every feature (besides median EV) is a share of the pitcher's fly balls allowed
-- run hrfb_explore_2026.sql first

USE statcast;


-- fly balls + HRs with pitcher_id. keeping ALL games here (special games too),
-- the venue column below handles where they were played
DROP TABLE IF EXISTS fb_hr_p;

CREATE TABLE fb_hr_p AS
SELECT pitcher_id, game_date, home_team, bat_side, pitch_type, zone, balls, strikes,
       launch_speed, hit_coord_x, hit_coord_y, bb_type, events
FROM sc_2026
WHERE (bb_type = 'fly_ball' OR events = 'home_run')
  AND pitcher_id IS NOT NULL;

CREATE INDEX idx_fbhrp_pitcher ON fb_hr_p (pitcher_id);


-- tag each row with venue + the flags we need
-- A's home games on the special_games dates = Las Vegas, other special games = neutral site
CREATE OR REPLACE VIEW fb_hr_p_tagged AS
SELECT
  f.*,
  (f.bb_type = 'fly_ball') AS is_fb,
  (f.events  = 'home_run') AS is_hr,
  CASE
    WHEN s.game_date IS NOT NULL AND f.home_team IN ('ATH','OAK') THEN 'ATH_VEGAS'
    WHEN s.game_date IS NOT NULL                                  THEN 'NEUTRAL'
    ELSE f.home_team
  END AS venue,
  -- batter ahead: 1-0, 2-0, 3-0, 2-1, 3-1
  ((f.balls, f.strikes) IN ((1,0),(2,0),(3,0),(2,1),(3,1))) AS batter_ahead,
  (f.zone BETWEEN 1 AND 9) AS in_zone,
  (f.pitch_type IN ('KC','SL','FO','FC','CU','FS')) AS target_pitch,
  -- pull = spray <= -15 after flipping lefties
  CASE
    WHEN f.hit_coord_x IS NULL OR f.hit_coord_y IS NULL THEN NULL
    WHEN f.bat_side = 'L' THEN -DEGREES(ATAN((f.hit_coord_x - 125.42) / (198.27 - f.hit_coord_y))) * 0.75 <= -15
    ELSE                        DEGREES(ATAN((f.hit_coord_x - 125.42) / (198.27 - f.hit_coord_y))) * 0.75 <= -15
  END AS is_pull
FROM fb_hr_p f
LEFT JOIN special_games s
  ON f.game_date = s.game_date AND f.home_team = s.home_team;


-- the feature table
CREATE OR REPLACE VIEW pitcher_hrfb_features_2026 AS
WITH fb_ev AS (   -- median fly ball EV, MySQL has no MEDIAN() so do it w/ row numbers
  SELECT pitcher_id, launch_speed,
         ROW_NUMBER() OVER (PARTITION BY pitcher_id ORDER BY launch_speed) AS rn,
         COUNT(*)     OVER (PARTITION BY pitcher_id)                       AS n
  FROM fb_hr_p_tagged
  WHERE is_fb AND launch_speed IS NOT NULL
),
med AS (
  SELECT pitcher_id, AVG(launch_speed) AS med_fb_ev
  FROM fb_ev
  WHERE rn IN (FLOOR((n + 1) / 2), CEIL((n + 1) / 2))   -- middle row (or avg of the 2 middle rows)
  GROUP BY pitcher_id
),
agg AS (
  SELECT
    pitcher_id,
    SUM(is_fb) AS fb,
    SUM(is_hr) AS hr,
    SUM(is_hr) / NULLIF(SUM(is_fb), 0) AS hr_fb,
    SUM(is_fb AND batter_ahead) / NULLIF(SUM(is_fb), 0) AS fb_batter_ahead_pct,
    SUM(is_fb AND in_zone)      / NULLIF(SUM(is_fb), 0) AS fb_in_zone_pct,
    SUM(is_fb AND venue IN ('ATH_VEGAS','WSH','PHI','CHC','NYY','HOU','SEA','TB','CIN','SD'))
                                / NULLIF(SUM(is_fb), 0) AS fb_top10_park_pct,
    SUM(is_fb AND target_pitch) / NULLIF(SUM(is_fb), 0) AS fb_target_pitch_pct,
    -- pull share only over fly balls that have hit coords
    SUM(is_fb AND is_pull)      / NULLIF(SUM(is_fb AND is_pull IS NOT NULL), 0) AS fb_pull_pct
  FROM fb_hr_p_tagged
  GROUP BY pitcher_id
)
SELECT a.*, m.med_fb_ev
FROM agg a
LEFT JOIN med m ON m.pitcher_id = a.pitcher_id
WHERE a.fb >= 100;   -- same 100 FB floor as the earlier pitcher model


-- quick peek
SELECT COUNT(*) AS pitchers FROM pitcher_hrfb_features_2026;
SELECT * FROM pitcher_hrfb_features_2026 ORDER BY hr_fb DESC LIMIT 15;