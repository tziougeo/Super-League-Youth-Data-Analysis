Create database SuperLeagueYouth
Use SuperLeagueYouth

   /* 
   SUPER LEAGUE GREECE – YOUTH (U21) PLAYER ANALYSIS
   Section 1: Data Exploration
   */

----1.1 Row count per table 
SELECT 'raw_competitions' AS table_name, COUNT(*) AS row_count FROM raw_competitions
UNION ALL SELECT 'raw_clubs', COUNT(*) FROM raw_clubs
UNION ALL SELECT 'raw_players', COUNT(*) FROM raw_players
UNION ALL SELECT 'raw_games', COUNT(*) FROM raw_games
UNION ALL SELECT 'raw_player_valuations', COUNT(*) FROM raw_player_valuations
UNION ALL SELECT 'raw_transfers', COUNT(*) FROM raw_transfers
UNION ALL SELECT 'raw_appearances', COUNT(*) FROM raw_appearances;

----1.2 Identify the Super League competition code
SELECT competition_id, name, type, country_name
FROM raw_competitions
WHERE country_name = 'Greece';

----1.3 Available Super League seasons and number of games per season
SELECT season, COUNT(*) AS games
FROM raw_games
WHERE competition_id = 'GR1'
GROUP BY season
ORDER BY season;

----1.4 Player appearances and distinct players per Super League season
SELECT g.season, COUNT(*) AS appearances, COUNT(DISTINCT a.player_id) AS players
FROM raw_appearances a
JOIN raw_games g ON a.game_id = g.game_id
WHERE a.competition_id = 'GR1'
GROUP BY g.season
ORDER BY g.season;

----1.5 Data quality check: Super League players with missing date of birth
SELECT COUNT(DISTINCT a.player_id) AS players_without_dob
FROM raw_appearances a
JOIN raw_players p ON a.player_id = p.player_id
WHERE a.competition_id = 'GR1'
  AND p.date_of_birth IS NULL;


   /* 
   Section 2: Data Cleaning & Preparation
   */

----2.1 Check for duplicate appearances in the Super League
SELECT appearance_id, COUNT(*) AS duplicates
FROM raw_appearances
WHERE competition_id = 'GR1'
GROUP BY appearance_id
HAVING COUNT(*) > 1;

----2.2 Sanity check on minutes played (nulls and unrealistic values)
SELECT
    MIN(minutes_played) AS min_minutes,
    MAX(minutes_played) AS max_minutes,
    SUM(CASE WHEN minutes_played IS NULL THEN 1 ELSE 0 END) AS null_minutes
FROM raw_appearances
WHERE competition_id = 'GR1';

----2.3 Build the clean appearances table for the Super League

----Age is calculated on July 1st of each season (standard U21 definition)
DROP TABLE IF EXISTS gr_appearances;

WITH base AS (
    SELECT
        a.appearance_id,
        a.game_id,
        g.season,
        CAST(a.date AS DATE)             AS match_date,
        a.player_id,
        p.name                           AS player_name,
        p.position,
        a.player_club_id                 AS club_id,
        a.minutes_played,
        a.goals,
        a.assists,
        a.yellow_cards,
        a.red_cards,
        CAST(p.date_of_birth AS DATE)    AS date_of_birth,
        DATEFROMPARTS(g.season, 7, 1)    AS season_start
    FROM raw_appearances a
    JOIN raw_games   g ON a.game_id   = g.game_id
    JOIN raw_players p ON a.player_id = p.player_id
    WHERE a.competition_id = 'GR1'
),
aged AS (
    SELECT
        *,
        DATEDIFF(YEAR, date_of_birth, season_start)
          - CASE WHEN DATEADD(YEAR, DATEDIFF(YEAR, date_of_birth, season_start), date_of_birth) > season_start
                 THEN 1 ELSE 0 END AS age_at_season_start
    FROM base
)
SELECT
    appearance_id,
    game_id,
    season,
    CONCAT(season, '/', RIGHT(CAST(season + 1 AS VARCHAR(4)), 2)) AS season_label,
    match_date,
    player_id,
    player_name,
    position,
    club_id,
    minutes_played,
    goals,
    assists,
    yellow_cards,
    red_cards,
    age_at_season_start,
    CASE WHEN age_at_season_start < 21 THEN 1 ELSE 0 END AS is_u21
INTO gr_appearances
FROM aged;

----2.4 Verify the clean table: players and U21 players per season
SELECT
    season_label,
    COUNT(*)                                             AS appearances,
    COUNT(DISTINCT player_id)                            AS players,
    COUNT(DISTINCT CASE WHEN is_u21 = 1 THEN player_id END) AS u21_players,
    MIN(age_at_season_start)                             AS youngest_age,
    MAX(age_at_season_start)                             AS oldest_age
FROM gr_appearances
GROUP BY season, season_label
ORDER BY season;

----2.5 Edge case check: youngest and oldest players (validate age calculation)
SELECT TOP 10
    season_label, player_name, position, age_at_season_start,
    COUNT(*)            AS appearances,
    SUM(minutes_played) AS minutes
FROM gr_appearances
WHERE age_at_season_start <= 16 OR age_at_season_start >= 39
GROUP BY season_label, player_name, position, age_at_season_start
ORDER BY age_at_season_start;

----2.6 Build the clubs table using the most recent club name from Super League games
DROP TABLE IF EXISTS gr_clubs;

WITH club_names AS (
    SELECT home_club_id AS club_id, home_club_name AS club_name, date
    FROM raw_games
    WHERE competition_id = 'GR1'
    UNION ALL
    SELECT away_club_id, away_club_name, date
    FROM raw_games
    WHERE competition_id = 'GR1'
),
ranked AS (
    SELECT
        club_id,
        club_name,
        ROW_NUMBER() OVER (PARTITION BY club_id ORDER BY date DESC) AS rn
    FROM club_names
    WHERE club_name IS NOT NULL
)
SELECT club_id, club_name
INTO gr_clubs
FROM ranked
WHERE rn = 1;

----2.7 Verify: every club in the appearances table has a name
SELECT COUNT(DISTINCT a.club_id) AS clubs_without_name
FROM gr_appearances a
LEFT JOIN gr_clubs c ON a.club_id = c.club_id
WHERE c.club_id IS NULL;

SELECT * FROM gr_clubs ORDER BY club_name;

    /*
    Section 3: Analysis
    */

----3.1 Q1: Share of minutes given to U21 players per club (all seasons)

----Only clubs with at least 3 Super League seasons, to avoid misleading small samples
SELECT
    c.club_name,
    COUNT(DISTINCT a.season)                                   AS seasons,
    SUM(a.minutes_played)                                      AS total_minutes,
    SUM(CASE WHEN a.is_u21 = 1 THEN a.minutes_played ELSE 0 END) AS u21_minutes,
    CAST(100.0 * SUM(CASE WHEN a.is_u21 = 1 THEN a.minutes_played ELSE 0 END)
         / SUM(a.minutes_played) AS DECIMAL(5,2))              AS u21_minutes_pct
FROM gr_appearances a
JOIN gr_clubs c ON a.club_id = c.club_id
GROUP BY c.club_id, c.club_name
HAVING COUNT(DISTINCT a.season) >= 3
ORDER BY u21_minutes_pct DESC;

----3.2 Q1: Share of minutes given to U21 players per club (latest season 2025/26)
SELECT
    c.club_name,
    COUNT(DISTINCT CASE WHEN a.is_u21 = 1 THEN a.player_id END)  AS u21_players,
    SUM(CASE WHEN a.is_u21 = 1 THEN a.minutes_played ELSE 0 END) AS u21_minutes,
    CAST(100.0 * SUM(CASE WHEN a.is_u21 = 1 THEN a.minutes_played ELSE 0 END)
         / SUM(a.minutes_played) AS DECIMAL(5,2))              AS u21_minutes_pct
FROM gr_appearances a
JOIN gr_clubs c ON a.club_id = c.club_id
WHERE a.season = 2025
GROUP BY c.club_id, c.club_name
ORDER BY u21_minutes_pct DESC;

----3.3 Q2: Evolution of U21 playing time in the league per season
SELECT
    season_label,
    COUNT(DISTINCT CASE WHEN is_u21 = 1 THEN player_id END)  AS u21_players,
    SUM(minutes_played)                                      AS total_minutes,
    SUM(CASE WHEN is_u21 = 1 THEN minutes_played ELSE 0 END) AS u21_minutes,
    CAST(100.0 * SUM(CASE WHEN is_u21 = 1 THEN minutes_played ELSE 0 END)
         / SUM(minutes_played) AS DECIMAL(5,2))              AS u21_minutes_pct
FROM gr_appearances
GROUP BY season, season_label
ORDER BY season;

----3.3b Q2: Investigate the 2020/21 spike: U21 minutes share per club, 2019/20 to 2021/22
--     A league-wide rise that reverses the next season suggests a season-specific factor (likely COVID-19)
SELECT
    c.club_name,
    CAST(100.0 * SUM(CASE WHEN a.season = 2019 AND a.is_u21 = 1 THEN a.minutes_played ELSE 0 END)
         / NULLIF(SUM(CASE WHEN a.season = 2019 THEN a.minutes_played ELSE 0 END), 0) AS DECIMAL(5,2)) AS pct_2019_20,
    CAST(100.0 * SUM(CASE WHEN a.season = 2020 AND a.is_u21 = 1 THEN a.minutes_played ELSE 0 END)
         / NULLIF(SUM(CASE WHEN a.season = 2020 THEN a.minutes_played ELSE 0 END), 0) AS DECIMAL(5,2)) AS pct_2020_21,
    CAST(100.0 * SUM(CASE WHEN a.season = 2021 AND a.is_u21 = 1 THEN a.minutes_played ELSE 0 END)
         / NULLIF(SUM(CASE WHEN a.season = 2021 THEN a.minutes_played ELSE 0 END), 0) AS DECIMAL(5,2)) AS pct_2021_22
FROM gr_appearances a
JOIN gr_clubs c ON a.club_id = c.club_id
WHERE a.season BETWEEN 2019 AND 2021
GROUP BY c.club_id, c.club_name
ORDER BY pct_2020_21 DESC;

----3.4 Q3: Build a summary table of all players who played as U21 in the Super League

----first_value = earliest recorded market value, peak_value = highest recorded market value
DROP TABLE IF EXISTS gr_u21_players;

WITH u21 AS (
    SELECT
        player_id,
        player_name,
        position,
        SUM(minutes_played)     AS u21_minutes,
        COUNT(DISTINCT season)  AS u21_seasons
    FROM gr_appearances
    WHERE is_u21 = 1
    GROUP BY player_id, player_name, position
),
vals AS (
    SELECT
        player_id,
        CAST(market_value_in_eur AS BIGINT) AS market_value,
        ROW_NUMBER() OVER (PARTITION BY player_id ORDER BY date ASC) AS rn_first
    FROM raw_player_valuations
    WHERE player_id IN (SELECT player_id FROM u21)
),
value_summary AS (
    SELECT
        player_id,
        MAX(CASE WHEN rn_first = 1 THEN market_value END) AS first_value,
        MAX(market_value)                                  AS peak_value
    FROM vals
    GROUP BY player_id
)
SELECT
    u.player_id,
    u.player_name,
    u.position,
    u.u21_minutes,
    u.u21_seasons,
    v.first_value,
    v.peak_value,
    v.peak_value - v.first_value AS value_growth
INTO gr_u21_players
FROM u21 u
LEFT JOIN value_summary v ON u.player_id = v.player_id;

----3.5 Data check: how many U21 players have no market value records
SELECT
    COUNT(*)                                             AS u21_players,
    SUM(CASE WHEN first_value IS NULL THEN 1 ELSE 0 END) AS without_valuation
FROM gr_u21_players;

----3.6 Q3: Top 15 players by market value growth
SELECT TOP 15
    player_name, position, u21_minutes, u21_seasons,
    first_value, peak_value, value_growth
FROM gr_u21_players
WHERE value_growth IS NOT NULL
ORDER BY value_growth DESC;

----3.7 Q3: Does playing time as U21 relate to value growth?
SELECT
    CASE
        WHEN u21_minutes < 500  THEN '1) Under 500'
        WHEN u21_minutes < 1500 THEN '2) 500-1,499'
        WHEN u21_minutes < 3000 THEN '3) 1,500-2,999'
        ELSE                         '4) 3,000+'
    END                                  AS u21_minutes_band,
    COUNT(*)                             AS players,
    AVG(peak_value)                      AS avg_peak_value,
    AVG(value_growth)                    AS avg_value_growth
FROM gr_u21_players
WHERE value_growth IS NOT NULL
GROUP BY
    CASE
        WHEN u21_minutes < 500  THEN '1) Under 500'
        WHEN u21_minutes < 1500 THEN '2) 500-1,499'
        WHEN u21_minutes < 3000 THEN '3) 1,500-2,999'
        ELSE                         '4) 3,000+'
    END
ORDER BY u21_minutes_band;

----3.7b Q3: Median value growth per minutes band (robust to outliers)
SELECT DISTINCT
    u21_minutes_band,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY value_growth)
        OVER (PARTITION BY u21_minutes_band) AS median_value_growth
FROM (
    SELECT
        CASE
            WHEN u21_minutes < 500  THEN '1) Under 500'
            WHEN u21_minutes < 1500 THEN '2) 500-1,499'
            WHEN u21_minutes < 3000 THEN '3) 1,500-2,999'
            ELSE                         '4) 3,000+'
        END AS u21_minutes_band,
        value_growth
    FROM gr_u21_players
    WHERE value_growth IS NOT NULL
) t
ORDER BY u21_minutes_band;

----3.8 Q4: Build a table of paid transfers of players developed as U21 at a Super League club
----transfer_fee is stored as text in raw_transfers and converted safely with TRY_CAST

DROP TABLE IF EXISTS gr_youth_sales;

WITH developed AS (
    SELECT
        player_id,
        club_id,
        SUM(minutes_played) AS u21_minutes_at_club,
        MIN(match_date)     AS first_u21_match
    FROM gr_appearances
    WHERE is_u21 = 1
    GROUP BY player_id, club_id
)
SELECT
    t.player_id,
    t.player_name,
    CAST(t.transfer_date AS DATE)                              AS transfer_date,
    t.transfer_season,
    d.club_id                                                  AS selling_club_id,
    t.to_club_name,
    CAST(TRY_CAST(t.transfer_fee AS DECIMAL(18,2)) AS BIGINT)  AS transfer_fee,
    d.u21_minutes_at_club,
    CASE WHEN t.to_club_id IN (SELECT club_id FROM gr_clubs)
         THEN 'Domestic' ELSE 'Abroad' END                     AS destination
INTO gr_youth_sales
FROM raw_transfers t
JOIN developed d
    ON t.player_id    = d.player_id
   AND t.from_club_id = d.club_id
WHERE TRY_CAST(t.transfer_fee AS DECIMAL(18,2)) > 0
  AND CAST(t.transfer_date AS DATE) >= d.first_u21_match;

----3.9 Q4: Revenue from youth player sales per club
SELECT
    c.club_name,
    COUNT(*)                                                   AS sales,
    SUM(s.transfer_fee)                                        AS total_revenue,
    MAX(s.transfer_fee)                                        AS biggest_sale,
    SUM(CASE WHEN s.destination = 'Abroad' THEN 1 ELSE 0 END)  AS sold_abroad
FROM gr_youth_sales s
JOIN gr_clubs c ON s.selling_club_id = c.club_id
GROUP BY c.club_id, c.club_name
ORDER BY total_revenue DESC;

----3.10 Q4: Top 10 youth player sales
SELECT TOP 10
    s.player_name,
    c.club_name AS selling_club,
    s.to_club_name,
    s.transfer_season,
    s.transfer_fee,
    s.destination
FROM gr_youth_sales s
JOIN gr_clubs c ON s.selling_club_id = c.club_id
ORDER BY s.transfer_fee DESC;

/* =========================================================
   Section 4: Preparation for Power BI
   ========================================================= */

----4.1 Add a short display name for clubs (for cleaner dashboard labels)
ALTER TABLE gr_clubs ADD club_short_name NVARCHAR(50);
GO

UPDATE gr_clubs
SET club_short_name =
    CASE
        WHEN club_name LIKE '%Olympiakos%'        THEN 'Olympiacos'
        WHEN club_name LIKE '%Panthessalonikios%' THEN 'PAOK'
        WHEN club_name LIKE '%Panathinaikos%'     THEN 'Panathinaikos'
        WHEN club_name LIKE '%Konstantinoupoleos%' THEN 'AEK'
        WHEN club_name LIKE '%Larisas%'           THEN 'AEL Larissa'
        WHEN club_name LIKE '%Aris%'              THEN 'Aris'
        WHEN club_name LIKE '%Irakliou%'          THEN 'OFI'
        WHEN club_name LIKE '%Niki Volou%' THEN 'Niki Volos'
        WHEN club_name LIKE '%Volou%'             THEN 'Volos'
        WHEN club_name LIKE '%Asteras%'           THEN 'Asteras Tripolis'
        WHEN club_name LIKE '%Levadiakos%'        THEN 'Levadiakos'
        WHEN club_name LIKE '%Atromitos%'         THEN 'Atromitos'
        WHEN club_name LIKE '%Panetolikos%'       THEN 'Panetolikos'  
        WHEN club_name LIKE '%Kifisias%'          THEN 'Kifisia'
        WHEN club_name LIKE '%Lamia%'             THEN 'Lamia'
        WHEN club_name LIKE '%Panionios%'         THEN 'Panionios'
        WHEN club_name LIKE '%Xanthi%'            THEN 'Xanthi'
        WHEN club_name LIKE '%Veria%'             THEN 'Veria'
        WHEN club_name LIKE '%Kerkyra%'           THEN 'Kerkyra'
        WHEN club_name LIKE '%Platanias%'         THEN 'Platanias'
        WHEN club_name LIKE '%Panserraikos%'      THEN 'Panserraikos'
        WHEN club_name LIKE '%Kalloni%'           THEN 'Kalloni'
        WHEN club_name LIKE '%Apollon Smyrnis%'   THEN 'Apollon Smyrnis'
        WHEN club_name LIKE '%Panthrakikos%'      THEN 'Panthrakikos'
        WHEN club_name LIKE '%Ionikos%'           THEN 'Ionikos'
        WHEN club_name LIKE '%Iraklis%'           THEN 'Iraklis'
        ELSE club_name
    END;

----4.2 Review: any club still showing its long official name gets fixed manually
SELECT club_id, club_name, club_short_name
FROM gr_clubs
ORDER BY club_short_name;

----4.3 Data quality check: short names shared by more than one club (expected: no rows)
--     Guards against pattern collisions such as '%Aris%' matching 'Larisas'
SELECT club_short_name, COUNT(*) AS clubs, STRING_AGG(club_name, ' | ') AS full_names
FROM gr_clubs
GROUP BY club_short_name
HAVING COUNT(*) > 1;
