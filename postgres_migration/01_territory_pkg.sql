-- =============================================================================================
-- 01_territory_pkg.sql
-- Схема territory_pkg -- сборка адреса объекта по иерархии ba7_data.territory.
--
-- Аналог Oracle territory_pkg.get_info + GetTerritoryInfo. В Oracle это были две сущности:
-- territory_pkg.get_info возвращал полный набор полей (включая id/название *_type для каждого
-- уровня), а GetTerritoryInfo была тонкой оберткой поверх него, отдающей наружу только то
-- подмножество, что реально нужно object_info_pkg (без *_type). Здесь они объединены в одну
-- функцию сразу с "урезанным" (GetTerritoryInfo-совместимым) набором полей -- лишней сущности
-- без дополнительного смысла не заводим.
-- =============================================================================================

CREATE TYPE territory_pkg.territory_info_type AS (
    short_adres      VARCHAR(100),
    full_adres       VARCHAR(1000),
    id_street        BIGINT,
    street_name      VARCHAR(200),
    id_city          BIGINT,
    city_name        VARCHAR(200),
    id_main_city     BIGINT,
    main_city_name   VARCHAR(200),
    id_district      BIGINT,
    district_name    VARCHAR(200),
    id_raion         BIGINT,
    raion_name       VARCHAR(200),
    id_region        BIGINT,
    region_name      VARCHAR(200),
    adr_pos01 INT, adr_pos02 INT, adr_pos03 INT, adr_pos04 INT, adr_pos05 INT,
    adr_pos06 INT, adr_pos07 INT, adr_pos08 INT, adr_pos09 INT, adr_pos10 INT,
    zip              NUMERIC(10)
);

-- -----------------------------------------------------------------------------------------------
-- territory_pkg.get_info(p_id_territory)
--
-- Обходит иерархию territory от заданной территории (лист) вверх до корня по id_parent и собирает:
--   * full_adres  -- полный адрес "страна, регион, ..., улица" (от корня к листу);
--   * short_adres -- то же самое, но обрывается на первом встреченном населённом пункте (id_territory
--     _class = 4), т.е. без региона/страны сверху;
--   * id/название street(8) / district(5, внутригородской район) / city(4) / main_city(второй по
--     счёту класс 4 -- случай вложенных нас.пунктов, например main_city=Сыктывкар, city=Максаковка)
--     / raion(7) / region(3);
--   * adr_pos01..adr_pos10 -- позиции в full_adres, с которых начинается адрес соответствующего
--     уровня (см. комментарий у m_hierarchy ниже);
--   * zip -- первый непустой почтовый индекс на пути от листа к корню.
--
-- Направление обхода и порядок вычислений внутри итерации -- один в один как в territory_pkg.body.sql
-- (Oracle), только CONNECT BY заменён на WITH RECURSIVE, а PL/SQL-таблица m$territory_hierarchy --
-- массивом INT[] (семантически то же самое: множество классов-предков, при первом попадании в
-- которое фиксируется текущая граница строки).
-- -----------------------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION territory_pkg.get_info(p_id_territory BIGINT)
RETURNS territory_pkg.territory_info_type
LANGUAGE plpgsql
AS $$
DECLARE
    r                    territory_pkg.territory_info_type;
    m_stop_short_adres   BOOLEAN := FALSE;
    m_add_text_len       INT;
    m_ter                RECORD;
    i                    INT;
    -- Для каждой позиции adr_pos01..10 -- набор классов территорий-предков, при первом попадании в
    -- которые (считая от листа к корню) фиксируется текущая граница full_adres. Индексы 1,2,6,9,10
    -- не используются (пустые списки -- никогда не триггерятся), как и в Oracle-оригинале. Формат
    -- строки -- ",class1,class2,...," -- повторяет исходный приём из territory_pkg.body.sql (там
    -- это была PL/SQL-таблица VARCHAR2, тут -- обычный TEXT[], т.к. PostgreSQL не допускает "рваных"
    -- многомерных массивов, а заводить 10 отдельных переменных было бы менее наглядно).
    m_hierarchy          TEXT[] := ARRAY[
        '',                  -- 1
        '',                  -- 2
        ',2,',               -- 3  (регион: граница сразу после страны)
        ',2,3,7,',           -- 4  (нас.пункт: граница после страны/региона/района)
        ',2,3,7,4,',         -- 5  (внутригородской район: граница после ... + нас.пункта)
        '',                  -- 6
        ',2,3,',             -- 7  (район: граница после страны/региона)
        ',2,3,7,4,5,',       -- 8  (улица: граница после всего вышестоящего)
        '',                  -- 9
        ''                   -- 10
    ];
    m_pos                INT[] := ARRAY[NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL]::INT[];
BEGIN
    FOR m_ter IN
        WITH RECURSIVE terr AS (
            SELECT b.id_territory, b.name, b.id_territory_class, b.id_territory_type, b.zip,
                   b.id_parent, 1 AS level_row
            FROM ba7_data.territory b
            WHERE b.id_territory = p_id_territory
            UNION ALL
            SELECT b.id_territory, b.name, b.id_territory_class, b.id_territory_type, b.zip,
                   b.id_parent, t.level_row + 1
            FROM ba7_data.territory b
            JOIN terr t ON b.id_territory = t.id_parent
        )
        SELECT t.id_territory, t.name, t.id_territory_class, t.zip, t.level_row,
               -- Префикс из краткого названия типа территории ("ул.", "г.", ...), с точкой на конце,
               -- если это не аббревиатура через дефис и точки там ещё нет.
               CASE WHEN tt.short_name IS NOT NULL
                    THEN tt.short_name
                        || CASE WHEN RIGHT(TRIM(tt.short_name), 1) = '.' OR tt.short_name LIKE '%-%'
                                THEN '' ELSE '.' END
                        || ' '
                    ELSE NULL END AS prefix
        FROM terr t
        LEFT JOIN ba7_data.territory_type tt
               ON tt.id_territory_class = t.id_territory_class AND tt.id_territory_type = t.id_territory_type
        ORDER BY t.level_row
    LOOP
        r.full_adres := COALESCE(m_ter.prefix, '') || m_ter.name || ', ' || COALESCE(r.full_adres, '');
        m_add_text_len := LENGTH(COALESCE(m_ter.prefix, '') || m_ter.name || ', ');

        FOR i IN 1..10 LOOP
            IF m_pos[i] IS NULL AND m_hierarchy[i] LIKE '%,' || m_ter.id_territory_class || ',%' THEN
                m_pos[i] := 1;
            END IF;
        END LOOP;
        FOR i IN 1..10 LOOP
            IF m_pos[i] IS NOT NULL THEN
                m_pos[i] := m_pos[i] + m_add_text_len;
            END IF;
        END LOOP;

        IF NOT m_stop_short_adres THEN
            r.short_adres := COALESCE(m_ter.prefix, '') || m_ter.name || ', ' || COALESCE(r.short_adres, '');
        END IF;

        IF m_ter.id_territory_class = 8 THEN                    -- улица
            IF r.id_street IS NULL THEN
                r.id_street := m_ter.id_territory;
                r.street_name := m_ter.name;
            END IF;

        ELSIF m_ter.id_territory_class = 5 THEN                 -- внутригородской район
            IF r.id_district IS NULL THEN
                r.id_district := m_ter.id_territory;
                r.district_name := m_ter.name;
            END IF;

        ELSIF m_ter.id_territory_class = 4 THEN                 -- населённый пункт
            IF r.id_city IS NULL THEN
                r.id_city := m_ter.id_territory;
                r.city_name := m_ter.name;
                m_stop_short_adres := TRUE;
            ELSE
                -- Вложенный населённый пункт (например main_city=Сыктывкар, city=Верхняя Максаковка).
                r.id_main_city := m_ter.id_territory;
                r.main_city_name := m_ter.name;
            END IF;

        ELSIF m_ter.id_territory_class = 7 THEN                 -- район
            IF r.id_raion IS NULL THEN
                r.id_raion := m_ter.id_territory;
                r.raion_name := m_ter.name;
            END IF;

        ELSIF m_ter.id_territory_class = 3 THEN                 -- регион/область/республика
            IF r.id_region IS NULL THEN
                r.id_region := m_ter.id_territory;
                r.region_name := m_ter.name;
            END IF;
        END IF;

        IF r.zip IS NULL THEN
            r.zip := m_ter.zip;
        END IF;
    END LOOP;

    r.adr_pos01 := COALESCE(m_pos[1], 0);
    r.adr_pos02 := COALESCE(m_pos[2], 0);
    r.adr_pos03 := COALESCE(m_pos[3], 0);
    r.adr_pos04 := COALESCE(m_pos[4], 0);
    r.adr_pos05 := COALESCE(m_pos[5], 0);
    r.adr_pos06 := COALESCE(m_pos[6], 0);
    r.adr_pos07 := COALESCE(m_pos[7], 0);
    r.adr_pos08 := COALESCE(m_pos[8], 0);
    r.adr_pos09 := COALESCE(m_pos[9], 0);
    r.adr_pos10 := COALESCE(m_pos[10], 0);

    RETURN r;
END;
$$;

-- TODO: аналог scheming_pkg.group_synonym/group_privs -- регистрация синонима territory_pkg и прав
-- EXECUTE для схем-потребителей (TEST_OWNER/TEST_OWNER_ROLE в Oracle-оригинале).
-- GRANT USAGE ON SCHEMA territory_pkg TO test_owner_role;
-- GRANT EXECUTE ON FUNCTION territory_pkg.get_info(BIGINT) TO test_owner_role;
