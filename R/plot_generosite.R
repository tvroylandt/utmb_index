# Quelles courses donnent les meilleurs index UTMB, à performance égale ?
#
# Trois façons de contrôler la performance :
#   A. à vitesse égale (allure en km-effort, par catégorie et par sexe) ;
#   B. à coureur égal (mêmes coureurs sur plusieurs courses, effets fixes) ;
#   C. à classement égal (index du coureur médian, du top 10 %…).
#
# Usage : Rscript R/plot_generosite.R   (depuis la racine du projet)

library(arrow)
library(dplyr)
library(tidyr)
library(ggplot2)
library(ggrepel)
library(forcats)
library(mgcv)
library(patchwork)
library(scales)

dir.create("outputs", showWarnings = FALSE)
MIN_FINISHERS <- 100   # finishers par course (toutes éditions) pour la retenir
MIN_RUNNERS_FE <- 40   # coureurs communs pour l'analyse à coureur égal

# ---- Données ---------------------------------------------------------------

courses <- read_parquet("data/courses.parquet") |>
  filter(has_results, !is_relay, !is_multi_stage,
         distance_km > 0, elevation_gain_m > 0) |>
  mutate(km_effort = distance_km + elevation_gain_m / 100,
         category = coalesce(category, "<20k"),
         category = factor(category, c("<20k", "20k", "50k", "100k", "100m")),
         level = factor(level, c("qualifier", "serie", "major", "finale")))

res <- read_parquet("data/resultats.parquet",
                    col_select = c(course_uid, runner_id, rank, time_s,
                                   is_finisher, gender, index)) |>
  filter(is_finisher, index > 0, !is.na(gender), time_s > 0) |>
  inner_join(select(courses, course_uid, event_id, race_id, year, event_name,
                    race_name, category, level, nb_stones, distance_km,
                    elevation_gain_m, km_effort),
             by = "course_uid") |>
  add_count(course_uid, name = "n_fin") |>
  mutate(vitesse_effort = km_effort / (time_s / 3600),     # km-effort / h
         pct = percent_rank(rank) , .by = course_uid) |>
  mutate(race_key = paste(event_id, race_id, sep = "-"))

# Courses (toutes éditions) assez fournies
courses_ok <- res |>
  summarise(n = n(), .by = race_key) |>
  filter(n >= MIN_FINISHERS)
res <- semi_join(res, courses_ok, by = "race_key")

noms <- res |>
  slice_max(year, n = 1, with_ties = FALSE, by = race_key) |>
  transmute(race_key, event_name, race_name, category, level, nb_stones,
            label = if_else(event_name == race_name | stringr::str_detect(race_name, stringr::fixed(event_name)),
                            race_name, paste0(event_name, " – ", race_name)) |> strtrim(48))

message(nrow(res), " résultats, ", n_distinct(res$race_key), " courses")

theme_set(theme_minimal(base_size = 12) +
            theme(plot.title.position = "plot", panel.grid.minor = element_blank()))
pal_level <- c(qualifier = "grey60", serie = "#4E79A7", major = "#E15759", finale = "#F28E2B")

# ---- A. À vitesse égale : résidu d'un GAM index ~ vitesse ------------------
# Un GAM par catégorie et sexe, sur un échantillon, puis prédiction partout.

set.seed(1)
ech <- res |> slice_sample(n = 400000)
ech <- ech |> mutate(grp = interaction(category, gender, drop = TRUE))
modeles <- ech |>
  group_split(grp) |>
  lapply(function(d) bam(index ~ s(log(vitesse_effort), k = 8), data = d))
names(modeles) <- levels(ech$grp)

res <- res |>
  mutate(grp = as.character(interaction(category, gender))) |>
  group_split(grp) |>
  lapply(function(d) {
    m <- modeles[[unique(d$grp)]]
    d$index_attendu <- as.numeric(predict(m, newdata = d))
    d
  }) |>
  bind_rows() |>
  mutate(residu = index - index_attendu)

effet_A <- res |>
  summarise(gain_index = mean(residu), se = sd(residu) / sqrt(n()), n = n(),
            .by = race_key) |>
  left_join(noms, by = "race_key")

# ---- B. À coureur égal : effets fixes coureur + course ----------------------
# index_ij = a_i + b_j. Résolu par projections alternées (pas de fixest ici).
# On garde les coureurs vus sur >= 2 courses ; on ne compare qu'au sein d'une
# même catégorie (un 20 km ne se compare pas à un 100 miles du même coureur).

fe_categorie <- function(d, iter = 60) {
  d <- d |> filter(!is.na(runner_id)) |>
    add_count(runner_id, name = "k") |> filter(k >= 2)
  d$b <- 0
  for (i in seq_len(iter)) {
    d <- d |> mutate(a = mean(index - b), .by = runner_id) |>
      mutate(b = mean(index - a), .by = race_key)
  }
  d |> summarise(effet = mean(b), n_comm = n(), sd_res = sd(index - a - b),
                 .by = race_key) |>
    mutate(se = sd_res / sqrt(n_comm))
}

effet_B <- res |>
  group_split(category) |>
  lapply(function(d) fe_categorie(d) |> mutate(category = d$category[1])) |>
  bind_rows() |>
  filter(n_comm >= MIN_RUNNERS_FE) |>
  group_by(category) |>
  mutate(gain_index_fe = effet - weighted.mean(effet, n_comm)) |>   # 0 = course moyenne
  ungroup() |>
  slice_max(n_comm, n = 1, with_ties = FALSE, by = race_key) |>   # catégorie qui change d'une année à l'autre
  select(-category) |>
  left_join(noms, by = "race_key")

# ---- C. À classement égal : index à percentile donné ------------------------

pct_index <- res |>
  filter(n_fin >= 50) |>
  mutate(tranche = case_when(pct <= .10 ~ "Top 10 %",
                             pct >= .45 & pct <= .55 ~ "Médian (45-55 %)",
                             TRUE ~ NA_character_)) |>
  filter(!is.na(tranche)) |>
  summarise(index_moy = mean(index), .by = c(race_key, tranche)) |>
  left_join(noms, by = "race_key")

# ---- Graphiques -------------------------------------------------------------

lollipop <- function(d, x, titre, sous, n = 8, par_categorie = TRUE) {
  d <- filter(d, !is.na(category))
  top <- if (par_categorie) {
    bind_rows(slice_max(d, {{ x }}, n = n, by = category), slice_min(d, {{ x }}, n = n, by = category))
  } else {
    bind_rows(slice_max(d, {{ x }}, n = n), slice_min(d, {{ x }}, n = n))
  }
  top <- top |> mutate(label = tidytext_reorder(label, {{ x }}, category))
  ggplot(top, aes(y = label, x = {{ x }}, colour = level)) +
    geom_vline(xintercept = 0, colour = "grey40") +
    geom_segment(aes(x = 0, xend = {{ x }}, yend = label), linewidth = .6) +
    geom_point(size = 2.4) +
    scale_y_discrete(labels = \(l) sub("___.*$", "", l)) +
    scale_colour_manual(values = pal_level, drop = FALSE) +
    labs(title = titre, subtitle = sous, x = "Points d'index vs. attendu", y = NULL, colour = "Niveau") +
    if (par_categorie) facet_wrap(~category, scales = "free_y", ncol = 2)
}
# ordre dans chaque facette (sans dépendre de tidytext)
tidytext_reorder <- function(label, x, cat) {
  key <- paste(label, cat, sep = "___")
  factor(key, levels = unique(key[order(x)]))
}

# 1. Relation allure -> index, par catégorie (le terrain de comparaison)
p1 <- res |> slice_sample(n = 300000) |>
  ggplot(aes(vitesse_effort, index)) +
  geom_bin2d(bins = 70) +
  geom_smooth(aes(colour = gender), method = "gam", formula = y ~ s(x, k = 8),
              se = FALSE, linewidth = 1) +
  scale_x_log10() +
  scale_fill_viridis_c(trans = "log10", option = "mako", direction = -1, guide = "none") +
  scale_colour_manual(values = c(H = "#E15759", F = "#F28E2B")) +
  facet_wrap(~category, scales = "free_x") +
  labs(title = "Index UTMB selon l'allure en km-effort",
       subtitle = "km-effort = distance + D+/100. Les courbes sont la référence « à performance égale »",
       x = "Vitesse (km-effort/h, échelle log)", y = "Index UTMB", colour = "Sexe")
ggsave("outputs/gen_1_allure_index.png", p1, width = 11, height = 7, dpi = 200, bg = "white")

# 2. Classement des courses à allure égale (A)
p2 <- effet_A |> filter(n >= 300) |>
  lollipop(gain_index, titre = "À allure égale : les courses qui donnent le plus / le moins d'index",
           sous = paste0("Écart moyen entre l'index obtenu et l'index attendu pour la même allure, catégorie et sexe. ",
                         "Courses ≥ 300 finishers."))
ggsave("outputs/gen_2_allure_egale.png", p2, width = 13, height = 10, dpi = 200, bg = "white")

# 3. À coureur égal (B)
p3 <- effet_B |>
  lollipop(gain_index_fe, titre = "Mêmes coureurs, courses différentes",
           sous = paste0("Effet course (effets fixes coureur + course), dans la même catégorie. ",
                         "Courses avec ≥ ", MIN_RUNNERS_FE, " coureurs communs avec d'autres courses."))
ggsave("outputs/gen_3_coureur_egal.png", p3, width = 13, height = 10, dpi = 200, bg = "white")

# 4. Concordance des deux méthodes
conc <- inner_join(effet_A, select(effet_B, race_key, gain_index_fe, n_comm), by = "race_key")
p4 <- ggplot(conc, aes(gain_index, gain_index_fe, colour = level, size = n_comm)) +
  geom_hline(yintercept = 0, colour = "grey70") + geom_vline(xintercept = 0, colour = "grey70") +
  geom_point(alpha = .55) +
  geom_text_repel(data = \(d) filter(d, abs(gain_index) > quantile(abs(gain_index), .995) |
                                       abs(gain_index_fe) > quantile(abs(gain_index_fe), .995)),
                  aes(label = label), size = 2.6, max.overlaps = 6, show.legend = FALSE) +
  scale_colour_manual(values = pal_level, drop = FALSE) +
  scale_size_area(max_size = 6, guide = "none") +
  facet_wrap(~category) +
  labs(title = "Les deux méthodes s'accordent-elles ?",
       subtitle = "Abscisse : à allure égale. Ordonnée : à coureur égal. Une course = un point",
       x = "Écart d'index à allure égale", y = "Effet course à coureur égal", colour = "Niveau")
ggsave("outputs/gen_4_concordance.png", p4, width = 12, height = 8, dpi = 200, bg = "white")

# 5. Effet du niveau / nombre de pierres
p5 <- effet_A |> filter(n >= 100) |>
  ggplot(aes(level, gain_index, fill = level)) +
  geom_hline(yintercept = 0, colour = "grey40") +
  geom_boxplot(outlier.alpha = .3, show.legend = FALSE) +
  scale_fill_manual(values = pal_level) +
  facet_wrap(~category, nrow = 1) +
  labs(title = "Les courses de niveau supérieur donnent-elles plus d'index ?",
       subtitle = "Écart d'index à allure égale, une course = un point",
       x = NULL, y = "Points d'index vs. attendu") +
  theme(axis.text.x = element_text(angle = 30, hjust = 1))
ggsave("outputs/gen_5_niveau.png", p5, width = 11, height = 5, dpi = 200, bg = "white")

# 6. À classement égal : médian vs top 10 %
p6 <- pct_index |>
  pivot_wider(names_from = tranche, values_from = index_moy) |>
  filter(!is.na(`Top 10 %`), !is.na(`Médian (45-55 %)`)) |>
  ggplot(aes(`Médian (45-55 %)`, `Top 10 %`, colour = level)) +
  geom_point(alpha = .4, size = 1) +
  geom_text_repel(data = \(d) filter(d, `Médian (45-55 %)` > quantile(`Médian (45-55 %)`, .995) |
                                       `Médian (45-55 %)` < quantile(`Médian (45-55 %)`, .005)),
                  aes(label = label), size = 2.8, show.legend = FALSE, max.overlaps = 20) +
  scale_colour_manual(values = pal_level, drop = FALSE) +
  guides(colour = guide_legend(override.aes = list(alpha = 1, size = 3))) +
  facet_wrap(~category) +
  labs(title = "Index à classement égal : coureur médian vs top 10 %",
       subtitle = "Index moyen du coureur médian et du top 10 % de chaque course (≥ 50 finishers)",
       x = "Index moyen du coureur médian", y = "Index moyen du top 10 %", colour = "Niveau")
ggsave("outputs/gen_6_classement.png", p6, width = 12, height = 8, dpi = 200, bg = "white")

# 7. Les courses « à enjeu » (Série, Major, Finale), à allure égale
p7 <- effet_A |> filter(level %in% c("serie", "major", "finale"), n >= 300) |>
  mutate(label = fct_reorder(label, gain_index)) |>
  ggplot(aes(gain_index, label, colour = level)) +
  geom_vline(xintercept = 0, colour = "grey40") +
  geom_pointrange(aes(xmin = gain_index - 2 * se, xmax = gain_index + 2 * se), size = .3) +
  scale_colour_manual(values = pal_level) +
  facet_wrap(~category, scales = "free_y", ncol = 2) +
  labs(title = "Courses Série / Major / Finale : index à allure égale",
       subtitle = "Écart moyen à l'index attendu (± 2 erreurs-types), courses ≥ 300 finishers",
       x = "Points d'index vs. attendu", y = NULL, colour = "Niveau")
ggsave("outputs/gen_7_series_majors.png", p7, width = 13, height = 12, dpi = 200, bg = "white")

readr::write_csv(effet_A |> arrange(desc(gain_index)), "outputs/generosite_allure_egale.csv")
readr::write_csv(effet_B |> arrange(desc(gain_index_fe)), "outputs/generosite_coureur_egal.csv")
message("OK")
