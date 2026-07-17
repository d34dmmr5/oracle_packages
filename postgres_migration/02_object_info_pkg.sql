-- ============================================================
-- 02c_object_info_pkg_transition.sql — пакет object_info_pkg
-- PostgreSQL 16 | ВАРИАНТ C: transition tables
-- Комплект проверен на живой базе (тесты T1–T12)
-- Выполнять ТРЕТЬИМ (после 00_ddl.sql и 01_territory_pkg.sql)
--
-- Архитектура: никакого накопления состояния между триггерами.
-- AFTER STATEMENT триггеры получают ВСЕ строки команды разом через
-- REFERENCING NEW/OLD TABLE (transition tables, PG 10+) и сразу
-- обрабатывают их. GUC/set_config для очередей не используется.
--
-- Поэтому из Oracle-пакета НЕ переносятся (потеряли смысл):
--   init(), add_object_insert/update/delete(), add_territory_update()
--   update_object_info() без параметров
-- Они существовали только чтобы обойти отсутствие transition tables
-- в Oracle 10g/11g: AFTER ROW копил ID в пакетную переменную,
-- AFTER STATEMENT обрабатывал накопленное. PostgreSQL отдаёт набор
-- изменённых строк напрямую — паттерн "накопить-обработать" не нужен.
--
-- Ручные точки входа сохранены:
--   update_object_info(BIGINT[], TEXT)  — список id
--   update_object_info(BIGINT,  TEXT)   — один id
--   update_object_info(object_row_type, TEXT) — готовая строка
--   update_object_info_territories(BIGINT[])  — пересчёт поддеревьев
-- ============================================================

-- ============================================================
-- get_version / format_object_no — без изменений (нет состояния)
-- ============================================================
CREATE OR REPLACE FUNCTION object_info_pkg.get_version()
RETURNS TEXT
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN '10';
END;
$$;

CREATE OR REPLACE FUNCTION object_info_pkg.format_object_no(
    p$object_no     TEXT,
    p$numeric_len   INTEGER
)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    m$nonnumeric    TEXT;
    m$index         INTEGER;
    m$object_no     TEXT;
BEGIN
    m$nonnumeric := translate(TRIM(p$object_no) || ',', '1234567890', '          ');
    m$index := strpos(m$nonnumeric, TRIM(m$nonnumeric));
    m$object_no := COALESCE(
        lpad(TRIM(p$object_no), length(TRIM(p$object_no)) + p$numeric_len - m$index),
        '    '
    );
    IF TRIM(m$object_no) <> TRIM(p$object_no) THEN
        m$object_no := p$object_no;
    END IF;
    RETURN m$object_no;
END;
$$;



-- ────────────────────────────────────────────────────────────
-- update_object_info_territories(p$id_territory_list)
-- Пересчёт всех объектов в поддеревьях указанных территорий.
-- Вызывается AFTER STATEMENT триггером territory (массив собирается
-- из transition table) и доступна как ручной API.
--
-- Oracle: territory-блок update_object_info() без параметров:
--   WITH terr AS (... START WITH ... CONNECT BY PRIOR
--                 b.id_territory = b.id_parent)  -- спуск вниз
--   SELECT DISTINCT id_object FROM object
--   WHERE id_territory IN (...) UNION ... id_territory2 IN (...)
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE PROCEDURE object_info_pkg.update_object_info_territories(
    p$id_territory_list BIGINT[]
)
LANGUAGE plpgsql
AS $$
DECLARE
    m$obj RECORD;
BEGIN
    IF p$id_territory_list IS NULL OR cardinality(p$id_territory_list) = 0 THEN
        RETURN;
    END IF;

    -- MERGE-фикс (защита от цикла): этот НИСХОДЯЩИЙ обход (потомки изменённой
    -- территории) на UNION ALL так же уязвим к циклу в иерархии, как и
    -- восходящий в get_info -- и именно он вешал backend при UPDATE territory,
    -- замыкающем цикл (триггер на territory зовёт эту процедуру). Нативная
    -- конструкция CYCLE (PostgreSQL 14+) останавливает рекурсию на первой
    -- повторно встреченной территории; строки-маркеры отфильтровываются
    -- (WHERE NOT is_cycle).
    FOR m$obj IN (
        WITH RECURSIVE terr AS (
            SELECT id_territory FROM territory
            WHERE id_territory = ANY(p$id_territory_list)
            UNION ALL
            SELECT t.id_territory
            FROM territory t
            JOIN terr ON t.id_parent = terr.id_territory
        ) CYCLE id_territory SET is_cycle USING cycle_path
        SELECT DISTINCT id_object FROM object
        WHERE id_territory IN (SELECT id_territory FROM terr WHERE NOT is_cycle)
        UNION
        SELECT id_object FROM object
        WHERE id_territory2 IN (SELECT id_territory FROM terr WHERE NOT is_cycle)
    )
    LOOP
        CALL object_info_pkg.update_object_info(m$obj.id_object, 'update');
    END LOOP;
END;
$$;


-- ────────────────────────────────────────────────────────────
-- update_object_info(list, action) — итерация по массиву
-- Oracle: FOR obj IN TABLE(p$id_object_list) LOOP ... END LOOP
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE PROCEDURE object_info_pkg.update_object_info(
    p$id_object_list    BIGINT[],
    p$action            TEXT
)
LANGUAGE plpgsql
AS $$
DECLARE
    m$id_object BIGINT;
BEGIN
    FOREACH m$id_object IN ARRAY p$id_object_list
    LOOP
        CALL object_info_pkg.update_object_info(m$id_object, p$action);
    END LOOP;
END;
$$;


-- ────────────────────────────────────────────────────────────
-- update_object_info(id, action) — SELECT по одному объекту
-- (логика идентична версии с temp-таблицами — состояние здесь не нужно)
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE PROCEDURE object_info_pkg.update_object_info(
    p$id_object BIGINT,
    p$action    TEXT
)
LANGUAGE plpgsql
AS $$
DECLARE
    m$object object_info_pkg.object_row_type;
BEGIN
    BEGIN
        SELECT
            id_object,
            id_territory, dom, building_no, kw,
            id_territory2, dom2, building_no2,
            id_object_class, id_object_type, sq_all,
            object_name, id_entity_instance, trace_info,
            addressing_mode, id_object_house, id_house_doorway,
            zip, object_no, volume, sq_life, room_no
        INTO STRICT
            m$object.id_object,
            m$object.id_territory, m$object.dom, m$object.building_no, m$object.kw,
            m$object.id_territory2, m$object.dom2, m$object.building_no2,
            m$object.id_object_class, m$object.id_object_type, m$object.sq_all,
            m$object.object_name, m$object.id_entity_instance, m$object.trace_info,
            m$object.addressing_mode, m$object.id_object_house, m$object.id_house_doorway,
            m$object.zip, m$object.object_no, m$object.volume, m$object.sq_life, m$object.room_no
        FROM object
        WHERE id_object = p$id_object;
    EXCEPTION WHEN NO_DATA_FOUND THEN
        RAISE EXCEPTION 'Объект с id_object = % не найден', p$id_object
            USING ERRCODE = 'P0001';
    END;

    CALL object_info_pkg.update_object_info(m$object, p$action);
END;
$$;


-- ────────────────────────────────────────────────────────────
-- update_object_info(object_row_type, action) — основная логика
-- (без изменений относительно temp-table версии — состояние здесь не используется)
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE PROCEDURE object_info_pkg.update_object_info(
    p$object    object_info_pkg.object_row_type,
    p$action    TEXT
)
LANGUAGE plpgsql
AS $$
DECLARE
    m$type_name         TEXT;
    m$object_address    TEXT;
    m$ti                public.territory_info_type;
    m$ti2               public.territory_info_type;
    m$zip               NUMERIC;
BEGIN
    IF LOWER(p$action) = 'delete' THEN
        DELETE FROM object_info_tbl WHERE id_object = p$object.id_object;
        RETURN;
    END IF;
    -- Oracle: SELECT name INTO — при отсутствии типа кидает NO_DATA_FOUND.
    -- В PL/pgSQL для той же семантики обязателен STRICT (иначе молча NULL).
    SELECT name INTO STRICT m$type_name
    FROM object_type
    WHERE id_object_class = p$object.id_object_class
      AND id_object_type  = p$object.id_object_type;

    IF p$object.id_territory IS NOT NULL THEN
        m$ti := public.get_territory_info(p$object.id_territory);

        -- MERGE-фикс (осиротевшая ссылка на территорию): при включённых FK
        -- недостижимо через саму БД, но реально при массовой заливке с временно
        -- отключёнными проверками. get_territory_info вернёт полностью пустой
        -- (NULL) результат -- без COALESCE ниже одно NULL-поле "заражает" весь
        -- адрес (в PG NULL || text = NULL), обнуляя даже уже собранную часть.
        IF m$ti.full_adres IS NULL THEN
            RAISE WARNING 'update_object_info: объект % ссылается на несуществующую территорию (id_territory=%)',
                p$object.id_object, p$object.id_territory;
        END IF;

        -- COALESCE(TRIM(dom),'') -- защита от NULL-номера дома (реальный ввод
        -- человеком: дом без номера). В Oracle || трактует NULL как пустую
        -- строку, в PG -- нет, поэтому здесь это делаем явно.
        m$object_address := 'д.' || COALESCE(TRIM(p$object.dom), '');

        IF p$object.building_no IS NOT NULL THEN
            m$object_address := m$object_address || ' корп. ' || TRIM(p$object.building_no);
        END IF;

        IF p$object.id_object_class = 10 THEN
            m$object_address := m$object_address || ' подъезд ' || COALESCE(TRIM(p$object.object_no::TEXT), '');
        END IF;

        IF p$object.kw IS NOT NULL THEN
            IF p$object.id_object_class = 11 THEN
                m$object_address := m$object_address
                    || ' кв. ' || TRIM(p$object.kw)
                    || ' ' || COALESCE(m$type_name, '')
                    || ' ' || COALESCE(TRIM(p$object.room_no), '');
            ELSE
                m$object_address := m$object_address
                    || ' ' || COALESCE(m$type_name, '')
                    || ' ' || TRIM(p$object.kw);
            END IF;
        END IF;

        m$ti.short_adres := COALESCE(m$ti.short_adres, '') || m$object_address;
        m$ti.full_adres  := COALESCE(m$ti.full_adres, '')  || m$object_address;
    END IF;

    IF p$object.id_territory2 IS NOT NULL THEN
        m$ti2 := public.get_territory_info(p$object.id_territory2);

        IF m$ti2.full_adres IS NULL THEN
            RAISE WARNING 'update_object_info: объект % ссылается на несуществующую альтернативную территорию (id_territory2=%)',
                p$object.id_object, p$object.id_territory2;
        END IF;

        m$object_address := 'д.' || COALESCE(TRIM(p$object.dom2), '');

        IF p$object.building_no2 IS NOT NULL THEN
            -- MERGE-фикс: в Oracle-оригинале building_no2 добавлялся ДВАЖДЫ
            -- ('корп. Б корп. Б') -- это баг копипаста (в основном адресе он
            -- добавляется один раз). Здесь исправлено на однократное добавление.
            -- Если для downstream-потребителей нужна бит-в-бит совместимость с
            -- Oracle-выхлопом -- продублируйте эту строку.
            m$object_address := m$object_address || ' корп. ' || TRIM(p$object.building_no2);
        END IF;

        IF p$object.id_object_class = 10 THEN
            m$object_address := m$object_address || ' подъезд ' || COALESCE(TRIM(p$object.object_no::TEXT), '');
        END IF;

        IF p$object.kw IS NOT NULL THEN
            IF p$object.id_object_class = 11 THEN
                m$object_address := m$object_address
                    || ' кв. ' || TRIM(p$object.kw)
                    || ' ' || COALESCE(m$type_name, '')
                    || ' ' || COALESCE(TRIM(p$object.room_no), '');
            ELSE
                m$object_address := m$object_address
                    || ' ' || COALESCE(m$type_name, '')
                    || ' ' || TRIM(p$object.kw);
            END IF;
        END IF;

        m$ti2.short_adres := COALESCE(m$ti2.short_adres, '') || m$object_address;
        m$ti2.full_adres  := COALESCE(m$ti2.full_adres, '')  || m$object_address;
    END IF;

    m$zip := COALESCE(p$object.zip, m$ti.zip);

    IF LOWER(p$action) = 'insert' THEN
        INSERT INTO object_info_tbl (
            id_object, id_territory, id_street, house, building_no, flat,
            id_object_class, id_object_type, sq_all,
            adres, full_adres,
            street_name, object_name, city_name, id_raion, raion_name, id_city,
            id_entity_instance, type_name, trace_info,
            adr_pos01, adr_pos02, adr_pos03, adr_pos04, adr_pos05,
            adr_pos06, adr_pos07, adr_pos08, adr_pos09, adr_pos10,
            id_territory2, id_street2, house2, building_no2,
            adres2, full_adres2,
            street_name2, city_name2, id_raion2, raion_name2, id_city2,
            is_exist_alternate_adres,
            addressing_mode, id_house_doorway, id_object_house,
            id_main_city, main_city_name, id_district, district_name,
            id_region, region_name, zip,
            object_no, volume, sq_life, room_no
        ) VALUES (
            p$object.id_object, p$object.id_territory, m$ti.id_street,
            p$object.dom, p$object.building_no, p$object.kw,
            p$object.id_object_class, p$object.id_object_type, p$object.sq_all,
            m$ti.short_adres, m$ti.full_adres,
            COALESCE(m$ti.street_name, ' '), p$object.object_name, m$ti.city_name,
            m$ti.id_raion, m$ti.raion_name, m$ti.id_city,
            p$object.id_entity_instance, m$type_name, p$object.trace_info,
            m$ti.adr_pos01, m$ti.adr_pos02, m$ti.adr_pos03, m$ti.adr_pos04, m$ti.adr_pos05,
            m$ti.adr_pos06, m$ti.adr_pos07, m$ti.adr_pos08, m$ti.adr_pos09, m$ti.adr_pos10,
            p$object.id_territory2, m$ti2.id_street, p$object.dom2, p$object.building_no2,
            m$ti2.short_adres, m$ti2.full_adres,
            COALESCE(m$ti2.street_name, ' '), m$ti2.city_name,
            m$ti2.id_raion, m$ti2.raion_name, m$ti2.id_city,
            CASE WHEN p$object.id_territory2 IS NOT NULL THEN 1 ELSE 0 END,
            p$object.addressing_mode, p$object.id_house_doorway, p$object.id_object_house,
            m$ti.id_main_city, m$ti.main_city_name, m$ti.id_district, m$ti.district_name,
            m$ti.id_region, m$ti.region_name, m$zip,
            p$object.object_no, p$object.volume, p$object.sq_life, p$object.room_no
        );
    END IF;

    IF LOWER(p$action) = 'update' THEN
        UPDATE object_info_tbl SET
            id_street       = m$ti.id_street,
            id_territory    = p$object.id_territory,
            house           = p$object.dom,
            building_no     = p$object.building_no,
            flat            = p$object.kw,
            id_object_class = p$object.id_object_class,
            id_object_type  = p$object.id_object_type,
            sq_all          = p$object.sq_all,
            adres           = m$ti.short_adres,
            full_adres      = m$ti.full_adres,
            adr_pos01 = CASE WHEN p$object.id_territory IS NOT NULL THEN m$ti.adr_pos01 ELSE adr_pos01 END,
            adr_pos02 = CASE WHEN p$object.id_territory IS NOT NULL THEN m$ti.adr_pos02 ELSE adr_pos02 END,
            adr_pos03 = CASE WHEN p$object.id_territory IS NOT NULL THEN m$ti.adr_pos03 ELSE adr_pos03 END,
            adr_pos04 = CASE WHEN p$object.id_territory IS NOT NULL THEN m$ti.adr_pos04 ELSE adr_pos04 END,
            adr_pos05 = CASE WHEN p$object.id_territory IS NOT NULL THEN m$ti.adr_pos05 ELSE adr_pos05 END,
            adr_pos06 = CASE WHEN p$object.id_territory IS NOT NULL THEN m$ti.adr_pos06 ELSE adr_pos06 END,
            adr_pos07 = CASE WHEN p$object.id_territory IS NOT NULL THEN m$ti.adr_pos07 ELSE adr_pos07 END,
            adr_pos08 = CASE WHEN p$object.id_territory IS NOT NULL THEN m$ti.adr_pos08 ELSE adr_pos08 END,
            adr_pos09 = CASE WHEN p$object.id_territory IS NOT NULL THEN m$ti.adr_pos09 ELSE adr_pos09 END,
            adr_pos10 = CASE WHEN p$object.id_territory IS NOT NULL THEN m$ti.adr_pos10 ELSE adr_pos10 END,
            street_name         = COALESCE(m$ti.street_name, ' '),
            object_name         = p$object.object_name,
            city_name           = m$ti.city_name,
            id_raion            = m$ti.id_raion,
            raion_name          = m$ti.raion_name,
            id_city             = m$ti.id_city,
            id_entity_instance  = p$object.id_entity_instance,
            type_name           = COALESCE(m$type_name, type_name),
            trace_info          = p$object.trace_info,
            -- MERGE-фикс: в Oracle-оригинале UPDATE-ветка ошибочно писала сюда
            -- id_territory2 (лист иерархии), тогда как INSERT-ветка корректно
            -- пишет id_street (id улицы). Приведено к поведению INSERT -- иначе
            -- одна и та же строка получала разный id_street2 после INSERT и
            -- после UPDATE. Для бит-в-бит Oracle-совместимости верните
            -- p$object.id_territory2.
            id_street2          = m$ti2.id_street,
            id_territory2       = p$object.id_territory2,
            house2              = p$object.dom2,
            building_no2        = p$object.building_no2,
            is_exist_alternate_adres = CASE WHEN p$object.id_territory2 IS NOT NULL THEN 1 ELSE 0 END,
            adres2              = m$ti2.short_adres,
            full_adres2         = m$ti2.full_adres,
            street_name2        = COALESCE(m$ti2.street_name, ' '),
            city_name2          = m$ti2.city_name,
            id_raion2           = m$ti2.id_raion,
            raion_name2         = m$ti2.raion_name,
            id_city2            = m$ti2.id_city,
            addressing_mode     = p$object.addressing_mode,
            id_house_doorway    = p$object.id_house_doorway,
            id_object_house     = p$object.id_object_house,
            id_main_city        = m$ti.id_main_city,
            main_city_name      = m$ti.main_city_name,
            id_district         = m$ti.id_district,
            district_name       = m$ti.district_name,
            id_region           = m$ti.id_region,
            region_name         = m$ti.region_name,
            zip                 = m$zip,
            object_no           = p$object.object_no,
            volume              = p$object.volume,
            sq_life             = p$object.sq_life,
            room_no             = p$object.room_no
        WHERE id_object = p$object.id_object;
    END IF;
END;
$$;


-- ────────────────────────────────────────────────────────────
-- create_view, rebuild, rebuild(batch) — без изменений
-- (не используют пакетное состояние init/add_*)
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE PROCEDURE object_info_pkg.create_view(
    p$with_grants INTEGER DEFAULT 0
)
LANGUAGE plpgsql
AS $$
BEGIN
    EXECUTE $sql$
        CREATE OR REPLACE VIEW object_info AS
            SELECT a.*
                , UPPER(COALESCE(a.street_name, ' '))       AS find_street_name
                , UPPER(COALESCE(a.city_name, ' '))         AS find_city_name
                , UPPER(COALESCE(TRIM(a.house), ' '))       AS find_house
                , UPPER(COALESCE(TRIM(a.building_no), ' ')) AS find_building_no
                , UPPER(COALESCE(TRIM(a.flat), ' '))        AS find_flat
            FROM object_info_tbl a
    $sql$;

    -- Выдача прав исключена по требованию. Параметр p$with_grants
    -- сохранён для совместимости сигнатуры с Oracle и игнорируется.
END;
$$;

CREATE OR REPLACE PROCEDURE object_info_pkg.rebuild()
LANGUAGE plpgsql
AS $$
DECLARE
    m$mode              TEXT;
    m$id_object_list    BIGINT[];
BEGIN
    m$mode := current_setting('app.db_access_mode', TRUE);
    PERFORM set_config('app.db_access_mode', '2', TRUE);

    DELETE FROM object_info_tbl WHERE id_object NOT IN (SELECT id_object FROM object);

    SELECT array_agg(id_object) INTO m$id_object_list
    FROM object WHERE id_object NOT IN (SELECT id_object FROM object_info_tbl);

    IF m$id_object_list IS NOT NULL AND cardinality(m$id_object_list) > 0 THEN
        CALL object_info_pkg.update_object_info(m$id_object_list, 'insert');
    END IF;

    UPDATE object_house   SET id_territory    = id_territory;
    UPDATE object_flat    SET id_object_house = id_object_house;
    UPDATE house_doorway  SET id_object_house = id_object_house;
    UPDATE object_unknown SET id_territory    = id_territory;
    UPDATE object_room    SET id_object_flat  = id_object_flat;
    UPDATE object         SET id_territory    = id_territory;

    COMMIT;
    PERFORM set_config('app.db_access_mode', COALESCE(m$mode, '1'), TRUE);
END;
$$;

CREATE OR REPLACE PROCEDURE object_info_pkg.rebuild(p$batch_size BIGINT)
LANGUAGE plpgsql
AS $$
DECLARE
    m$mode              TEXT;
    m$min_id            BIGINT;
    m$max_id            BIGINT;
    m$from_id           BIGINT;
    m$to_id             BIGINT;
    m$id_object_list    BIGINT[];
BEGIN
    IF p$batch_size IS NULL THEN
        CALL object_info_pkg.rebuild();
        RETURN;
    END IF;

    -- MERGE-фикс: в батч-версии set_config делаем session-level (is_local=FALSE),
    -- т.к. COMMIT после каждого батча (ниже) сбросил бы transaction-local
    -- настройку. app.db_access_mode -- placeholder-аналог int_rep_session и на
    -- логику не влияет, но держим его консистентным на всё время пересборки.
    m$mode := current_setting('app.db_access_mode', TRUE);
    PERFORM set_config('app.db_access_mode', '2', FALSE);

    SELECT MIN(id_object), MAX(id_object) INTO m$min_id, m$max_id FROM object;
    IF m$min_id IS NULL THEN
        PERFORM set_config('app.db_access_mode', COALESCE(m$mode, '1'), FALSE);
        RETURN;
    END IF;

    m$from_id := m$min_id;
    LOOP
        m$to_id := m$from_id + p$batch_size - 1;

        DELETE FROM object_info_tbl
        WHERE id_object BETWEEN m$from_id AND m$to_id
          AND id_object NOT IN (SELECT id_object FROM object);

        SELECT array_agg(id_object) INTO m$id_object_list
        FROM object
        WHERE id_object BETWEEN m$from_id AND m$to_id
          AND id_object NOT IN (SELECT id_object FROM object_info_tbl);

        IF m$id_object_list IS NOT NULL AND cardinality(m$id_object_list) > 0 THEN
            CALL object_info_pkg.update_object_info(m$id_object_list, 'insert');
        END IF;

        UPDATE object_house   SET id_territory    = id_territory    WHERE id_object BETWEEN m$from_id AND m$to_id;
        UPDATE object_flat    SET id_object_house = id_object_house WHERE id_object BETWEEN m$from_id AND m$to_id;
        UPDATE house_doorway  SET id_object_house = id_object_house WHERE id_object BETWEEN m$from_id AND m$to_id;
        UPDATE object_unknown SET id_territory    = id_territory    WHERE id_object BETWEEN m$from_id AND m$to_id;
        UPDATE object_room    SET id_object_flat  = id_object_flat  WHERE id_object BETWEEN m$from_id AND m$to_id;
        UPDATE object         SET id_territory    = id_territory    WHERE id_object BETWEEN m$from_id AND m$to_id;

        -- MERGE-фикс (durability для больших пересборок): COMMIT после каждого
        -- батча. Без него batch-версия -- это ОДНА транзакция на все ~5 минут
        -- (для 500K object): огромный WAL, долгие блокировки, при сбое посреди
        -- откатывается всё и прогресс теряется. С per-batch COMMIT прогресс
        -- сохраняется, блокировки освобождаются между батчами, а повторный
        -- запуск идемпотентно продолжает (осиротевшие удаляются, недостающие
        -- вставляются).
        COMMIT;

        EXIT WHEN m$to_id >= m$max_id;
        m$from_id := m$to_id + 1;
    END LOOP;

    PERFORM set_config('app.db_access_mode', COALESCE(m$mode, '1'), FALSE);
END;
$$;

