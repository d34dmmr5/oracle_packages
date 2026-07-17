-- ============================================================
-- 04_test_data.sql — тестовые данные
-- PostgreSQL 16 | Выполнять ПЯТЫМ (после 03c_triggers_transition.sql)
--
-- Иерархия территорий — Украина:
--   страна (2) → область (3) → район (7) → нас. пункт (4)
--   → улица (8); внутригородской район (5); вложенный
--   нас. пункт (4→4) для проверки main_city.
--
-- Объекты подобраны так, чтобы пройти ВСЕ ветки триггеров:
--   дом mode=1, дом mode=2 с подъездами, угловой дом с
--   альтернативным адресом, комната, прочий объект.
-- Заполнение object_info_tbl происходит автоматически
-- триггерами по ходу INSERT — rebuild не требуется.
-- ============================================================

-- ────────────────────────────────────────────────────────────
-- 0. Очистка от предыдущих (в т.ч. частично упавших) прогонов
-- Скрипт идемпотентен: можно запускать повторно.
-- Порядок DELETE учитывает внешние ключи (дети → родители).
-- Всё выполняется одной транзакцией.
-- ────────────────────────────────────────────────────────────
BEGIN;

DELETE FROM object_room;
DELETE FROM object_flat;
DELETE FROM house_doorway;
DELETE FROM object_house;
DELETE FROM object_unknown;
DELETE FROM object;          -- триггер tads_e52 удалит строки из object_info_tbl
TRUNCATE object_info_tbl;    -- страховка от осиротевших строк прошлых прогонов
DELETE FROM territory;       -- self-FK: NO ACTION проверяется в конце стейтмента
DELETE FROM territory_type;
DELETE FROM object_type;

-- ────────────────────────────────────────────────────────────
-- 1. Справочник типов территорий
-- prefix строится как short_name + '.' + ' ' (точка не
-- добавляется, если short_name кончается на '.' или содержит '-')
-- ────────────────────────────────────────────────────────────
INSERT INTO territory_type (id_territory_class, id_territory_type, name, short_name) VALUES
    (2, 1, 'Страна',                  NULL),      -- без префикса
    (3, 1, 'Область',                 'обл'),     -- 'обл. '
    (7, 1, 'Район',                   'р-н'),     -- 'р-н ' (дефис → без точки)
    (4, 1, 'Город',                   'г'),       -- 'г. '
    (4, 2, 'Посёлок городского типа', 'пгт'),     -- 'пгт. '
    (5, 1, 'Район города',            'р-н'),     -- 'р-н '
    (8, 1, 'Улица',                   'ул'),      -- 'ул. '
    (8, 2, 'Проспект',                'просп');   -- 'просп. '

-- ────────────────────────────────────────────────────────────
-- 2. Иерархия территорий
-- ────────────────────────────────────────────────────────────
INSERT INTO territory (id_territory, id_parent, id_territory_class, id_territory_type, name, zip) VALUES
    (1,  NULL, 2, 1, 'Украина',            NULL),
    -- Киевская область → Бучанский район → г. Буча → ул. Вокзальная
    (2,  1,    3, 1, 'Киевская',           NULL),
    (3,  2,    7, 1, 'Бучанский',          NULL),
    (4,  3,    4, 1, 'Буча',               8292),   -- 08292
    (5,  4,    8, 1, 'Вокзальная',         NULL),   -- zip унаследуется от Бучи
    -- г. Киев (спецстатус, прямо под страной)
    (6,  1,    4, 1, 'Киев',               1001),   -- 01001
    (7,  6,    5, 1, 'Шевченковский',      NULL),
    (8,  7,    8, 1, 'Владимирская',       1030),   -- свой zip у улицы
    -- пгт Пуща-Водица подчинён Киеву: city = Пуща-Водица, main_city = Киев
    (9,  6,    4, 2, 'Пуща-Водица',        NULL),   -- zip унаследуется от Киева
    (10, 9,    8, 1, 'Лесная',             NULL),
    -- Львовская область → Львовский район → г. Львов → 2 улицы
    (11, 1,    3, 1, 'Львовская',          NULL),
    (12, 11,   7, 1, 'Львовский',          NULL),
    (13, 12,   4, 1, 'Львов',              79000),
    (14, 13,   8, 1, 'Зелёная',            NULL),
    (15, 13,   8, 2, 'Свободы',            NULL),
    -- Одесская область → Одесский район → г. Одесса → ул. Дерибасовская
    (16, 1,    3, 1, 'Одесская',           NULL),
    (17, 16,   7, 1, 'Одесский',           NULL),
    (18, 17,   4, 1, 'Одесса',             65000),
    (19, 18,   8, 1, 'Дерибасовская',      NULL);

-- ────────────────────────────────────────────────────────────
-- 3. Справочник типов объектов
-- name попадает в адресную строку перед номером:
--   квартира: '… кв. 5', комната: '… кв. 1 комн. 3'
-- SELECT INTO STRICT в пакете требует наличия типа для каждого
-- класса/типа вставляемых объектов.
-- ────────────────────────────────────────────────────────────
INSERT INTO object_type (id_object_class, id_object_type, name) VALUES
    (1,  1, 'Жилой дом'),
    (2,  1, 'кв.'),
    (10, 1, 'подъезд'),
    (11, 1, 'комн.'),
    (99, 1, 'объект');

-- ────────────────────────────────────────────────────────────
-- 4. Объекты
-- Адресные поля object заполняют BEFORE ROW триггеры подклассов;
-- в object задаются только идентификация, класс/тип и object_no.
-- ────────────────────────────────────────────────────────────

-- ── A. Буча, ул. Вокзальная, д. 10 — дом mode=1 («по домам») ──
INSERT INTO object (id_object, id_object_class, id_object_type, object_name) VALUES
    (101, 1, 1, 'Дом Вокзальная 10');
INSERT INTO object_house (id_object, id_territory, house_no, addressing_mode) VALUES
    (101, 5, '10', 1);

-- Подъезд №1 (mode=1: house_no у подъезда обязан быть NULL)
INSERT INTO object (id_object, id_object_class, id_object_type, object_name, object_no) VALUES
    (104, 10, 1, 'Подъезд 1', 1);
INSERT INTO house_doorway (id_object, id_object_house, house_no) VALUES
    (104, 101, NULL);

-- Квартиры 1 и 5
INSERT INTO object (id_object, id_object_class, id_object_type, object_name) VALUES
    (102, 2, 1, 'Квартира 1'),
    (103, 2, 1, 'Квартира 5');
INSERT INTO object_flat (id_object, id_object_house, flat_no, sq_life) VALUES
    (102, 101, '1', 32.5),
    (103, 101, '5', 47.1);

-- Комната 3 в квартире 1 (class 11: адрес '… кв. 1 комн. 3')
INSERT INTO object (id_object, id_object_class, id_object_type, object_name) VALUES
    (105, 11, 1, 'Комната 3');
INSERT INTO object_room (id_object, id_object_flat, room_no, sq_life) VALUES
    (105, 102, '3', 11.8);

-- ── B. Киев, ул. Владимирская — дом mode=2 («по подъездам») ──
-- У каждого подъезда СВОЙ номер дома; квартиры адресуются через подъезд.
INSERT INTO object (id_object, id_object_class, id_object_type, object_name) VALUES
    (111, 1, 1, 'Дом Владимирская 12/12а');
INSERT INTO object_house (id_object, id_territory, house_no, addressing_mode) VALUES
    (111, 8, '12', 2);

INSERT INTO object (id_object, id_object_class, id_object_type, object_name, object_no) VALUES
    (112, 10, 1, 'Подъезд 1', 1),
    (113, 10, 1, 'Подъезд 2', 2);
INSERT INTO house_doorway (id_object, id_object_house, house_no) VALUES
    (112, 111, '12'),
    (113, 111, '12а');

INSERT INTO object (id_object, id_object_class, id_object_type, object_name) VALUES
    (114, 2, 1, 'Квартира 1 (п.1)'),
    (115, 2, 1, 'Квартира 2 (п.2)');
INSERT INTO object_flat (id_object, id_object_house, id_house_doorway, flat_no) VALUES
    (114, 111, 112, '1'),
    (115, 111, 113, '2');

-- ── C. Львов — угловой дом с альтернативным адресом ──
-- Основной: ул. Зелёная, д. 1 корп. А; альтернативный: просп. Свободы, д. 2 корп. Б
-- Демонстрирует ветку territory2 и сохранённый баг оригинала
-- (building_no2 в адресе дублируется: '… корп. Б корп. Б')
INSERT INTO object (id_object, id_object_class, id_object_type, object_name) VALUES
    (121, 1, 1, 'Угловой дом Зелёная/Свободы');
INSERT INTO object_house (id_object, id_territory, house_no, building_no,
                          id_territory2, house_no2, building_no2, addressing_mode) VALUES
    (121, 14, '1', 'А', 15, '2', 'Б', 1);

-- ── D. Пуща-Водица — вложенный нас. пункт (city / main_city) ──
-- Ожидание: city_name = 'Пуща-Водица', main_city_name = 'Киев',
-- zip унаследован от Киева (1001)
INSERT INTO object (id_object, id_object_class, id_object_type, object_name) VALUES
    (131, 1, 1, 'Дом Лесная 7');
INSERT INTO object_house (id_object, id_territory, house_no, addressing_mode) VALUES
    (131, 10, '7', 1);

-- ── E. Одесса — «прочий объект» (object_unknown) ──
INSERT INTO object (id_object, id_object_class, id_object_type, object_name) VALUES
    (141, 99, 1, 'Гараж');
INSERT INTO object_unknown (id_object, id_territory, house_no) VALUES
    (141, 19, '3');

COMMIT;

-- ────────────────────────────────────────────────────────────
-- 5. Контрольные запросы
-- ────────────────────────────────────────────────────────────

-- 5.1 Все адреса (кэш заполнен триггерами по ходу INSERT)
SELECT id_object, adres, zip
FROM object_info
ORDER BY id_object;

-- 5.2 Полные адреса и позиционные маркеры
SELECT id_object, full_adres, adr_pos04,
       SUBSTRING(full_adres FROM adr_pos04) AS from_city_level
FROM object_info
WHERE id_object IN (101, 114)
ORDER BY id_object;

-- 5.3 city / main_city для вложенного нас. пункта (дом в Пуще-Водице)
-- Ожидание: city_name='Пуща-Водица', main_city_name='Киев', zip=1001
SELECT id_object, city_name, main_city_name, zip
FROM object_info
WHERE id_object = 131;

-- 5.4 Альтернативный адрес углового дома (виден баг оригинала:
-- 'корп. Б корп. Б' в adres2/full_adres2)
SELECT id_object, adres, adres2, is_exist_alternate_adres
FROM object_info
WHERE id_object = 121;

-- 5.5 Адресация по подъездам: у квартир дом из подъезда ('12' и '12а')
SELECT id_object, house, flat, adres
FROM object_info
WHERE id_object IN (114, 115)
ORDER BY id_object;

-- 5.6 Комната: '… д.10 кв. 1 комн. 3'
SELECT id_object, room_no, adres
FROM object_info
WHERE id_object = 105;

-- 5.7 Сверка полноты: каждый object имеет строку в object_info_tbl
SELECT (SELECT COUNT(*) FROM object)          AS objects,
       (SELECT COUNT(*) FROM object_info_tbl) AS cached;
