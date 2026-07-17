-- ============================================================
-- 01_territory_pkg.sql — territory_pkg.get_info + get_territory_info
-- PostgreSQL 16 | Комплект проверен на живой базе (тесты T1–T12)
-- Выполнять ВТОРЫМ (после 00_ddl.sql)
-- ============================================================
-- ────────────────────────────────────────────────────────────
-- territory_pkg.get_info
-- Oracle: PROCEDURE get_info(p$id_territory NUMBER, ... 33 OUT)
-- PG:     PROCEDURE с INOUT-параметрами
--
-- Поднимается по иерархии territory от листа к корню (снизу вверх).
-- На каждом шаге:
--   - строит full_adres и short_adres (вставка В НАЧАЛО строки)
--   - вычисляет позиции adr_pos01..10 в full_adres
--   - классифицирует территорию по id_territory_class
--   - берёт первый непустой zip из иерархии
--
-- Oracle: CONNECT BY b.id_territory = PRIOR b.id_parent
-- PG:     WITH RECURSIVE + ORDER BY level_row (обязателен!)
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE PROCEDURE territory_pkg.get_info(
    IN    p$id_territory        BIGINT,
    INOUT p$short_adres         TEXT,
    INOUT p$full_adres          TEXT,
    INOUT p$id_street           BIGINT,
    INOUT p$street_name         TEXT,
    INOUT p$id_street_type      BIGINT,
    INOUT p$street_type_name    TEXT,
    INOUT p$id_city             BIGINT,
    INOUT p$city_name           TEXT,
    INOUT p$id_city_type        BIGINT,
    INOUT p$city_type_name      TEXT,
    INOUT p$id_main_city        BIGINT,
    INOUT p$main_city_name      TEXT,
    INOUT p$id_main_city_type   BIGINT,
    INOUT p$main_city_type_name TEXT,
    INOUT p$id_district         BIGINT,
    INOUT p$district_name       TEXT,
    INOUT p$id_district_type    BIGINT,
    INOUT p$district_type_name  TEXT,
    INOUT p$id_raion            BIGINT,
    INOUT p$raion_name          TEXT,
    INOUT p$id_raion_type       BIGINT,
    INOUT p$raion_type_name     TEXT,
    INOUT p$id_region           BIGINT,
    INOUT p$region_name         TEXT,
    INOUT p$id_region_type      BIGINT,
    INOUT p$region_type_name    TEXT,
    INOUT p$id_country          BIGINT,
    INOUT p$country_name        TEXT,
    INOUT p$id_country_type     BIGINT,
    INOUT p$country_type_name   TEXT,
    INOUT p$adr_pos01           INTEGER,
    INOUT p$adr_pos02           INTEGER,
    INOUT p$adr_pos03           INTEGER,
    INOUT p$adr_pos04           INTEGER,
    INOUT p$adr_pos05           INTEGER,
    INOUT p$adr_pos06           INTEGER,
    INOUT p$adr_pos07           INTEGER,
    INOUT p$adr_pos08           INTEGER,
    INOUT p$adr_pos09           INTEGER,
    INOUT p$adr_pos10           INTEGER,
    INOUT p$zip                 NUMERIC
)
LANGUAGE plpgsql
AS $$
DECLARE
    m$stop_short_adres  BOOLEAN := FALSE;
    m$add_text_len      INTEGER;
    -- Oracle: TYPE t$territory_hierarchy IS TABLE OF VARCHAR2(100) INDEX BY PLS_INTEGER
    -- PG:     TEXT[] с индексами 1..10
    m$hierarchy         TEXT[] := ARRAY[
        '',             -- pos01: не используется
        '',             -- pos02: не используется
        ',2,',          -- pos03: страна
        ',2,3,7,',      -- pos04: страна + регион + район
        ',2,3,7,4,',    -- pos05: + населённый пункт
        '',             -- pos06: не используется
        ',2,3,',        -- pos07: страна + регион
        ',2,3,7,4,5,',  -- pos08: + микрорайон
        '',             -- pos09: не используется
        ''              -- pos10: не используется
    ];
    m$ter RECORD;
BEGIN
    -- Инициализация
    p$adr_pos01 := NULL; p$adr_pos02 := NULL; p$adr_pos03 := NULL;
    p$adr_pos04 := NULL; p$adr_pos05 := NULL; p$adr_pos06 := NULL;
    p$adr_pos07 := NULL; p$adr_pos08 := NULL; p$adr_pos09 := NULL;
    p$adr_pos10 := NULL;
    p$short_adres := NULL;
    p$full_adres  := NULL;

    -- Oracle: FOR m$ter IN (SELECT ... FROM territory b
    --             LEFT JOIN territory_type t ON ...
    --             START WITH b.id_territory = p$id_territory
    --             CONNECT BY b.id_territory = PRIOR b.id_parent)
    -- PG: WITH RECURSIVE, ORDER BY level_row критичен
    --
    -- MERGE-фикс (защита от цикла в иерархии): Oracle CONNECT BY сам ловит цикл
    -- в данных (ORA-01436). У WITH RECURSIVE такой защиты по умолчанию НЕТ, и
    -- циклическая иерархия (id_parent A->B->A -- ошибка ввода оператором)
    -- уводит запрос в настоящий бесконечный цикл, вешая backend. Используем
    -- нативную для PostgreSQL 14+ конструкцию CYCLE: она помечает первую
    -- повторно встреченную территорию (is_cycle=TRUE) и НЕ разворачивает её
    -- дальше -- рекурсия гарантированно конечна. Ниже такие строки
    -- отфильтровываются (WHERE NOT is_cycle), а факт обнаружения цикла
    -- логируется через RAISE WARNING (адрес при этом собирается частично).
    FOR m$ter IN (
        WITH RECURSIVE hier AS (
            SELECT b.id_territory, b.id_territory_class, b.id_territory_type,
                   b.id_parent, b.name, b.zip, 1 AS level_row
            FROM territory b
            WHERE b.id_territory = p$id_territory
            UNION ALL
            SELECT b.id_territory, b.id_territory_class, b.id_territory_type,
                   b.id_parent, b.name, b.zip, h.level_row + 1
            FROM territory b
            JOIN hier h ON b.id_territory = h.id_parent
        ) CYCLE id_territory SET is_cycle USING cycle_path
        SELECT
            h.id_territory, h.id_territory_class, h.id_territory_type,
            h.name, h.zip, h.level_row, h.is_cycle,
            -- Oracle: NVL2(t.short_name, t.short_name || CASE ... END || ' ', NULL)
            CASE WHEN t.short_name IS NOT NULL THEN
                t.short_name ||
                CASE WHEN RIGHT(TRIM(t.short_name), 1) = '.'
                          OR t.short_name LIKE '%-%'
                     THEN '' ELSE '.' END || ' '
            ELSE NULL END AS prefix,
            -- Oracle: NVL(t.short_name, t.name)
            COALESCE(t.short_name, t.name) AS territory_type_name
        FROM hier h
        LEFT JOIN territory_type t
            ON t.id_territory_class = h.id_territory_class
           AND t.id_territory_type  = h.id_territory_type
        ORDER BY h.level_row
    )
    LOOP
        -- Обнаружен цикл в иерархии territory: строка-маркер (та же территория,
        -- встреченная повторно) в адрес не входит -- пропускаем и предупреждаем.
        IF m$ter.is_cycle THEN
            RAISE WARNING 'territory_pkg.get_info(%): цикл в иерархии territory на территории % (id_parent -> ... -> сам на себя). Адрес собран частично.',
                p$id_territory, m$ter.id_territory;
            CONTINUE;
        END IF;
        -- Oracle: p$full_adres := m$ter.prefix || m$ter.name || ', ' || p$full_adres
        -- ВАЖНО: COALESCE(p$full_adres,'') — в PG NULL || text = NULL
        p$full_adres   := COALESCE(m$ter.prefix, '') || m$ter.name || ', '
                          || COALESCE(p$full_adres, '');
        m$add_text_len := length(COALESCE(m$ter.prefix, '') || m$ter.name || ', ');

        -- Активируем позиции adr_posXX при первом совпадении класса
        IF p$adr_pos01 IS NULL AND m$hierarchy[1]  LIKE '%,' || m$ter.id_territory_class::TEXT || ',%' THEN p$adr_pos01 := 1; END IF;
        IF p$adr_pos02 IS NULL AND m$hierarchy[2]  LIKE '%,' || m$ter.id_territory_class::TEXT || ',%' THEN p$adr_pos02 := 1; END IF;
        IF p$adr_pos03 IS NULL AND m$hierarchy[3]  LIKE '%,' || m$ter.id_territory_class::TEXT || ',%' THEN p$adr_pos03 := 1; END IF;
        IF p$adr_pos04 IS NULL AND m$hierarchy[4]  LIKE '%,' || m$ter.id_territory_class::TEXT || ',%' THEN p$adr_pos04 := 1; END IF;
        IF p$adr_pos05 IS NULL AND m$hierarchy[5]  LIKE '%,' || m$ter.id_territory_class::TEXT || ',%' THEN p$adr_pos05 := 1; END IF;
        IF p$adr_pos06 IS NULL AND m$hierarchy[6]  LIKE '%,' || m$ter.id_territory_class::TEXT || ',%' THEN p$adr_pos06 := 1; END IF;
        IF p$adr_pos07 IS NULL AND m$hierarchy[7]  LIKE '%,' || m$ter.id_territory_class::TEXT || ',%' THEN p$adr_pos07 := 1; END IF;
        IF p$adr_pos08 IS NULL AND m$hierarchy[8]  LIKE '%,' || m$ter.id_territory_class::TEXT || ',%' THEN p$adr_pos08 := 1; END IF;
        IF p$adr_pos09 IS NULL AND m$hierarchy[9]  LIKE '%,' || m$ter.id_territory_class::TEXT || ',%' THEN p$adr_pos09 := 1; END IF;
        IF p$adr_pos10 IS NULL AND m$hierarchy[10] LIKE '%,' || m$ter.id_territory_class::TEXT || ',%' THEN p$adr_pos10 := 1; END IF;

        -- Сдвигаем активированные позиции на длину добавленной части
        IF p$adr_pos01 IS NOT NULL THEN p$adr_pos01 := p$adr_pos01 + m$add_text_len; END IF;
        IF p$adr_pos02 IS NOT NULL THEN p$adr_pos02 := p$adr_pos02 + m$add_text_len; END IF;
        IF p$adr_pos03 IS NOT NULL THEN p$adr_pos03 := p$adr_pos03 + m$add_text_len; END IF;
        IF p$adr_pos04 IS NOT NULL THEN p$adr_pos04 := p$adr_pos04 + m$add_text_len; END IF;
        IF p$adr_pos05 IS NOT NULL THEN p$adr_pos05 := p$adr_pos05 + m$add_text_len; END IF;
        IF p$adr_pos06 IS NOT NULL THEN p$adr_pos06 := p$adr_pos06 + m$add_text_len; END IF;
        IF p$adr_pos07 IS NOT NULL THEN p$adr_pos07 := p$adr_pos07 + m$add_text_len; END IF;
        IF p$adr_pos08 IS NOT NULL THEN p$adr_pos08 := p$adr_pos08 + m$add_text_len; END IF;
        IF p$adr_pos09 IS NOT NULL THEN p$adr_pos09 := p$adr_pos09 + m$add_text_len; END IF;
        IF p$adr_pos10 IS NOT NULL THEN p$adr_pos10 := p$adr_pos10 + m$add_text_len; END IF;

        -- short_adres строится только до первого нас. пункта (class=4)
        IF NOT m$stop_short_adres THEN
            p$short_adres := COALESCE(m$ter.prefix, '') || m$ter.name || ', '
                             || COALESCE(p$short_adres, '');
        END IF;

        -- Классификация по id_territory_class
        IF m$ter.id_territory_class = 8 THEN          -- улица
            IF p$id_street IS NULL THEN
                p$id_street        := m$ter.id_territory;
                p$street_name      := m$ter.name;
                p$id_street_type   := m$ter.id_territory_type;
                p$street_type_name := m$ter.territory_type_name;
            END IF;
        ELSIF m$ter.id_territory_class = 5 THEN        -- внутригородской район
            IF p$id_district IS NULL THEN
                p$id_district        := m$ter.id_territory;
                p$district_name      := m$ter.name;
                p$id_district_type   := m$ter.id_territory_type;
                p$district_type_name := m$ter.territory_type_name;
            END IF;
        ELSIF m$ter.id_territory_class = 4 THEN        -- нас. пункт
            IF p$id_city IS NULL THEN
                p$id_city        := m$ter.id_territory;
                p$city_name      := m$ter.name;
                p$id_city_type   := m$ter.id_territory_type;
                p$city_type_name := m$ter.territory_type_name;
                m$stop_short_adres := TRUE;
            ELSE
                -- второй нас. пункт = главный
                -- Пример: city=Верхняя Максаковка, main_city=Сыктывкар
                p$id_main_city        := m$ter.id_territory;
                p$main_city_name      := m$ter.name;
                p$id_main_city_type   := m$ter.id_territory_type;
                p$main_city_type_name := m$ter.territory_type_name;
            END IF;
        ELSIF m$ter.id_territory_class = 7 THEN        -- район
            IF p$id_raion IS NULL THEN
                p$id_raion        := m$ter.id_territory;
                p$raion_name      := m$ter.name;
                p$id_raion_type   := m$ter.id_territory_type;
                p$raion_type_name := m$ter.territory_type_name;
            END IF;
        ELSIF m$ter.id_territory_class = 3 THEN        -- регион
            IF p$id_region IS NULL THEN
                p$id_region        := m$ter.id_territory;
                p$region_name      := m$ter.name;
                p$id_region_type   := m$ter.id_territory_type;
                p$region_type_name := m$ter.territory_type_name;
            END IF;
        ELSIF m$ter.id_territory_class = 2 THEN        -- страна
            IF p$id_country IS NULL THEN
                p$id_country        := m$ter.id_territory;
                p$country_name      := m$ter.name;
                p$id_country_type   := m$ter.id_territory_type;
                p$country_type_name := m$ter.territory_type_name;
            END IF;
        END IF;

        -- первый непустой zip из иерархии
        IF p$zip IS NULL THEN
            p$zip := m$ter.zip;
        END IF;
    END LOOP;

    -- Oracle: p$adr_posXX := NVL(p$adr_posXX, 0)
    p$adr_pos01 := COALESCE(p$adr_pos01, 0);
    p$adr_pos02 := COALESCE(p$adr_pos02, 0);
    p$adr_pos03 := COALESCE(p$adr_pos03, 0);
    p$adr_pos04 := COALESCE(p$adr_pos04, 0);
    p$adr_pos05 := COALESCE(p$adr_pos05, 0);
    p$adr_pos06 := COALESCE(p$adr_pos06, 0);
    p$adr_pos07 := COALESCE(p$adr_pos07, 0);
    p$adr_pos08 := COALESCE(p$adr_pos08, 0);
    p$adr_pos09 := COALESCE(p$adr_pos09, 0);
    p$adr_pos10 := COALESCE(p$adr_pos10, 0);
END;
$$;


-- ────────────────────────────────────────────────────────────
-- get_territory_info(p$id_territory) → territory_info_type
-- Обёртка над territory_pkg.get_info — аналог Oracle GetTerritoryInfo.sql
-- Принимает 1 аргумент, возвращает составной тип вместо 27 OUT-параметров
-- "Лишние" OUT (типы территорий, страна) отбрасываются в локальные переменные
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.get_territory_info(p$id_territory BIGINT)
RETURNS public.territory_info_type
LANGUAGE plpgsql
AS $$
DECLARE
    m$result                public.territory_info_type;
    m$id_street_type        BIGINT;  m$street_type_name      TEXT;
    m$id_city_type          BIGINT;  m$city_type_name        TEXT;
    m$id_main_city_type     BIGINT;  m$main_city_type_name   TEXT;
    m$id_district_type      BIGINT;  m$district_type_name    TEXT;
    m$id_raion_type         BIGINT;  m$raion_type_name       TEXT;
    m$id_region_type        BIGINT;  m$region_type_name      TEXT;
    m$id_country            BIGINT;  m$country_name          TEXT;
    m$id_country_type       BIGINT;  m$country_type_name     TEXT;
BEGIN
    CALL territory_pkg.get_info(
        p$id_territory,
        m$result.short_adres,       m$result.full_adres,
        m$result.id_street,         m$result.street_name,       m$id_street_type,       m$street_type_name,
        m$result.id_city,           m$result.city_name,         m$id_city_type,         m$city_type_name,
        m$result.id_main_city,      m$result.main_city_name,    m$id_main_city_type,    m$main_city_type_name,
        m$result.id_district,       m$result.district_name,     m$id_district_type,     m$district_type_name,
        m$result.id_raion,          m$result.raion_name,        m$id_raion_type,        m$raion_type_name,
        m$result.id_region,         m$result.region_name,       m$id_region_type,       m$region_type_name,
        m$id_country,               m$country_name,             m$id_country_type,      m$country_type_name,
        m$result.adr_pos01,         m$result.adr_pos02,         m$result.adr_pos03,
        m$result.adr_pos04,         m$result.adr_pos05,         m$result.adr_pos06,
        m$result.adr_pos07,         m$result.adr_pos08,         m$result.adr_pos09,
        m$result.adr_pos10,         m$result.zip
    );
    RETURN m$result;
END;
$$;
