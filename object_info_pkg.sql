CREATE OR REPLACE PACKAGE object_info_pkg AS
/*
Пакет решает задачи по актуализации сводной таблицы object_info_tbl (как следствие - представления object_info).
В задачи входит:
    1) Актуализация конкретной строки в object_info_tbl (создание, удаление, обновление) с разными точками входа:
        - по списку ИД объектов
        - по одному ИД объекта (для использования из триггеров уровня команды подклассовых таблицы сущности объект)
        - по типу OBJECT%ROWTYPE (для использования из триггера на object, чтобы не делать лишний SELECT)
    2) Обновление всей таблицы object_info_tbl
    3) Создание триггеров для обновления (раньше их писали руками, а зачем? :)))
    4) Пересоздание представления (опционально с выдачей прав и созданием синонимов)


DROP TRIGGER taiu6_object;
*/



l$id_object_insert TTableNumber;
l$id_object_update TTableNumber;
l$id_object_delete TTableNumber;

l$id_territory_update TTableNumber;

PROCEDURE init;

PROCEDURE add_object_insert(p$id_object NUMBER);
PROCEDURE add_object_update(p$id_object NUMBER);
PROCEDURE add_object_delete(p$id_object NUMBER);

PROCEDURE add_territory_update(p$id_territory NUMBER);

PROCEDURE update_object_info;
PROCEDURE update_object_info(p$id_object_list TTableNumber, p$action VARCHAR2);
PROCEDURE update_object_info(p$id_object NUMBER, p$action VARCHAR2);
PROCEDURE update_object_info(p$object OBJECT%ROWTYPE, p$action VARCHAR2);

PROCEDURE create_triggers;
PROCEDURE create_view(p$with_grants NUMBER DEFAULT 0);

PROCEDURE rebuild;
PROCEDURE rebuild(p$batch_size NUMBER);

FUNCTION get_version RETURN VARCHAR2;
FUNCTION format_object_no(p$object_no VARCHAR2, p$numeric_len NUMBER) RETURN VARCHAR2 DETERMINISTIC;
END;
/

-- @C:\svn\oracle\ba7_data\table\object_info\object_info_pkg_body.sql



CREATE OR REPLACE PACKAGE BODY object_info_pkg AS

/*
    Список полей таблицы object, которые нужны для обновления данных в object_info_tbl (id_object добавлять не надо!!).
    Используется для генерации триггеров.
    При необходимости синхронизации с object_info_tbl нового поля таблицы object нужно:
        - добавить его в список, 
        - а также обработать в командах INSERT и UPDATE в методе update_object_info
*/

l$object_required_column_list TTableString := TTableString('id_territory','dom','building_no','kw','id_territory2','dom2','building_no2',
    'id_object_class','id_object_type','sq_all','object_name','id_entity_instance','trace_info', 'addressing_mode', 'id_object_house', 
    'id_house_doorway', 'zip', 'object_no', 'volume', 'sq_life', 'room_no');



PROCEDURE init AS
BEGIN
    l$id_object_insert := TTableNumber();
    l$id_object_update := TTableNumber();
    l$id_object_delete := TTableNumber();
    l$id_territory_update := TTableNumber();
END;

PROCEDURE add_object_insert(p$id_object NUMBER) AS
BEGIN
    l$id_object_insert.EXTEND;
    l$id_object_insert(l$id_object_insert.COUNT) := p$id_object;
END;

PROCEDURE add_object_update(p$id_object NUMBER) AS
BEGIN
    l$id_object_update.EXTEND;
    l$id_object_update(l$id_object_update.COUNT) := p$id_object;
END;

PROCEDURE add_territory_update(p$id_territory NUMBER) AS
BEGIN
    l$id_territory_update.EXTEND;
    l$id_territory_update(l$id_territory_update.COUNT) := p$id_territory;
END;

PROCEDURE add_object_delete(p$id_object NUMBER) AS
BEGIN
    l$id_object_delete.EXTEND;
    l$id_object_delete(l$id_object_delete.COUNT) := p$id_object;
END;

PROCEDURE update_object_info AS
BEGIN
    IF l$id_object_delete.COUNT > 0 THEN
        DELETE FROM object_info_tbl WHERE id_object IN (SELECT column_value FROM TABLE(l$id_object_delete));
        l$id_object_delete.DELETE;
    END IF;

    IF l$id_object_update.COUNT > 0 THEN
        update_object_info(l$id_object_update, 'update');
        l$id_object_update.DELETE;
    END IF;

    IF l$id_object_insert.COUNT > 0 THEN
        update_object_info(l$id_object_insert, 'insert');
        l$id_object_insert.DELETE;
    END IF;

    IF l$id_territory_update.COUNT > 0 THEN
        FOR obj IN (WITH terr AS (
                        SELECT b.id_territory
                        FROM territory b
                            START WITH b.id_territory IN (SELECT column_value FROM TABLE(l$id_territory_update))
                            CONNECT BY PRIOR b.id_territory = b.id_parent)
                    SELECT DISTINCT id_object
                    FROM object
                    WHERE id_territory IN (SELECT id_territory FROM terr)
                        UNION
                    SELECT id_object
                    FROM object
                    WHERE id_territory2 IN (SELECT id_territory FROM terr))
        LOOP
            update_object_info(obj.id_object, 'update');
        END LOOP;
    END IF;
END;

PROCEDURE update_object_info(p$id_object_list TTableNumber, p$action VARCHAR2) AS
BEGIN
    FOR obj IN (SELECT column_value AS id_object FROM TABLE(p$id_object_list))
    LOOP
        update_object_info(obj.id_object, p$action);
    END LOOP;
END;

PROCEDURE update_object_info(p$id_object NUMBER, p$action VARCHAR2) AS
--m$object    object%ROWTYPE;
m$plsql       VARCHAR2(32000);
BEGIN
    m$plsql := '
DECLARE
    m$id_object NUMBER := :1;
    m$object    object%ROWTYPE;
BEGIN
    BEGIN
        SELECT id_object' || string_pkg.replace_multiply(', <<column_name>>', '<<column_name>>', l$object_required_column_list) || '
            INTO m$object.id_object' || string_pkg.replace_multiply(', m$object.<<column_name>>', '<<column_name>>', l$object_required_column_list) || '
        FROM object
        WHERE id_object = m$id_object;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN RAISE_APPLICATION_ERROR(-20000, ''Объект с id_object = '' || m$id_object || '' не найден'');
    END;
    --dbms_output.put_line(m$object.id_object ||'' ''|| m$object.id_territory||'' ''|| m$object.id_entity_instance);
    object_info_pkg.update_object_info(m$object, ''' || p$action || ''');
END;';
    EXECUTE IMMEDIATE m$plsql USING IN p$id_object;
END;

PROCEDURE update_object_info(p$object object%ROWTYPE, p$action VARCHAR2) AS
m$type_name       VARCHAR2(500) ;
m$object_address  VARCHAR2(1000);

m$adres           VARCHAR2(1000);
m$full_adres      VARCHAR2(1000);
m$id_street       NUMBER(10)    ;
m$street_name     VARCHAR2(500) ;
m$id_district     NUMBER(10)    ;
m$district_name   VARCHAR2(500) ;
m$id_city         NUMBER(10)    ;
m$city_name       VARCHAR2(500) ;
m$id_main_city    NUMBER(10)    ;
m$main_city_name  VARCHAR2(500) ;
m$id_raion        NUMBER(10)    ;
m$raion_name      VARCHAR2(500) ;
m$id_region       NUMBER(10)    ;
m$region_name     VARCHAR2(500) ;

m$adr_pos01       PLS_INTEGER;
m$adr_pos02       PLS_INTEGER;
m$adr_pos03       PLS_INTEGER;
m$adr_pos04       PLS_INTEGER;
m$adr_pos05       PLS_INTEGER;
m$adr_pos06       PLS_INTEGER;
m$adr_pos07       PLS_INTEGER;
m$adr_pos08       PLS_INTEGER;
m$adr_pos09       PLS_INTEGER;
m$adr_pos10       PLS_INTEGER;
m$adr_posXX       PLS_INTEGER;
--для альтернативного адреса
m$adres2          VARCHAR2(1000);
m$full_adres2     VARCHAR2(1000);
m$street_name2    VARCHAR2(500) ;
m$id_street2      NUMBER(10)    ;
m$city_name2      VARCHAR2(500) ;
m$id_district2    NUMBER(10)    ;
m$district_name2  VARCHAR2(500) ;
m$id_main_city2   NUMBER(10)    ;
m$main_city_name2 VARCHAR2(500) ;
m$id_region2      NUMBER(10)    ;
m$region_name2    VARCHAR2(500) ;
m$id_raion2       NUMBER(10)    ;
m$raion_name2     VARCHAR2(500) ;
m$id_city2        NUMBER(10)    ;
m$zip             NUMBER;
m$zip2            NUMBER;
BEGIN

    IF LOWER(p$action) = 'delete' THEN
        DELETE FROM object_info_tbl WHERE id_object = p$object.id_object;
        RETURN;
    END IF;

    IF TRUE /*p$object.id_object_type != NVL(:old.id_object_type, -999999) Так как мы уже не в триггере, то эту оптимизацию мы потеряли ((( */ THEN
        SELECT name
            INTO m$type_name
        FROM object_type
        WHERE id_object_class = p$object.id_object_class AND id_object_type = p$object.id_object_type;
    END IF;

    IF p$object.id_territory IS NOT NULL THEN
        GetTerritoryInfo(p$object.id_territory, m$adres, m$full_adres,
                    m$id_street, m$street_name,
                    m$id_city, m$city_name,
                    m$id_main_city, m$main_city_name,
                    m$id_district, m$district_name,
                    m$id_raion, m$raion_name,
                    m$id_region, m$region_name,
                    m$adr_pos01, m$adr_pos02, m$adr_pos03, m$adr_pos04, m$adr_pos05, m$adr_pos06, m$adr_pos07, m$adr_pos08, m$adr_pos09, m$adr_pos10, m$zip);

        m$object_address := 'д.' || TRIM(p$object.dom);

/*
        m$adres := m$adres || 'д.' || TRIM(p$object.dom);
        m$full_adres := m$full_adres || 'д.' || TRIM(p$object.dom);
*/

        IF p$object.building_no IS NOT NULL THEN
            m$object_address := m$object_address || ' корп. ' || TRIM(p$object.building_no);
/*
            m$adres := m$adres || ' корп. ' || TRIM(p$object.building_no);
            m$full_adres := m$full_adres || ' корп. ' || TRIM(p$object.building_no);
*/
        END IF;

        IF p$object.id_object_class = 10 THEN
            m$object_address := m$object_address || ' подъезд ' || TRIM(p$object.object_no);
/*
            m$adres := m$adres || ' подъезд ' || TRIM(p$object.object_no);
            m$full_adres := m$full_adres || ' подъезд ' || TRIM(p$object.object_no);
*/
        END IF;

        IF p$object.kw IS NOT NULL THEN
            -- Для комнат помещений добавляем номер квартиры и затем логический номер 
            IF p$object.id_object_class = 11 THEN
                -- 28.03.2022 SHA появился room_no - номер комнаты помещения
                m$object_address := m$object_address || ' кв. ' || TRIM(p$object.kw) || ' ' || m$type_name || ' ' || TRIM(p$object.room_no) /*p$object.object_no*/;
            ELSE
                m$object_address := m$object_address || ' ' || m$type_name || ' ' || TRIM(p$object.kw);
            END IF;
        END IF;

        m$adres := m$adres || m$object_address;
        m$full_adres := m$full_adres || m$object_address;
    END IF;

    IF p$object.id_territory2 IS NOT NULL THEN
        GetTerritoryInfo(p$object.id_territory2, m$adres2, m$full_adres2,
                      m$id_street2, m$street_name2,
                      m$id_city2, m$city_name2,
                      m$id_main_city2, m$main_city_name2,
                      m$id_district2, m$district_name2,
                      m$id_raion2, m$raion_name2,
                      m$id_region2, m$region_name2,
                      m$adr_posXX , m$adr_posXX, m$adr_posXX, m$adr_posXX , m$adr_posXX, m$adr_posXX,m$adr_posXX , m$adr_posXX, m$adr_posXX, m$adr_posXX, m$zip2);

        m$object_address := 'д.' || TRIM(p$object.dom2);
/*
        m$adres2 := m$adres2 || 'д.' || TRIM(p$object.dom2);
        m$full_adres2 := m$full_adres2 || 'д.' || TRIM(p$object.dom2);
*/
        IF p$object.building_no2 IS NOT NULL THEN
            m$object_address := m$object_address || ' корп. ' || TRIM(p$object.building_no2);
            m$object_address := m$object_address || ' корп. ' || TRIM(p$object.building_no2);
        END IF;

        -- Логика для подъездов, комнат и помещений та же что и для основного адреса
        IF p$object.id_object_class = 10 THEN
            m$object_address := m$object_address || ' подъезд ' || TRIM(p$object.object_no);
        END IF;

        IF p$object.kw IS NOT NULL THEN
            -- Для комнат помещений добавляем номер квартиры и затем логический номер 
            IF p$object.id_object_class = 11 THEN
                -- 28.03.2022 SHA появился room_no - номер комнаты помещения
                m$object_address := m$object_address || ' кв. ' || TRIM(p$object.kw) || ' ' || m$type_name || ' ' || TRIM(p$object.room_no) /*p$object.object_no*/;
            ELSE
                m$object_address := m$object_address || ' ' || m$type_name || ' ' || TRIM(p$object.kw);
            END IF;
        END IF;

        m$adres2 := m$adres2 || m$object_address;
        m$full_adres2 := m$full_adres2 || m$object_address;
    END IF;

    IF p$object.zip IS NOT NULL THEN
        m$zip := p$object.zip;
    END IF;

    IF LOWER(p$action) = 'insert' THEN
        INSERT INTO object_info_tbl (id_object, id_territory, id_street, house, building_no, flat, id_object_class, id_object_type, sq_all
                , adres
                , full_adres
                , street_name, object_name, city_name, id_raion, raion_name, id_city, id_entity_instance, type_name, trace_info
                , adr_pos01, adr_pos02, adr_pos03, adr_pos04, adr_pos05, adr_pos06, adr_pos07, adr_pos08, adr_pos09, adr_pos10
                , id_territory2, id_street2, house2, building_no2
                , adres2
                , full_adres2
                , street_name2, city_name2, id_raion2, raion_name2, id_city2, is_exist_alternate_adres
                , addressing_mode, id_house_doorway, id_object_house, id_main_city, main_city_name, id_district, district_name, id_region, region_name, zip
                , object_no, volume, sq_life, room_no)
            VALUES (p$object.id_object, p$object.id_territory, m$id_street, p$object.dom, p$object.building_no, p$object.kw, p$object.id_object_class, p$object.id_object_type, p$object.sq_all
                , m$adres /*|| DECODE(p$object.kw, NULL, NULL, ' ' || m$type_name || ' ' || TRIM(p$object.kw))*/        -- ТЕПЕРЬ АДРЕС ПОЛНОСТЬЮ СОБРАН ВЫШЕ
                , m$full_adres /*|| DECODE(p$object.kw, NULL, NULL, ' ' || m$type_name || ' ' || TRIM(p$object.kw))*/   -- ТЕПЕРЬ АДРЕС ПОЛНОСТЬЮ СОБРАН ВЫШЕ
                , NVL(m$street_name, ' '), p$object.object_name, m$city_name, m$id_raion, m$raion_name, m$id_city, p$object.id_entity_instance, m$type_name, p$object.trace_info
                , m$adr_pos01, m$adr_pos02, m$adr_pos03, m$adr_pos04, m$adr_pos05, m$adr_pos06, m$adr_pos07, m$adr_pos08, m$adr_pos09, m$adr_pos10
                , p$object.id_territory2, m$id_street2, p$object.dom2, p$object.building_no2
                , m$adres2 /*|| DECODE(p$object.kw, NULL, NULL, ' ' || m$type_name || ' ' || TRIM(p$object.kw))*/       -- ТЕПЕРЬ АДРЕС ПОЛНОСТЬЮ СОБРАН ВЫШЕ
                , m$full_adres2 /*|| DECODE(p$object.kw, NULL, NULL, ' ' || m$type_name || ' ' || TRIM(p$object.kw))*/  -- ТЕПЕРЬ АДРЕС ПОЛНОСТЬЮ СОБРАН ВЫШЕ
                , NVL(m$street_name2, ' '), m$city_name2, m$id_raion2, m$raion_name2, m$id_city2, NVL2(p$object.id_territory2, 1, 0)
                , p$object.addressing_mode, p$object.id_house_doorway, p$object.id_object_house, m$id_main_city, m$main_city_name, m$id_district, m$district_name, m$id_region, m$region_name, m$zip
                , p$object.object_no, p$object.volume, p$object.sq_life, p$object.room_no);
    END IF;

    IF LOWER(p$action) = 'update' THEN
        UPDATE object_info_tbl
            SET id_street = m$id_street
                , id_territory = p$object.id_territory
                , house = p$object.dom
                , building_no = p$object.building_no
                , flat = p$object.kw
                , id_object_class = p$object.id_object_class
                , id_object_type = p$object.id_object_type
                , sq_all = p$object.sq_all
                , adres = m$adres /*|| DECODE(p$object.kw, NULL, NULL, ' ' || NVL(m$type_name, type_name) || ' ' || TRIM(p$object.kw))*/            -- ТЕПЕРЬ АДРЕС ПОЛНОСТЬЮ СОБРАН ВЫШЕ
                , full_adres = m$full_adres /*|| DECODE(p$object.kw, NULL, NULL, ' ' || NVL(m$type_name, type_name) || ' ' || TRIM(p$object.kw))*/  -- ТЕПЕРЬ АДРЕС ПОЛНОСТЬЮ СОБРАН ВЫШЕ
                , adr_pos01 = NVL2(p$object.id_territory, m$adr_pos01, adr_pos01)
                , adr_pos02 = NVL2(p$object.id_territory, m$adr_pos02, adr_pos02)
                , adr_pos03 = NVL2(p$object.id_territory, m$adr_pos03, adr_pos03)
                , adr_pos04 = NVL2(p$object.id_territory, m$adr_pos04, adr_pos04)
                , adr_pos05 = NVL2(p$object.id_territory, m$adr_pos05, adr_pos05)
                , adr_pos06 = NVL2(p$object.id_territory, m$adr_pos06, adr_pos06)
                , adr_pos07 = NVL2(p$object.id_territory, m$adr_pos07, adr_pos07)
                , adr_pos08 = NVL2(p$object.id_territory, m$adr_pos08, adr_pos08)
                , adr_pos09 = NVL2(p$object.id_territory, m$adr_pos09, adr_pos09)
                , adr_pos10 = NVL2(p$object.id_territory, m$adr_pos10, adr_pos10)
                , street_name = NVL(m$street_name, ' ')
                , object_name = p$object.object_name
                , city_name = m$city_name
                , id_raion = m$id_raion
                , raion_name = m$raion_name
                , id_city = m$id_city
                , id_entity_instance = p$object.id_entity_instance
                , type_name = NVL(m$type_name, type_name)
                , trace_info = p$object.trace_info
                , id_street2 = p$object.id_territory2
                , id_territory2 = p$object.id_territory2
                , house2 = p$object.dom2
                , building_no2 = p$object.building_no2
                , is_exist_alternate_adres = NVL2(p$object.id_territory2, 1, 0)
                , adres2 = m$adres2 /*DECODE(p$object.id_territory2, null, null, m$adres2 || DECODE(p$object.kw, NULL, NULL, ' ' || NVL(m$type_name, type_name) || ' ' || TRIM(p$object.kw)))*/                     -- ТЕПЕРЬ АДРЕС ПОЛНОСТЬЮ СОБРАН ВЫШЕ
                , full_adres2 = m$full_adres2   /*DECODE(p$object.id_territory2 , null, null, m$full_adres2 || DECODE(p$object.kw, NULL, NULL, ' ' || NVL(m$type_name, type_name) || ' ' || TRIM(p$object.kw)))*/   -- ТЕПЕРЬ АДРЕС ПОЛНОСТЬЮ СОБРАН ВЫШЕ
                , street_name2 = NVL(m$street_name2, ' ')
                , city_name2 = m$city_name2
                , id_raion2 = m$id_raion2
                , raion_name2 = m$raion_name2
                , id_city2 = m$id_city2
                , addressing_mode = p$object.addressing_mode
                , id_house_doorway = p$object.id_house_doorway
                , id_object_house = p$object.id_object_house
                , id_main_city = m$id_main_city
                , main_city_name = m$main_city_name
                , id_district = m$id_district
                , district_name = m$district_name
                , id_region = m$id_region
                , region_name = m$region_name
                , zip = m$zip
                , object_no = p$object.object_no
                , volume = p$object.volume
                , sq_life = p$object.sq_life
                , room_no = p$object.room_no
            WHERE id_object = p$object.id_object;
    END IF;

END;


PROCEDURE create_triggers AS
m$description VARCHAR2(1000);
m$ddl   VARCHAR2(32000);
BEGIN
    m$description := 'Триггер для обновления информации в object_info_tbl.
Триггер сгенерирован автоматически '||TO_CHAR(SYSDATE, 'dd.mm.yyyy hh24:mi:ss');

--  DROP TRIGGER TAIU6_OBJECT;
    ddl_pkg.create_trigger(
          scheming_pkg.generate_schema('BA7_DATA')
        , 'TAIUD$E52$OBJECT_INFO'
        , 'AFTER EACH ROW'
        , 'INSERT OR UPDATE OR DELETE'
        , scheming_pkg.generate_schema('BA7_DATA')
        , 'OBJECT'
        , null
        , 'NVL(SYS_CONTEXT(''CTX_TRIGGER_CONTROL'',''TAIUD$E52$OBJECT_INFO''),''1'')=''1'''
        , m$description
        ,
'm$object    object%ROWTYPE;
m$action    VARCHAR2(10);'
        ,
'IF DELETING THEN
    m$object.id_object := :old.id_object;
    m$action := ''delete'';
    
ELSE 
    -- 20.09.2021 SHA: Нельзя условие на контекст выносить в WHEN, т.к. при слиянии объектов для удаляемого объекта не будет удаляться object_info_tbl
    IF UPDATING AND NVL(SYS_CONTEXT(''ctx_'||scheming_pkg.generate_schema('BA7_REP')||''', ''writer''), ''-'') = ''dublicate_pkg'' THEN
        RETURN;
    END IF;
    
    m$object.id_object := :new.id_object;
'||string_pkg.replace_multiply('    m$object.<<column_name>> := :new.<<column_name>>;'||CHR(10), '<<column_name>>', l$object_required_column_list)||'
    IF INSERTING THEN
        m$action := ''insert'';
    ELSE
        m$action := ''update'';
    END IF;
END IF;
object_info_pkg.update_object_info(m$object, m$action);');


    ddl_pkg.create_trigger(
          scheming_pkg.generate_schema('BA7_DATA')
        , 'TCBU$E98$OBJECT_INFO'
        , 'BEFORE STATEMENT'
        , 'UPDATE'
        , scheming_pkg.generate_schema('BA7_DATA')
        , 'TERRITORY'
        , 'ID_PARENT, ID_TERRITORY_CLASS, ID_TERRITORY_TYPE, NAME, ZIP'
        , null
        , m$description
        , null
        ,
'object_info_pkg.init();');

--  DROP TRIGGER TAIU6_TERRITORY /* INSERT INTO tmp_chg_territory (id_territory) VALUES (:new.id_territory); */;
    ddl_pkg.create_trigger(
          scheming_pkg.generate_schema('BA7_DATA')
        , 'TAU$E98$OBJECT_INFO'
        , 'AFTER EACH ROW'
        , 'UPDATE'
        , scheming_pkg.generate_schema('BA7_DATA')
        , 'TERRITORY'
        , 'ID_PARENT, ID_TERRITORY_CLASS, ID_TERRITORY_TYPE, NAME'
        , q'[(NVL(SYS_CONTEXT('CTX_TRIGGER_CONTROL','TAU$E98$OBJECT_INFO'),'1')='1')]'
        , m$description
        , null
        ,
'object_info_pkg.add_territory_update(:new.id_territory);');

--  DROP TRIGGER TAIU7_TERRITORY;
    ddl_pkg.create_trigger(
          scheming_pkg.generate_schema('BA7_DATA')
        , 'TCAU$E98$OBJECT_INFO'
        , 'AFTER STATEMENT'
        , 'UPDATE'
        , scheming_pkg.generate_schema('BA7_DATA')
        , 'TERRITORY'
        , 'ID_PARENT, ID_TERRITORY_CLASS, ID_TERRITORY_TYPE, NAME'
        , null
        , m$description
        , null
        ,
'object_info_pkg.update_object_info();');

END;

PROCEDURE create_view(p$with_grants NUMBER DEFAULT 0) AS
m$ddl           VARCHAR2(32000);
m$ddl_grants    TTableString := TTableString(
     q'{scheming_pkg.group_privs('object_info', 'SELECT', 'TEST_OWNER', 1)}'
    ,q'{scheming_pkg.group_privs('object_info', 'SELECT', 'TEST_OWNER_ROLE')}'
    ,q'{scheming_pkg.group_privs('object_info', 'SELECT', 'STD_POLICY', 1)}'
    ,q'{scheming_pkg.group_privs('object_info', 'SELECT', 'std_policy_role')}');

BEGIN
    m$ddl :=
q'[CREATE OR REPLACE VIEW object_info AS
    SELECT a.*
        , UPPER(NVL(a.street_name, ' ')) AS find_street_name
        , UPPER(NVL(a.city_name, ' ')) AS find_city_name
        , UPPER(NVL(TRIM(a.house), ' ')) AS find_house
        , UPPER(NVL(TRIM(a.building_no), ' ')) AS find_building_no
        , UPPER(NVL(TRIM(a.flat), ' ')) AS find_flat
  FROM object_info_tbl a]';

    EXECUTE IMMEDIATE m$ddl;

    IF p$with_grants = 1 THEN
        FOR i IN m$ddl_grants.FIRST .. m$ddl_grants.LAST LOOP
            EXECUTE IMMEDIATE m$ddl_grants(i);
        END LOOP;
    END IF;
END;


PROCEDURE rebuild AS
m$mode  NUMBER;
m$id_object_insert  TTableNumber;
BEGIN
    m$mode := int_rep_session.getDbAccessMode();
    int_rep_session.setDbAccessMode(2);

    -- Удаляем, если объекта уже нет
    DELETE FROM object_info_tbl WHERE id_object NOT IN (SELECT id_object FROM object);

    -- Вставляем, если объект есть, а в _tbl нету
    SELECT id_object
        BULK COLLECT INTO m$id_object_insert
    FROM object
    WHERE id_object NOT IN (SELECT id_object FROM object_info_tbl);
    IF m$id_object_insert.COUNT > 0 THEN
        update_object_info(m$id_object_insert, 'insert');
    END IF;

    UPDATE object_house SET id_territory = id_territory;
    UPDATE object_flat SET id_object_house = id_object_house;
    UPDATE house_doorway SET id_object_house = id_object_house;
    UPDATE object_unknown SET id_territory = id_territory;
    UPDATE object_room SET id_object_flat = id_object_flat;
    UPDATE object SET id_territory = id_territory;
    COMMIT;
    int_rep_session.setDbAccessMode(m$mode);
END;


PROCEDURE rebuild(p$batch_size NUMBER) AS
m$mode  NUMBER;
BEGIN
    IF p$batch_size IS NULL THEN
        rebuild();
    ELSE
        m$mode := int_rep_session.getDbAccessMode();
        int_rep_session.setDbAccessMode(2);

        run_sql_parts('DELETE FROM ' || scheming_pkg.generate_schema('ba7_data') || '.object_info_tbl WHERE id_object BETWEEN :1 AND :2 AND id_object NOT IN (SELECT id_object FROM object)', 
            scheming_pkg.generate_schema('ba7_data') || '.object_info_tbl.id_object', null, p$batch_size, 1);

        run_sql_parts('DECLARE
m$id_object_insert  TTableNumber;
BEGIN
    SELECT id_object
        BULK COLLECT INTO m$id_object_insert
    FROM ' || scheming_pkg.generate_schema('ba7_data') || '.object
    WHERE id_object BETWEEN :1 AND :2 AND id_object NOT IN (SELECT id_object FROM ' || scheming_pkg.generate_schema('ba7_data') || '.object_info_tbl);
    IF m$id_object_insert.COUNT > 0 THEN
        ' || scheming_pkg.generate_schema('ba7_data') || '.object_info_pkg.update_object_info(m$id_object_insert, ''insert'');
    END IF;
END;', scheming_pkg.generate_schema('ba7_data') || '.object.id_object', null, p$batch_size, 1);

        run_sql_parts('UPDATE ' || scheming_pkg.generate_schema('ba7_data') || '.object_house SET id_territory = id_territory WHERE id_object BETWEEN :1 AND :2', 
            scheming_pkg.generate_schema('ba7_data') || '.object_house.id_object', null, p$batch_size, 1);
        run_sql_parts('UPDATE ' || scheming_pkg.generate_schema('ba7_data') || '.object_flat SET id_object_house = id_object_house WHERE id_object BETWEEN :1 AND :2', 
            scheming_pkg.generate_schema('ba7_data') || '.object_flat.id_object', null, p$batch_size, 1);
        run_sql_parts('UPDATE ' || scheming_pkg.generate_schema('ba7_data') || '.house_doorway SET id_object_house = id_object_house WHERE id_object BETWEEN :1 AND :2', 
            scheming_pkg.generate_schema('ba7_data') || '.house_doorway.id_object', null, p$batch_size, 1);
        run_sql_parts('UPDATE ' || scheming_pkg.generate_schema('ba7_data') || '.object_unknown SET id_territory = id_territory WHERE id_object BETWEEN :1 AND :2', 
            scheming_pkg.generate_schema('ba7_data') || '.object_unknown.id_object', null, p$batch_size, 1);
        run_sql_parts('UPDATE ' || scheming_pkg.generate_schema('ba7_data') || '.object_room SET id_object_flat = id_object_flat WHERE id_object BETWEEN :1 AND :2', 
            scheming_pkg.generate_schema('ba7_data') || '.object_room.id_object', null, p$batch_size, 1);
        run_sql_parts('UPDATE ' || scheming_pkg.generate_schema('ba7_data') || '.object SET id_territory = id_territory WHERE id_object BETWEEN :1 AND :2', 
            scheming_pkg.generate_schema('ba7_data') || '.object.id_object', null, p$batch_size, 1);
        int_rep_session.setDbAccessMode(m$mode);
    END IF;
END;

FUNCTION format_object_no(p$object_no VARCHAR2, p$numeric_len NUMBER) RETURN VARCHAR2 DETERMINISTIC AS
m$nonnumeric_object_no  VARCHAR2(100);
m$index     NUMBER;
m$object_no VARCHAR2(100);
BEGIN
    m$nonnumeric_object_no := TRANSLATE(TRIM(p$object_no) || ',', '1234567890', '          ');
    m$index := INSTR(m$nonnumeric_object_no, TRIM(m$nonnumeric_object_no));
    m$object_no := NVL(LPAD(TRIM(p$object_no), LENGTH(TRIM(p$object_no)) + p$numeric_len - m$index), '    ');
    IF TRIM(m$object_no) != TRIM(p$object_no) THEN
        m$object_no := p$object_no;
    END IF;
    RETURN m$object_no;
END;

FUNCTION get_version RETURN VARCHAR2 AS
/*
Версии:
    1.0 от 28.12.2016 SHA: первоначальная реализация, взятая из триггеров + обработка zip (Почтовый индекс)
    1.1 от 10.04.2017 SHA: добвлено протаскивание object_no в object_info_tblи формирование адреса для подъездов
    2 от 12.12.2017 SHA:    добавлена фукнция format_object_no для выравнивания цифровой части из номера дома, квартиры и вообще из любого номера до указанного кол-ва символов.
        Логика функции используется в триггерах на object_flat, object_house, потому теперь используется функция.
        Обработка object_room в rebuild'е
    3 от 12.02.2018 SHA: добавил отлов NO_DATA_FOUND при выборке данных об объекте (в методе update_object_info)
    4 от 03.04.2019 SHA: доработано пересоздание таблицы: добавлено удаление и добавление строк, было только обновление
    5 от 06.05.2019 SHA: доработано формирование адреса для комнат помещений
    6 от 16.07.2020 SHA: обработка volume
    7 от 02.09.2021 SHA: триггер для object генерируется с условием на writer != dublicate_pkg
    8 от 20.09.2021 SHA: условие на writer = dublicate_pkg перенесено из условия WHEN триггера в тело, чтобы не срабатывать только на UPDATE
    9 от 07.12.2021 SHA: обработан sq_life
    10 от 28.03.2022 SHA: обработан room_no комнат, в т.ч. для формирования адреса
*/
BEGIN
    RETURN '10';
END;



END;
/
