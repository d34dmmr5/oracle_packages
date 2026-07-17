-- =============================================================================================
-- 03_object_info_triggers.sql
-- AFTER STATEMENT-триггеры на ba7_data.object и ba7_data.territory, синхронизирующие
-- object_info_tbl. Замена Oracle-пакетных коллекций (l$id_object_insert/update/delete,
-- l$id_territory_update из object_info_pkg): вместо накопления id в переменных, общих на весь
-- пакет/сессию, каждый DML собирает свой набор строк через нативный механизм PostgreSQL --
-- transition tables (REFERENCING NEW/OLD TABLE), доступные только для statement-level триггеров.
--
-- Нейминг триггеров/функций: T + A(after)/B(before) + S(statement)/R(row) + событие(insert/update/
-- delete, одной буквой на каждое) + порядковый номер + "_" + имя таблицы. A/B соответствуют
-- исходной Oracle-конвенции (TAIU=AFTER, TBIU=BEFORE) -- см. CLAUDE.md.
--
-- Важное отличие от Oracle: один statement-триггер с transition table не может обслуживать сразу
-- несколько событий (INSERT/UPDATE/DELETE) -- у каждого события своя допустимая комбинация
-- OLD TABLE/NEW TABLE. Поэтому на object -- три отдельные функции/триггера вместо одного
-- TAIU6_OBJECT, как и описано в документации миграции ("отдельные триггеры, триггерные функции и
-- массивы для каждой DML-операции").
--
-- Oracle-триггер TCBU$E98$OBJECT_INFO (BEFORE STATEMENT UPDATE ON TERRITORY, вызывавший
-- object_info_pkg.init() для обнуления пакетных коллекций перед накоплением) здесь не нужен --
-- обнулять нечего, transition table существует только в рамках одного statement.
-- =============================================================================================

-- === object: INSERT ===========================================================================

CREATE OR REPLACE FUNCTION ba7_data.tasi1_object() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
    m_ids BIGINT[];
BEGIN
    SELECT array_agg(id_object) INTO m_ids FROM new_t;
    PERFORM object_info_pkg.update_object_info(m_ids, 'insert');
    RETURN NULL;
END;
$$;

CREATE TRIGGER tasi1_object
    AFTER INSERT ON ba7_data.object
    REFERENCING NEW TABLE AS new_t
    FOR EACH STATEMENT
    EXECUTE FUNCTION ba7_data.tasi1_object();

-- === object: UPDATE ===========================================================================

CREATE OR REPLACE FUNCTION ba7_data.tasu1_object() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
    m_ids BIGINT[];
BEGIN
    -- 20.09.2021 SHA (перенесено из комментария Oracle-оригинала): при слиянии объектов
    -- (dublicate_pkg) запись в object_info_tbl для "поглощаемого" объекта не должна обновляться
    -- этим триггером -- этим займётся сам процесс слияния. В Oracle это проверялось через
    -- SYS_CONTEXT('ctx_ba7_rep', 'writer'). PostgreSQL-аналога сессионного контекста BA7 пока нет --
    -- раскомментировать и адаптировать, когда появится (например, через current_setting с
    -- пользовательским GUC вида 'ba7.writer').
    -- IF current_setting('ba7.writer', true) = 'dublicate_pkg' THEN
    --     RETURN NULL;
    -- END IF;

    SELECT array_agg(id_object) INTO m_ids FROM new_t;
    PERFORM object_info_pkg.update_object_info(m_ids, 'update');
    RETURN NULL;
END;
$$;

CREATE TRIGGER tasu1_object
    AFTER UPDATE ON ba7_data.object
    REFERENCING NEW TABLE AS new_t
    FOR EACH STATEMENT
    EXECUTE FUNCTION ba7_data.tasu1_object();

-- === object: DELETE ===========================================================================

CREATE OR REPLACE FUNCTION ba7_data.tasd1_object() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
    m_ids BIGINT[];
BEGIN
    SELECT array_agg(id_object) INTO m_ids FROM old_t;
    PERFORM object_info_pkg.update_object_info(m_ids, 'delete');
    RETURN NULL;
END;
$$;

CREATE TRIGGER tasd1_object
    AFTER DELETE ON ba7_data.object
    REFERENCING OLD TABLE AS old_t
    FOR EACH STATEMENT
    EXECUTE FUNCTION ba7_data.tasd1_object();

-- === territory: UPDATE ========================================================================
-- Аналог связки Oracle TAIU6_TERRITORY (row, копил id в tmp_chg_territory) + TAIU7_TERRITORY
-- (statement, разворачивал потомков через CONNECT BY и форсировал UPDATE object). В PostgreSQL
-- transition table сама по себе уже даёт statement-триггеру полный список изменённых территорий --
-- промежуточная таблица tmp_chg_territory и парный row-триггер не нужны.
--
-- В Oracle-оригинале триггер объявлялся как "AFTER UPDATE OF id_parent, id_territory_class,
-- id_territory_type, name" -- пересчёт нужен только если менялось то, что влияет на адрес.
-- PostgreSQL не разрешает сочетать список колонок (UPDATE OF ...) с transition tables (ошибка
-- "transition tables cannot be specified for triggers with column lists"), поэтому тот же фильтр
-- реализован вручную внутри функции -- JOIN new_t к old_t по id_territory и сравнение колонок.
-- zip тоже включён в проверку (наследуется по той же иерархии), в отличие от Oracle-оригинала, где
-- он не отслеживался.

CREATE OR REPLACE FUNCTION ba7_data.tasu1_territory() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
    m_ids BIGINT[];
BEGIN
    -- Защита от цикла в иерархии (см. подробный комментарий в territory_pkg.get_info,
    -- 01_territory_pkg.sql): здесь она "бесплатная" -- UNION (не UNION ALL) сам обрывает
    -- рекурсию, потому что рекурсивный член выбирает единственную колонку id_territory без
    -- изменяющихся от итерации к итерации значений (в отличие от get_info, где накапливается
    -- level_row/адрес и потому нужен явный visited-массив). ВАЖНО: если сюда когда-нибудь
    -- добавят ещё колонки в SELECT рекурсивного члена -- эта защита от цикла молча перестанет
    -- работать (строки перестанут быть текстуально идентичными и не будут признаваться
    -- дубликатами) -- в этом случае нужен явный visited-массив по аналогии с get_info.
    WITH RECURSIVE changed AS (
        SELECT n.id_territory
        FROM new_t n
        JOIN old_t o ON o.id_territory = n.id_territory
        WHERE n.id_parent IS DISTINCT FROM o.id_parent
           OR n.id_territory_class IS DISTINCT FROM o.id_territory_class
           OR n.id_territory_type IS DISTINCT FROM o.id_territory_type
           OR n.name IS DISTINCT FROM o.name
           OR n.zip IS DISTINCT FROM o.zip
    ),
    terr AS (
        SELECT id_territory FROM changed
        UNION
        SELECT b.id_territory
        FROM ba7_data.territory b
        JOIN terr t ON b.id_parent = t.id_territory
    )
    SELECT array_agg(DISTINCT x.id_object) INTO m_ids
    FROM (
        SELECT id_object FROM ba7_data.object WHERE id_territory  IN (SELECT id_territory FROM terr)
        UNION
        SELECT id_object FROM ba7_data.object WHERE id_territory2 IN (SELECT id_territory FROM terr)
    ) x;

    PERFORM object_info_pkg.update_object_info(m_ids, 'update');
    RETURN NULL;
END;
$$;

CREATE TRIGGER tasu1_territory
    AFTER UPDATE ON ba7_data.territory
    REFERENCING OLD TABLE AS old_t NEW TABLE AS new_t
    FOR EACH STATEMENT
    EXECUTE FUNCTION ba7_data.tasu1_territory();
