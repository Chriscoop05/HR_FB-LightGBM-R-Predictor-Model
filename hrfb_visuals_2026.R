library(DBI)
library(tidyverse)
library(gt)
library(mlbplotR)   



# connection details come from .Renviron (git-ignored), never hardcoded
con = dbConnect(
  RMariaDB::MariaDB(),
  dbname   = Sys.getenv("DB_NAME"),
  host     = Sys.getenv("DB_HOST"),
  port     = as.integer(Sys.getenv("DB_PORT")),
  user     = Sys.getenv("DB_USER"),
  password = Sys.getenv("DB_PWD")
)

# shared look: centered titles, nothing under the plot
theme_hrfb = theme_classic(base_size = 13) +
  theme(plot.title = element_text(hjust = 0.5, face = "bold", size = 16),
        plot.subtitle = element_text(hjust = 0.5, color = "grey30"),
        plot.caption  = element_blank())



# Strike zone, Gameday zones 1-14 shaded by HR/FB (catcher's view)

dbGetQuery(con, "SELECT * FROM hrfb_by_zone;") |>
  mutate(across(everything(), as.numeric)) |>
  left_join(
    tribble(
      ~zone, ~xmin,  ~xmax, ~ymin, ~ymax, ~lx,   ~ly,
      11,    -1.25,  0,     2.25,  3.5,   -1.0,  3.3,
      12,     0,     1.25,  2.25,  3.5,    1.0,  3.3,
      13,    -1.25,  0,     1.0,   2.25,  -1.0,  1.2,
      14,     0,     1.25,  1.0,   2.25,   1.0,  1.2,
      1,     -0.75, -0.25,  2.5,   3.0,   -0.5,  2.75,
      2,     -0.25,  0.25,  2.5,   3.0,    0,    2.75,
      3,      0.25,  0.75,  2.5,   3.0,    0.5,  2.75,
      4,     -0.75, -0.25,  2.0,   2.5,   -0.5,  2.25,
      5,     -0.25,  0.25,  2.0,   2.5,    0,    2.25,
      6,      0.25,  0.75,  2.0,   2.5,    0.5,  2.25,
      7,     -0.75, -0.25,  1.5,   2.0,   -0.5,  1.75,
      8,     -0.25,  0.25,  1.5,   2.0,    0,    1.75,
      9,      0.25,  0.75,  1.5,   2.0,    0.5,  1.75
    ),
    by = "zone"
  ) |>
  arrange(desc(zone > 9)) |>   # outer quadrants first so the 3x3 draws on top
  ggplot() +
  geom_rect(aes(xmin = xmin, xmax = xmax, ymin = ymin, ymax = ymax, fill = hr_fb),
            color = "black", linewidth = 0.6) +
  # thick outline around the actual strike zone
  annotate("rect", xmin = -0.75, xmax = 0.75, ymin = 1.5, ymax = 3.0,
           fill = NA, color = "black", linewidth = 1.6) +
  # home plate, catcher's view
  annotate("polygon",
           x = c(-0.708, 0.708, 0.708, 0, -0.708),
           y = c(0.55, 0.55, 0.45, 0.3, 0.45),
           fill = "white", color = "black", linewidth = 0.8) +
  geom_text(aes(lx, ly, label = paste0(zone, "\n", scales::percent(hr_fb, accuracy = 0.1))),
            size = 3.8, fontface = "bold", lineheight = 0.9) +
  scale_fill_distiller(palette = "YlOrRd", direction = 1, labels = scales::percent) +
  coord_fixed(xlim = c(-1.4, 1.4), ylim = c(0.25, 3.6)) +
  labs(title = "2026 HR/FB% by Gameday Zone",
       subtitle = "catcher's view · zones 11-14 are outside the zone",
       fill = "HR/FB") +
  theme_void(base_size = 13) +
  theme(plot.title    = element_text(hjust = 0.5, face = "bold", size = 16),
        plot.subtitle = element_text(hjust = 0.5, color = "grey30"),
        legend.position = "right")

ggsave("charts/01_zone.png", width = 6, height = 6.5, dpi = 150)



#Park table with team logos 

dbGetQuery(con, "SELECT * FROM hrfb_by_park;") |>
  mutate(across(c(hr, fb, hr_fb, league_hr_fb), as.numeric),
         team = clean_team_abbrs(str_extract(park, "^[A-Z]+"))) |>
  arrange(desc(hr_fb)) |>
  mutate(rank = row_number(),
         vs_lg = hr_fb - league_hr_fb) |>
  select(rank, team, park, fb, hr, hr_fb, vs_lg) |>
  gt() |>
  gt_fmt_mlb_logo(columns = "team") |>
  fmt_number(columns = c(fb, hr), decimals = 0) |>
  fmt_percent(columns = hr_fb, decimals = 1) |>
  fmt_percent(columns = vs_lg, decimals = 1, force_sign = TRUE) |>
  data_color(columns = hr_fb, palette = c("#1D2D5C", "white", "#C8102E")) |>
  cols_label(rank = "Rk", team = "", park = "Park", fb = "FB", hr = "HR",
             hr_fb = "HR/FB", vs_lg = "vs Lg") |>
  cols_align(align = "center", columns = everything()) |>
  tab_header(title = md("**2026 HR/FB% by Ballpark**"),
             subtitle = "neutral-site & special games removed") |>
  opt_align_table_header(align = "center") |>
  tab_options(table.font.size = px(12), data_row.padding = px(2),
              heading.title.font.size = px(18)) |>
  print()



#Count grid: balls across, strikes down (4 x 3)
dbGetQuery(con, "SELECT * FROM hrfb_by_count;") |>
  mutate(across(c(balls, strikes, hr, fb, hr_fb), as.numeric)) |>
  ggplot(aes(factor(balls), factor(strikes, levels = 2:0), fill = hr_fb)) +
  geom_tile(color = "white", linewidth = 1.5) +
  geom_text(aes(label = paste0(balls, "-", strikes, "\n",
                               scales::percent(hr_fb, accuracy = 0.1), "\n",
                               "FBs=", scales::comma(fb))),
            size = 3.6, lineheight = 0.9, fontface = "bold") +
  scale_fill_distiller(palette = "YlOrRd", direction = 1, labels = scales::percent) +
  coord_fixed() +
  labs(title = "2026 HR/FB% by Count",
       x = "Balls", y = "Strikes", fill = "HR/FB") +
  theme_hrfb +
  theme(axis.line = element_blank(), axis.ticks = element_blank())

ggsave("charts/02_count_grid.png", width = 7, height = 5, dpi = 150)



#Pitch type columns
dbGetQuery(con, "SELECT * FROM hrfb_by_pitch_type;") |>
  mutate(across(c(hr, fb, hr_fb, league_hr_fb), as.numeric),
         se = sqrt(hr_fb * (1 - hr_fb) / fb)) |>
  ggplot(aes(reorder(pitch_type, -hr_fb), hr_fb, fill = pitch_type)) +
  geom_col(color = "black", linewidth = 0.3) +
  geom_hline(aes(yintercept = league_hr_fb), linetype = "dashed") +
  geom_text(aes(y = 0, label = paste0("FBs=", scales::comma(fb))), vjust = -0.6, size = 2.8) +
  scale_fill_manual(values = c(
    FF = "#D22D49", SI = "#FE9D00", FC = "#933F2C",
    SL = "#EEE716", ST = "#DDB33A", SV = "#93AFD4",
    CU = "#00D1ED", KC = "#6236CD",
    CH = "#1DBE3A", FS = "#3BACAC", FO = "#55CCAB", SC = "#60DB33"
  )) +
  scale_y_continuous(labels = scales::percent, expand = expansion(mult = c(0, 0.08))) +
  labs(title = "2026 HR/FB% by Pitch Type",
       subtitle = "dashed = league avg || bars = 95% interval",
       x = NULL, y = "HR/FB%") +
  theme_hrfb +
  theme(legend.position = "none")

ggsave("charts/03_pitch_type.png", width = 8, height = 4.5, dpi = 150)



#Pitch class columns
dbGetQuery(con, "SELECT * FROM hrfb_by_pitch_class;") |>
  mutate(across(c(hr, fb, hr_fb, league_hr_fb), as.numeric),
         se = sqrt(hr_fb * (1 - hr_fb) / fb),
         pitch_class = factor(pitch_class, levels = c("Fastball", "Breaking", "Offspeed"))) |>
  ggplot(aes(pitch_class, hr_fb, fill = pitch_class)) +
  geom_col(width = 0.6) +
  geom_hline(aes(yintercept = league_hr_fb), linetype = "dashed") +
  geom_text(aes(label = scales::percent(hr_fb, accuracy = 0.1)), vjust = -1.4, fontface = "bold") +
  scale_fill_manual(values = c(Fastball = "#D22D49", Breaking = "#EEE716", Offspeed = "#1DBE3A")) +
  scale_y_continuous(labels = scales::percent, expand = expansion(mult = c(0, 0.15))) +
  labs(title = "2026 HR/FB% by Pitch Class",
       x = NULL, y = "HR/FB%") +
  theme_hrfb +
  theme(legend.position = "none")

ggsave("charts/04_pitch_class.png", width = 8, height = 4.5, dpi = 150)


#Count leverage columns

dbGetQuery(con, "SELECT * FROM hrfb_by_leverage;") |>
  mutate(across(c(hr, fb, hr_fb, league_hr_fb), as.numeric),
         se = sqrt(hr_fb * (1 - hr_fb) / fb),
         count_leverage = factor(count_leverage,
                                 levels = c("Pitcher ahead", "Even", "Hitter ahead", "Full"))) |>
  ggplot(aes(count_leverage, hr_fb, fill = count_leverage)) +
  geom_col(width = 0.6) +
  geom_hline(aes(yintercept = league_hr_fb), linetype = "dashed") +
  geom_text(aes(label = scales::percent(hr_fb, accuracy = 0.1)), vjust = -1.4, fontface = "bold") +
  scale_fill_manual(values = c("Pitcher ahead" = "#1D2D5C", "Even" = "grey60",
                               "Hitter ahead" = "#C8102E", "Full" = "#F0B323")) +
  scale_y_continuous(labels = scales::percent, expand = expansion(mult = c(0, 0.15))) +
  labs(title = "2026 HR/FB% by Count Leverage",
       x = NULL, y = "HR/FB%") +
  theme_hrfb +
  theme(legend.position = "none",
        plot.subtitle = element_text(hjust = 0.5, color = "grey30", size = 9))

ggsave("charts/05_leverage.png", width = 8, height = 4.5, dpi = 150)



#Spray direction columns
dbGetQuery(con, "SELECT * FROM hrfb_by_spray;") |>
  mutate(across(c(hr, fb, hr_fb, league_hr_fb), as.numeric),
         se = sqrt(hr_fb * (1 - hr_fb) / fb),
         spray_dir = factor(spray_dir, levels = c("Pull", "Straight", "Oppo"))) |>
  ggplot(aes(spray_dir, hr_fb, fill = spray_dir)) +
  geom_col(width = 0.6) +
  #geom_errorbar(aes(ymin = hr_fb - 1.96 * se, ymax = hr_fb + 1.96 * se), width = 0.15) +
  geom_hline(aes(yintercept = league_hr_fb), linetype = "dashed") +
  geom_text(aes(label = scales::percent(hr_fb, accuracy = 0.1)), vjust = -1.4, fontface = "bold") +
  scale_fill_manual(values = c(Pull = "#C8102E", Straight = "grey60", Oppo = "#1D2D5C")) +
  scale_y_continuous(labels = scales::percent, expand = expansion(mult = c(0, 0.15))) +
  labs(title = "2026 HR/FB% by Spray Direction",
       x = NULL, y = "HR/FB%") +
  theme_hrfb +
  theme(legend.position = "none")

ggsave("charts/06_spray.png", width = 8, height = 4.5, dpi = 150)


#Fastball velo buckets, line chart, slowest -> fastest
dbGetQuery(con, "SELECT * FROM hrfb_by_fb_velo;") |>
  mutate(across(c(bin_order, hr, fb, hr_fb, league_hr_fb), as.numeric),
         se = sqrt(hr_fb * (1 - hr_fb) / fb)) |>
  arrange(bin_order) |>
  mutate(fb_velo_bin = fct_inorder(fb_velo_bin)) |>
  ggplot(aes(fb_velo_bin, hr_fb, group = 1)) +
  geom_hline(aes(yintercept = league_hr_fb), linetype = "dashed") +
  geom_line(color = "#D22D49", linewidth = 1.2) +
  geom_point(color = "#D22D49", size = 2.5) +
  geom_text(aes(label = scales::percent(hr_fb, accuracy = 0.1)), vjust = -1, size = 3) +
  scale_y_continuous(labels = scales::percent) +
  labs(title = "2026 HR/FB% by Fastball Velocity",
       subtitle = "FF, SI, FC || dashed = league avg",
       x = "Velo", y = "HR/FB%") +
  theme_hrfb

ggsave("charts/07_fb_velo.png", width = 8, height = 4.5, dpi = 150)


#Exit velo buckets, line chart, softest -> hardest
dbGetQuery(con, "SELECT * FROM hrfb_by_ev;") |>
  mutate(across(c(bin_order, hr, fb, hr_fb, league_hr_fb), as.numeric),
         se = sqrt(hr_fb * (1 - hr_fb) / fb)) |>
  arrange(bin_order) |>
  mutate(ev_bin = fct_inorder(ev_bin)) |>
  ggplot(aes(ev_bin, hr_fb, group = 1)) +
  geom_hline(aes(yintercept = league_hr_fb), linetype = "dashed") +
  geom_line(color = "#1D2D5C", linewidth = 1.2) +
  geom_point(color = "#1D2D5C", size = 2.5) +
  geom_text(aes(label = scales::percent(hr_fb, accuracy = 0.1)), vjust = -1, size = 3.5) +
  scale_y_continuous(labels = scales::percent, expand = expansion(mult = c(0.05, 0.12))) +
  labs(title = "2026 HR/FB% by Exit Velocity",
       subtitle = "dashed = league avg",
       x = "Exit velocity (mph)", y = "HR/FB%") +
  theme_hrfb

ggsave("charts/08_ev.png", width = 8, height = 4.5, dpi = 150)

dbDisconnect(con)