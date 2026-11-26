library(DBI)
library(tidyverse)
library(lightgbm)   

# run hrfb_pitcher_features_2026.sql first

# connection details come from .Renviron (git-ignored), never hardcoded
con = dbConnect(
  RMariaDB::MariaDB(),
  dbname   = Sys.getenv("DB_NAME"),
  host     = Sys.getenv("DB_HOST"),
  port     = as.integer(Sys.getenv("DB_PORT")),
  user     = Sys.getenv("DB_USER"),
  password = Sys.getenv("DB_PWD")
)

feats = c("med_fb_ev", "fb_batter_ahead_pct", "fb_in_zone_pct",
          "fb_top10_park_pct", "fb_target_pitch_pct", "fb_pull_pct")

set.seed(26)

# one row per pitcher, names from people, random 5 folds for honest out-of-fold preds
df = dbGetQuery(con, "SELECT * FROM pitcher_hrfb_features_2026;") |>
  mutate(across(everything(), as.numeric)) |>
  left_join(people, by = c("pitcher_id" = "pitcher")) |>
  select(-name_first, -name_last) |>
  drop_na(all_of(feats), hr_fb) |>
  mutate(fold = sample(rep(1:5, length.out = n())))

dbDisconnect(con)

# how many pitchers we're working with
nrow(df)   

# small trees + regularization, we don't have a lot of rows
params = list(
  objective = "regression",
  metric= "rmse",
  learning_rate = 0.03,
  num_leaves= 7,
  max_depth = 3,
  min_data_in_leaf = 15,
  feature_fraction = 0.8,
  bagging_fraction = 0.8,
  bagging_freq = 1,
  lambda_l2 = 1,
  verbose = -1
)

# pick the number of rounds with 5-fold CV (weighted by fly balls so tiny samples count less)
best_iter = lgb.cv(
  params  = params,
  data    = lgb.Dataset(as.matrix(df[feats]), label = df$hr_fb, weight = df$fb),
  nrounds = 2000,
  nfold   = 5,
  early_stopping_rounds = 50,
  verbose = -1
)$best_iter

best_iter


# out-of-fold predictions: each pitcher predicted by a model that never saw him
df = map_dfr(1:5, \(k) {
  m = lgb.train(params,
                lgb.Dataset(as.matrix(df[df$fold != k, feats]),
                            label = df$hr_fb[df$fold != k],
                            weight = df$fb[df$fold != k]),
                nrounds = best_iter, verbose = -1)
  df |> filter(fold == k) |> mutate(oof_pred = predict(m, as.matrix(df[df$fold == k, feats])))
})

#does it beat just guessing the (weighted) league avg for everyone?
df |>
  summarise(
    rmse_model = sqrt(weighted.mean((hr_fb -oof_pred)^2, fb)),
    rmse_baseline = sqrt(weighted.mean((hr_fb - weighted.mean(hr_fb, fb))^2, fb)),
    oof_r2 = 1 - sum(fb * (hr_fb - oof_pred)^2) /
      sum(fb * (hr_fb - weighted.mean(hr_fb, fb))^2),
    cor_pred_act  = cor(hr_fb, oof_pred)
  )


# final model on everyone, for importance / SHAP
model = lgb.train(params,
                  lgb.Dataset(as.matrix(df[feats]), label = df$hr_fb, weight = df$fb),
                  nrounds = best_iter, verbose = -1)

#importance table
lgb.importance(model)


#predicted vs actual 
df |>
  ggplot(aes(hr_fb, oof_pred)) +
  geom_abline(slope = 1, intercept = 0, linetype = "dashed") +
  geom_point(aes(size = fb), alpha = 0.5, color = "#1D2D5C", show.legend = FALSE) +
  scale_x_continuous(labels = scales::percent) +
  scale_y_continuous(labels = scales::percent) +
  coord_equal() +
  labs(title = "LightGBM HR/FB%: Predicted vs Actual (2026)",
       subtitle = "out-of-fold predictions || dashed = perfect || bigger points = more fly balls",
       x = "Actual HR/FB%", y = "Predicted HR/FB%") +
  theme_classic(base_size = 13) +
  theme(plot.title = element_text(hjust = 0.5, face = "bold", size = 16),
        plot.subtitle = element_text(hjust = 0.5, color = "grey30"))

ggsave("charts/lgbm_pred_vs_actual.png", width = 7, height = 7, dpi = 150)


# SHAP feature contribution
# lightgbm 4.x: type = "contrib". on older versions use predcontrib = TRUE instead
predict(model, as.matrix(df[feats]), type = "contrib") |>
  as_tibble(.name_repair = ~ c(feats, "bias")) |>
  select(-bias) |>
  pivot_longer(everything(), names_to = "feature", values_to = "shap") |>
  group_by(feature) |>
  summarise(mean_abs_shap = mean(abs(shap))) |>
  mutate(feature = case_match(feature,
                              "med_fb_ev"~ "Median FB exit velo",
                              "fb_batter_ahead_pct" ~ "% FB w/ batter ahead",
                              "fb_in_zone_pct"~ "% FB in zone",
                              "fb_top10_park_pct"~ "% FB in top-10 HR parks",
                              "fb_target_pitch_pct" ~ "% FB off KC/SL/FO/FC/CU/FS",
                              "fb_pull_pct" ~ "% FB pulled",
                              .default = feature)) |>
  ggplot(aes(reorder(feature, mean_abs_shap), mean_abs_shap)) +
  geom_col(fill = "#C8102E") +
  coord_flip() +
  scale_y_continuous(labels = scales::percent) +
  labs(title = "What Drives the HR/FB% Predictions?",
       subtitle = "mean SHAP || avg size of each feature's push on a pitcher's prediction",
       x = NULL, y = "Mean |SHAP| (HR/FB pts)") +
  theme_classic(base_size = 13) +
  theme(plot.title = element_text(hjust = 0.5, face = "bold", size = 16),
        plot.subtitle = element_text(hjust = 0.5, color = "grey30"))

ggsave("charts/lgbm_shap_importance.png", width = 8, height = 4.5, dpi = 150)


# biggest misses, out of fold
df |>
  mutate(resid = hr_fb - oof_pred) |>
  arrange(desc(abs(resid))) |>
  select(full_name, fb, hr, hr_fb, oof_pred, resid) |>
  head(15)