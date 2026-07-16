CREATE OR REPLACE TRIGGER TBIU1_OBJECT_HOUSE 
    BEFORE INSERT OR UPDATE OF id_territory, house_no, building_no, id_territory2, house_no2, building_no2, addressing_mode, zip, sq_life ON OBJECT_HOUSE 
        FOR EACH ROW 
DECLARE
/*
    07.12.2021 SHA: обработан sq_life
*/
BEGIN
    /* Триггер, который:
        1) Форматирует номера домов
        2) Копирует в основную таблицу object ряд полей
        3) Вносит изменения в помещения и подъезды в зависимости от режима адресации
     */
/*
    m$new_house_no := NVL(LPAD(TRIM(:new.house_no), 10, ' '), '          ');
    -- Если после сдвига номер здания не испортился, то соглашаемся на сдвиг
    IF TRIM(m$new_house_no) = TRIM(:new.house_no) THEN
        :new.house_no := m$new_house_no;
    END IF;
*/  
    
    :new.house_no := object_info_pkg.format_object_no(:new.house_no, 10);
/*
    m$new_house_no2 := NVL(LPAD(TRIM(:new.house_no2), 6, ' '), '      ');
    -- Если после сдвига номер здания не испортился, то соглашаемся на сдвиг
    IF TRIM(m$new_house_no2) = TRIM(:new.house_no2) THEN
        :new.house_no2 := m$new_house_no2;
    END IF;
*/
    :new.house_no2 := object_info_pkg.format_object_no(:new.house_no2, 6);
    
    UPDATE object
        SET   id_territory = :new.id_territory
            , dom = :new.house_no
            , building_no = :new.building_no
            , id_territory2 = :new.id_territory2
            , dom2 = :new.house_no2
            , building_no2 = :new.building_no2
            , addressing_mode = :new.addressing_mode
            , zip = :new.zip
            , sq_life = :new.sq_life
        WHERE id_object = :new.id_object;

    -- Если адресация "по домам", то обновляем данные из дома в помещениях, подъездах, комнатах
    IF :new.addressing_mode = 1 THEN
        UPDATE object SET id_territory = :new.id_territory, dom = :new.house_no, building_no = :new.building_no
                , id_territory2 = :new.id_territory2, dom2 = :new.house_no2, building_no2 = :new.building_no2
                , addressing_mode = :new.addressing_mode, zip = :new.zip
            WHERE id_object IN (
                -- Помещения
                SELECT id_object FROM object_flat WHERE id_object_house = :old.id_object
                    UNION ALL
                -- Подъезды
                SELECT id_object FROM house_doorway WHERE id_object_house = :old.id_object
                    UNION ALL
                -- Комнаты
                SELECT id_object FROM object_room WHERE id_object_flat IN (SELECT id_object FROM object_flat WHERE id_object_house = :old.id_object));
/*
        UPDATE object SET id_territory = :new.id_territory, dom = :new.house_no, building_no = :new.building_no
                , id_territory2 = :new.id_territory2, dom2 = :new.house_no2, building_no2 = :new.building_no2
                , addressing_mode = :new.addressing_mode, zip = :new.zip
            WHERE id_object IN (SELECT id_object FROM house_doorway WHERE id_object_house = :old.id_object);
*/

    -- Если адресация "по подъездам", то обновляем данные в помещениях, подъездах, комнатах
    ELSIF :new.addressing_mode = 2 THEN
        UPDATE object A SET A.id_territory = :new.id_territory, A.building_no = NULL, A.id_territory2 = NULL, A.dom2 = NULL, A.building_no2 = NULL,
                A.dom = (SELECT C.house_no
                         FROM object_flat B
                         JOIN house_doorway C ON B.id_object_house = C.id_object_house AND B.id_house_doorway = C.id_object
                         WHERE A.id_object = B.id_object),
                addressing_mode = :new.addressing_mode, zip = :new.zip
        WHERE A.id_object IN (
            -- Помещения
            SELECT id_object FROM object_flat WHERE id_object_house = :old.id_object
                UNION ALL
            -- Комнаты
            SELECT id_object FROM object_room WHERE id_object_flat IN (SELECT id_object FROM object_flat WHERE id_object_house = :old.id_object));

        UPDATE (SELECT A.id_territory, A.dom, A.building_no, A.id_territory2, A.dom2, A.building_no2, B.house_no, A.addressing_mode, A.zip
                FROM object A
                JOIN house_doorway B ON A.id_object = B.id_object
                WHERE B.id_object_house = :old.id_object)
            SET id_territory = :new.id_territory, dom = house_no, building_no = NULL
                , id_territory2 = NULL, dom2 = NULL, building_no2 = NULL, addressing_mode = :new.addressing_mode, zip = :new.zip;
    ELSE
        RAISE_APPLICATION_ERROR(-20000, '<<Неизвестный способ адресации в доме ('||:new.addressing_mode||')>>');
    END IF;
end;
/
