-- =============================================================================================
-- 02_object_info_pkg.sql
-- Схема object_info_pkg -- синхронизация ba7_data.object_info_tbl с ba7_data.object/territory.
-- Аналог тела Oracle-пакета object_info_pkg (без пакетных коллекций -- см. 03_object_info_triggers.sql
-- про то, чем они заменены).
-- =============================================================================================

-- -----------------------------------------------------------------------------------------------
-- format_object_no -- выравнивание цифровой части номера (дом/квартира/комната) под заданную длину,
-- чтобы строковая сортировка номеров совпадала с числовой (например "5а" не оказывался после "10а").
-- Точный построчный порт Oracle-функции, включая её защитный откат к исходному значению, если
-- вычисленная длина оказалась меньше исходной (LPAD в этом случае обрежет строку).
-- -----------------------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION object_info_pkg.format_object_no(p_object_no VARCHAR, p_numeric_len INT)
RETURNS VARCHAR
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    m_nonnumeric_object_no VARCHAR(100);
    m_index                INT;
    m_object_no            VARCHAR(100);
BEGIN
    m_nonnumeric_object_no := TRANSLATE(TRIM(p_object_no) || ',', '1234567890', REPEAT(' ', 10));
    m_index := POSITION(TRIM(m_nonnumeric_object_no) IN m_nonnumeric_object_no);
    m_object_no := COALESCE(
        LPAD(TRIM(p_object_no), LENGTH(TRIM(p_object_no)) + p_numeric_len - m_index),
        '    ');
    IF TRIM(m_object_no) IS DISTINCT FROM TRIM(p_object_no) THEN
        m_object_no := p_object_no;
    END IF;
    RETURN m_object_no;
END;
$$;

-- -----------------------------------------------------------------------------------------------
-- update_object_info(object_row_type, action) -- ядро пакета: собирает адрес объекта через
-- territory_pkg.get_info и пишет строку в object_info_tbl (INSERT/UPDATE/DELETE).
-- Прямой аналог Oracle update_object_info(p$object OBJECT%ROWTYPE, p$action VARCHAR2).
-- -----------------------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION object_info_pkg.update_object_info(
    p_object object_info_pkg.object_row_type,
    p_action TEXT
) RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    m_type_name       VARCHAR(500);
    m_object_address  VARCHAR(1000);
    t                 territory_pkg.territory_info_type;   -- адрес по id_territory (основной)
    t2                territory_pkg.territory_info_type;   -- адрес по id_territory2 (альтернативный)
    m_adres           VARCHAR(100);
    m_full_adres      VARCHAR(1000);
    m_adres2          VARCHAR(100);
    m_full_adres2     VARCHAR(1000);
    m_zip             NUMERIC(10);
BEGIN
    IF LOWER(p_action) = 'delete' THEN
        DELETE FROM ba7_data.object_info_tbl WHERE id_object = p_object.id_object;
        RETURN;
    END IF;

    SELECT name INTO STRICT m_type_name
    FROM ba7_data.object_type
    WHERE id_object_class = p_object.id_object_class AND id_object_type = p_object.id_object_type;

    -- === Основной адрес ==========================================================================
    IF p_object.id_territory IS NOT NULL THEN
        t := territory_pkg.get_info(p_object.id_territory);
        m_adres := t.short_adres;
        m_full_adres := t.full_adres;

        m_object_address := 'д.' || TRIM(p_object.dom);
        IF p_object.building_no IS NOT NULL THEN
            m_object_address := m_object_address || ' корп. ' || TRIM(p_object.building_no);
        END IF;

        IF p_object.id_object_class = 10 THEN                        -- подъезд
            m_object_address := m_object_address || ' подъезд ' || TRIM(p_object.object_no::TEXT);
        END IF;

        IF p_object.kw IS NOT NULL THEN
            IF p_object.id_object_class = 11 THEN                    -- комната
                -- Для комнат добавляем номер квартиры и затем логический номер комнаты
                m_object_address := m_object_address || ' кв. ' || TRIM(p_object.kw)
                    || ' ' || m_type_name || ' ' || TRIM(p_object.room_no);
            ELSE
                m_object_address := m_object_address || ' ' || m_type_name || ' ' || TRIM(p_object.kw);
            END IF;
        END IF;

        m_adres := m_adres || m_object_address;
        m_full_adres := m_full_adres || m_object_address;
    END IF;

    -- === Альтернативный адрес (угловые дома с двумя официальными адресами) ======================
    IF p_object.id_territory2 IS NOT NULL THEN
        t2 := territory_pkg.get_info(p_object.id_territory2);
        m_adres2 := t2.short_adres;
        m_full_adres2 := t2.full_adres;

        m_object_address := 'д.' || TRIM(p_object.dom2);
        IF p_object.building_no2 IS NOT NULL THEN
            m_object_address := m_object_address || ' корп. ' || TRIM(p_object.building_no2);
        END IF;

        -- Логика для подъездов/комнат/помещений та же, что и для основного адреса
        IF p_object.id_object_class = 10 THEN
            m_object_address := m_object_address || ' подъезд ' || TRIM(p_object.object_no::TEXT);
        END IF;

        IF p_object.kw IS NOT NULL THEN
            IF p_object.id_object_class = 11 THEN
                m_object_address := m_object_address || ' кв. ' || TRIM(p_object.kw)
                    || ' ' || m_type_name || ' ' || TRIM(p_object.room_no);
            ELSE
                m_object_address := m_object_address || ' ' || m_type_name || ' ' || TRIM(p_object.kw);
            END IF;
        END IF;

        m_adres2 := m_adres2 || m_object_address;
        m_full_adres2 := m_full_adres2 || m_object_address;
    END IF;

    -- zip: свой у объекта, если задан, иначе -- то, что вернула сборка адреса (наследуется по
    -- иерархии territory снизу вверх -- см. territory_pkg.get_info).
    m_zip := COALESCE(p_object.zip, t.zip);

    IF LOWER(p_action) = 'insert' THEN
        INSERT INTO ba7_data.object_info_tbl (
            id_object, id_territory, id_street, house, building_no, flat, id_object_class, id_object_type, sq_all,
            adres, full_adres, street_name, object_name, city_name, id_raion, raion_name, id_city, id_entity_instance,
            type_name, trace_info,
            adr_pos01, adr_pos02, adr_pos03, adr_pos04, adr_pos05, adr_pos06, adr_pos07, adr_pos08, adr_pos09, adr_pos10,
            id_territory2, id_street2, house2, building_no2, adres2, full_adres2, street_name2, city_name2, id_raion2, raion_name2,
            is_exist_alternate_adres, addressing_mode, id_house_doorway, id_object_house,
            id_main_city, main_city_name, id_district, district_name, id_region, region_name, zip,
            object_no, volume, sq_life, room_no
        ) VALUES (
            p_object.id_object, p_object.id_territory, t.id_street, p_object.dom, p_object.building_no, p_object.kw,
            p_object.id_object_class, p_object.id_object_type, p_object.sq_all,
            m_adres, m_full_adres,
            COALESCE(t.street_name, ' '), p_object.object_name, t.city_name, t.id_raion, t.raion_name, t.id_city,
            p_object.id_entity_instance, m_type_name, p_object.trace_info,
            t.adr_pos01, t.adr_pos02, t.adr_pos03, t.adr_pos04, t.adr_pos05, t.adr_pos06, t.adr_pos07, t.adr_pos08, t.adr_pos09, t.adr_pos10,
            p_object.id_territory2, t2.id_street, p_object.dom2, p_object.building_no2,
            m_adres2, m_full_adres2,
            COALESCE(t2.street_name, ' '), t2.city_name, t2.id_raion, t2.raion_name,
            CASE WHEN p_object.id_territory2 IS NOT NULL THEN 1 ELSE 0 END,
            p_object.addressing_mode, p_object.id_house_doorway, p_object.id_object_house,
            t.id_main_city, t.main_city_name, t.id_district, t.district_name, t.id_region, t.region_name, m_zip,
            p_object.object_no, p_object.volume, p_object.sq_life, p_object.room_no
        );
    END IF;

    IF LOWER(p_action) = 'update' THEN
        UPDATE ba7_data.object_info_tbl SET
            id_street = t.id_street,
            id_territory = p_object.id_territory,
            house = p_object.dom,
            building_no = p_object.building_no,
            flat = p_object.kw,
            id_object_class = p_object.id_object_class,
            id_object_type = p_object.id_object_type,
            sq_all = p_object.sq_all,
            adres = m_adres,
            full_adres = m_full_adres,
            -- Если у объекта нет основной территории (id_territory IS NULL), adr_posNN не трогаем --
            -- как и в Oracle-оригинале (NVL2(:new.id_territory, m$adr_posNN, adr_posNN)).
            adr_pos01 = CASE WHEN p_object.id_territory IS NOT NULL THEN t.adr_pos01 ELSE adr_pos01 END,
            adr_pos02 = CASE WHEN p_object.id_territory IS NOT NULL THEN t.adr_pos02 ELSE adr_pos02 END,
            adr_pos03 = CASE WHEN p_object.id_territory IS NOT NULL THEN t.adr_pos03 ELSE adr_pos03 END,
            adr_pos04 = CASE WHEN p_object.id_territory IS NOT NULL THEN t.adr_pos04 ELSE adr_pos04 END,
            adr_pos05 = CASE WHEN p_object.id_territory IS NOT NULL THEN t.adr_pos05 ELSE adr_pos05 END,
            adr_pos06 = CASE WHEN p_object.id_territory IS NOT NULL THEN t.adr_pos06 ELSE adr_pos06 END,
            adr_pos07 = CASE WHEN p_object.id_territory IS NOT NULL THEN t.adr_pos07 ELSE adr_pos07 END,
            adr_pos08 = CASE WHEN p_object.id_territory IS NOT NULL THEN t.adr_pos08 ELSE adr_pos08 END,
            adr_pos09 = CASE WHEN p_object.id_territory IS NOT NULL THEN t.adr_pos09 ELSE adr_pos09 END,
            adr_pos10 = CASE WHEN p_object.id_territory IS NOT NULL THEN t.adr_pos10 ELSE adr_pos10 END,
            street_name = COALESCE(t.street_name, ' '),
            object_name = p_object.object_name,
            city_name = t.city_name,
            id_raion = t.id_raion,
            raion_name = t.raion_name,
            id_city = t.id_city,
            id_entity_instance = p_object.id_entity_instance,
            type_name = COALESCE(m_type_name, type_name),
            trace_info = p_object.trace_info,
            -- ИСПРАВЛЕНО относительно Oracle-оригинала: там UPDATE-ветка ошибочно писала
            -- "id_street2 = :new.id_territory2" (копипаст-баг, INSERT-ветка делает это правильно
            -- через m$id_street2). Здесь -- корректно, из результата сборки альтернативного адреса.
            id_street2 = t2.id_street,
            id_territory2 = p_object.id_territory2,
            house2 = p_object.dom2,
            building_no2 = p_object.building_no2,
            is_exist_alternate_adres = CASE WHEN p_object.id_territory2 IS NOT NULL THEN 1 ELSE 0 END,
            adres2 = m_adres2,
            full_adres2 = m_full_adres2,
            street_name2 = COALESCE(t2.street_name, ' '),
            city_name2 = t2.city_name,
            id_raion2 = t2.id_raion,
            raion_name2 = t2.raion_name,
            id_city2 = t2.id_city,
            addressing_mode = p_object.addressing_mode,
            id_house_doorway = p_object.id_house_doorway,
            id_object_house = p_object.id_object_house,
            id_main_city = t.id_main_city,
            main_city_name = t.main_city_name,
            id_district = t.id_district,
            district_name = t.district_name,
            id_region = t.id_region,
            region_name = t.region_name,
            zip = m_zip,
            object_no = p_object.object_no,
            volume = p_object.volume,
            sq_life = p_object.sq_life,
            room_no = p_object.room_no
        WHERE id_object = p_object.id_object;
    END IF;
END;
$$;

-- -----------------------------------------------------------------------------------------------
-- update_object_info(id_object, action) -- добирает строку из ba7_data.object по id и передаёт
-- дальше. В Oracle-оригинале это делалось через EXECUTE IMMEDIATE (динамический SQL по списку
-- l$object_required_column_list, чтобы не дублировать список колонок) -- здесь список колонок
-- статический (он и так продублирован в object_row_type в 00_ddl.sql), поэтому обычный SELECT.
-- -----------------------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION object_info_pkg.update_object_info(p_id_object BIGINT, p_action TEXT)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    m_object object_info_pkg.object_row_type;
BEGIN
    BEGIN
        SELECT id_object, id_territory, dom, building_no, kw, id_territory2, dom2, building_no2,
               id_object_class, id_object_type, sq_all, object_name, id_entity_instance, trace_info,
               addressing_mode, id_object_house, id_house_doorway, zip, object_no, volume, sq_life, room_no
            INTO STRICT m_object
        FROM ba7_data.object
        WHERE id_object = p_id_object;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE EXCEPTION 'Объект с id_object = % не найден', p_id_object;
    END;

    PERFORM object_info_pkg.update_object_info(m_object, p_action);
END;
$$;

-- -----------------------------------------------------------------------------------------------
-- update_object_info(id_object_list, action) -- та же операция скопом по массиву id.
--
-- 'delete' обрабатывается отдельной прямой командой DELETE, а не через цикл по одиночным id --
-- как и в Oracle-оригинале (там верхнеуровневая update_object_info без аргументов делала
-- "DELETE FROM object_info_tbl WHERE id_object IN (...)" отдельной веткой, а не звала
-- update_object_info(id,'delete') по одному). Это принципиально: к моменту вызова из
-- AFTER DELETE STATEMENT-триггера (03_object_info_triggers.sql) строк в ba7_data.object уже нет --
-- перегрузка по одиночному id ищет данные именно там и упадёт с "объект не найден".
-- -----------------------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION object_info_pkg.update_object_info(p_id_object_list BIGINT[], p_action TEXT)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    m_id_object BIGINT;
BEGIN
    IF p_id_object_list IS NULL THEN
        RETURN;
    END IF;

    IF LOWER(p_action) = 'delete' THEN
        DELETE FROM ba7_data.object_info_tbl WHERE id_object = ANY (p_id_object_list);
        RETURN;
    END IF;

    FOREACH m_id_object IN ARRAY p_id_object_list LOOP
        PERFORM object_info_pkg.update_object_info(m_id_object, p_action);
    END LOOP;
END;
$$;

-- -----------------------------------------------------------------------------------------------
-- rebuild() -- полная пересборка object_info_tbl: удалить осиротевшие строки, вставить отсутствующие,
-- затем форсировать пересчёт производных полей "пустыми" UPDATE по всем подтиповым таблицам и object
-- (срабатывают триггеры из 03_object_info_triggers.sql / 04_subtype_triggers.sql).
-- -----------------------------------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE object_info_pkg.rebuild()
LANGUAGE plpgsql
AS $$
DECLARE
    m_id_object_insert BIGINT[];
BEGIN
    -- TODO: аналог int_rep_session.setDbAccessMode(2) -- в Oracle-оригинале временно переключал
    -- режим доступа к БД, чтобы массовый пересчёт не попадал в очередь межбазовой репликации BA7.
    -- PostgreSQL-аналога пакета int_rep_session ещё нет; при появлении -- обернуть тело вызовами
    -- сохранения/восстановления режима по аналогии с Oracle-версией.
    -- m_mode := int_rep_session.getDbAccessMode();
    -- CALL int_rep_session.setDbAccessMode(2);

    DELETE FROM ba7_data.object_info_tbl
    WHERE id_object NOT IN (SELECT id_object FROM ba7_data.object);

    SELECT array_agg(id_object) INTO m_id_object_insert
    FROM ba7_data.object
    WHERE id_object NOT IN (SELECT id_object FROM ba7_data.object_info_tbl);

    IF m_id_object_insert IS NOT NULL AND array_length(m_id_object_insert, 1) > 0 THEN
        PERFORM object_info_pkg.update_object_info(m_id_object_insert, 'insert');
    END IF;

    UPDATE ba7_data.object_house   SET id_territory    = id_territory;
    UPDATE ba7_data.object_flat    SET id_object_house = id_object_house;
    UPDATE ba7_data.house_doorway  SET id_object_house = id_object_house;
    UPDATE ba7_data.object_unknown SET id_territory    = id_territory;
    UPDATE ba7_data.object_room    SET id_object_flat  = id_object_flat;
    UPDATE ba7_data.object         SET id_territory    = id_territory;

    -- CALL int_rep_session.setDbAccessMode(m_mode);
END;
$$;

-- -----------------------------------------------------------------------------------------------
-- rebuild(batch_size) -- то же самое, но диапазонами id_object, чтобы не держать долгую транзакцию
-- и блокировки на всю таблицу разом. Прямой идиоматичный PostgreSQL-аналог Oracle run_sql_parts:
-- там это была отдельная фреймворковая процедура с динамическим SQL, здесь -- обычный LOOP по
-- диапазонам с COMMIT после каждого батча (допустимо для PROCEDURE, вызванной верхнеуровневым CALL).
-- -----------------------------------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE object_info_pkg.rebuild(p_batch_size BIGINT)
LANGUAGE plpgsql
AS $$
DECLARE
    m_min_id           BIGINT;
    m_max_id           BIGINT;
    m_from             BIGINT;
    m_to               BIGINT;
    m_id_object_insert BIGINT[];
BEGIN
    IF p_batch_size IS NULL THEN
        CALL object_info_pkg.rebuild();
        RETURN;
    END IF;

    SELECT MIN(id_object), MAX(id_object) INTO m_min_id, m_max_id FROM ba7_data.object;
    IF m_min_id IS NULL THEN
        RETURN;
    END IF;

    m_from := m_min_id;
    WHILE m_from <= m_max_id LOOP
        m_to := m_from + p_batch_size - 1;

        DELETE FROM ba7_data.object_info_tbl
        WHERE id_object BETWEEN m_from AND m_to
          AND id_object NOT IN (SELECT id_object FROM ba7_data.object);

        SELECT array_agg(id_object) INTO m_id_object_insert
        FROM ba7_data.object
        WHERE id_object BETWEEN m_from AND m_to
          AND id_object NOT IN (SELECT id_object FROM ba7_data.object_info_tbl);

        IF m_id_object_insert IS NOT NULL AND array_length(m_id_object_insert, 1) > 0 THEN
            PERFORM object_info_pkg.update_object_info(m_id_object_insert, 'insert');
        END IF;

        UPDATE ba7_data.object_house   SET id_territory    = id_territory    WHERE id_object BETWEEN m_from AND m_to;
        UPDATE ba7_data.object_flat    SET id_object_house = id_object_house WHERE id_object BETWEEN m_from AND m_to;
        UPDATE ba7_data.house_doorway  SET id_object_house = id_object_house WHERE id_object BETWEEN m_from AND m_to;
        UPDATE ba7_data.object_unknown SET id_territory    = id_territory    WHERE id_object BETWEEN m_from AND m_to;
        UPDATE ba7_data.object_room    SET id_object_flat  = id_object_flat  WHERE id_object BETWEEN m_from AND m_to;
        UPDATE ba7_data.object         SET id_territory    = id_territory    WHERE id_object BETWEEN m_from AND m_to;

        COMMIT;

        m_from := m_to + 1;
    END LOOP;
END;
$$;

-- TODO: аналог scheming_pkg.group_synonym/group_privs -- права EXECUTE для схем-потребителей.
-- GRANT USAGE ON SCHEMA object_info_pkg TO test_owner_role;
-- GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA object_info_pkg TO test_owner_role;
