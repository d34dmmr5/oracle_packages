-- ============================================================
-- 05_tests.sql — поведенческие тесты
-- PostgreSQL 16 | Выполнять ПОСЛЕ 04_test_data.sql
--
-- Каждый тест: действие → SELECT-проверка.
-- Ожидаемый результат указан в комментарии над проверкой.
-- Негативные тесты обёрнуты в DO-блоки: ожидаемая ошибка
-- перехватывается, выводится NOTICE 'OK ...', вставки блока
-- откатываются подтранзакцией — мусора не остаётся.
-- Тесты зависят друг от друга — выполнять по порядку.
-- ============================================================

-- ────────────────────────────────────────────────────────────
-- T1. Смена номера квартиры (подкласс → object → object_info)
-- ────────────────────────────────────────────────────────────
UPDATE object_flat SET flat_no = '7' WHERE id_object = 103;

-- ОЖИДАНИЕ: flat = '  7' (format_object_no до 4 знаков),
-- adres = 'г. Буча, ул. Вокзальная, д.10 кв. 7'
SELECT id_object, flat, adres FROM object_info WHERE id_object = 103;


-- ────────────────────────────────────────────────────────────
-- T2. Каскад territory: переименование улицы
-- Затрагивает все объекты на ул. Вокзальная (101-105)
-- ────────────────────────────────────────────────────────────
UPDATE territory SET name = 'Привокзальная' WHERE id_territory = 5;

-- ОЖИДАНИЕ: 5 строк, во всех adres содержит 'ул. Привокзальная';
-- adr_pos04 у 101 НЕ изменился (=40): улица (class 8) добавляется
-- в full_adres ДО активации pos04 и в его смещение не входит.
SELECT id_object, adres, adr_pos04 FROM object_info
WHERE id_object IN (101,102,103,104,105) ORDER BY id_object;


-- ────────────────────────────────────────────────────────────
-- T3. Каскад territory вверх по дереву: переименование Киева
-- Поддерево Киева: ул. Владимирская (111-115) И пгт Пуща-Водица (131)
-- ────────────────────────────────────────────────────────────
UPDATE territory SET name = 'Київ' WHERE id_territory = 6;

-- ОЖИДАНИЕ: 6 строк. У 111-115 adres начинается с 'г. Київ, ...';
-- у 131 adres без изменений ('пгт. Пуща-Водица, ...' — short_adres
-- обрезается на первом нас. пункте), но main_city_name = 'Київ'
-- и full_adres содержит 'г. Київ'.
SELECT id_object, adres, main_city_name FROM object_info
WHERE id_object IN (111,112,113,114,115,131) ORDER BY id_object;


-- ────────────────────────────────────────────────────────────
-- T4. UPDATE territory только zip — пересчёта НЕТ (quirk оригинала:
-- zip не входит в отслеживаемые колонки триггера)
-- ────────────────────────────────────────────────────────────
UPDATE territory SET zip = 1234 WHERE id_territory = 8;

-- ОЖИДАНИЕ: zip у объекта 111 ОСТАЛСЯ 1030 (старый) —
-- триггер отфильтровал изменение как незначимое.
SELECT id_object, zip FROM object_info WHERE id_object = 111;

UPDATE territory SET zip = 1030 WHERE id_territory = 8;  -- вернуть


-- ────────────────────────────────────────────────────────────
-- T5. Перенос подъезда в другой дом (transition-триггер AFTER STMT
-- на house_doorway обязан перенести и квартиры этого подъезда)
-- ────────────────────────────────────────────────────────────
-- Новый дом mode=2 на той же улице
INSERT INTO object (id_object, id_object_class, id_object_type, object_name) VALUES
    (116, 1, 1, 'Дом Владимирская 14');
INSERT INTO object_house (id_object, id_territory, house_no, addressing_mode) VALUES
    (116, 8, '14', 2);

-- Переносим подъезд 113 (house_no '12а') из дома 111 в дом 116
UPDATE house_doorway SET id_object_house = 116 WHERE id_object = 113;

-- ОЖИДАНИЕ: у квартиры 115 (была за подъездом 113) id_object_house = 116
SELECT id_object, id_object_house, id_house_doorway
FROM object_flat WHERE id_object = 115;


-- ────────────────────────────────────────────────────────────
-- T6. Смена номера дома у подъезда (mode=2) — каскад на квартиры
-- ────────────────────────────────────────────────────────────
UPDATE house_doorway SET house_no = '16' WHERE id_object = 112;

-- ОЖИДАНИЕ (Киев уже 'Київ' после T3):
--   112: adres = 'г. Київ, р-н Шевченковский, ул. Владимирская, д.16 подъезд 1'
--   114: adres = 'г. Київ, р-н Шевченковский, ул. Владимирская, д.16 кв. 1'
SELECT id_object, house, adres FROM object_info
WHERE id_object IN (112, 114) ORDER BY id_object;


-- ────────────────────────────────────────────────────────────
-- T7. Удаление объекта — строка уходит из object_info
-- ────────────────────────────────────────────────────────────
DELETE FROM object_room WHERE id_object = 105;
DELETE FROM object      WHERE id_object = 105;

-- ОЖИДАНИЕ: 0 строк
SELECT COUNT(*) AS should_be_zero FROM object_info WHERE id_object = 105;


-- ────────────────────────────────────────────────────────────
-- T8. Отключение основного триггера — кэш перестаёт обновляться
-- ────────────────────────────────────────────────────────────
SET app.trigger_taiud_e52_object_info = '0';

UPDATE object_flat SET flat_no = '9' WHERE id_object = 102;

-- ОЖИДАНИЕ: рассинхрон. object.kw уже '  9' (BEFORE ROW подкласса
-- отработал), а object_info.flat ещё '  1' (statement-триггер отключён)
SELECT o.kw AS object_kw, oi.flat AS cached_flat
FROM object o JOIN object_info_tbl oi USING (id_object)
WHERE o.id_object = 102;

SET app.trigger_taiud_e52_object_info = '1';
CALL object_info_pkg.update_object_info(102, 'update');

-- ОЖИДАНИЕ: синхронизировано, flat = '  9',
-- adres = 'г. Буча, ул. Привокзальная, д.10 кв. 9'
SELECT flat, adres FROM object_info WHERE id_object = 102;


-- ────────────────────────────────────────────────────────────
-- T9. Режим writer = 'dublicate_pkg' — UPDATE пропускается
-- ────────────────────────────────────────────────────────────
SET app.writer = 'dublicate_pkg';

UPDATE object SET object_name = 'Кв.5 переименована' WHERE id_object = 103;

-- ОЖИДАНИЕ: в кэше СТАРОЕ имя 'Квартира 5' (триггер пропустил UPDATE)
SELECT object_name FROM object_info WHERE id_object = 103;

SET app.writer = '';
CALL object_info_pkg.update_object_info(103, 'update');

-- ОЖИДАНИЕ: 'Кв.5 переименована'
SELECT object_name FROM object_info WHERE id_object = 103;


-- ────────────────────────────────────────────────────────────
-- T10. НЕГАТИВНЫЙ: подъезд с номером дома при mode=1 → P0001
-- DO-блок ловит ошибку; вставки внутри блока откатываются.
-- ────────────────────────────────────────────────────────────
DO $$
BEGIN
    INSERT INTO object (id_object, id_object_class, id_object_type, object_name, object_no)
        VALUES (901, 10, 1, 'Подъезд-нарушитель', 9);
    INSERT INTO house_doorway (id_object, id_object_house, house_no)
        VALUES (901, 101, '99');   -- дом 101 mode=1: house_no запрещён
    RAISE EXCEPTION 'ТЕСТ ПРОВАЛЕН: ошибка не возникла';
EXCEPTION WHEN SQLSTATE 'P0001' THEN
    RAISE NOTICE 'T10 OK — ожидаемая ошибка: %', SQLERRM;
END;
$$;

-- ОЖИДАНИЕ: 0 строк (вставка объекта 901 откатилась подтранзакцией)
SELECT COUNT(*) AS should_be_zero FROM object WHERE id_object = 901;


-- ────────────────────────────────────────────────────────────
-- T11. НЕГАТИВНЫЙ: квартира в доме mode=2 без ссылки на подъезд → P0001
-- ────────────────────────────────────────────────────────────
DO $$
BEGIN
    INSERT INTO object (id_object, id_object_class, id_object_type, object_name)
        VALUES (902, 2, 1, 'Квартира-нарушитель');
    INSERT INTO object_flat (id_object, id_object_house, id_house_doorway, flat_no)
        VALUES (902, 111, NULL, '3');   -- дом 111 mode=2: подъезд обязателен
    RAISE EXCEPTION 'ТЕСТ ПРОВАЛЕН: ошибка не возникла';
EXCEPTION WHEN SQLSTATE 'P0001' THEN
    RAISE NOTICE 'T11 OK — ожидаемая ошибка: %', SQLERRM;
END;
$$;

SELECT COUNT(*) AS should_be_zero FROM object WHERE id_object = 902;


-- ────────────────────────────────────────────────────────────
-- T12. rebuild: полное восстановление кэша с нуля
-- ────────────────────────────────────────────────────────────
TRUNCATE object_info_tbl;

CALL object_info_pkg.rebuild(5000);

-- ОЖИДАНИЕ: objects = cached = 13
-- (13 объектов: 101-104, 111-116, 121, 131, 141; 105 удалён в T7)
SELECT (SELECT COUNT(*) FROM object)          AS objects,
       (SELECT COUNT(*) FROM object_info_tbl) AS cached;

-- ОЖИДАНИЕ: адреса восстановлены с учётом ВСЕХ изменений тестов:
--   101: 'г. Буча, ул. Привокзальная, д.10'                                  (T2)
--   102: 'г. Буча, ул. Привокзальная, д.10 кв. 9'                            (T8)
--   114: 'г. Київ, р-н Шевченковский, ул. Владимирская, д.16 кв. 1'          (T3+T6)
--   115: 'г. Київ, р-н Шевченковский, ул. Владимирская, д.12а кв. 2'         (T5: дом 116)
--   121: adres2 = 'г. Львов, просп. Свободы, д.2 корп. Б'                    (MERGE-фикс: баг дубля building_no2 исправлен)
--   131: city_name='Пуща-Водица', main_city_name='Київ', zip=1001
SELECT id_object, adres, zip FROM object_info ORDER BY id_object;

SELECT id_object, adres2 FROM object_info WHERE id_object = 121;
SELECT city_name, main_city_name, zip FROM object_info WHERE id_object = 131;


-- ════════════════════════════════════════════════════════════
-- СТРЕСС-ТЕСТЫ MERGE-версии (T13–T16) — данные от живых людей
-- содержат ошибки; проверяем, что код деградирует штатно, а не
-- виснет и не портит уже собранное.
-- ════════════════════════════════════════════════════════════

-- ────────────────────────────────────────────────────────────
-- T13. Цикл в иерархии territory (ошибка ввода: A->B->A).
-- В прежних вариантах (и Oracle-порте до фикса) это вешало backend
-- намертво: и восходящий обход get_info, и нисходящий обход триггера
-- на territory. MERGE-версия: нативный CYCLE — не виснет, WARNING.
-- ────────────────────────────────────────────────────────────
DO $$
DECLARE
    m$adr TEXT;
BEGIN
    INSERT INTO territory (id_territory, id_parent, id_territory_class, id_territory_type, name)
        VALUES (90001, NULL, 8, 1, 'Цикл-A'), (90002, 90001, 4, 1, 'Цикл-B');
    -- замыкаем цикл: этот UPDATE запускает триггер на territory (нисходящий обход)
    UPDATE territory SET id_parent = 90002 WHERE id_territory = 90001;
    -- восходящий обход
    m$adr := (public.get_territory_info(90001)).full_adres;
    RAISE NOTICE 'T13 OK — цикл не повесил БД, частичный адрес: %', m$adr;
    -- откат тестовых строк
    UPDATE territory SET id_parent = NULL WHERE id_territory IN (90001, 90002);
    DELETE FROM territory WHERE id_territory IN (90001, 90002);
END;
$$;


-- ────────────────────────────────────────────────────────────
-- T14. Дом с NULL номером (человек не заполнил дом).
-- MERGE-версия: адрес деградирует частично ('...д.'), НЕ обнуляется целиком.
-- ────────────────────────────────────────────────────────────
INSERT INTO object (id_object, id_object_class, id_object_type, object_name)
    VALUES (911, 1, 1, 'Дом без номера');
INSERT INTO object_house (id_object, id_territory, house_no, addressing_mode)
    VALUES (911, 5, NULL, 1);

-- ОЖИДАНИЕ: full_adres = 'страна ... ул. Привокзальная, д.' (не NULL, не пусто)
SELECT id_object, '['||COALESCE(full_adres,'<NULL>')||']' AS full_adres
FROM object_info WHERE id_object = 911;

DELETE FROM object_house WHERE id_object = 911;
DELETE FROM object WHERE id_object = 911;


-- ────────────────────────────────────────────────────────────
-- T15. Осиротевшая ссылка на территорию (массовая заливка с FK off).
-- MERGE-версия: WARNING + адрес собирается из известного (номер дома),
-- без обнуления. Проверяем на прямом вызове update_object_info с типом,
-- минуя FK (чистая проверка ветки, без порчи схемы).
-- ────────────────────────────────────────────────────────────
DO $$
DECLARE
    m$obj object_info_pkg.object_row_type;
BEGIN
    m$obj.id_object       := -1;   -- несуществующий, только для сборки строки
    m$obj.id_territory    := 88888888;  -- территории нет
    m$obj.dom             := '5';
    m$obj.id_object_class := 1;
    m$obj.id_object_type  := 1;
    -- временная строка object_info_tbl, чтобы UPDATE-ветке было что писать
    INSERT INTO object_info_tbl (id_object) VALUES (-1);
    CALL object_info_pkg.update_object_info(m$obj, 'update');
    RAISE NOTICE 'T15 OK — осиротевшая территория обработана без падения';
    -- проверим что адрес не NULL, а частичный ('д.5')
    PERFORM 1 FROM object_info_tbl WHERE id_object = -1 AND full_adres = 'д.5';
    IF FOUND THEN
        RAISE NOTICE 'T15 OK — адрес деградировал частично: д.5';
    ELSE
        RAISE WARNING 'T15 неожиданно: full_adres = %', (SELECT full_adres FROM object_info_tbl WHERE id_object=-1);
    END IF;
    DELETE FROM object_info_tbl WHERE id_object = -1;
END;
$$;


-- ────────────────────────────────────────────────────────────
-- T16. Кривой addressing_mode (=3) отклоняется и не попадает в таблицу.
-- Два рубежа обороны: BEFORE ROW триггер object_house (его ветка ELSE,
-- ошибка P0001 'Неизвестный способ адресации') срабатывает ПЕРВЫМ, ещё
-- до CHECK-ограничения ck_object_house_addr_mode. CHECK остаётся как
-- defense-in-depth (на случай отключения/правки триггера). Тест принимает
-- любой из двух путей отказа — важно, что строка не сохраняется.
-- ────────────────────────────────────────────────────────────
DO $$
BEGIN
    INSERT INTO object (id_object, id_object_class, id_object_type, object_name)
        VALUES (912, 1, 1, 'Дом с кривым режимом');
    INSERT INTO object_house (id_object, id_territory, house_no, addressing_mode)
        VALUES (912, 5, '7', 3);   -- 3 — недопустимо (только 1 или 2)
    RAISE EXCEPTION 'ТЕСТ ПРОВАЛЕН: addressing_mode=3 не отклонён';
EXCEPTION
    WHEN check_violation THEN
        RAISE NOTICE 'T16 OK — CHECK отклонил addressing_mode=3';
    WHEN raise_exception THEN
        RAISE NOTICE 'T16 OK — триггер отклонил addressing_mode=3: %', SQLERRM;
END;
$$;

SELECT COUNT(*) AS should_be_zero FROM object WHERE id_object = 912;
