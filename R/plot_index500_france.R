# En France, quelle course donne l'index 500 avec le temps le plus long par
# mètre de dénivelé ?
#
# Pour chaque course : temps médian des finishers dont l'index est entre 490 et
# 510 (≈ index 500), divisé par le D+ (h pour 1000 m D+). Plus le ratio est
# élevé, plus on peut y aller « doucement » pour décrocher 500 : la course est
# généreuse. Les éditions sont regroupées par course (event_id + race_id).
#
# Limite : seules les courses dont le pays de départ est renseigné « FR »
# sont retenues (le pays est vide pour ~40 % des courses du jeu de données).
#
# Usage : Rscript R/plot_index500_france.R [format]   (depuis la racine du projet)
#   format optionnel (<20k, 20k, 50k, 100k, 100m) : restreint l'analyse à ce format
#   et suffixe les fichiers (ex. index500_france_20k.png).

library(arrow)
library(dplyr)
library(ggplot2)
library(forcats)
library(scales)
library(ggrepel)

dir.create("outputs", showWarnings = FALSE)
CIBLE <- 500
TOLERANCE <- 10      # fenêtre d'index : 490-510
MIN_COUREURS <- 30   # finishers dans la fenêtre (toutes éditions) pour retenir la course
MIN_DPLUS <- 300     # on écarte les courses quasi plates (ratio explosif)
TOP <- 25
FORMAT <- commandArgs(trailingOnly = TRUE)[1]   # NA = tous les formats
SUFFIXE <- if (is.na(FORMAT)) "" else paste0("_", FORMAT)
SOUS_TITRE_FORMAT <- if (is.na(FORMAT)) "" else paste0(" — format ", FORMAT)

courses <- read_parquet("data/courses.parquet") |>
  filter(start_country == "FR", has_results, !is_relay, !is_multi_stage,
         distance_km > 0, elevation_gain_m >= MIN_DPLUS) |>
  mutate(category = coalesce(category, "<20k"),
         category = factor(category, c("<20k", "20k", "50k", "100k", "100m")),
         race_key = paste(event_id, race_id, sep = "-"))

res <- read_parquet("data/resultats.parquet",
                    col_select = c(course_uid, time_s, is_finisher, index)) |>
  filter(is_finisher, time_s > 0, abs(index - CIBLE) <= TOLERANCE) |>
  inner_join(courses, by = "course_uid")

noms <- courses |>
  slice_max(year, n = 1, with_ties = FALSE, by = race_key) |>
  transmute(race_key, event_name, race_name,
            label = if_else(event_name == race_name | stringr::str_detect(race_name, stringr::fixed(event_name)),
                            race_name, paste0(event_name, " – ", race_name)) |>
              tolower() |> tools::toTitleCase() |> strtrim(46))

classement <- res |>
  summarise(temps_h = median(time_s) / 3600,
            dplus = median(elevation_gain_m),
            distance = median(distance_km),
            n = n(), n_editions = n_distinct(year),
            .by = c(race_key, category)) |>
  filter(n >= MIN_COUREURS) |>
  mutate(h_par_1000m = temps_h / (dplus / 1000),
         min_par_km = temps_h * 60 / distance,
         min_par_kmeffort = temps_h * 60 / (distance + dplus / 100)) |>
  left_join(noms, by = "race_key") |>
  filter(is.na(FORMAT) | category == FORMAT)

message(nrow(classement), " courses françaises retenues")

pal_cat <- c("<20k" = "#9AA5B1", "20k" = "#4E79A7", "50k" = "#59A14F",
             "100k" = "#E15759", "100m" = "#B07AA1")

lollipop_500 <- function(d, ratio, etiquette, titre_x, rapporte_a, fichier) {
  top <- slice_max(d, {{ ratio }}, n = TOP, with_ties = FALSE) |>
    mutate(label = fct_reorder(label, {{ ratio }}), etiquette = etiquette(pick(everything())))
  p <- ggplot(top, aes({{ ratio }}, label, colour = category)) +
    geom_segment(aes(x = 0, xend = {{ ratio }}, yend = label), linewidth = .7) +
    geom_point(size = 3) +
    geom_text(aes(label = etiquette), hjust = -.15, size = 3, colour = "grey30") +
    scale_x_continuous(expand = expansion(mult = c(0, .3))) +
    scale_colour_manual(values = pal_cat, drop = TRUE) +
    labs(title = paste0("France", SOUS_TITRE_FORMAT, " : où décroche-t-on l'index 500 le plus « doucement » ?"),
         subtitle = paste0("Temps médian des finishers à index ", CIBLE, " ± ", TOLERANCE,
                           ", rapporté ", rapporte_a, ". Toutes éditions, ≥ ", MIN_COUREURS,
                           " finishers dans la fenêtre."),
         x = titre_x, y = NULL, colour = "Format") +
    theme_minimal(base_size = 12) +
    theme(plot.title.position = "plot", panel.grid.minor = element_blank(),
          panel.grid.major.y = element_blank())
  ggsave(fichier, p, width = 11, height = 8, dpi = 200, bg = "white")
}

lollipop_500(classement, h_par_1000m,
             \(d) sprintf("%.0f h pour %.0f m D+", d$temps_h, d$dplus),
             "Heures par 1000 m de D+ pour un index ≈ 500", "au dénivelé positif",
             paste0("outputs/index500_france", SUFFIXE, ".png"))

lollipop_500(classement, min_par_km,
             \(d) sprintf("%.0f h pour %.0f km", d$temps_h, d$distance),
             "Minutes par km pour un index ≈ 500 (allure moyenne)", "à la distance",
             paste0("outputs/index500_france_distance", SUFFIXE, ".png"))

# Croisement distance x D+ : une course = un point, couleur = temps par km-effort
cr <- classement |> mutate(rang = row_number(desc(min_par_kmeffort)))
p3 <- ggplot(cr, aes(distance, dplus, colour = min_par_kmeffort)) +
  geom_point(aes(size = temps_h), alpha = .8) +
  geom_text_repel(data = filter(cr, rang <= 8), aes(label = strtrim(label, 30)), size = 2.8, colour = "grey20",
                  max.overlaps = Inf, min.segment.length = 0, box.padding = .8,
                  point.padding = .5, nudge_x = -.15, nudge_y = -.1, seed = 1) +
  scale_x_log10(breaks = c(10, 20, 40, 80, 160)) +
  scale_y_log10(labels = label_number(big.mark = " ")) +
  scale_colour_viridis_c(option = "plasma", direction = -1, end = .9) +
  scale_size_area(max_size = 9, breaks = c(2, 6, 12, 24, 40), name = "Temps à\nindex 500 (h)") +
  labs(title = paste0("France", SOUS_TITRE_FORMAT, " : distance, dénivelé et temps pour décrocher l'index 500"),
       subtitle = paste0("Une course = un point. Couleur : minutes par km-effort (distance + D+/100) à index ≈ ",
                         CIBLE, " ;\nplus c'est foncé, plus la course est généreuse. Étiquettes : les 8 plus généreuses."),
       x = "Distance (km, échelle log)", y = "D+ (m, échelle log)",
       colour = "min / km-effort") +
  theme_minimal(base_size = 12) +
  theme(plot.title.position = "plot", panel.grid.minor = element_blank())
ggsave(paste0("outputs/index500_france_croise", SUFFIXE, ".png"), p3, width = 11, height = 8, dpi = 200, bg = "white")

readr::write_csv(arrange(classement, desc(h_par_1000m)), paste0("outputs/index500_france", SUFFIXE, ".csv"))
message("OK")
