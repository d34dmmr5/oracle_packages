-- =============================================================================================
-- 00_ddl.sql
-- Схемы, таблицы и типы для PostgreSQL 16-версии BA7_DATA.
--
-- Схема ba7_data          — сами данные (аналог Oracle-схемы BA7_DATA).
-- Схема territory_pkg     — функции-заменители пакета territory_pkg (сборка адреса по иерархии).
-- Схема object_info_pkg   — функции-заменители пакета object_info_pkg (синхронизация object_info_tbl)
--                            + составной тип object_row_type.
--
-- Отдельная схема на "пакет" — это способ сымитировать инкапсуляцию Oracle-пакетов в PostgreSQL:
-- у PostgreSQL нет PACKAGE BODY, где тело функций скрыто от пользователя схемы с данными, поэтому
-- функции/процедуры выносятся в отдельные схемы, а на схему с данными (ba7_data) правами
-- ограничивается прямой доступ к их исходникам (см. TODO про GRANT в конце файла).
-- =============================================================================================

CREATE SCHEMA IF NOT EXISTS ba7_data;
CREATE SCHEMA IF NOT EXISTS territory_pkg;
CREATE SCHEMA IF NOT EXISTS object_info_pkg;

-- =============================================================================================
-- Справочник территорий (страна -> регион -> район -> нас.пункт -> внутригородской район -> улица)
-- =============================================================================================

CREATE TABLE ba7_data.territory (
    id_territory        BIGINT PRIMARY KEY,
    id_agent            INT,
    name                VARCHAR(200) NOT NULL,
    id_parent           BIGINT REFERENCES ba7_data.territory (id_territory),
    id_territory_class  INT NOT NULL,
    id_territory_type   INT,
    id_settlement       INT,
    zip_type            INT,
    zip                 NUMERIC(10),
    full_name           VARCHAR(200)
);

-- Обход иерархии в territory_pkg.get_info идёт от листа к корню по id_parent -- индекс критичен.
CREATE INDEX i1_territory_parent ON ba7_data.territory (id_parent);

CREATE TABLE ba7_data.territory_type (
    id_territory_class INT NOT NULL,
    id_territory_type  INT NOT NULL,
    name                VARCHAR(200),
    short_name          VARCHAR(50),
    PRIMARY KEY (id_territory_class, id_territory_type)
);

-- =============================================================================================
-- Классификатор объектов
-- =============================================================================================

CREATE TABLE ba7_data.object_type (
    id_object_class INT NOT NULL,
    id_object_type  INT NOT NULL,
    name            VARCHAR(500),
    PRIMARY KEY (id_object_class, id_object_type)
);

-- =============================================================================================
-- Основная таблица объектов.
-- Подтиповые таблицы (object_house/object_flat/house_doorway/object_room/object_unknown) копируют
-- вниз в OBJECT адресные поля через BEFORE ROW триггеры -- см. 04_subtype_triggers.sql.
-- =============================================================================================

CREATE TABLE ba7_data.object (
    id_object           BIGINT PRIMARY KEY,
    id_territory        BIGINT REFERENCES ba7_data.territory (id_territory),
    dom                 VARCHAR(10),
    building_no         VARCHAR(30),
    kw                  VARCHAR(30),
    id_territory2       BIGINT REFERENCES ba7_data.territory (id_territory),
    dom2                VARCHAR(6),
    building_no2        VARCHAR(30),
    id_object_class     INT NOT NULL,
    id_object_type      INT NOT NULL,
    sq_all              NUMERIC(10,2),
    sq_life             NUMERIC,
    volume              NUMERIC,
    object_name         VARCHAR(50),
    room_no             VARCHAR(30),
    id_entity_instance  BIGINT,
    trace_info          VARCHAR(2000),
    addressing_mode     INT,
    -- id_object_house/id_house_doorway намеренно без FK: в Oracle-оригинале это тоже простые NUMBER
    -- без ALTER TABLE ADD CONSTRAINT, т.к. object_house/house_doorway сами ссылаются на object
    -- (см. ниже) -- FK в обе стороны дал бы циклическую зависимость.
    id_object_house     BIGINT,
    id_house_doorway    BIGINT,
    zip                 NUMERIC(10),
    object_no           BIGINT,
    FOREIGN KEY (id_object_class, id_object_type)
        REFERENCES ba7_data.object_type (id_object_class, id_object_type)
);

CREATE INDEX i1_object_territory  ON ba7_data.object (id_territory);
CREATE INDEX i1_object_territory2 ON ba7_data.object (id_territory2);

-- =============================================================================================
-- Подтиповые таблицы. Каждая -- "расширение" object по id_object (1:1, PK одновременно и FK).
-- =============================================================================================

-- Дом/здание. addressing_mode: 1 = "по домам" (единый номер, наследуют все помещения/подъезды/
-- комнаты), 2 = "по подъездам" (свой номер дома у каждого house_doorway).
CREATE TABLE ba7_data.object_house (
    id_object        BIGINT PRIMARY KEY REFERENCES ba7_data.object (id_object),
    id_territory     BIGINT REFERENCES ba7_data.territory (id_territory),
    house_no         VARCHAR(10),
    building_no      VARCHAR(30),
    id_territory2    BIGINT REFERENCES ba7_data.territory (id_territory),
    house_no2        VARCHAR(6),
    building_no2     VARCHAR(30),
    addressing_mode  INT NOT NULL CHECK (addressing_mode IN (1, 2)),
    zip              NUMERIC(10),
    sq_life          NUMERIC
);

-- Подъезд. Существует только при addressing_mode = 2 у своего дома (номер дома -- свой, house_no).
CREATE TABLE ba7_data.house_doorway (
    id_object        BIGINT PRIMARY KEY REFERENCES ba7_data.object (id_object),
    id_object_house  BIGINT NOT NULL REFERENCES ba7_data.object_house (id_object),
    house_no         VARCHAR(10)
);

CREATE INDEX i1_house_doorway_house ON ba7_data.house_doorway (id_object_house);

-- Помещение/квартира. id_house_doorway обязателен, когда дом в режиме "по подъездам" (проверяется
-- в триггере, не в CHECK -- значение зависит от addressing_mode дома, а не от самой строки).
CREATE TABLE ba7_data.object_flat (
    id_object         BIGINT PRIMARY KEY REFERENCES ba7_data.object (id_object),
    id_object_house   BIGINT NOT NULL REFERENCES ba7_data.object_house (id_object),
    id_house_doorway  BIGINT REFERENCES ba7_data.house_doorway (id_object),
    flat_no           VARCHAR(30),
    sq_life           NUMERIC
);

CREATE INDEX i1_object_flat_house   ON ba7_data.object_flat (id_object_house);
CREATE INDEX i1_object_flat_doorway ON ba7_data.object_flat (id_house_doorway);

-- Комната (общежития, коммуналки) -- всегда внутри помещения, наследует адрес только от него.
CREATE TABLE ba7_data.object_room (
    id_object       BIGINT PRIMARY KEY REFERENCES ba7_data.object (id_object),
    id_object_flat  BIGINT NOT NULL REFERENCES ba7_data.object_flat (id_object),
    room_no         VARCHAR(30),
    sq_life         NUMERIC
);

CREATE INDEX i1_object_room_flat ON ba7_data.object_room (id_object_flat);

-- Прочие объекты: гараж, сарай, подстанция и т.д. -- без подъездов/наследования, простое копирование.
CREATE TABLE ba7_data.object_unknown (
    id_object     BIGINT PRIMARY KEY REFERENCES ba7_data.object (id_object),
    id_territory  BIGINT REFERENCES ba7_data.territory (id_territory),
    house_no      VARCHAR(10),
    zip           NUMERIC(10)
);

-- =============================================================================================
-- Составной тип-заменитель OBJECT%ROWTYPE.
-- В Oracle-пакете object_info_pkg параметр update_object_info(p$object OBJECT%ROWTYPE, ...)
-- получал автоматически весь набор колонок OBJECT. В PostgreSQL такого автоматизма нет, поэтому
-- явный тип с тем же перечнем полей, что реально нужен апдейту object_info_tbl -- один в один
-- список l$object_required_column_list из Oracle-пакета (+ id_object).
-- =============================================================================================

CREATE TYPE object_info_pkg.object_row_type AS (
    id_object            BIGINT,
    id_territory         BIGINT,
    dom                  VARCHAR(10),
    building_no          VARCHAR(30),
    kw                   VARCHAR(30),
    id_territory2        BIGINT,
    dom2                 VARCHAR(6),
    building_no2         VARCHAR(30),
    id_object_class      INT,
    id_object_type       INT,
    sq_all               NUMERIC(10,2),
    object_name          VARCHAR(50),
    id_entity_instance   BIGINT,
    trace_info           VARCHAR(2000),
    addressing_mode      INT,
    id_object_house      BIGINT,
    id_house_doorway     BIGINT,
    zip                  NUMERIC(10),
    object_no            BIGINT,
    volume               NUMERIC,
    sq_life              NUMERIC,
    room_no              VARCHAR(30)
);

-- =============================================================================================
-- Отчётная (денормализованная) таблица адресов -- аналог object_info_tbl.
-- =============================================================================================

CREATE TABLE ba7_data.object_info_tbl (
    id_object                 BIGINT PRIMARY KEY,
    id_territory               BIGINT,
    id_street                  BIGINT,
    house                      VARCHAR(10),
    building_no                VARCHAR(30),
    flat                       VARCHAR(30),
    id_object_class            INT,
    id_object_type             INT,
    sq_all                     NUMERIC(10,2),
    adres                      VARCHAR(100),
    full_adres                 VARCHAR(1000),
    street_name                VARCHAR(200),
    object_name                VARCHAR(50),
    city_name                  VARCHAR(200),
    id_raion                   BIGINT,
    raion_name                 VARCHAR(200),
    id_city                    BIGINT,
    id_entity_instance         BIGINT,
    type_name                  VARCHAR(500),
    trace_info                 VARCHAR(2000),
    adr_pos01 INT, adr_pos02 INT, adr_pos03 INT, adr_pos04 INT, adr_pos05 INT,
    adr_pos06 INT, adr_pos07 INT, adr_pos08 INT, adr_pos09 INT, adr_pos10 INT,
    -- альтернативный адрес (угловые дома с двумя официальными адресами)
    id_territory2               BIGINT,
    id_street2                  BIGINT,
    street_name2                VARCHAR(200),
    house2                      VARCHAR(6),
    building_no2                VARCHAR(30),
    adres2                      VARCHAR(100),
    full_adres2                 VARCHAR(1000),
    id_city2                    BIGINT,
    city_name2                  VARCHAR(200),
    id_raion2                   BIGINT,
    raion_name2                 VARCHAR(200),
    is_exist_alternate_adres    INT DEFAULT 0,
    addressing_mode             INT,
    id_house_doorway            BIGINT,
    id_object_house             BIGINT,
    id_region                   BIGINT,
    region_name                 VARCHAR(200),
    id_main_city                BIGINT,
    main_city_name              VARCHAR(200),
    id_district                 BIGINT,
    district_name               VARCHAR(200),
    object_no                   BIGINT,
    volume                      NUMERIC,
    sq_life                     NUMERIC,
    room_no                     VARCHAR(30),
    zip                         NUMERIC(10)
);

-- Поисковый индекс по street/house/flat -- аналог I1_OBJECT_INFO_TBL из Oracle. Там он был "UNIQUE",
-- но реальную уникальность обеспечивает id_object, входящий в состав индекса, а не сама комбинация
-- street/house/flat -- поэтому здесь обычный (не уникальный) индекс с тем же назначением.
CREATE INDEX i1_object_info_tbl ON ba7_data.object_info_tbl
    (id_street, UPPER(TRIM(house)), UPPER(TRIM(flat)), id_object);

-- =============================================================================================
-- Представление object_info -- аналог VIEW из object_info_pkg.create_view.
-- =============================================================================================

CREATE OR REPLACE VIEW ba7_data.object_info AS
SELECT a.*,
       UPPER(COALESCE(a.street_name, ' '))       AS find_street_name,
       UPPER(COALESCE(a.city_name, ' '))         AS find_city_name,
       UPPER(COALESCE(TRIM(a.house), ' '))       AS find_house,
       UPPER(COALESCE(TRIM(a.building_no), ' ')) AS find_building_no,
       UPPER(COALESCE(TRIM(a.flat), ' '))        AS find_flat
FROM ba7_data.object_info_tbl a;

-- TODO: аналог scheming_pkg.group_synonym/group_privs -- в Oracle-оригинале это регистрация
-- синонимов и выдача прав на схемы-потребители (TEST_OWNER, STD_POLICY). PostgreSQL-эквивалента
-- scheming_pkg ещё нет, поэтому ниже -- заглушка, которую нужно раскомментировать и адаптировать
-- под реальные роли, когда появится PG-аналог этого фреймворкового пакета.
-- GRANT USAGE ON SCHEMA ba7_data TO test_owner_role, std_policy_role;
-- GRANT SELECT ON ba7_data.object_info TO test_owner_role, std_policy_role;
