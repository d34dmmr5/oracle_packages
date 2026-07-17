-- ============================================================
-- 00_ddl.sql — DDL базы данных (MERGE-версия: лучшее из двух вариантов)
-- PostgreSQL 16 | Проверено на живой базе (тесты T1–T16)
--
-- Порядок выполнения комплекта:
--   00_ddl.sql             ← этот файл (ПЕРВЫМ)
--   01_territory_pkg.sql
--   02_object_info_pkg.sql
--   03_triggers.sql
--   04_test_data.sql       (тестовые данные, идемпотентен)
--   05_tests.sql           (поведенческие тесты T1–T16)
--
-- Метки "MERGE-фикс" в коде помечают места, где к базовому варианту
-- (transition tables) добавлены доработки надёжности — см. README.md.
--
-- Содержит:
--   1. Создание тестовой БД (закомментировано — выполнить отдельно)
--   2. Схемы object_info_pkg, territory_pkg
--   3. Составные типы object_row_type, territory_info_type
--   4. Базовые таблицы (реконструкция по Oracle-архиву)
--   5. Таблицу object_info_tbl
--   6. Индексы
--
-- Права (GRANT) намеренно отсутствуют.
-- ============================================================

-- ────────────────────────────────────────────────────────────
-- 1. Тестовая база данных
-- CREATE DATABASE нельзя выполнять внутри транзакции —
-- выполните эти две команды отдельно, до запуска этого файла:
--
--   CREATE DATABASE object_info_test ENCODING 'UTF8';
--   \c object_info_test
-- ────────────────────────────────────────────────────────────


-- ────────────────────────────────────────────────────────────
-- 2. Схемы (аналог Oracle PACKAGE namespace)
-- ────────────────────────────────────────────────────────────
CREATE SCHEMA IF NOT EXISTS object_info_pkg;
CREATE SCHEMA IF NOT EXISTS territory_pkg;


-- ────────────────────────────────────────────────────────────
-- 3. Составные типы
--
-- ВАЖНО: прямой CREATE TYPE с квалифицированным именем схемы,
-- без DO-блока. CREATE TYPE не поддерживает IF NOT EXISTS для
-- составных типов даже в PG 16, поэтому при повторном запуске
-- файла на существующей базе эти два стейтмента упадут с
-- "type already exists" — это ожидаемо и безопасно.
-- Для полного пересоздания: DROP TYPE ... CASCADE (уронит
-- зависимые процедуры — их придётся создать заново).
-- ────────────────────────────────────────────────────────────

-- Аналог Oracle object%ROWTYPE, ограниченный полями из
-- l$object_required_column_list (object_info_pkg.sql, строки 63-65)
-- + id_object
CREATE TYPE object_info_pkg.object_row_type AS (
    id_object           BIGINT,
    id_territory        BIGINT,
    dom                 VARCHAR(10),   -- основной дом: format_object_no(..., 10)
    building_no         VARCHAR(30),
    kw                  VARCHAR(30),
    id_territory2       BIGINT,
    dom2                VARCHAR(6),    -- альтернативный дом: format_object_no(..., 6)
    building_no2        VARCHAR(30),   -- Oracle: BUILDING_NO2 VARCHAR2(30)
    id_object_class     INTEGER,
    id_object_type      INTEGER,
    sq_all              NUMERIC(10,2),
    object_name         VARCHAR(50),
    id_entity_instance  BIGINT,
    trace_info          VARCHAR(2000),
    addressing_mode     INTEGER,       -- 1 = по домам, 2 = по подъездам
    id_object_house     BIGINT,
    id_house_doorway    BIGINT,
    zip                 NUMERIC(10),
    object_no           BIGINT,
    volume              NUMERIC,
    sq_life             NUMERIC,
    room_no             VARCHAR(30)    -- VARCHAR: format_object_no выравнивает пробелами
);

-- Аналог 27 OUT-параметров Oracle-процедуры GetTerritoryInfo
-- (без типов территорий — они отбрасываются в обёртке)
CREATE TYPE public.territory_info_type AS (
    short_adres     TEXT,       -- адрес от улицы (до первого нас. пункта)
    full_adres      TEXT,       -- полный адрес от корня иерархии
    id_street       BIGINT,     -- улица (id_territory_class = 8)
    street_name     TEXT,
    id_city         BIGINT,     -- нас. пункт (class = 4, первый снизу)
    city_name       TEXT,
    id_main_city    BIGINT,     -- второй нас. пункт (для вложенных)
    main_city_name  TEXT,
    id_district     BIGINT,     -- внутригородской район (class = 5)
    district_name   TEXT,
    id_raion        BIGINT,     -- район (class = 7)
    raion_name      TEXT,
    id_region       BIGINT,     -- регион (class = 3)
    region_name     TEXT,
    adr_pos01       INTEGER,    -- позиции в full_adres (см. territory_pkg.get_info)
    adr_pos02       INTEGER,
    adr_pos03       INTEGER,
    adr_pos04       INTEGER,
    adr_pos05       INTEGER,
    adr_pos06       INTEGER,
    adr_pos07       INTEGER,
    adr_pos08       INTEGER,
    adr_pos09       INTEGER,
    adr_pos10       INTEGER,
    zip             NUMERIC(10)
);


-- ────────────────────────────────────────────────────────────
-- 4. Базовые таблицы
--
-- В Oracle-архиве нет ни одного CREATE TABLE для них — только
-- ALTER TABLE, триггеры и SELECT. Структура ниже реконструирована
-- по фактическому использованию полей (:new./:old. в триггерах,
-- SELECT в пакетах) — это минимально достаточный набор.
-- В реальной системе у таблиц могут быть дополнительные поля,
-- не участвующие в адресной логике.
--
-- Порядок создания важен из-за FK.
-- ────────────────────────────────────────────────────────────

-- Справочник типов территорий: даёт префикс адреса ('ул.', 'г.')
CREATE TABLE IF NOT EXISTS territory_type (
    id_territory_class  INTEGER NOT NULL,
    id_territory_type   INTEGER NOT NULL,
    name                VARCHAR(200),
    short_name          VARCHAR(50),

    CONSTRAINT pk_territory_type PRIMARY KEY (id_territory_class, id_territory_type)
);

-- Иерархия территорий (самоссылка через id_parent)
-- Классы: 2=страна, 3=регион, 7=район, 4=нас.пункт, 5=внутригор.район, 8=улица
CREATE TABLE IF NOT EXISTS territory (
    id_territory        BIGINT       NOT NULL,
    id_parent           BIGINT,
    id_territory_class  INTEGER,
    id_territory_type   INTEGER,
    name                VARCHAR(500) NOT NULL,
    zip                 NUMERIC(10),

    CONSTRAINT pk_territory PRIMARY KEY (id_territory),
    CONSTRAINT fk_territory_parent
        FOREIGN KEY (id_parent) REFERENCES territory (id_territory),
    CONSTRAINT fk_territory_type
        FOREIGN KEY (id_territory_class, id_territory_type)
        REFERENCES territory_type (id_territory_class, id_territory_type)
);

CREATE INDEX IF NOT EXISTS i1_territory_parent ON territory (id_parent);

-- Справочник типов объектов: даёт type_name ('квартира', 'помещение')
-- Классы: 10 = подъезд, 11 = комната (используются в update_object_info)
CREATE TABLE IF NOT EXISTS object_type (
    id_object_class  INTEGER NOT NULL,
    id_object_type   INTEGER NOT NULL,
    name             VARCHAR(500),

    CONSTRAINT pk_object_type PRIMARY KEY (id_object_class, id_object_type)
);

-- Основная таблица объектов недвижимости
-- Поля = l$object_required_column_list + id_object
CREATE TABLE IF NOT EXISTS object (
    id_object            BIGINT          NOT NULL,
    id_territory         BIGINT,
    dom                  VARCHAR(10),
    building_no          VARCHAR(30),
    kw                   VARCHAR(30),
    id_territory2        BIGINT,
    dom2                 VARCHAR(6),
    building_no2         VARCHAR(30),
    id_object_class      INTEGER,
    id_object_type       INTEGER,
    sq_all               NUMERIC(10,2),
    sq_life              NUMERIC,
    volume               NUMERIC,
    object_name          VARCHAR(50),
    room_no              VARCHAR(30),
    id_entity_instance   BIGINT,
    trace_info           VARCHAR(2000),
    addressing_mode      INTEGER,
    id_object_house      BIGINT,
    id_house_doorway     BIGINT,
    zip                  NUMERIC(10),
    object_no            BIGINT,

    CONSTRAINT pk_object PRIMARY KEY (id_object),
    CONSTRAINT fk_object_territory
        FOREIGN KEY (id_territory)  REFERENCES territory (id_territory),
    CONSTRAINT fk_object_territory2
        FOREIGN KEY (id_territory2) REFERENCES territory (id_territory),
    CONSTRAINT fk_object_type
        FOREIGN KEY (id_object_class, id_object_type)
        REFERENCES object_type (id_object_class, id_object_type)
);

-- Подкласс "дом"
CREATE TABLE IF NOT EXISTS object_house (
    id_object         BIGINT       NOT NULL,
    id_territory      BIGINT,
    house_no          VARCHAR(10),
    building_no       VARCHAR(30),
    id_territory2     BIGINT,
    house_no2         VARCHAR(6),
    building_no2      VARCHAR(30),
    addressing_mode   INTEGER      NOT NULL DEFAULT 1,
    zip               NUMERIC(10),
    sq_life           NUMERIC,

    -- MERGE-фикс (из моего варианта): раньше addressing_mode принимал любое
    -- целое, и невалидное значение отлавливалось только в ELSE-ветке триггера
    -- (уже после того как оно записано в таблицу). CHECK не даёт кривым данным
    -- вообще попасть в object_house.
    CONSTRAINT ck_object_house_addr_mode CHECK (addressing_mode IN (1, 2)),
    CONSTRAINT pk_object_house PRIMARY KEY (id_object),
    CONSTRAINT fk_object_house_object
        FOREIGN KEY (id_object)    REFERENCES object (id_object),
    CONSTRAINT fk_object_house_territory
        FOREIGN KEY (id_territory) REFERENCES territory (id_territory),
    CONSTRAINT fk_object_house_territory2
        FOREIGN KEY (id_territory2) REFERENCES territory (id_territory)
);

-- Подкласс "подъезд"
CREATE TABLE IF NOT EXISTS house_doorway (
    id_object         BIGINT      NOT NULL,
    id_object_house   BIGINT      NOT NULL,
    house_no          VARCHAR(6),     -- заполняется только при addressing_mode = 2

    CONSTRAINT pk_house_doorway PRIMARY KEY (id_object),
    CONSTRAINT fk_house_doorway_object
        FOREIGN KEY (id_object)       REFERENCES object (id_object),
    CONSTRAINT fk_house_doorway_house
        FOREIGN KEY (id_object_house) REFERENCES object_house (id_object)
);

CREATE INDEX IF NOT EXISTS i1_house_doorway_house ON house_doorway (id_object_house);

-- Подкласс "помещение" (квартира / нежилое)
CREATE TABLE IF NOT EXISTS object_flat (
    id_object          BIGINT       NOT NULL,
    id_object_house    BIGINT       NOT NULL,
    id_house_doorway   BIGINT,          -- обязателен при addressing_mode = 2
    flat_no            VARCHAR(30),
    sq_life            NUMERIC,

    CONSTRAINT pk_object_flat PRIMARY KEY (id_object),
    CONSTRAINT fk_object_flat_object
        FOREIGN KEY (id_object)        REFERENCES object (id_object),
    CONSTRAINT fk_object_flat_house
        FOREIGN KEY (id_object_house)  REFERENCES object_house (id_object),
    CONSTRAINT fk_object_flat_doorway
        FOREIGN KEY (id_house_doorway) REFERENCES house_doorway (id_object)
);

CREATE INDEX IF NOT EXISTS i1_object_flat_house   ON object_flat (id_object_house);
CREATE INDEX IF NOT EXISTS i2_object_flat_doorway ON object_flat (id_house_doorway);

-- Подкласс "комната" (внутри помещения; появился в версии 10, 28.03.2022)
CREATE TABLE IF NOT EXISTS object_room (
    id_object        BIGINT       NOT NULL,
    id_object_flat   BIGINT       NOT NULL,
    room_no          VARCHAR(30),
    sq_life          NUMERIC,

    CONSTRAINT pk_object_room PRIMARY KEY (id_object),
    CONSTRAINT fk_object_room_object
        FOREIGN KEY (id_object)      REFERENCES object (id_object),
    CONSTRAINT fk_object_room_flat
        FOREIGN KEY (id_object_flat) REFERENCES object_flat (id_object)
);

CREATE INDEX IF NOT EXISTS i1_object_room_flat ON object_room (id_object_flat);

-- Подкласс "прочий объект"
CREATE TABLE IF NOT EXISTS object_unknown (
    id_object      BIGINT       NOT NULL,
    id_territory   BIGINT,
    house_no       VARCHAR(10),
    zip            NUMERIC(10),

    CONSTRAINT pk_object_unknown PRIMARY KEY (id_object),
    CONSTRAINT fk_object_unknown_object
        FOREIGN KEY (id_object)    REFERENCES object (id_object),
    CONSTRAINT fk_object_unknown_territory
        FOREIGN KEY (id_territory) REFERENCES territory (id_territory)
);


-- ────────────────────────────────────────────────────────────
-- 5. object_info_tbl — денормализованный кэш адресов
-- Структура реконструирована по истории ALTER TABLE
-- (00_update_object_info_tbl.sql) и INSERT/UPDATE в пакете.
-- Не редактировать напрямую — только через процедуры пакета.
-- ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS object_info_tbl (
    id_object               BIGINT          NOT NULL,
    id_territory            BIGINT,
    id_street               BIGINT,
    house                   VARCHAR(10),    -- основной дом до 10 символов
    building_no             VARCHAR(30),
    flat                    VARCHAR(30),    -- Oracle: MODIFY(FLAT VARCHAR2(30))
    id_object_class         INTEGER,
    id_object_type          INTEGER,
    sq_all                  NUMERIC(10,2),
    adres                   VARCHAR(100),   -- краткий адрес; Oracle ADRES2 VARCHAR2(100), по симметрии
    full_adres              VARCHAR(1000),
    street_name             VARCHAR(200),
    object_name             VARCHAR(50),
    city_name               VARCHAR(200),
    id_raion                BIGINT,
    raion_name              VARCHAR(200),
    id_city                 BIGINT,
    id_entity_instance      BIGINT,
    type_name               VARCHAR(500),
    trace_info              VARCHAR(2000),
    -- Позиция в full_adres, с которой начинается адрес
    -- соответствующего уровня. Пример: SUBSTR(full_adres, adr_pos04)
    -- = адрес начиная с населённого пункта.
    adr_pos01               INTEGER,
    adr_pos02               INTEGER,
    adr_pos03               INTEGER,
    adr_pos04               INTEGER,
    adr_pos05               INTEGER,
    adr_pos06               INTEGER,
    adr_pos07               INTEGER,
    adr_pos08               INTEGER,
    adr_pos09               INTEGER,
    adr_pos10               INTEGER,
    -- Альтернативный адрес (добавлен 15.05.2013)
    id_territory2           BIGINT,
    id_street2              BIGINT,
    street_name2            VARCHAR(200),
    house2                  VARCHAR(6),     -- Oracle: HOUSE2 CHAR(6)
    building_no2            VARCHAR(30),    -- Oracle: BUILDING_NO2 VARCHAR2(30)
    adres2                  VARCHAR(100),   -- Oracle: ADRES2 VARCHAR2(100)
    full_adres2             VARCHAR(1000),  -- Oracle: FULL_ADRES2 VARCHAR2(1000)
    id_city2                BIGINT,
    city_name2              VARCHAR(200),
    id_raion2               BIGINT,
    raion_name2             VARCHAR(200),
    is_exist_alternate_adres INTEGER        DEFAULT 0,
    addressing_mode         INTEGER,
    id_house_doorway        BIGINT,
    id_object_house         BIGINT,         -- добавлено 11.07.2016
    -- Поля для сопоставления с ФИАС (добавлены 20.11.2015)
    id_region               BIGINT,
    region_name             VARCHAR(200),
    id_main_city            BIGINT,
    main_city_name          VARCHAR(200),
    id_district             BIGINT,
    district_name           VARCHAR(200),
    object_no               BIGINT,
    volume                  NUMERIC,
    sq_life                 NUMERIC,
    room_no                 VARCHAR(30),    -- добавлено 28.03.2022
    zip                     NUMERIC(10),

    CONSTRAINT pk_object_info_tbl PRIMARY KEY (id_object)
);

COMMENT ON TABLE object_info_tbl IS
'Денормализованный кэш адресов объектов недвижимости.
Заполняется и обновляется автоматически через триггеры.
Не редактировать напрямую — только через процедуры object_info_pkg.';


-- ────────────────────────────────────────────────────────────
-- 6. Индексы
-- ────────────────────────────────────────────────────────────

-- Oracle: CREATE UNIQUE INDEX I1_OBJECT_INFO_TBL ON object_info_tbl
--         (ID_STREET, UPPER(TRIM(HOUSE)), UPPER(TRIM(FLAT)), ID_OBJECT)
CREATE UNIQUE INDEX IF NOT EXISTS i1_object_info_tbl
    ON object_info_tbl (id_street, UPPER(TRIM(house)), UPPER(TRIM(flat)), id_object);

CREATE INDEX IF NOT EXISTS i2_object_info_tbl_territory ON object_info_tbl (id_territory);
CREATE INDEX IF NOT EXISTS i3_object_info_tbl_city      ON object_info_tbl (id_city);

-- Oracle: CREATE UNIQUE INDEX I1_OBJECT ON OBJECT
--         (ID_TERRITORY, UPPER(TRIM(DOM)), UPPER(TRIM(KW)), ID_OBJECT)
CREATE UNIQUE INDEX IF NOT EXISTS i1_object
    ON object (id_territory, UPPER(TRIM(dom)), UPPER(TRIM(kw)), id_object);
