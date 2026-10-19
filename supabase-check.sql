-- ════════════════════════════════════════════════════════════════
--  진단 — public 스키마에 지금 무엇이 있는지 보여줍니다.
--  아무것도 바꾸지 않습니다. 결과를 그대로 복사해서 알려주세요.
-- ════════════════════════════════════════════════════════════════

select '── 테이블 ──' as "항목", '' as "내용"
union all
select t.table_name,
       (select string_agg(c.column_name || ' ' || c.data_type, ', ' order by c.ordinal_position)
          from information_schema.columns c
         where c.table_schema = 'public' and c.table_name = t.table_name)
  from information_schema.tables t
 where t.table_schema = 'public' and t.table_type = 'BASE TABLE'

union all select '', ''
union all select '── 함수 ──', ''
union all
select p.proname,
       pg_get_function_identity_arguments(p.oid) || ' → ' || pg_get_function_result(p.oid)
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'

union all select '', ''
union all select '── 행 수 ──', ''
union all
select 'employees',   (select count(*)::text from public.employees)
 where exists (select 1 from information_schema.tables
                where table_schema='public' and table_name='employees')
union all
select 'annuals',     (select count(*)::text from public.annuals)
 where exists (select 1 from information_schema.tables
                where table_schema='public' and table_name='annuals')
union all
select 'change_logs', (select count(*)::text from public.change_logs)
 where exists (select 1 from information_schema.tables
                where table_schema='public' and table_name='change_logs')
union all
select 'admin_pins',  (select count(*)::text from public.admin_pins)
 where exists (select 1 from information_schema.tables
                where table_schema='public' and table_name='admin_pins');
