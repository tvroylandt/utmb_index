library(ggplot2)
library(dplyr)
library(readr)

races <- read_csv("data/races.csv", show_col_types = FALSE) |>
  filter(year == 2025, !is.na(distance), !is.na(elevationGain), distance > 0, elevationGain > 0) |>
  mutate(category = factor(coalesce(category, "n/a"), levels = c("20k", "50k", "100k", "100m", "n/a")))

make_plot <- function(log_scale) {
  p <- ggplot(races, aes(distance, elevationGain, colour = category)) +
    geom_point(alpha = 0.5, size = 1.3) +
    scale_colour_manual(values = c("20k" = "#4E79A7", "50k" = "#59A14F", "100k" = "#F28E2B",
                                   "100m" = "#E15759", "n/a" = "grey60")) +
    guides(colour = guide_legend(override.aes = list(alpha = 1, size = 3))) +
    labs(title = "Courses UTMB Index 2025 : distance et dénivelé",
         subtitle = paste(nrow(races), "courses, un point par course",
                          if (log_scale) "(échelles logarithmiques)" else ""),
         x = "Distance (km)", y = "Dénivelé positif (m)", colour = "Catégorie") +
    theme_minimal(base_size = 12)
  if (log_scale) {
    p + scale_x_log10(labels = scales::label_number(big.mark = " ")) +
      scale_y_log10(labels = scales::label_number(big.mark = " "))
  } else {
    p + scale_x_continuous(labels = scales::label_number(big.mark = " ")) +
      scale_y_continuous(labels = scales::label_number(big.mark = " "))
  }
}

ggsave("distance_denivele_2025.png", make_plot(TRUE), width = 9, height = 6, dpi = 200, bg = "white")
ggsave("distance_denivele_2025_lineaire.png", make_plot(FALSE), width = 9, height = 6, dpi = 200, bg = "white")
