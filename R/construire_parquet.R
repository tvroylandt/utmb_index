# -------------------------- #
# Construction des parquet propres à partir des CSV scrapés
# -------------------------- #

# à lancer à la fin du scraping (scrape_utmb.py races puis results)
# Entrées :
# - data/races.csv : une ligne par course (édition d'une course)
# Sorties (data/) :
# - data/evenements.parquet : une ligne par évènement (toutes éditions confondues)
# - data/courses.parquet : une ligne par course et par année, clé course_uid
# - data/resultats.parquet : une ligne par coureur et par course

library(tidyverse)

# Import -----------------------------------------------------------------
# dates en anglais ("2025-Jun-24"), indépendamment de la langue du système
df_races_raw <- read_csv(
  "data/races.csv",
  col_types = cols(.default = col_character()),
  na = c("", "NA")
)

df_results_raw <- read_csv(
  "data/results.csv",
  col_types = cols(.default = col_character()),
  na = c("", "NA")
)

# Identifiants -----------------------------------------------------------
# Dans l'URI `<n>.<slug>.<année>`, <n> identifie la course d'une année sur l'autre
# (ex. 407 = EcoTrail Paris 80 km de 2008 à 2026), alors que `id` change à chaque édition.
# L'évènement n'a pas d'identifiant dans le scraping : on le reconstruit en reliant
# - les courses qui portent le même nom d'évènement la même année (formats d'une édition)
# - les éditions successives d'une même course (même n°), ce qui absorbe les changements de nom
# Un évènement = une composante connexe, identifiée par le plus petit n° de course qu'elle contient
# (`event_num`). Ces numéros ne servent qu'à construire les identifiants lisibles ci-dessous.
df_races_id <- df_races_raw |>
  mutate(
    race_num = as.integer(str_extract(uriResults, "^[0-9]+")),
    year = as.integer(year),
    event_key = str_squish(str_to_lower(coalesce(eventName, "")))
  )

# arêtes : chaque course est reliée à la première course de son (année, nom d'évènement)
df_edges <- df_races_id |>
  group_by(year, event_key) |>
  mutate(race_num_ref = min(race_num)) |>
  ungroup() |>
  distinct(race_num, race_num_ref)

g <- igraph::graph_from_data_frame(df_edges, directed = FALSE)
df_event_num <- tibble(
  race_num = as.integer(igraph::V(g)$name),
  component = igraph::components(g)$membership
) |>
  group_by(component) |>
  mutate(event_num = min(race_num)) |>
  ungroup() |>
  select(race_num, event_num)

# Courses à étapes -------------------------------------------------------
# Détection sur le nom de la course (et, plus strictement, sur le nom de l'évènement)
# après passage en minuscules sans accents. Une étape de relais (« Relay - Stage 2 ») est
# un relais, pas une course à étapes ; « Single Stage » désigne la version en une fois.
regex_relais <- "\\brelais\\b|\\brelay\\b|\\brelevo\\b|\\bstaffel\\b"
regex_etapes_course <- str_c(
  "\\bstages?\\b|multi-?stage|stage-?race|stage-?run|\\betapes?\\b|\\betappes?\\b|",
  "\\btappe\\b|\\betapas?\\b|\\bday ?[0-9]\\b|\\bjour ?[0-9]\\b|\\bdia ?[0-9]\\b|",
  "\\b[2-9] ?(jours|days?|dias)\\b|\\b[2-9]-day\\b|\\bx[2-9]s\\b"
)
regex_etapes_evenement <- "stage-? ?race|multi-?stage|stage-? ?run|\\bstages? by\\b|\\betapes\\b"
regex_une_etape <- "single-? ?stage|one-? ?stage"
regex_numero_etape <- "(?:stage|etape|etappe|tappe|day|jour|dia) ?([0-9]+)"

# Identifiants lisibles --------------------------------------------------
# event_id et race_id sont des slugs du nom le plus récent (sans accents, années retirées).
# Ils restent stables d'une année sur l'autre même si le nom change : on garde celui de la dernière édition.
# En cas de doublon, on ajoute le pays puis le numéro d'origine.
slugifier <- function(x, defaut) {
  x |>
    stringi::stri_trans_general("Latin-ASCII") |>
    str_to_lower() |>
    str_remove_all("\\b(19|20)[0-9]{2}\\b") |>
    str_replace_all("[^a-z0-9]+", "-") |>
    str_remove_all("^-|-$") |>
    na_if("") |>
    coalesce(defaut)
}

# évènements : nom de la dernière édition
df_event_slug <- df_races_id |>
  left_join(df_event_num, by = join_by(race_num)) |>
  arrange(event_num, desc(year), desc(startDate)) |>
  distinct(event_num, .keep_all = TRUE) |>
  mutate(
    slug = slugifier(eventName, "evenement"),
    slug_pays = str_c(slug, "-", str_to_lower(coalesce(startCountry, "xx")))
  ) |>
  mutate(event_id = if_else(n() > 1, slug_pays, slug), .by = slug) |>
  mutate(event_id = if_else(n() > 1, str_c(event_id, "-", event_num), event_id), .by = event_id) |>
  select(event_num, event_id)

# courses : nom de la dernière édition, dans l'évènement
df_race_slug <- df_races_id |>
  left_join(df_event_num, by = join_by(race_num)) |>
  arrange(race_num, desc(year), desc(startDate)) |>
  distinct(race_num, .keep_all = TRUE) |>
  mutate(race_id = slugifier(name, "course")) |>
  mutate(race_id = if_else(n() > 1, str_c(race_id, "-", race_num), race_id), .by = c(event_num, race_id)) |>
  select(race_num, race_id)

# Courses ----------------------------------------------------------------
df_courses <- df_races_id |>
  left_join(df_event_num, by = join_by(race_num)) |>
  mutate(
    nom_ascii = stringi::stri_trans_general(str_to_lower(coalesce(name, "")), "Latin-ASCII"),
    evenement_ascii = stringi::stri_trans_general(str_to_lower(coalesce(eventName, "")), "Latin-ASCII"),
    is_relay = str_detect(nom_ascii, regex_relais),
    is_multi_stage = !is_relay &
      !str_detect(nom_ascii, regex_une_etape) &
      (str_detect(nom_ascii, regex_etapes_course) |
        str_detect(evenement_ascii, regex_etapes_evenement)),
    stage_number = if_else(
      is_multi_stage,
      as.integer(str_match(nom_ascii, regex_numero_etape)[, 2]),
      NA_integer_
    )
  ) |>
  transmute(
    course_uid = str_c(event_id, "/", race_id, "/", year),
    year,
    event_id,
    race_id,
    edition_id = str_c(event_id, "/", year),
    event_num,
    race_num,
    utmb_id = as.integer(id),
    uri_results = uriResults,
    event_name = eventName,
    race_name = name,
    category,
    start_date = parse_date(startDate, "%Y-%b-%d", locale = locale("en")),
    start_country = startCountry,
    start_place = startPlace,
    distance_km = as.numeric(distance),
    elevation_gain_m = as.numeric(elevationGain),
    has_results = hasResults == "True",
    level,
    nb_stones = as.integer(nbStones),
    url,
    is_multi_stage,
    stage_number,
    is_relay
  ) |>
  arrange(event_id, race_id, year)

# la clé doit être unique
stopifnot(!anyDuplicated(df_courses$course_uid))

# Évènements -------------------------------------------------------------
df_evenements <- df_courses |>
  arrange(event_id, desc(year)) |>
  group_by(event_id) |>
  summarise(
    event_name = first(event_name), # nom de la dernière édition
    first_year = min(year),
    last_year = max(year),
    n_editions = n_distinct(year),
    n_races = n_distinct(race_id),
    event_num = first(event_num),
    start_country = first(na.omit(start_country)),
    .groups = "drop"
  )

# Résultats --------------------------------------------------------------
# Le CSV est alimenté au fil de l'eau : on retire les doublons éventuels.
df_resultats <- df_results_raw |>
  distinct() |>
  mutate(
    uriResults = race_uri,
    # temps `HH:MM:SS` (HH peut dépasser 99)
    h = as.integer(str_extract(time, "^[0-9]+")),
    m = as.integer(str_match(time, "^[0-9]+:([0-9]+):")[, 2]),
    s = as.integer(str_extract(time, "[0-9]+$"))
  ) |>
  inner_join(
    df_courses |> select(course_uid, year, event_id, race_id, uri_results),
    by = join_by(uriResults == uri_results)
  ) |>
  transmute(
    course_uid,
    year,
    event_id,
    race_id,
    rank = if_else(as.integer(rank) > 0, as.integer(rank), NA_integer_),
    runner_id = as.integer(str_extract(runnerUri, "^[0-9]+")),
    runner_uri = runnerUri,
    fullname,
    time_hms = time,
    time_s = na_if(h * 3600L + m * 60L + s, 0L), # 00:00:00 = temps non renseigné
    is_finisher = !is.na(time_s),
    gender = case_when(
      str_to_upper(gender) %in% c("H", "F") ~ str_to_upper(gender),
      .default = NA_character_
    ),
    age_group = ageGroup,
    nationality_code = nationalityCode,
    nationality,
    index = as.integer(index)
  ) |>
  arrange(course_uid, rank)

# Contrôles --------------------------------------------------------------
n_hors_courses <- df_results_raw |>
  distinct(race_uri) |>
  anti_join(df_courses, by = join_by(race_uri == uri_results)) |>
  nrow()
message("Résultats sans course correspondante dans races.csv : ", n_hors_courses, " course(s)")
message(
  nrow(df_evenements), " évènements, ",
  nrow(df_courses), " courses (",
  sum(df_courses$is_multi_stage), " à étapes, ", sum(df_courses$is_relay), " relais), ",
  nrow(df_resultats), " résultats"
)

# Export -----------------------------------------------------------------
arrow::write_parquet(df_evenements, "data/evenements.parquet")
arrow::write_parquet(df_courses, "data/courses.parquet")
arrow::write_parquet(df_resultats, "data/resultats.parquet")
