-- =============================================================================================
-- 04_subtype_triggers.sql
-- BEFORE ROW триггеры на подтиповых таблицах (object_house, object_flat, house_doorway,
-- object_room, object_unknown) -- копируют/пересчитывают адресные поля вниз, в основную ba7_data.
-- object, и, где нужно, каскадно -- на соседние подтиповые таблицы. Прямой построчный порт
-- Oracle trigger.object_house.sql / trigger.object_flat.sql / trigger.house_doorway.sql /
-- trigger.object_room.sql / trigger.object_unknown.sql.
--
-- Синтаксические замены: :new/:old -> NEW/OLD, RAISE_APPLICATION_ERROR -> RAISE EXCEPTION,
-- NVL -> COALESCE, DECODE -> CASE, UPDATING('col') -> NEW.col IS DISTINCT FROM OLD.col (точнее
-- по смыслу, чем Oracle-вариант "колонка присутствовала в SET", но эквивалентно на практике).
-- =============================================================================================

-- =============================================================================================
-- object_house -- аналог trigger.object_house.sql
-- =============================================================================================

CREATE OR REPLACE FUNCTION ba7_data.tbriu1_object_house() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    NEW.house_no  := object_info_pkg.format_object_no(NEW.house_no, 10);
    NEW.house_no2 := object_info_pkg.format_object_no(NEW.house_no2, 6);

    UPDATE ba7_data.object
        SET id_territory = NEW.id_territory,
            dom = NEW.house_no,
            building_no = NEW.building_no,
            id_territory2 = NEW.id_territory2,
            dom2 = NEW.house_no2,
            building_no2 = NEW.building_no2,
            addressing_mode = NEW.addressing_mode,
            zip = NEW.zip,
            sq_life = NEW.sq_life
        WHERE id_object = NEW.id_object;

    IF NEW.addressing_mode = 1 THEN
        -- "По домам": единый номер -- каскадом на все помещения, подъезды и комнаты этого дома.
        UPDATE ba7_data.object
            SET id_territory = NEW.id_territory, dom = NEW.house_no, building_no = NEW.building_no,
                id_territory2 = NEW.id_territory2, dom2 = NEW.house_no2, building_no2 = NEW.building_no2,
                addressing_mode = NEW.addressing_mode, zip = NEW.zip
        WHERE id_object IN (
            SELECT id_object FROM ba7_data.object_flat WHERE id_object_house = NEW.id_object
                UNION ALL
            SELECT id_object FROM ba7_data.house_doorway WHERE id_object_house = NEW.id_object
                UNION ALL
            SELECT r.id_object
            FROM ba7_data.object_room r
            JOIN ba7_data.object_flat f ON r.id_object_flat = f.id_object
            WHERE f.id_object_house = NEW.id_object
        );

    ELSIF NEW.addressing_mode = 2 THEN
        -- "По подъездам": помещения/комнаты берут номер дома от СВОЕГО подъезда (через
        -- object_flat.id_house_doorway). Если помещение ещё не привязано к подъезду (или для
        -- комнаты нет пути к дверному объекту через её помещение) -- dom уходит в NULL: тот же
        -- эффект, что и в Oracle-оригинале (там это был коррелированный подзапрос без совпадения).
        UPDATE ba7_data.object A
            SET id_territory = NEW.id_territory,
                building_no = NULL,
                id_territory2 = NULL,
                dom2 = NULL,
                building_no2 = NULL,
                dom = (
                    SELECT c.house_no
                    FROM ba7_data.object_flat b
                    JOIN ba7_data.house_doorway c
                         ON b.id_object_house = c.id_object_house AND b.id_house_doorway = c.id_object
                    WHERE b.id_object = A.id_object
                ),
                addressing_mode = NEW.addressing_mode,
                zip = NEW.zip
        WHERE A.id_object IN (
            SELECT id_object FROM ba7_data.object_flat WHERE id_object_house = NEW.id_object
                UNION ALL
            SELECT r.id_object
            FROM ba7_data.object_room r
            JOIN ba7_data.object_flat f ON r.id_object_flat = f.id_object
            WHERE f.id_object_house = NEW.id_object
        );

        -- Сами подъезды -- берут номер дома из собственного house_no.
        UPDATE ba7_data.object A
            SET id_territory = NEW.id_territory,
                dom = B.house_no,
                building_no = NULL,
                id_territory2 = NULL,
                dom2 = NULL,
                building_no2 = NULL,
                addressing_mode = NEW.addressing_mode,
                zip = NEW.zip
        FROM ba7_data.house_doorway B
        WHERE A.id_object = B.id_object
          AND B.id_object_house = NEW.id_object;

    ELSE
        -- На практике недостижимо (addressing_mode ограничен CHECK в 00_ddl.sql), оставлено для
        -- симметрии с Oracle-оригиналом и на случай, если CHECK будет ослаблен.
        RAISE EXCEPTION 'Неизвестный способ адресации в доме (%)', NEW.addressing_mode;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER tbriu1_object_house
    BEFORE INSERT OR UPDATE OF
        id_territory, house_no, building_no, id_territory2, house_no2, building_no2, addressing_mode, zip, sq_life
    ON ba7_data.object_house
    FOR EACH ROW
    EXECUTE FUNCTION ba7_data.tbriu1_object_house();

-- =============================================================================================
-- object_flat -- аналог trigger.object_flat.sql
-- =============================================================================================

CREATE OR REPLACE FUNCTION ba7_data.tbriu1_object_flat() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
    m_id_territory     BIGINT;
    m_house_no         VARCHAR(10);
    m_building_no      VARCHAR(30);
    m_id_territory2    BIGINT;
    m_house_no2        VARCHAR(6);
    m_building_no2     VARCHAR(30);
    m_addressing_mode  INT;
    m_zip              NUMERIC(10);
BEGIN
    NEW.flat_no := object_info_pkg.format_object_no(NEW.flat_no, 4);

    -- Данные берутся в зависимости от способа адресации: "по домам" -- из самого object_house,
    -- "по подъездам" -- из привязанного house_doorway (через LEFT JOIN по id_house_doorway).
    SELECT a.id_territory,
           CASE a.addressing_mode WHEN 1 THEN a.house_no WHEN 2 THEN b.house_no ELSE NULL END,
           CASE a.addressing_mode WHEN 1 THEN a.building_no ELSE NULL END,
           CASE a.addressing_mode WHEN 1 THEN a.id_territory2 ELSE NULL END,
           CASE a.addressing_mode WHEN 1 THEN a.house_no2 ELSE NULL END,
           CASE a.addressing_mode WHEN 1 THEN a.building_no2 ELSE NULL END,
           a.addressing_mode, a.zip
        INTO STRICT m_id_territory, m_house_no, m_building_no,
                    m_id_territory2, m_house_no2, m_building_no2,
                    m_addressing_mode, m_zip
    FROM ba7_data.object_house a
    LEFT JOIN ba7_data.house_doorway b
           ON a.id_object = b.id_object_house AND b.id_object = NEW.id_house_doorway
    WHERE a.id_object = NEW.id_object_house;

    IF m_addressing_mode = 2 THEN
        IF NEW.id_house_doorway IS NULL THEN
            RAISE EXCEPTION 'Для способа адресации "по подъездам" обязательно указание в объекте-помещении ссылки на объект-подъезд';
        END IF;
        IF m_house_no IS NULL THEN
            RAISE EXCEPTION 'Для способа адресации "по подъездам" обязательно указание в объекте-подъезде номера дома';
        END IF;
    END IF;

    UPDATE ba7_data.object
        SET id_territory = m_id_territory, dom = m_house_no, building_no = m_building_no, kw = NEW.flat_no,
            id_territory2 = m_id_territory2, dom2 = m_house_no2, building_no2 = m_building_no2,
            addressing_mode = m_addressing_mode, zip = m_zip,
            id_object_house = NEW.id_object_house, id_house_doorway = NEW.id_house_doorway,
            sq_life = NEW.sq_life
        WHERE id_object = NEW.id_object;

    RETURN NEW;
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        RAISE EXCEPTION 'Не найден объект-здание (id_object=%) для данного объекта-помещения', NEW.id_object_house;
END;
$$;

CREATE TRIGGER tbriu1_object_flat
    BEFORE INSERT OR UPDATE OF id_object_house, id_house_doorway, flat_no, sq_life ON ba7_data.object_flat
    FOR EACH ROW
    EXECUTE FUNCTION ba7_data.tbriu1_object_flat();

-- =============================================================================================
-- house_doorway -- аналог связки Oracle tbiu1_house_doorway (row) + tсbu1_house_doorway/
-- tсau1_house_doorway (statement, через num_collect_pkg -- обход mutating table).
--
-- Row-часть (адрес самого подъезда + каскад в помещения ЭТОГО ЖЕ подъезда при смене его house_no)
-- остаётся BEFORE ROW триггером. А вот перенос помещений вслед за подъездом при смене его
-- id_object_house (т.е. подъезд "переехал" в другое здание) в Oracle требовал session-scoped
-- именованных списков именно из-за mutating table (нельзя в BEFORE ROW триггере по house_doorway
-- читать/менять другую строку house_doorway или конфликтующим образом трогать object_flat в разгар
-- той же DML-операции). В PostgreSQL для этого достаточно родной transition table на AFTER
-- STATEMENT -- см. ниже tasu1_house_doorway.
-- =============================================================================================

CREATE OR REPLACE FUNCTION ba7_data.tbriu1_house_doorway() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
    m_id_territory     BIGINT;
    m_house_no         VARCHAR(10);
    m_building_no      VARCHAR(30);
    m_addressing_mode  INT;
    m_zip              NUMERIC(10);
    m_id_territory2    BIGINT;
    m_house_no2        VARCHAR(6);
    m_building_no2     VARCHAR(30);
BEGIN
    -- Выбираем данные из объекта-здания в случае адресации "по домам" и из самого объекта-подъезда
    -- (его собственного NEW.house_no) в случае адресации "по подъездам".
    SELECT a.id_territory,
           CASE a.addressing_mode WHEN 1 THEN a.house_no WHEN 2 THEN NEW.house_no ELSE NULL END,
           CASE a.addressing_mode WHEN 1 THEN a.building_no ELSE NULL END,
           CASE a.addressing_mode WHEN 1 THEN a.id_territory2 ELSE NULL END,
           CASE a.addressing_mode WHEN 1 THEN a.house_no2 ELSE NULL END,
           CASE a.addressing_mode WHEN 1 THEN a.building_no2 ELSE NULL END,
           a.addressing_mode, a.zip
        INTO STRICT m_id_territory, m_house_no, m_building_no,
                    m_id_territory2, m_house_no2, m_building_no2,
                    m_addressing_mode, m_zip
    FROM ba7_data.object_house a
    WHERE a.id_object = NEW.id_object_house;

    IF m_addressing_mode = 1 THEN
        IF NEW.house_no IS NOT NULL THEN
            RAISE EXCEPTION 'Для способа адресации "по домам" не нужно заполнять номера дома в объекте-подъезде (%)', NEW.house_no;
        END IF;
    ELSIF m_addressing_mode = 2 THEN
        IF NEW.house_no IS NULL THEN
            RAISE EXCEPTION 'Для способа адресации "по подъездам" обязательно указание в объекте-подъезде номера дома';
        END IF;
        -- Oracle-оригинал форматировал номер через внешнюю функцию format_left(:new.house_no, 6),
        -- которой нет в репозитории (не Oracle-пакет из этого проекта и не задокументирована).
        -- Заменено на уже перенесённую object_info_pkg.format_object_no с длиной 10 -- как для
        -- первичного номера дома в object_house, т.к. house_no подъезда в режиме 2 фактически
        -- замещает первичный dom объекта (см. CASE выше).
        NEW.house_no := object_info_pkg.format_object_no(NEW.house_no, 10);
        m_house_no := NEW.house_no;
    END IF;

    UPDATE ba7_data.object
        SET id_territory = m_id_territory, dom = m_house_no, building_no = m_building_no,
            id_territory2 = m_id_territory2, dom2 = m_house_no2, building_no2 = m_building_no2,
            addressing_mode = m_addressing_mode, zip = m_zip, id_object_house = NEW.id_object_house
        WHERE id_object = NEW.id_object;

    -- Если адресация "по подъездам" и номер дома в ЭТОМ подъезде изменился -- обновляем номер дома
    -- и в помещениях, уже привязанных именно к нему.
    IF m_addressing_mode = 2 AND TG_OP = 'UPDATE' AND NEW.house_no IS DISTINCT FROM OLD.house_no THEN
        UPDATE ba7_data.object
            SET id_territory = m_id_territory, dom = m_house_no, building_no = m_building_no,
                id_territory2 = m_id_territory2, dom2 = m_house_no2, building_no2 = m_building_no2,
                addressing_mode = m_addressing_mode, zip = m_zip
        WHERE id_object IN (
            SELECT id_object FROM ba7_data.object_flat
            WHERE id_object_house = NEW.id_object_house AND id_house_doorway = NEW.id_object
        );
    END IF;

    RETURN NEW;
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        RAISE EXCEPTION 'Не найден объект-здание (id_object=%) для данного объекта-подъезда', NEW.id_object_house;
END;
$$;

CREATE TRIGGER tbriu1_house_doorway
    BEFORE INSERT OR UPDATE OF id_object_house, house_no ON ba7_data.house_doorway
    FOR EACH ROW
    EXECUTE FUNCTION ba7_data.tbriu1_house_doorway();

-- --- перенос подъезда в другое здание: каскад на его помещения (statement, transition table) ----

CREATE OR REPLACE FUNCTION ba7_data.tasu1_house_doorway() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    -- Если у подъезда сменился объект-здание (id_object_house), переносим вслед за ним все
    -- помещения, которые были привязаны именно к этому подъезду. Дальнейший пересчёт их адреса
    -- выполнит уже существующий tbriu1_object_flat -- он сработает как обычный BEFORE ROW триггер
    -- на этом же UPDATE (id_object_house входит в его список отслеживаемых колонок).
    UPDATE ba7_data.object_flat f
        SET id_object_house = n.id_object_house
    FROM new_t n
    JOIN old_t o ON o.id_object = n.id_object
    WHERE f.id_object_house = o.id_object_house
      AND f.id_house_doorway = o.id_object
      AND n.id_object_house IS DISTINCT FROM o.id_object_house;

    RETURN NULL;
END;
$$;

CREATE TRIGGER tasu1_house_doorway
    AFTER UPDATE ON ba7_data.house_doorway
    REFERENCING OLD TABLE AS old_t NEW TABLE AS new_t
    FOR EACH STATEMENT
    EXECUTE FUNCTION ba7_data.tasu1_house_doorway();

-- =============================================================================================
-- object_room -- аналог trigger.object_room.sql. Комната всегда наследует адрес от родительского
-- помещения БЕЗ развилки по addressing_mode -- читает уже посчитанные поля из object (адрес
-- помещения к этому моменту гарантированно актуален, т.к. object_flat обрабатывается раньше).
-- =============================================================================================

CREATE OR REPLACE FUNCTION ba7_data.tbriu1_object_room() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
    m_flat ba7_data.object%ROWTYPE;
BEGIN
    NEW.room_no := object_info_pkg.format_object_no(NEW.room_no, 4);

    SELECT * INTO STRICT m_flat FROM ba7_data.object WHERE id_object = NEW.id_object_flat;

    UPDATE ba7_data.object
        SET id_territory = m_flat.id_territory,
            dom = m_flat.dom,
            building_no = m_flat.building_no,
            kw = m_flat.kw,
            room_no = NEW.room_no,
            id_territory2 = m_flat.id_territory2,
            dom2 = m_flat.dom2,
            building_no2 = m_flat.building_no2,
            addressing_mode = m_flat.addressing_mode,
            zip = m_flat.zip,
            id_object_house = m_flat.id_object_house,
            id_house_doorway = m_flat.id_house_doorway,
            sq_life = NEW.sq_life
        WHERE id_object = NEW.id_object;

    RETURN NEW;
END;
$$;

CREATE TRIGGER tbriu1_object_room
    BEFORE INSERT OR UPDATE OF id_object_flat, sq_life, room_no ON ba7_data.object_room
    FOR EACH ROW
    EXECUTE FUNCTION ba7_data.tbriu1_object_room();

-- =============================================================================================
-- object_unknown -- аналог trigger.object_unknown.sql. Простейший случай: прочие объекты (гараж,
-- сарай, подстанция и т.д.) -- без подъездов и наследования, просто форматирование + копирование.
-- =============================================================================================

CREATE OR REPLACE FUNCTION ba7_data.tbriu1_object_unknown() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    NEW.house_no := object_info_pkg.format_object_no(NEW.house_no, 10);

    UPDATE ba7_data.object
        SET id_territory = NEW.id_territory,
            dom = NEW.house_no,
            zip = NEW.zip
        WHERE id_object = NEW.id_object;

    RETURN NEW;
END;
$$;

CREATE TRIGGER tbriu1_object_unknown
    BEFORE INSERT OR UPDATE OF id_territory, house_no, zip ON ba7_data.object_unknown
    FOR EACH ROW
    EXECUTE FUNCTION ba7_data.tbriu1_object_unknown();
