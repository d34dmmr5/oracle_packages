
		 __________________________________
		/||==============================||\
	   ⟨o||object_info_pkg ==> PostgreSQL||o⟩
		\||==============================||/
		 ‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾ 
		 
CREATE SCHEMA IF NOT EXISTS object_info_pkg;

----
init
----

CREATE OR REPLACE PROCEDURE object_info_pkg.init(
	OUT l$id_object_insert 	  int8[],
	OUT l$id_object_update 	  int8[],
	OUT l$id_object_delete 	  int8[],
	OUT l$id_territory_update int8[]
)
AS $$
BEGIN
	-- аналог TTableNumber() - инициализация пустой коллекции
	l$id_object_insert    := ARRAY[]::int8[];
	l$id_object_update    := ARRAY[]::int8[];
	l$id_object_delete	  := ARRAY[]::int8[];
	l$id_territory_update := ARRAY[]::int8[];
END;
$$ LANGUAGE plpgsql;

-----------------
add_object_insert
-----------------

CREATE OR REPLACE PROCEDURE object_info_pkg.add_object_insert(
	INOUT l$id_object_insert int8[],
	IN    l$id_object 		 int8
)
AS $$
BEGIN
	-- аналог .EXTEND + присвоение последнему элементу
	l$id_object_insert := array_append(l$id_object_insert, l$id_object);
END;
$$ LANGUAGE plpgsql;

-----------------
add_object_update
-----------------

CREATE OR REPLACE PROCEDURE object_info_pkg.add_object_update(
	INOUT l$id_object_update int8[],
	IN 	  l$id_object 		 int8
)
AS $$
BEGIN
	l$id_object_update := array_append(l$id_object_update, l$id_object);
END;
$$ LANGUAGE plpgsql;

-----------------
add_object_delete
-----------------
CREATE OR REPLACE PROCEDURE object_info_pkg.add_object_delete(
	INOUT l$id_object_delete int8[],
	IN    l$id_object 		 int8
)
AS $$
BEGIN
	l$id_object_delete := array_append(l$id_object_delete, l$id_object);
END;
$$ LANGUAGE plpgsql;


--------------------
add_territory_update
--------------------
CREATE OR REPLACE PROCEDURE object_info_pkg.add_territory_update(
	INOUT l$id_territory_update int8[],
	IN    l$id_territory 		int8
)
AS $$
BEGIN
	l$id_territory_update := array_append(l$id_territory_update, l$id_territory);
END;
$$ LANGUAGE plpgsql;


------------------
update_object_info
------------------
CREATE OR REPLACE PROCEDURE object_info_pkg.update_object_info(
	INOUT p$id_object_insert 	int8[],
	INOUT p$id_object_update 	int8[],
	INOUT p$id_object_delete 	int8[],
	INOUT p$id_territory_update int8[]
)
AS $$
DECLARE
	m$obj RECORD;
BEGIN
	IF cardinality(p$id_object_delete) > 0 THEN
		DELETE FROM object_info_tbl
		WHERE id_object = ANY(p$id_object_delete);
		p$id_object_delete := ARRAY[]::int8[];
	END IF;

	IF cardinality(p$id_object_update) > 0 THEN
		CALL object_info_pkg.update_object_info(p$id_object_update, 'update');
		p$id_object_update := ARRAY[]::int8[];
	END IF;

	IF cardinality(p$id_object_insert) > 0 THEN
		CALL object_info_pkg.update_object_info(p$id_object_insert, 'insert');
		p$id_object_insert := ARRAY[]::int8[];
	END IF;

	IF cardinality(p$id_territory_update) > 0 THEN
		FOR m$obj IN (
			WITH RECURSIVE terr AS (
				SELECT id_territory
				FROM territory
				WHERE id_territory = ANY(p$id_territory_update)
					UNION ALL
				SELECT t.id_territory
				FROM territory t
				JOIN terr ON t.id_parent = terr.id_territory
            )
			SELECT DISTINCT id_object FROM object
			WHERE id_territory = ANY(
				SELECT id_territory FROM terr
            )
				UNION
			SELECT id_object FROM object
			WHERE id_territory2 = ANY(
				SELECT id_territory FROM terr
			)
		)
		LOOP
			CALL object_info_pkg.update_object_info(m$obj.id_object, 'update');
		END LOOP;
-- В пакете Oracle нет явного .DELETE после территорий
-- Добавляем для корректности - чтобы повторный вызов не обработал снова
		p$id_territory_update := ARRAY[]::int8[];
	END IF;
END;
$$ LANGUAGE plpgsql;

--
==
--

CREATE OR REPLACE PROCEDURE object_info_pkg.update_object_info(
	IN p$id_object_list BIGINT[],
	IN l$action TEXT
)
AS $$
DECLARE
    m$id_object int8;
BEGIN
	FOREACH m$id_object IN ARRAY p$id_object_list
	LOOP
		CALL object_info_pkg.update_object_info(m$id_object, l$action);
	END LOOP;
END;
$$ LANGUAGE plpgsql;

--
==
--

PROCEDURE update_object_info(
	p$object int, 
	p$action text
) as $$
m$type_name       text;
m$object_address  text;
		--
m$adres           text;
m$full_adres      text;
m$id_street       int;
m$street_name     text;
m$id_district     int;
m$district_name   text;
m$id_city         int;
m$city_name       text;
m$id_main_city    int;
m$main_city_name  text;
m$id_raion        int;
m$raion_name      text;
m$id_region       int;
m$region_name     text;
		--
m$adr_pos01       int;
m$adr_pos02       int;
m$adr_pos03       int;
m$adr_pos04       int;
m$adr_pos05       int;
m$adr_pos06       int;
m$adr_pos07       int;
m$adr_pos08       int;
m$adr_pos09       int;
m$adr_pos10       int;
m$adr_posXX       int;
		--
--для альтернативного адреса
m$adres2          text;
m$full_adres2     text;
m$street_name2    text;
m$id_street2      int;
m$city_name2      text;
m$id_district2    int;
m$district_name2  text;
m$id_main_city2   int;
m$main_city_name2 text;
m$id_region2      int;
m$region_name2    text;
m$id_raion2       int;
m$raion_name2     text;
m$id_city2        int;
m$zip             int;
m$zip2            int;
BEGIN
	IF LOWER(p$action) = 'delete' THEN
        DELETE FROM object_info_tbl WHERE id_object = p$object.id_object;
        RETURN;
    END IF;
    -- Условие IF TRUE сохраняем как есть - исторически там была оптимизация
    -- которая проверяла изменился ли id_object_type, но в триггере это недоступно
	IF TRUE THEN
		SELECT name
			INTO m$type_name
		FROM object_type
		WHERE id_object_class = p$object.id_object_class
		  AND id_object_type  = p$object.id_object_type;
    END IF;

-- -- -- -- ОСНОВНОЙ АДРЕС -- -- --
-- -- Oracle: IF p$object.id_territory IS NOT NULL THEN
--		GetTerritoryInfo(p$object.id_territory, m$adres, m$full_adres,
--			m$id_street, m$street_name, m$id_city, m$city_name,
--			m$id_main_city, m$main_city_name, m$id_district, m$district_name,
--			m$id_raion, m$raion_name, m$id_region, m$region_name,
--			m$adr_pos01..10, m$zip);
-- -- PG: GetTerritoryInfo возвращает составной тип territory_info_type
	IF p$object.id_territory IS NOT NULL THEN
		SELECT
			short_adres,  full_adres,
			id_street,    street_name,
			id_city, 	  city_name,
			id_main_city, main_city_name,
			id_district,  district_name,
			id_raion, 	  raion_name,
			id_region, 	  region_name,
			adr_pos01, 	  adr_pos02, 
			adr_pos03, 	  adr_pos04, 
			adr_pos05,	  adr_pos06, 
			adr_pos07, 	  adr_pos08, 
			adr_pos09, 	  adr_pos10,
			zip
		INTO
			m$adres, 		m$full_adres,
			m$id_street, 	m$street_name,
			m$id_city, 		m$city_name,
			m$id_main_city, m$main_city_name,
			m$id_district,  m$district_name,
			m$id_raion, 	m$raion_name,
			m$id_region, 	m$region_name,
			m$adr_pos01, 	m$adr_pos02, 
			m$adr_pos03, 	m$adr_pos04, 
			m$adr_pos05, 	m$adr_pos06, 
			m$adr_pos07, 	m$adr_pos08, 
			m$adr_pos09, 	m$adr_pos10,
			m$zip
		FROM get_territory_info(p$object.id_territory);

        	m$object_address := 'д.' || TRIM(p$object.dom);

		IF p$object.building_no IS NOT NULL THEN
			m$object_address := m$object_address || ' корп. ' || TRIM(p$object.building_no);
		END IF;

		IF p$object.id_object_class = 10 THEN
			m$object_address := m$object_address || ' подъезд ' || TRIM(p$object.object_no::TEXT);
		END IF;

		IF p$object.kw IS NOT NULL THEN
			IF p$object.id_object_class = 11 THEN
				m$object_address := m$object_address
					||' кв. '|| TRIM(p$object.kw)
					||  ' '	 || m$type_name
					||  ' '	 || TRIM(p$object.room_no::TEXT);
			ELSE
				m$object_address := m$object_address
					||' '|| m$type_name
					||' '|| TRIM(p$object.kw);
			END IF;
		END IF;

		m$adres		 := m$adres      || m$object_address;
		m$full_adres := m$full_adres || m$object_address;
    END IF;

    -- -- -- АЛЬТЕРНАТИВНЫЙ АДРЕС -- -- --
	IF p$object.id_territory2 IS NOT NULL THEN
		SELECT
			short_adres,  full_adres,
			id_street, 	  street_name,
			id_city, 	  city_name,
			id_main_city, main_city_name,
			id_district,  district_name,
			id_raion, 	  raion_name,
			id_region, 	  region_name,
            -- Oracle передаёт m$adr_posXX для всех 10 позиций альт. адреса —
            -- эти значения не используются, это заглушка (я надеюсь) 
            adr_pos01, adr_pos02, 
			adr_pos03, adr_pos04, 
			adr_pos05, adr_pos06, 
			adr_pos07, adr_pos08, 
			adr_pos09, adr_pos10,
            zip
        INTO
			m$adres2, 		 m$full_adres2,
			m$id_street2, 	 m$street_name2,
			m$id_city2, 	 m$city_name2,
			m$id_main_city2, m$main_city_name2,
			m$id_district2,  m$district_name2,
			m$id_raion2, 	 m$raion_name2,
			m$id_region2, 	 m$region_name2,

			m$adr_posXX, m$adr_posXX, 
			m$adr_posXX, m$adr_posXX, 
			m$adr_posXX, m$adr_posXX, 
			m$adr_posXX, m$adr_posXX, 
			m$adr_posXX, m$adr_posXX,
			m$zip2
        FROM get_territory_info(p$object.id_territory2);

        m$object_address := 'д.' || TRIM(p$object.dom2);

        -- Oracle: баг в оригинале (строки 292-293) - building_no2 добавляется дважды
        -- Воспроизводим один раз 
        IF p$object.building_no2 IS NOT NULL THEN
			m$object_address := m$object_address ||' корп. '|| TRIM(p$object.building_no2);
		END IF;

		IF p$object.id_object_class = 10 THEN
			m$object_address := m$object_address ||' подъезд '|| TRIM(p$object.object_no::TEXT);
		END IF;

		IF p$object.kw IS NOT NULL THEN
			IF p$object.id_object_class = 11 THEN
				m$object_address := m$object_address
					||' кв. '|| TRIM(p$object.kw)
					||  ' '  || m$type_name
					||  ' '  || TRIM(p$object.room_no::TEXT);
			ELSE
				m$object_address := m$object_address
					||' '|| m$type_name
					||' '|| TRIM(p$object.kw);
			END IF;
		END IF;

		m$adres2	  := m$adres2      || m$object_address;
		m$full_adres2 := m$full_adres2 || m$object_address;
	END IF;

    -- Oracle: IF p$object.zip IS NOT NULL THEN m$zip := p$object.zip; END IF;
    -- zip из объекта приоритетнее чем zip из территории
    IF p$object.zip IS NOT NULL THEN
        m$zip := p$object.zip;
    END IF;

	-- -- -- INSERT -- -- --  
    IF LOWER(p$action) = 'insert' THEN
		INSERT INTO object_info_tbl (
			id_object, 		 id_territory, 	 id_street, 
			house, 			 building_no, 	 flat,
			id_object_class, id_object_type, sq_all,
			adres, 		 	 full_adres, 	 street_name, 
			object_name, 	 city_name, 	 id_raion, 
			raion_name, 	 id_city, 		 id_entity_instance, 
			type_name, 		 trace_info,

			adr_pos01, adr_pos02, 
			adr_pos03, adr_pos04, 
			adr_pos05, adr_pos06, 
			adr_pos07, adr_pos08, 
			adr_pos09, adr_pos10,

			id_territory2, 	 id_street2, 	   house2, 
			building_no2, 	 adres2, 		   full_adres2,
			street_name2, 	 city_name2, 	   id_raion2, 
			raion_name2, 	 id_city2, 		   is_exist_alternate_adres,
			addressing_mode, id_house_doorway, id_object_house,
			id_main_city, 	 main_city_name,   id_district, 
			district_name, 	 id_region, 	   region_name,
			zip,
			object_no, 		 volume, sq_life,  room_no
        )
        VALUES (
			p$object.id_object,   p$object.id_territory, 
			m$id_street, 		  p$object.dom, 			p$object.building_no, 
			p$object.kw, 		  p$object.id_object_class, p$object.id_object_type, 
			p$object.sq_all, 	  m$adres, 					m$full_adres,
   COALESCE(m$street_name, ' '),  p$object.object_name, 	m$city_name,

			m$id_raion, 				 m$raion_name, m$id_city,
			p$object.id_entity_instance, m$type_name,  p$object.trace_info,

			m$adr_pos01, m$adr_pos02, 
			m$adr_pos03, m$adr_pos04, 
			m$adr_pos05, m$adr_pos06, 
			m$adr_pos07, m$adr_pos08, 
			m$adr_pos09, m$adr_pos10,

			p$object.id_territory2, m$id_street2, p$object.dom2, 
			p$object.building_no2,  m$adres2, 	  m$full_adres2,
   COALESCE(m$street_name2, ' '),   m$city_name2, m$id_raion2, 
			m$raion_name2, 			m$id_city2,

			CASE WHEN p$object.id_territory2 IS NOT NULL THEN 1 ELSE 0 END,

			p$object.addressing_mode, p$object.id_house_doorway, p$object.id_object_house,
			m$id_main_city, 		  m$main_city_name, 		 m$id_district, 
			m$district_name, 		  m$id_region, 				 m$region_name,
            m$zip,
			p$object.object_no, 	  p$object.volume, 			 p$object.sq_life, 
			p$object.room_no
        );
    END IF;

	-- -- -- UPDATE -- -- -- 
	IF LOWER(p$action) = 'update' THEN
		UPDATE object_info_tbl SET
			id_street       = m$id_street,
			id_territory    = p$object.id_territory,
			house           = p$object.dom,
			building_no     = p$object.building_no,
			flat            = p$object.kw,
			id_object_class = p$object.id_object_class,
            id_object_type  = p$object.id_object_type,
            sq_all          = p$object.sq_all,
            adres           = m$adres,
            full_adres      = m$full_adres,
            -- Oracle: NVL2(p$object.id_territory, m$adr_pos01, adr_pos01)
            -- Если id_territory не NULL => берём новое значение, иначе оставляем старое
            -- PG: CASE WHEN p$object.id_territory IS NOT NULL THEN ... ELSE ... END
            adr_pos01 = CASE WHEN p$object.id_territory IS NOT NULL THEN m$adr_pos01 ELSE adr_pos01 END,
            adr_pos02 = CASE WHEN p$object.id_territory IS NOT NULL THEN m$adr_pos02 ELSE adr_pos02 END,
            adr_pos03 = CASE WHEN p$object.id_territory IS NOT NULL THEN m$adr_pos03 ELSE adr_pos03 END,
            adr_pos04 = CASE WHEN p$object.id_territory IS NOT NULL THEN m$adr_pos04 ELSE adr_pos04 END,
            adr_pos05 = CASE WHEN p$object.id_territory IS NOT NULL THEN m$adr_pos05 ELSE adr_pos05 END,
            adr_pos06 = CASE WHEN p$object.id_territory IS NOT NULL THEN m$adr_pos06 ELSE adr_pos06 END,
            adr_pos07 = CASE WHEN p$object.id_territory IS NOT NULL THEN m$adr_pos07 ELSE adr_pos07 END,
            adr_pos08 = CASE WHEN p$object.id_territory IS NOT NULL THEN m$adr_pos08 ELSE adr_pos08 END,
            adr_pos09 = CASE WHEN p$object.id_territory IS NOT NULL THEN m$adr_pos09 ELSE adr_pos09 END,
            adr_pos10 = CASE WHEN p$object.id_territory IS NOT NULL THEN m$adr_pos10 ELSE adr_pos10 END,
            -- Oracle: NVL(m$street_name, ' ') => COALESCE
            street_name        = COALESCE(m$street_name, ' '),
            object_name        = p$object.object_name,
            city_name          = m$city_name,
            id_raion           = m$id_raion,
            raion_name         = m$raion_name,
            id_city            = m$id_city,
            id_entity_instance = p$object.id_entity_instance,
            type_name          = COALESCE(m$type_name, type_name),
            trace_info         = p$object.trace_info,
            id_street2         = p$object.id_territory2,
            id_territory2      = p$object.id_territory2,
            house2             = p$object.dom2,
            building_no2       = p$object.building_no2,

            -- Oracle: NVL2(p$object.id_territory2, 1, 0)
            is_exist_alternate_adres = CASE WHEN p$object.id_territory2 IS NOT NULL THEN 1 ELSE 0 END,

            adres2             = m$adres2,
            full_adres2        = m$full_adres2,
            street_name2       = COALESCE(m$street_name2, ' '),
            city_name2         = m$city_name2,
            id_raion2          = m$id_raion2,
            raion_name2        = m$raion_name2,
            id_city2           = m$id_city2,
            addressing_mode    = p$object.addressing_mode,
            id_house_doorway   = p$object.id_house_doorway,
            id_object_house    = p$object.id_object_house,
            id_main_city       = m$id_main_city,
            main_city_name     = m$main_city_name,
            id_district        = m$id_district,
            district_name      = m$district_name,
            id_region          = m$id_region,
            region_name        = m$region_name,
            zip                = m$zip,
            object_no          = p$object.object_no,
            volume             = p$object.volume,
            sq_life            = p$object.sq_life,
            room_no            = p$object.room_no
        WHERE id_object = p$object.id_object;
    END IF;
END;
$$ language plpgsql;
