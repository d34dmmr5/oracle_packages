CREATE OR REPLACE TRIGGER tbiu1_object_unknown
    BEFORE INSERT OR UPDATE OF id_territory, house_no, zip ON object_unknown
        FOR EACH ROW 
BEGIN
    /* Триггер, который:
        1) Форматирует номера домов
        2) Копирует в основную таблицу object ряд полей
     */
--    :new.house_no := NVL(LPAD(TRIM(:new.house_no), 10, ' '), '          ');
    :new.house_no := object_info_pkg.format_object_no(:new.house_no, 10);
    UPDATE object
        SET   id_territory = :new.id_territory
            , dom = :new.house_no
            , zip = :new.zip
        WHERE id_object = :new.id_object;
end;
/
