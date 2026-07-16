-- сработает триггер на object и обновиться object_info_tbl
call ba7_rep.int_rep_session.setDbAccessMode(2);
UPDATE ba7_data.object SET id_territory=id_territory;
commit;
/
