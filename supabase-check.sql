-- ════════════════════════════════════════════════════════════════
--  진단 — 이 데이터베이스에 무엇이 있는지 보여줍니다.
--  읽기 전용입니다. 아무것도 바꾸지 않습니다.
--
--  앱 구분: wn_  = 웨이브넷 스케줄 (이 앱)
--           그 외 = 다른 앱 (시흥영업팀 등) — 건드리지 않습니다
-- ════════════════════════════════════════════════════════════════

select case when t.table_name like 'wn\_%' then '웨이브넷' else '다른 앱' end as "앱",
       t.table_name as "테이블",
       (select count(*) from information_schema.columns c
         where c.table_schema='public' and c.table_name=t.table_name)::text as "컬럼수",
       (select string_agg(c.column_name, ', ' order by c.ordinal_position)
          from information_schema.columns c
         where c.table_schema='public' and c.table_name=t.table_name) as "컬럼"
  from information_schema.tables t
 where t.table_schema='public' and t.table_type='BASE TABLE'
 order by 1 desc, 2;

select case when p.proname like 'wn\_%' then '웨이브넷' else '다른 앱' end as "앱",
       p.proname as "함수",
       pg_get_function_identity_arguments(p.oid) as "인자",
       pg_get_function_result(p.oid) as "반환"
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public'
 order by 1 desc, 2;
