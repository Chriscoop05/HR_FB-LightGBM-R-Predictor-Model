# What Drives HR/FB%? A 2026 Statcast Breakdown

An exploration of home-run-per-fly-ball rate (HR/FB%) across the 2026 MLB season, built on a local MySQL Statcast database and analyzed in R and Python. The project has two parts:

1. **League-wide splits.** HR/FB% broken down by zone, pitch type, pitch class, count, count leverage, fastball velocity, ballpark, spray direction and exit velocity, with a visual for each.
2. **Pitcher-level model.** A LightGBM regression that tries to predict each pitcher's 2026 HR/FB% from six contact and context features, interpreted with SHAP values.

---

## Data

- **Source:** Baseball Savant Statcast pitch-level data for the 2026 season, loaded into a local MySQL 8.4 database (`sc_2026`).
- **Scope:** every batted ball that was a fly ball (`bb_type = 'fly_ball'`) or a home run (`events = 'home_run'`).
- **Special and neutral-site games removed (league splits only).** None of these games count in the split tables:

| Date(s) | Listed home team | Venue |
|---|---|---|
| Apr 25–26 | SD | Mexico City (vs. AZ) |
| Jun 8–10 | ATH | Las Vegas (vs. MIL) |
| Jun 12–14 | ATH | Las Vegas (vs. COL) |
| Aug 13 | MIN | Field of Dreams (vs. PHI) |
| Aug 23 | MIL | Little League Classic (vs. ATL) |

The A's regular 2026 home games are labeled **ATH (Sacramento)**. The pitcher model keeps every game and tags the Las Vegas games as their own venue.

---

## HR/FB% definition

```
HR/FB% = all home runs in the split / all fly balls in the split
```

The numerator counts **every** home run in that bin, including line-drive home runs. Examples:
- 0-1 count: HRs on 0-1 pitches / FBs on 0-1 pitches
- Zone 5: HRs in zone 5 / FBs in zone 5
- 105–110 mph: HRs hit 105–110 / FBs hit 105–110

Because line-drive home runs are in the numerator but not the denominator, a split with lots of hard line drives can go **above 100%**. The top exit-velocity bin (110–120 mph) is the main example. Each split table includes an `ld_hr` column so you can see how many line-drive HRs are in each bin.

---

## League splits

| Split | Bins |
|---|---|
| Zone | Statcast zones 1–9 (strike zone) and 11–14 (shadow), catcher's view |
| Pitch type | Individual Statcast pitch codes |
| Pitch class | **Fastball** (FF, SI, FT, FC) · **Breaking** (SL, ST, SV, CU, KC) · **Offspeed** (CH, FS, FO, SC) |
| Count | All 12 ball-strike counts |
| Count leverage | **Even** (0-0, 1-1, 2-2) · **Pitcher ahead** (0-1, 0-2, 1-2) · **Hitter ahead** (1-0, 2-0, 3-0, 2-1, 3-1) · **Full** (3-2) |
| Fastball velo | 1-mph bins from 90–91 to 101–102, plus 102+ |
| Park | Home venue (special games excluded) |
| Spray | **Pull** (≤ −15°) · **Straight** · **Oppo** (≥ 15°), flipped for left-handed hitters |
| Exit velocity | 95–100, 100–105, 105–110, 110–120 mph |

Spray angle is estimated from Statcast hit coordinates:

```
spray = atan((hc_x - 125.42) / (198.27 - hc_y)) * (180 / pi) * 0.75
```

### Visuals (`hrfb_visuals_2026.R`)
- **Zone:** shaded strike-zone grid with the HR/FB% printed in each zone
- **Park:** `gt` table ranking every park by HR/FB%, with team logos from `mlbplotR`
- **Count:** 4 × 3 grid (balls × strikes)
- **Pitch type:** bar chart using Baseball Savant's pitch colors
- **Pitch class, leverage, spray:** bar charts
- **Fastball velo, exit velo:** line charts in increasing bin order

---

## Pitcher model

### Sample
Pitchers who allowed **at least 100 fly balls in 2026** (`WHERE fb >= 100`), which leaves **91 pitchers**, almost all full-time starters. The cutoff exists because individual HR/FB% is very noisy at small samples. At a ~11% league rate, binomial noise alone is about ±3.1 points (1 SD) for a pitcher with 100 fly balls.

### Features (one row per pitcher, computed on fly balls)

| # | Feature | Description |
|---|---|---|
| 1 | `med_fb_ev` | Median fly-ball exit velocity |
| 2 | `fb_batter_ahead_pct` | Share of fly balls allowed with the hitter ahead in the count |
| 3 | `fb_in_zone_pct` | Share of fly balls on pitches in the zone (1–9) |
| 4 | `fb_top10_park_pct` | Share of fly balls allowed in the 10 highest HR/FB parks: ATH (Las Vegas), WSH, PHI, CHC, NYY, HOU, SEA, TB, CIN, SD |
| 5 | `fb_target_pitch_pct` | Share of fly balls on KC, SL, FO, FC, CU or FS |
| 6 | `fb_pull_pct` | Share of fly balls that were pulled |

**Target:** pitcher HR/FB% (all HRs / all FBs).

### Method
- LightGBM regression, kept small for a 91-row dataset: `num_leaves = 7`, `max_depth = 3`, `min_data_in_leaf = 15`
- Number of rounds chosen with 5-fold `lgb.cv` (up to 2,000 rounds, early stopping at 50)
- Performance judged on **out-of-fold predictions**, so every pitcher is scored by a model that never saw him
- Final model fit on all 91 pitchers for feature importance and SHAP values

### Results

| Metric | Value |
|---|---|
| RMSE (model) | 0.0293 |
| RMSE (baseline: predict league mean) | 0.0340 |
| Out-of-fold R² | 0.259 |
| Correlation (predicted vs. actual) | 0.50 |

The model beats a league-average guess by about 14% in RMSE. That's a real but modest signal, not a strong predictive model. The RMSE of 2.9 points is already below the ~3.1 points of pure sampling noise expected at 100 fly balls, so most of what's left over is likely luck no pitcher-level feature can capture.

### Caveats
- **Feature 4 leaks.** The top-10 parks were chosen from 2026 HR/FB% itself, so part of that feature's value comes from the target.
- **Feature 1 overlaps the target.** Harder fly balls are home runs more often almost by definition, so median fly-ball EV partly describes the outcome rather than predicting it.
- **Small sample.** With 91 rows, one train/test split can shift R² noticeably. Results should be checked over repeated seeds before trusting any single feature's ranking.
- **One season.** No test on how well 2026 features predict 2027 HR/FB%.

---

## Repository structure

```
├── sql/
│   ├── hrfb_explore_2026.sql  # special-games table, cleaned view, all league split views
│   └── hrfb_pitcher_features_2026.sql   # pitcher-level feature view for the model
├── R/
│   ├── hrfb_visuals_2026.R   # charts and park table
│   └── hrfb_lightgbm_2026.R    # LightGBM model, CV, SHAP
└── README.md
```

---

## How to run

**1. Database.** Load 2026 Statcast data into a MySQL table named `sc_2026`, then run the two SQL files in order:

```
sql/hrfb_explore_2026.sql
sql/hrfb_pitcher_features_2026.sql
```

**2. Credentials.** The R and Python scripts read connection details from environment variables, never from the code. Copy `.Renviron.example` to `.Renviron` in the project root and fill in your own values:

```
DB_NAME=
DB_HOST=
DB_PORT=
DB_USER=
DB_PWD=
```

Keep a blank line at the end of the file, then restart R. `.Renviron` is listed in `.gitignore` and should never be committed.

**3. R packages.**

```r
install.packages(c("DBI", "RMariaDB", "tidyverse", "gt", "mlbplotR", "lightgbm"))
```

**4. Python packages.**

```
pip install pandas sqlalchemy pymysql
```

**5. Run** `R/hrfb_visuals_2026.R` for the charts and `R/hrfb_lightgbm_2026.R` for the model.

---



