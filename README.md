# UTMB Index

## Descriptif

Ce projet récupère les courses du [UTMB Index](https://utmb.world/fr/index-races) et leurs résultats (rang, temps, index), puis les met en forme dans des fichiers parquet propres, prêts à être analysés : suivi d'une course dans le temps, comparaison des formats d'une même édition, évolution de l'index des coureurs.

## Fonctionnement

Étapes :

- scraping des courses avec `scrape_utmb.py races` (`data/races.csv`)
- scraping des résultats avec `scrape_utmb.py results`, reprenable (`data/results.csv`, `data/results_done.txt`, `data/scrape.log`)
- mise en forme avec `R/construire_parquet.R` : `data/evenements.parquet`, `data/courses.parquet`, `data/resultats.parquet`
- graphiques exploratoires avec `plot_2025.R` (distance et dénivelé des courses 2025)

Le code R se relance en entier à la fin du scraping, sans autre manipulation : `Rscript R/construire_parquet.R` (environ 30 secondes). Le dossier `data/` n'est pas versionné.

### Scraping

Voir l'en-tête de `scrape_utmb.py` pour les options. Points à retenir :

- le scraping est séquentiel (le site renvoie des 503 si on parallélise) ;
- l'`index` par course n'est renseigné que pour un compte connecté : exporter `UTMB_USER` et `UTMB_PASSWORD` (compte MyUTMB, pas Google ni Facebook) avant `results`. Sans connexion la colonne est vide ;
- `results` ne traite par défaut que les années 2021 à 2025 (`--since`, `--until`).

## Identifiants

Une course est identifiée par **l'année, l'identifiant de l'évènement et l'identifiant de la course**. On peut ainsi suivre une course d'une année sur l'autre, et retrouver les différents formats d'une même édition.

| Colonne | Contenu | Exemple |
| --- | --- | --- |
| `year` | année de l'édition | 2025 |
| `event_id` | évènement, toutes éditions et tous formats confondus | 407 |
| `race_id` | course (un format), stable d'une année sur l'autre | 1867 |
| `edition_id` | édition d'un évènement : `year`-`event_id` | 2025-407 |
| `course_uid` | clé unique d'une course sur une édition : `year`-`event_id`-`race_id` | 2025-407-1867 |
| `utmb_id` | `id` du site, propre à chaque course et chaque année (ne pas utiliser pour le suivi dans le temps) | 109612 |

Exemple : l'EcoTrail Paris est l'évènement 407. Son 80 km est la course 407 (identifiant historique), son 45 km la course 1867, etc.

- `course_uid` identifie une ligne de `courses.parquet` ; `edition_id` regroupe les formats d'une même édition ; `event_id` + `race_id` suit une course dans le temps.
- Les jointures entre tables se font sur `course_uid`.

### Reconstruction de `race_id` et `event_id`

Le scraping ne donne pas d'identifiant d'évènement. Dans l'URI des résultats (`407.ecotrailparis-r-trail80km.2025`), le nombre de tête est stable d'une année sur l'autre pour une même course : c'est `race_id`. Le champ `id` du site change à chaque édition.

`event_id` est reconstruit : on relie

- les courses qui ont le même nom d'évènement (`eventName`, insensible à la casse) la même année : ce sont les formats d'une édition ;
- les éditions successives d'une même course (même `race_id`), ce qui absorbe les changements de nom d'évènement (EcoTrail Paris Ile-de-France devenu EcoTrail Paris, UTMB devenu HOKA UTMB Mont-Blanc…).

Un évènement est un ensemble de courses ainsi reliées. Son `event_id` est le plus petit `race_id` qu'il contient. Conséquences :

- `event_id` est stable tant que les données ne changent pas, mais peut changer si un nouveau scraping relie deux évènements jusque-là séparés (par exemple un évènement qui fusionne avec un autre). Ne pas figer `event_id` hors du projet sans le recalculer ;
- une course qui change complètement de nom d'évènement et de format la même année reste séparée ;
- un nom d'évènement très générique, partagé par deux évènements différents la même année, les fusionnerait. Vérifier avec `evenements.parquet` (`n_races` anormalement grand).

## Tables

### `data/evenements.parquet`

Une ligne par évènement.

| Colonne | Contenu |
| --- | --- |
| `event_id` | identifiant de l'évènement |
| `event_name` | nom lors de la dernière édition |
| `first_year`, `last_year` | première et dernière année |
| `n_editions` | nombre d'années distinctes |
| `n_races` | nombre de courses (`race_id`) distinctes |
| `start_country` | pays de départ (le plus récent renseigné) |

### `data/courses.parquet`

Une ligne par course et par année (clé `course_uid`). Inclut les courses sans résultats (`has_results = FALSE`).

| Colonne | Contenu |
| --- | --- |
| `course_uid`, `year`, `event_id`, `race_id`, `edition_id`, `utmb_id` | identifiants (voir plus haut) |
| `uri_results` | URI du site, jointure avec `race_uri` de `results.csv` |
| `event_name`, `race_name` | nom de l'évènement et de la course pour l'année |
| `category` | catégorie UTMB : 20k, 50k, 100k, 100m ; vide pour les courses plus courtes |
| `start_date` | date de départ |
| `start_country`, `start_place` | lieu de départ (souvent vides avant 2010) |
| `distance_km`, `elevation_gain_m` | distance et dénivelé positif |
| `has_results` | résultats publiés sur le site |
| `level` | niveau de la course dans l'index |
| `nb_stones` | nombre de pierres (qualification UTMB) |
| `url` | site de la course |
| `is_multi_stage` | course à étapes (voir ci-dessous) |
| `stage_number` | numéro d'étape quand il figure dans le nom, sinon vide |
| `is_relay` | course en relais |

### `data/resultats.parquet`

Une ligne par coureur et par course. Seules les courses présentes dans `results.csv` y figurent.

| Colonne | Contenu |
| --- | --- |
| `course_uid`, `year`, `event_id`, `race_id` | identifiants de la course |
| `rank` | classement ; vide pour les non-classés |
| `runner_id`, `runner_uri` | identifiant du coureur sur le site (vide pour les coureurs anonymes) |
| `fullname` | nom affiché (`Anonymous` pour les coureurs anonymes) |
| `time_hms`, `time_s` | temps `HH:MM:SS` d'origine et en secondes |
| `is_finisher` | temps renseigné |
| `gender` | `H` ou `F` ; vide si la valeur du site est inexploitable |
| `age_group` | catégorie d'âge du site (U18, U20, 20-34, 35-39… 80+) |
| `nationality_code`, `nationality` | nationalité |
| `index` | index UTMB du coureur sur la course (vide si le scraping n'était pas connecté) |

## Méthode

### Nettoyage

- Tous les champs sont lus en texte puis typés explicitement.
- Dates du site en anglais (`2025-Jun-24`) : lues indépendamment de la langue du système.
- Doublons exacts de `results.csv` supprimés (le fichier est alimenté au fil de l'eau et le scraping est reprenable).
- `rank = -1` (valeur du site pour les non-classés) devient vide. Les lignes sans temps sont conservées, avec `is_finisher = FALSE`.
- Temps `00:00:00` considéré comme non renseigné. Les temps peuvent dépasser 99 heures (format `HHH:MM:SS`), d'où le passage en secondes.
- `gender` : seules les valeurs `H` et `F` sont gardées (quelques centaines de valeurs parasites sur plusieurs millions).
- Coureurs anonymes : conservés (ils comptent dans le classement) mais sans `runner_id`. Une même course peut en contenir plusieurs, ils ne se suivent pas dans le temps.
- Un contrôle affiche en console les courses de `results.csv` absentes de `races.csv` (elles sont écartées) ; l'unicité de `course_uid` est vérifiée.

### Courses à étapes (`is_multi_stage`)

Sur UTMB Index, chaque étape d'une course à étapes est parfois publiée comme une course distincte (« GPT100 Stage Race - Stage 2 »), parfois la course à étapes est publiée en un seul résultat (« 100 km en 3 étapes »). L'indicateur est posé sur les deux cas, d'après le nom de la course et de l'évènement :

- nom de la course, passé en minuscules sans accents : `stage`, `stages`, `multistage`, `stage race`, `stage run`, `étape(s)`, `etappe`, `etapa`, `day 2` / `jour 2` / `dia 2`, `2 days` / `3 jours` / `2 días`, `x3s` ;
- nom de l'évènement, avec des expressions plus strictes (`stage race`, `multi-stage`, `stage run`, `étapes`) : un évènement qui se dit à étapes marque toutes ses courses ;
- exclus : les relais (`is_relay`, dont « Relay - Stage 2 » qui est un relais, pas une course à étapes) et les versions en une fois (« Single Stage », « One Stage »).

`stage_number` reprend le numéro d'étape quand le nom le donne (`Stage 3`, `Day 2`, `Etape 1`).

Limites : c'est une détection par mots-clés, sur le nom. Elle peut manquer une course à étapes sans mention dans son nom (certains formats « 2 jours » écrits autrement) et reste à valider à la main sur les cas qui comptent. Pour les courses dont les étapes sont publiées séparément, regrouper par `edition_id` et filtrer sur `is_multi_stage`, mais attention aux courses d'un même évènement qui ne sont pas des étapes (formats courts du même week-end).

## Utilisation

```r
library(tidyverse)

courses <- arrow::read_parquet("data/courses.parquet")
resultats <- arrow::read_parquet("data/resultats.parquet")

# suivre l'EcoTrail Paris 80 km dans le temps
resultats |>
  filter(event_id == 407, race_id == 407, is_finisher) |>
  summarise(temps_median_h = median(time_s) / 3600, .by = year)

# les différents formats d'une édition
courses |> filter(edition_id == "2025-407") |> select(race_name, distance_km, elevation_gain_m)
```

## À faire à la fin du scraping

- relancer `Rscript R/construire_parquet.R` ;
- lire les deux lignes de contrôle affichées en console (courses sans correspondance, nombre d'évènements, de courses à étapes et de résultats) ;
- vérifier `n_races` dans `evenements.parquet` (évènements anormalement gros) et un échantillon de `is_multi_stage` sur les nouvelles années.
