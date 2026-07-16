# Миграция BA7_DATA / object_info на PostgreSQL 16

Вторая попытка переноса Oracle-логики учёта объектов недвижимости (см. корень репозитория и
`../CLAUDE.md`) на PostgreSQL 16 — с нуля, по документированной архитектуре из
`packages_docs_1.odt`. Предыдущая попытка (файл `пакет_PLpgSQL.sql`, удалён из истории git)
прокидывала списки id через `INOUT`-параметры процедур, имитируя Oracle-пакетные переменные —
это не давало корректно обрабатывать массовые DML-операции и не соответствовало документированной
архитектуре. Здесь вместо этого используются нативные механизмы PostgreSQL 16 — statement-level
триггеры с transition tables.

## Порядок разворачивания

Скрипты применяются по номерам, каждый зависит от предыдущих:

```bash
psql -d your_database -v ON_ERROR_STOP=1 -f 00_ddl.sql
psql -d your_database -v ON_ERROR_STOP=1 -f 01_territory_pkg.sql
psql -d your_database -v ON_ERROR_STOP=1 -f 02_object_info_pkg.sql
psql -d your_database -v ON_ERROR_STOP=1 -f 03_object_info_triggers.sql
psql -d your_database -v ON_ERROR_STOP=1 -f 04_subtype_triggers.sql
```

Проверено на чистой PostgreSQL 16 базе (все пять файлов применяются без ошибок, полный
сквозной сценарий дом → подъезд/квартира → комната работает, включая перенос подъезда между
зданиями и `object_info_pkg.rebuild()`).

## Схемы

| Схема             | Назначение                                                                 |
|-------------------|-----------------------------------------------------------------------------|
| `ba7_data`        | Таблицы данных + все триггеры (аналог Oracle-схемы `BA7_DATA`).            |
| `territory_pkg`   | Сборка адреса по иерархии `territory` (аналог Oracle-пакета `territory_pkg` + `GetTerritoryInfo`). |
| `object_info_pkg` | Синхронизация `object_info_tbl` (аналог тела Oracle-пакета `object_info_pkg`) + тип `object_row_type`. |

Отдельная схема на "пакет" — способ сымитировать инкапсуляцию Oracle PACKAGE BODY: в PostgreSQL нет
скрытого тела пакета, поэтому функции/процедуры логики вынесены из схемы с данными, а права на
`ba7_data` и на схемы-пакеты можно разграничивать независимо (см. TODO про `GRANT` в каждом файле).

## Архитектурные решения (из `packages_docs_1.odt`) и как они реализованы

1. **Нет пакетных переменных, общих на сессию.** Вместо коллекции `TTableNumber`, которую в Oracle
   заполняли построчные триггеры и вычитывали статейные, здесь **AFTER STATEMENT-триггеры с
   transition tables** (`REFERENCING NEW TABLE`/`OLD TABLE`, файлы `03_`/`04_`) — PostgreSQL сам
   собирает набор затронутых одной DML-операцией строк и передаёт его как обычную таблицу.
   Ограничение PostgreSQL: один statement-триггер с transition table не может обслуживать сразу
   несколько событий (`INSERT OR UPDATE OR DELETE`) — поэтому на `object` три отдельных триггера
   (`tasi1_object`/`tasu1_object`/`tasd1_object`) вместо одного `TAIU6_OBJECT`.
2. **Нет инкапсуляции пакета.** Функции/процедуры разнесены по схемам `territory_pkg`/
   `object_info_pkg`, отдельно от данных (`ba7_data`) — см. таблицу схем выше.
3. **Нет автоматического `OBJECT%ROWTYPE` в сигнатуре без завязки на конкретную таблицу.**
   Явный составной тип `object_info_pkg.object_row_type` с полями, которые реально нужны
   `update_object_info` — аналог `l$object_required_column_list` из Oracle-пакета. *Уточнение*:
   PL/pgSQL **на самом деле поддерживает** `tablename%ROWTYPE` как тип локальной переменной внутри
   функции (используется в `04_subtype_triggers.sql` для `object_room`) — ограничение касается
   только использования `%ROWTYPE` как типа параметра функции на границе схем, для чего явный
   составной тип всё равно необходим и предпочтительнее (он уже, чем весь `object`, и не меняется
   при добавлении в `object` не относящихся к адресу колонок).
4. **`num_collect_pkg` (обход mutating table в Oracle для каскада "подъезд переехал в другое
   здание → перенести его помещения").** Заменён на AFTER STATEMENT-триггер с transition table
   (`tasu1_house_doorway` в `04_subtype_triggers.sql`) — тот же приём, что и в п.1, но локально для
   `house_doorway`/`object_flat`.

## Что сознательно не перенесено (TODO, закомментировано в коде)

Вызовы внешних Oracle-фреймворковых пакетов оставлены в виде закомментированных TODO прямо в местах
использования — их PostgreSQL-аналогов пока нет:

- `scheming_pkg` (`group_synonym`/`group_privs`) — регистрация синонимов и прав для схем-потребителей
  (`TEST_OWNER`, `STD_POLICY`) — заменено на закомментированные `GRANT` в конце `00_`/`01_`/`02_`.
- `ddl_pkg.create_trigger` — динамическая генерация DDL триггеров — в PostgreSQL-версии триггеры
  создаются статическим DDL (`03_`/`04_`), генерация не нужна.
- `int_rep_session.setDbAccessMode` — временное переключение режима доступа к БД на время
  `object_info_pkg.rebuild()`, чтобы не попадать в очередь межбазовой репликации BA7 — TODO в
  `02_object_info_pkg.sql`.
- `num_collect_pkg` — см. п.4 выше, для `house_doorway` уже реально заменён; если он используется
  где-то ещё за пределами перенесённого кода, то аналогично нужен transition table.
- `run_sql_parts` — батчевое выполнение по диапазонам id — заменено на обычный `LOOP` внутри
  `object_info_pkg.rebuild(p_batch_size)`, отдельный PostgreSQL-аналог не нужен.
- Сессионный контекст BA7 (`SYS_CONTEXT('ctx_ba7_rep', 'writer')`, использовался в Oracle-триггере
  на `object`, чтобы не трогать `object_info_tbl` во время слияния объектов через `dublicate_pkg`) —
  TODO в `tasu1_object()` (`03_object_info_triggers.sql`), предполагаемый аналог —
  `current_setting('ba7.writer', true)`.

## Отличия от Oracle-оригинала помимо чисто синтаксических

- **Исправлен явный баг** в Oracle `object_info_pkg.update_object_info` (UPDATE-ветка): там
  `id_street2` ошибочно присваивался из `:new.id_territory2` (копипаст, INSERT-ветка делает это
  правильно). В PostgreSQL-версии (`02_object_info_pkg.sql`) — исправлено, отмечено комментарием.
- Триггер на `territory` теперь дополнительно следит за изменением `zip` (в Oracle-оригинале
  `AFTER UPDATE OF ID_PARENT, ID_TERRITORY_CLASS, ID_TERRITORY_TYPE, NAME` не отслеживал `zip`,
  хотя zip наследуется по той же иерархии и меняется, влияя на потомков).
- `object_house.addressing_mode` теперь под `CHECK (addressing_mode IN (1, 2))` — в Oracle не было
  ограничения на уровне таблицы, только проверка в триггере.
- Функция `format_left`, которую Oracle-оригинал `trigger.house_doorway.sql` вызывал для форматирования
  `house_no` подъезда, не найдена в репозитории (не является ни одним из перенесённых Oracle-пакетов).
  Заменена на уже перенесённую `object_info_pkg.format_object_no(..., 10)` — той же функцией и той же
  длиной, что используется для первичного номера дома везде остальные (см. комментарий в
  `04_subtype_triggers.sql`).
- Известный (сохранённый как есть, не исправленный) нюанс из Oracle-оригинала: при
  `addressing_mode = 2` каскадное обновление `object` для комнат в `trigger.object_house.sql`
  использует коррелированный подзапрос, который не находит совпадений для строк-комнат (он ищет по
  `object_flat`, а не по `object_room`) — их `dom` уходит в `NULL`. Поведение перенесено 1:1
  (см. комментарий в `04_subtype_triggers.sql`), т.к. неочевидно, что это баг, а не осознанный
  edge-case оригинальной системы — стоит уточнить при появлении реальных данных с комнатами в домах
  с адресацией "по подъездам".

## Проверено вручную (нет тестового фреймворка/CI в репозитории)

- `territory_pkg.get_info` — сборка `full_adres`/`short_adres`/`adr_pos01..10`/`zip` по иерархии
  из 5 уровней (страна → регион → район → город → улица), значения позиций сверены вручную.
- `object_info_pkg.format_object_no` — выравнивание номеров с буквенным суффиксом.
- `object_info_pkg.update_object_info` — INSERT/UPDATE/DELETE, включая ошибку при отсутствующем
  `id_object` и связку id-list → single-id → object_row_type.
- Полный сценарий: дом (`addressing_mode=1`) → квартира → комната — адрес и `object_info_tbl`
  собираются автоматически через прямые `INSERT`/`UPDATE` в `object`/`object_house`/`object_flat`/
  `object_room`, без ручного вызова `update_object_info`.
- Дом с `addressing_mode=2` (по подъездам): подъезд, квартира, перенос подъезда в другое здание —
  `object_flat.id_object_house` и адрес корректно следуют за подъездом.
- `object_unknown` (прочий объект) — прямое копирование территории/номера/индекса.
- Валидационные ошибки (`RAISE EXCEPTION`) — отсутствие обязательного `id_house_doorway`/`house_no`
  при `addressing_mode = 2`, отсутствие `house_no` не должно быть при `addressing_mode = 1`.
- `object_info_pkg.rebuild()` и `rebuild(p_batch_size)` — удаление осиротевших строк, вставка
  отсутствующих, восстановление после ручного искажения `object_info_tbl`.
- Массовые DML (`INSERT`/`UPDATE`/`DELETE` нескольких строк `object` одной командой) — обрабатываются
  одним срабатыванием statement-триггера, не по одному разу на строку.
