---------------------------------------------------------------------------------------------
-----Обновление от 11.07.2016 PRA
---------------------------------------------------------------------------------------------
/* 	1.исправлен триггер "BA7_DATA"."TAIU6_OBJECT" для "BA7_DATA"."OBJECT" При Update было id_street=:new.id_territory а надо  id_street= m$id_street 
	2.Добавлено поле id_object_house, которая для помещений содержит ссылку на дом (по аналогии с object_flat), 
		сделано что бы можно было по object_info получить полную ссылку на HOUSE_DOORWAY, а то ID_HOUSE_DOORWAY было а ссылки на дом не было
*/
ALTER TABLE object_info_tbl add (id_object_house NUMBER(8));
обновить тригген BA7_DATA"."TAIU6_OBJECT для object взяв 01_procedure_triggers_views.sql 
обновить object_info_tbl 02_update_data_object_info_tbl.sql 								 
обновить object_info 


---------------------------------------------------------------------------------------------
-----Обновление от 20.11.2015 PRA

---------------------------------------------------------------------------------------------
/*
Для сопоставления справочника Территорий и Объектов с ФИАС http://wiki.gis-lab.info/w/ФИАС
	- добавлены поля id_region, id_settlement_city, id_district
	- сделано четкое заполнение всех этих ИД в соответсвии с классом территории в GETTERRITORYINFO 
*/ 

ALTER TABLE object_info_tbl add (id_region NUMBER(8), region_name VARCHAR2(200),
                                 id_main_city NUMBER(8), main_city_name VARCHAR2(200),
                                 id_district NUMBER(8), district_name VARCHAR2(200));

обновить процедуру GETTERRITORYINFO взяв 01_procedure_triggers_views.sql 
обновить тригген BA7_DATA"."TAIU6_OBJECT для object взяв 01_procedure_triggers_views.sql 
обновить object_info_tbl 02_update_data_object_info_tbl.sql 								 
обновить object_info 
CREATE OR REPLACE VIEW ba7_data.object_info AS
SELECT a.*,
       UPPER(NVL(a.street_name, ' ')) AS find_street_name,
       UPPER(NVL(a.city_name, ' ')) AS find_city_name,
       UPPER(NVL(TRIM(a.house), ' ')) AS find_house,
       UPPER(NVL(TRIM(a.building_no), ' ')) AS find_building_no,
       UPPER(NVL(TRIM(a.flat), ' ')) AS find_flat
  FROM object_info_tbl a;

/*
ALTER TABLE object_info_tbl DROP COLUMN SETTLEMENT_CITY_NAME;   
ALTER TABLE object_info_tbl DROP COLUMN ID_SETTLEMENT_CITY;
*/
---------------------------------------------------------------------------------------------
-----Обновление структуры object_info_tbl   от 15.05.2013
---------------------------------------------------------------------------------------------

/*
select * from table(inter_db_pkg.execute_query('select 1 from all_tables where table_name=upper(''object_info_tbl'')'));
*/

/*
Тестовый     15.05.2013
МФЦ Ангарск  15.05.2013
Сыктывкар    17.05.2013
Инта СБА     17.05.2013
Печора -
ЦЖР          17.05.2013
Прикамье     17.05.2013
Ухта цжр     17.05.2013 
Сосногорск   17.05.2013
Усинск       17.05.2013
Ухта         17.05.2013
Сосногорский Водоканал  20.05.2013                                  
RЭСК - южные районы                                       full_adres null
Воркутинский СБА 20.05.2013
Воргашорский ЖКХ                                            +
        29 Оптовая Региональная Энергетика                           
*/

/*
03.08.2012 добавлены поля adr_pos01...adr_pos10 которые сожердать номер позиции(символа) в full_adres с которого 
начинается часть адрес сооветсветсвующего класса территории. Например adr_pos03 соответсвует  id_territory_class =3 (регион), 
и с этой позциии начинается адрес до региона включительно,т.е. SUBSTR(full_adres,adr_pos03) (Например Республика Коме, г.Сыктывкар, ул. Пушкина 134-79), 
а в adr_pos04 - id_territory_class =4 (населенный пункт), выводить  адрес до нас. пункта включительно т.е. SUBSTR(full_adres,adr_pos03) (Например  г.Сыктывкар, ул. Пушкина 134-79)
*/





---------------------------------------------------------------------------------------------
-----Обновление структуры object_info_tbl   от 15.05.2013
---------------------------------------------------------------------------------------------

ALTER TABLE object_info_tbl add (ID_TERRITORY2 NUMBER(8), 
                                 ID_STREET2 NUMBER(8),
                                 STREET_NAME2 VARCHAR2(200),
                                 HOUSE2  CHAR(6), 
                                 BUILDING_NO2 VARCHAR2(30), 
                                 ADRES2 VARCHAR2(100), 
                                 FULL_ADRES2 VARCHAR2(1000), 
                                 ID_CITY2 NUMBER, 
                                 CITY_NAME2 VARCHAR2(200),
                                 ID_RAION2 NUMBER, 
                                 RAION_NAME2 VARCHAR2(200),
                                 IS_EXIST_ALTERNATE_ADRES NUMBER(1) DEFAULT 0);


---------------------------------------------------------------------------------------------
-----Обновление структуры object_info_tbl   
---------------------------------------------------------------------------------------------
ALTER TABLE object_info_tbl ADD (trace_info  VARCHAR2(2000));

UPDATE object_info_tbl X SET X.trace_info = (Select A.trace_info FROM object A WHERE A.id_object = X.id_object)
WHERE X.id_object IN (SELECT id_object FROM object where TRIM(trace_info) IS NOT NULL);

CONN ba7_data/ba7_data@&SERVER
--Доп часть  ID_HOUSE_DOORWAY, ADDRESSING_MODE, увеличние дома до 10 знаков
ALTER TABLE object_info_tbl add (ADDRESSING_MODE NUMBER(1),  ID_HOUSE_DOORWAY NUMBER(8));

---------------------------------------------------------------------------------------------
-----Перегенерация адресов с целью заполнения adr_posXX
---------------------------------------------------------------------------------------------
set serveroutput on;

DECLARE
i NUMBER(10);
begin

    UPDATE ba7_data.object SET id_territory = id_territory
        WHERE ROWNUM<5001 and id_object in (select id_object from object_info_tbl where full_adres is null);

COMMIT;

select count(*) into i
  from object_info_tbl where full_adres is null;

dbms_output.put_line('Кол-во пустых full_adres = '||to_char(i));

commit;

END;
/
                     
---------------------------------------------------------------------------------------------
-----Был косяк в триггере с заполнением ADRES2 исправлено от 29.05.2013
---------------------------------------------------------------------------------------------

set serveroutput on;

DECLARE
i NUMBER(10);
begin

     UPDATE ba7_data.object SET id_territory = id_territory
          WHERE ROWNUM<5001 and id_object in (select id_object from object_info_tbl where adres2 is not null);

COMMIT;

select count(*) into i
  from object_info_tbl where adres2 is not null;

dbms_output.put_line('Кол-во не пустых adres2 = '||to_char(i));

commit;

END;
/


---------------------------------------------------------------------------------------------
-----Изменение полей KW и FLAT char30 на varchar2(30)
---------------------------------------------------------------------------------------------

DROP INDEX BA7_DATA.I1_OBJECT;

ALTER TABLE BA7_DATA.OBJECT MODIFY(KW VARCHAR2(30));

UPDATE object set kw = rtrim(kw) WHERE kw is not null;

COMMIT;

CREATE UNIQUE INDEX BA7_DATA.I1_OBJECT ON BA7_DATA.OBJECT  (ID_TERRITORY, UPPER(TRIM(DOM)), UPPER(TRIM(KW)), ID_OBJECT)  TABLESPACE BA_DATA;


DROP INDEX BA7_DATA.I1_OBJECT_INFO_TBL;

ALTER TABLE BA7_DATA.OBJECT_INFO_TBL MODIFY(FLAT VARCHAR2(30));

UPDATE object_info_tbl set flat = rtrim(flat) WHERE flat is not null;

COMMIT;

CREATE UNIQUE INDEX "BA7_DATA"."I1_OBJECT_INFO_TBL" ON "BA7_DATA"."OBJECT_INFO_TBL"  ("ID_STREET", UPPER(TRIM("HOUSE")), UPPER(TRIM("FLAT")), "ID_OBJECT") ;

---------------------------------------------------------------------------------------------
----- Обновление от 28.12.2016 SHA+ZAN (Добавление и обработка поля ZIP "Почтовый индекс")
---------------------------------------------------------------------------------------------
смотри в апдейты, сюда ...

