-- ============================================================
-- 03c_triggers_transition.sql — триггерные функции, триггеры, VIEW
-- PostgreSQL 16 | ВАРИАНТ C: transition tables
-- Комплект проверен на живой базе (тесты T1–T12)
-- Выполнять ЧЕТВЁРТЫМ (после 02c_object_info_pkg_transition.sql)
--
-- Архитектура: раздельные массивы для каждой операции.
-- Каждая операция (INSERT / UPDATE / DELETE) имеет СВОЙ
-- AFTER STATEMENT триггер и СВОЮ функцию, которая складывает id
-- всех затронутых командой строк в свой локальный массив
-- (m$ids_insert / m$ids_update / m$ids_delete) из transition
-- table и сразу обрабатывает его. Состояние между вызовами не
-- хранится вообще: ни GUC (set_config), ни temp-таблиц.
--
-- Ограничение PG: один триггер с REFERENCING = одно событие,
-- поэтому вместо одного AFTER INSERT OR UPDATE OR DELETE — три
-- отдельных триггера (это и даёт раздельные массивы естественно).
--
-- BEFORE ROW триггеры подклассовых таблиц (object_house,
-- object_flat, house_doorway, object_room, object_unknown)
-- не изменились: они модифицируют NEW (format_object_no, rpad)
-- и валидируют — transition tables там неприменимы.
-- ============================================================


-- ============================================================
-- ТРИГГЕРЫ НА OBJECT — три раздельных STATEMENT-триггера
-- Oracle: один TAIUD$E52$OBJECT_INFO (AFTER ROW, INSERT OR UPDATE
-- OR DELETE) — построчно передавал :new в update_object_info.
-- Здесь каждая операция собирает СВОЙ массив id из transition
-- table и обрабатывает его одним вызовом.
-- ============================================================

-- INSERT: массив id новых строк → update_object_info(list, 'insert')
CREATE OR REPLACE FUNCTION object_info_pkg.trg_object_ins_stmt()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    m$ids_insert BIGINT[];
BEGIN
    m$ids_insert := ARRAY(SELECT id_object FROM new_t);

    IF cardinality(m$ids_insert) > 0 THEN
        CALL object_info_pkg.update_object_info(m$ids_insert, 'insert');
    END IF;
    RETURN NULL;
END;
$$;

CREATE OR REPLACE TRIGGER tais_e52_object_info
AFTER INSERT
ON object
REFERENCING NEW TABLE AS new_t
FOR EACH STATEMENT
WHEN (current_setting('app.trigger_taiud_e52_object_info', TRUE) IS DISTINCT FROM '0')
EXECUTE FUNCTION object_info_pkg.trg_object_ins_stmt();


-- UPDATE: массив id изменённых строк → update_object_info(list, 'update')
-- Oracle v8 (20.09.2021): при writer = 'dublicate_pkg' UPDATE
-- пропускается (DELETE при слиянии объектов обрабатывается).
CREATE OR REPLACE FUNCTION object_info_pkg.trg_object_upd_stmt()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    m$ids_update BIGINT[];
BEGIN
    IF current_setting('app.writer', TRUE) = 'dublicate_pkg' THEN
        RETURN NULL;
    END IF;

    m$ids_update := ARRAY(SELECT id_object FROM new_t);

    IF cardinality(m$ids_update) > 0 THEN
        CALL object_info_pkg.update_object_info(m$ids_update, 'update');
    END IF;
    RETURN NULL;
END;
$$;

CREATE OR REPLACE TRIGGER taus_e52_object_info
AFTER UPDATE
ON object
REFERENCING NEW TABLE AS new_t
FOR EACH STATEMENT
WHEN (current_setting('app.trigger_taiud_e52_object_info', TRUE) IS DISTINCT FROM '0')
EXECUTE FUNCTION object_info_pkg.trg_object_upd_stmt();


-- DELETE: массив id удалённых строк → удаление из object_info_tbl
CREATE OR REPLACE FUNCTION object_info_pkg.trg_object_del_stmt()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    m$ids_delete BIGINT[];
BEGIN
    m$ids_delete := ARRAY(SELECT id_object FROM old_t);

    IF cardinality(m$ids_delete) > 0 THEN
        DELETE FROM object_info_tbl WHERE id_object = ANY(m$ids_delete);
    END IF;
    RETURN NULL;
END;
$$;

CREATE OR REPLACE TRIGGER tads_e52_object_info
AFTER DELETE
ON object
REFERENCING OLD TABLE AS old_t
FOR EACH STATEMENT
WHEN (current_setting('app.trigger_taiud_e52_object_info', TRUE) IS DISTINCT FROM '0')
EXECUTE FUNCTION object_info_pkg.trg_object_del_stmt();


-- ============================================================
-- ТРИГГЕР НА TERRITORY — один AFTER STATEMENT
-- Oracle: тройка TCBU$E98 (init) + TAU$E98 (накопление построчно)
-- + TCAU$E98 (обработка) существовала только потому, что Oracle
-- 10g/11g не умел отдать AFTER STATEMENT все строки команды.
-- Transition table убирает саму причину: массив территорий
-- собирается одним SELECT из new_t.
--
-- Нюанс оригинала: TCBU реагировал и на zip (только init, без
-- обработки) — итог для UPDATE только zip был "ничего не делать".
-- Здесь триггер по тем же колонкам, что TAU/TCAU (без zip):
-- поведение идентично.
-- ============================================================
CREATE OR REPLACE FUNCTION object_info_pkg.trg_territory_upd_stmt()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    m$ids_territory BIGINT[];
BEGIN
    -- Управляющая переменная оригинала (TAU$E98$OBJECT_INFO)
    IF current_setting('app.trigger_tau_e98_object_info', TRUE) = '0' THEN
        RETURN NULL;
    END IF;

    -- Ограничение PG (0A000): триггер с transition tables не может
    -- иметь список колонок UPDATE OF. Поэтому триггер объявлен на
    -- любой UPDATE, а отбор "значимых" изменений выполнен здесь:
    -- берём только строки, где реально изменилась хотя бы одна из
    -- колонок id_parent / id_territory_class / id_territory_type / name.
    -- Отличие от Oracle: UPDATE OF срабатывал по упоминанию колонки
    -- в SET (даже без смены значения); здесь — по фактическому
    -- изменению значения. Это строже и не даёт лишних пересчётов.
    -- UPDATE только zip, как и в оригинале, пересчёта не вызывает.
    m$ids_territory := ARRAY(
        SELECT DISTINCT n.id_territory
        FROM new_t n
        JOIN old_t o USING (id_territory)
        WHERE (n.id_parent, n.id_territory_class, n.id_territory_type, n.name)
              IS DISTINCT FROM
              (o.id_parent, o.id_territory_class, o.id_territory_type, o.name)
    );

    IF cardinality(m$ids_territory) = 0 THEN
        RETURN NULL;
    END IF;

    CALL object_info_pkg.update_object_info_territories(m$ids_territory);
    RETURN NULL;
END;
$$;

CREATE OR REPLACE TRIGGER tau_e98_object_info
AFTER UPDATE
ON territory
REFERENCING OLD TABLE AS old_t NEW TABLE AS new_t
FOR EACH STATEMENT
EXECUTE FUNCTION object_info_pkg.trg_territory_upd_stmt();


-- ============================================================
-- ТРИГГЕР НА OBJECT_HOUSE — TBIU1_OBJECT_HOUSE
-- Oracle: BEFORE INSERT OR UPDATE OF id_territory, house_no, building_no,
--         id_territory2, house_no2, building_no2, addressing_mode, zip, sq_life
-- ============================================================
CREATE OR REPLACE FUNCTION trg_object_house_biu()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    -- Oracle: :new.house_no := object_info_pkg.format_object_no(:new.house_no, 10)
    NEW.house_no  := object_info_pkg.format_object_no(NEW.house_no,  10);
    NEW.house_no2 := object_info_pkg.format_object_no(NEW.house_no2, 6);

    UPDATE object SET
        id_territory    = NEW.id_territory,
        dom             = NEW.house_no,
        building_no     = NEW.building_no,
        id_territory2   = NEW.id_territory2,
        dom2            = NEW.house_no2,
        building_no2    = NEW.building_no2,
        addressing_mode = NEW.addressing_mode,
        zip             = NEW.zip,
        sq_life         = NEW.sq_life
    WHERE id_object = NEW.id_object;

    -- Режим "по домам" (addressing_mode = 1)
    -- Oracle использовал :old.id_object (при INSERT = NULL → подзапросы
    -- пусты). В PG обращение к OLD в BEFORE INSERT — ошибка выполнения
    -- ("record old is not assigned yet"), поэтому здесь NEW.id_object:
    -- при UPDATE PK не меняется (old = new), при INSERT детей ещё нет —
    -- семантика идентична оригиналу.
    IF NEW.addressing_mode = 1 THEN
        UPDATE object SET
            id_territory    = NEW.id_territory,
            dom             = NEW.house_no,
            building_no     = NEW.building_no,
            id_territory2   = NEW.id_territory2,
            dom2            = NEW.house_no2,
            building_no2    = NEW.building_no2,
            addressing_mode = NEW.addressing_mode,
            zip             = NEW.zip
        WHERE id_object IN (
            SELECT id_object FROM object_flat   WHERE id_object_house = NEW.id_object
            UNION ALL
            SELECT id_object FROM house_doorway WHERE id_object_house = NEW.id_object
            UNION ALL
            SELECT id_object FROM object_room
            WHERE id_object_flat IN (
                SELECT id_object FROM object_flat WHERE id_object_house = NEW.id_object
            )
        );

    -- Режим "по подъездам" (addressing_mode = 2)
    ELSIF NEW.addressing_mode = 2 THEN
        -- Помещения и комнаты: dom берётся из подъезда
        UPDATE object a SET
            id_territory    = NEW.id_territory,
            building_no     = NULL,
            id_territory2   = NULL,
            dom2            = NULL,
            building_no2    = NULL,
            dom = (
                SELECT c.house_no
                FROM object_flat b
                JOIN house_doorway c
                    ON b.id_object_house = c.id_object_house
                   AND b.id_house_doorway = c.id_object
                WHERE a.id_object = b.id_object
            ),
            addressing_mode = NEW.addressing_mode,
            zip             = NEW.zip
        WHERE a.id_object IN (
            SELECT id_object FROM object_flat WHERE id_object_house = NEW.id_object
            UNION ALL
            SELECT id_object FROM object_room
            WHERE id_object_flat IN (
                SELECT id_object FROM object_flat WHERE id_object_house = NEW.id_object
            )
        );

        -- Подъезды: dom берётся из самого подъезда
        -- Oracle: UPDATE (SELECT A.id_territory, A.dom, ... FROM object A JOIN house_doorway B ...) SET ...
        -- PG:     UPDATE ... FROM (аналог updateable VIEW)
        UPDATE object a SET
            id_territory    = NEW.id_territory,
            dom             = b.house_no,
            building_no     = NULL,
            id_territory2   = NULL,
            dom2            = NULL,
            building_no2    = NULL,
            addressing_mode = NEW.addressing_mode,
            zip             = NEW.zip
        FROM house_doorway b
        WHERE a.id_object      = b.id_object
          AND b.id_object_house = NEW.id_object;

    ELSE
        -- Oracle: RAISE_APPLICATION_ERROR(-20000, '<<Неизвестный способ адресации...>>')
        RAISE EXCEPTION '<<Неизвестный способ адресации в доме (%)>>', NEW.addressing_mode
            USING ERRCODE = 'P0001';
    END IF;

    RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER tbiu1_object_house
BEFORE INSERT OR UPDATE OF
    id_territory, house_no, building_no,
    id_territory2, house_no2, building_no2,
    addressing_mode, zip, sq_life
ON object_house
FOR EACH ROW
EXECUTE FUNCTION trg_object_house_biu();


-- ============================================================
-- ТРИГГЕР НА OBJECT_FLAT — TBIU1_OBJECT_FLAT
-- Oracle: BEFORE INSERT OR UPDATE OF id_object_house, id_house_doorway, flat_no, sq_life
-- Oracle: DECODE(A.addressing_mode, 1, A.house_no, 2, B.house_no, NULL)
-- PG:     CASE WHEN A.addressing_mode = 1 THEN A.house_no WHEN 2 THEN B.house_no END
-- ============================================================
CREATE OR REPLACE FUNCTION trg_object_flat_biu()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    m$id_territory      BIGINT;
    m$house_no          TEXT;
    m$building_no       TEXT;
    m$id_territory2     BIGINT;
    m$house_no2         TEXT;
    m$building_no2      TEXT;
    m$addressing_mode   INTEGER;
    m$zip               NUMERIC;
BEGIN
    -- Oracle: :new.flat_no := object_info_pkg.format_object_no(:new.flat_no, 4)
    NEW.flat_no := object_info_pkg.format_object_no(NEW.flat_no, 4);

    BEGIN
        SELECT
            a.id_territory,
            CASE a.addressing_mode WHEN 1 THEN a.house_no   WHEN 2 THEN b.house_no   ELSE NULL END,
            CASE a.addressing_mode WHEN 1 THEN a.building_no                          ELSE NULL END,
            CASE a.addressing_mode WHEN 1 THEN a.id_territory2                        ELSE NULL END,
            CASE a.addressing_mode WHEN 1 THEN a.house_no2                            ELSE NULL END,
            CASE a.addressing_mode WHEN 1 THEN a.building_no2                         ELSE NULL END,
            a.addressing_mode,
            a.zip
        INTO STRICT
            m$id_territory, m$house_no, m$building_no,
            m$id_territory2, m$house_no2, m$building_no2,
            m$addressing_mode, m$zip
        FROM object_house a
        LEFT JOIN house_doorway b
            ON a.id_object = b.id_object_house
           AND b.id_object = NEW.id_house_doorway
        WHERE a.id_object = NEW.id_object_house;
    EXCEPTION WHEN NO_DATA_FOUND THEN
        RAISE EXCEPTION '<<Не найден объект-здание (id_object=%) для данного объекта-помещения>>', NEW.id_object_house
            USING ERRCODE = 'P0001';
    END;

    IF m$addressing_mode = 2 THEN
        IF NEW.id_house_doorway IS NULL THEN
            RAISE EXCEPTION '<<Для способа адресации "по подъездам" обязательно указание в объекте-помещении ссылки на объект-подъезд>>'
                USING ERRCODE = 'P0001';
        END IF;
        IF m$house_no IS NULL THEN
            RAISE EXCEPTION '<<Для способа адресации "по подъездам" обязательно указание в объекте-подъезде номера дома>>'
                USING ERRCODE = 'P0001';
        END IF;
    END IF;

    UPDATE object SET
        id_territory     = m$id_territory,
        dom              = m$house_no,
        building_no      = m$building_no,
        kw               = NEW.flat_no,
        id_territory2    = m$id_territory2,
        dom2             = m$house_no2,
        building_no2     = m$building_no2,
        addressing_mode  = m$addressing_mode,
        zip              = m$zip,
        id_object_house  = NEW.id_object_house,
        id_house_doorway = NEW.id_house_doorway,
        sq_life          = NEW.sq_life
    WHERE id_object = NEW.id_object;

    RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER tbiu1_object_flat
BEFORE INSERT OR UPDATE OF id_object_house, id_house_doorway, flat_no, sq_life
ON object_flat
FOR EACH ROW
EXECUTE FUNCTION trg_object_flat_biu();


-- ============================================================
-- ТРИГГЕРЫ НА HOUSE_DOORWAY — ВАРИАНТ C
-- Oracle: tcbu1 (BEFORE STMT, сброс накопителя) + tbiu1 (BEFORE ROW)
-- + tcau1 (AFTER STMT, FORALL). Накопитель не нужен: BEFORE ROW
-- оставлен (валидация, формат, UPDATE object), AFTER STATEMENT
-- получает пары old/new напрямую из transition tables.
-- ============================================================


-- BEFORE EACH ROW: форматирование + обновление object + накопление
CREATE OR REPLACE FUNCTION trg_house_doorway_biu()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    m$id_territory      BIGINT;
    m$house_no          TEXT;
    m$building_no       TEXT;
    m$id_territory2     BIGINT;
    m$house_no2         TEXT;
    m$building_no2      TEXT;
    m$addressing_mode   INTEGER;
    m$zip               NUMERIC;
BEGIN
    BEGIN
        SELECT
            a.id_territory,
            CASE a.addressing_mode WHEN 1 THEN a.house_no    WHEN 2 THEN NEW.house_no ELSE NULL END,
            CASE a.addressing_mode WHEN 1 THEN a.building_no                           ELSE NULL END,
            CASE a.addressing_mode WHEN 1 THEN a.id_territory2                         ELSE NULL END,
            CASE a.addressing_mode WHEN 1 THEN a.house_no2                             ELSE NULL END,
            CASE a.addressing_mode WHEN 1 THEN a.building_no2                          ELSE NULL END,
            a.addressing_mode,
            a.zip
        INTO STRICT
            m$id_territory, m$house_no, m$building_no,
            m$id_territory2, m$house_no2, m$building_no2,
            m$addressing_mode, m$zip
        FROM object_house a
        WHERE a.id_object = NEW.id_object_house;
    EXCEPTION WHEN NO_DATA_FOUND THEN
        RAISE EXCEPTION '<<Не найден объект-здание (id_object=%) для данного объекта-подъезда>>', NEW.id_object_house
            USING ERRCODE = 'P0001';
    END;

    IF m$addressing_mode = 1 THEN
        IF NEW.house_no IS NOT NULL THEN
            RAISE EXCEPTION '<<Для способа адресации "по домам" не нужно заполнять номера дома в объекте-подъезде (%)>>', NEW.house_no
                USING ERRCODE = 'P0001';
        END IF;

    ELSIF m$addressing_mode = 2 THEN
        IF NEW.house_no IS NULL THEN
            RAISE EXCEPTION '<<Для способа адресации "по подъездам" обязательно указание в объекте-подъезде номера дома>>'
                USING ERRCODE = 'P0001';
        END IF;
        -- Oracle: :new.house_no := format_left(:new.house_no, 6)
        -- format_left = rpad(TRIM(...), 6, ' ') в PG
        NEW.house_no := rpad(TRIM(NEW.house_no), 6, ' ');
        m$house_no   := NEW.house_no;
    END IF;

    UPDATE object SET
        id_territory    = m$id_territory,
        dom             = m$house_no,
        building_no     = m$building_no,
        id_territory2   = m$id_territory2,
        dom2            = m$house_no2,
        building_no2    = m$building_no2,
        addressing_mode = m$addressing_mode,
        zip             = m$zip,
        id_object_house = NEW.id_object_house
    WHERE id_object = NEW.id_object;

    -- Oracle: IF m$addressing_mode = 2 AND UPDATING('house_no')
    -- Вложенный IF обязателен: при INSERT обращение к OLD — ошибка
    -- выполнения в PG, а порядок вычисления частей AND формально
    -- не гарантирован. Внутри ветки TG_OP='UPDATE' OLD безопасен.
    IF TG_OP = 'UPDATE' THEN
    IF m$addressing_mode = 2
       AND OLD.house_no IS DISTINCT FROM NEW.house_no
    THEN
        UPDATE object SET
            id_territory    = m$id_territory,
            dom             = m$house_no,
            building_no     = m$building_no,
            id_territory2   = m$id_territory2,
            dom2            = m$house_no2,
            building_no2    = m$building_no2,
            addressing_mode = m$addressing_mode,
            zip             = m$zip
        WHERE id_object IN (
            SELECT id_object FROM object_flat
            WHERE id_object_house  = OLD.id_object_house
              AND id_house_doorway = OLD.id_object
        );
    END IF;
    END IF;  -- TG_OP = 'UPDATE'

    -- Накопление НЕ нужно: пары старое/новое значение id_object_house
    -- доступны AFTER STATEMENT триггеру напрямую через transition
    -- tables (old_t / new_t) — см. trg_house_doorway_upd_stmt ниже.

    RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER tbiu1_house_doorway
BEFORE INSERT OR UPDATE OF id_object_house, house_no
ON house_doorway
FOR EACH ROW
EXECUTE FUNCTION trg_house_doorway_biu();


-- AFTER STATEMENT: применяем накопленное к object_flat
-- Oracle: FORALL i IN m$ids.FIRST .. m$ids.LAST

-- AFTER STATEMENT: применяем перемещения подъездов к object_flat
-- Oracle: num_collect_pkg (3 коллекции, синхронные по индексу)
-- + FORALL i IN FIRST..LAST UPDATE object_flat ...
-- Здесь пары (старое, новое) значение id_object_house доступны
-- напрямую: old_t JOIN new_t по PK — накопители не нужны.
CREATE OR REPLACE FUNCTION trg_house_doorway_upd_stmt()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE object_flat f SET
        id_object_house = c.house_new
    FROM (
        SELECT o.id_object        AS obj_old,
               o.id_object_house  AS house_old,
               n.id_object_house  AS house_new
        FROM old_t o
        JOIN new_t n USING (id_object)
        -- триггер объявлен без UPDATE OF (ограничение 0A000 для
        -- transition tables) — фильтруем фактическую смену дома здесь
        WHERE o.id_object_house IS DISTINCT FROM n.id_object_house
    ) c
    WHERE f.id_object_house  = c.house_old
      AND f.id_house_doorway = c.obj_old;

    RETURN NULL;
END;
$$;

CREATE OR REPLACE TRIGGER taus1_house_doorway
AFTER UPDATE
ON house_doorway
REFERENCING OLD TABLE AS old_t NEW TABLE AS new_t
FOR EACH STATEMENT
EXECUTE FUNCTION trg_house_doorway_upd_stmt();


-- ============================================================
-- ТРИГГЕР НА OBJECT_ROOM — TBIU1_OBJECT_ROOM
-- Oracle: BEFORE INSERT OR UPDATE OF id_object_flat, sq_life, room_no
-- ============================================================
CREATE OR REPLACE FUNCTION trg_object_room_biu()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    m$id_territory      BIGINT;
    m$house_no          TEXT;
    m$building_no       TEXT;
    m$id_territory2     BIGINT;
    m$house_no2         TEXT;
    m$building_no2      TEXT;
    m$addressing_mode   INTEGER;
    m$zip               NUMERIC;
    m$id_object_house   BIGINT;
    m$id_house_doorway  BIGINT;
    m$kw                TEXT;
BEGIN
    -- Oracle: :new.room_no := object_info_pkg.format_object_no(:new.room_no, 4)
    -- room_no хранится как VARCHAR, ::TEXT гарантирует совместимость если INTEGER
    NEW.room_no := object_info_pkg.format_object_no(NEW.room_no::TEXT, 4);

    -- Oracle: FROM object f, object o
    -- WHERE f.id_object = :new.id_object_flat AND o.id_object = :new.id_object
    SELECT f.id_territory, f.dom, f.building_no,
           f.id_territory2, f.dom2, f.building_no2,
           f.addressing_mode, f.zip,
           f.id_object_house, f.id_house_doorway, f.kw
    INTO STRICT
        m$id_territory, m$house_no, m$building_no,
        m$id_territory2, m$house_no2, m$building_no2,
        m$addressing_mode, m$zip,
        m$id_object_house, m$id_house_doorway, m$kw
    FROM object f, object o
    WHERE f.id_object = NEW.id_object_flat
      AND o.id_object = NEW.id_object;

    UPDATE object SET
        id_territory     = m$id_territory,
        dom              = m$house_no,
        building_no      = m$building_no,
        kw               = m$kw,
        room_no          = NEW.room_no,
        id_territory2    = m$id_territory2,
        dom2             = m$house_no2,
        building_no2     = m$building_no2,
        addressing_mode  = m$addressing_mode,
        zip              = m$zip,
        id_object_house  = m$id_object_house,
        id_house_doorway = m$id_house_doorway,
        sq_life          = NEW.sq_life
    WHERE id_object = NEW.id_object;

    RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER tbiu1_object_room
BEFORE INSERT OR UPDATE OF id_object_flat, sq_life, room_no
ON object_room
FOR EACH ROW
EXECUTE FUNCTION trg_object_room_biu();


-- ============================================================
-- ТРИГГЕР НА OBJECT_UNKNOWN — TBIU1_OBJECT_UNKNOWN
-- Oracle: BEFORE INSERT OR UPDATE OF id_territory, house_no, zip
-- ============================================================
CREATE OR REPLACE FUNCTION trg_object_unknown_biu()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.house_no := object_info_pkg.format_object_no(NEW.house_no, 10);

    UPDATE object SET
        id_territory = NEW.id_territory,
        dom          = NEW.house_no,
        zip          = NEW.zip
    WHERE id_object = NEW.id_object;

    RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER tbiu1_object_unknown
BEFORE INSERT OR UPDATE OF id_territory, house_no, zip
ON object_unknown
FOR EACH ROW
EXECUTE FUNCTION trg_object_unknown_biu();


-- ============================================================
-- VIEW object_info
-- Oracle: NVL → COALESCE (гранты Oracle-оригинала опущены по требованию)
-- ============================================================
CREATE OR REPLACE VIEW object_info AS
    SELECT a.*
        , UPPER(COALESCE(a.street_name, ' '))       AS find_street_name
        , UPPER(COALESCE(a.city_name, ' '))         AS find_city_name
        , UPPER(COALESCE(TRIM(a.house), ' '))       AS find_house
        , UPPER(COALESCE(TRIM(a.building_no), ' ')) AS find_building_no
        , UPPER(COALESCE(TRIM(a.flat), ' '))        AS find_flat
    FROM object_info_tbl a;
