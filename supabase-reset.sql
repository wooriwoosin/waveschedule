-- ════════════════════════════════════════════════════════════════
--  ⚠ 전체 초기화 — 데이터가 모두 지워집니다. 되돌릴 수 없습니다.
--
--  supabase-schema.sql 이 "데이터가 들어있는 테이블이 있어 중단했습니다"
--  라고 거부했는데도 정말 처음부터 다시 만들고 싶을 때만 쓰세요.
--
--  먼저 아래 조회로 무엇이 지워질지 확인하세요:
--
--    select 'employees' t, count(*) from public.employees
--    union all select 'annuals',    count(*) from public.annuals
--    union all select 'change_logs',count(*) from public.change_logs;
--
--  Google 시트는 건드리지 않으므로, 지워도 시트에서 다시 이전할 수 있습니다.
-- ════════════════════════════════════════════════════════════════

drop table if exists public.annuals      cascade;
drop table if exists public.employees    cascade;
drop table if exists public.change_logs  cascade;
drop table if exists public.settings     cascade;
drop table if exists public.admin_pins   cascade;
drop table if exists public.pin_attempts cascade;

-- 함수는 인자 구성이 달라도 지워지도록 이름으로 찾아 지운다
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure::text as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('pin_role','assert_admin','check_pin','save_annual',
                         'add_employee','update_employee','retire_employee',
                         'unretire_employee','delete_employee','save_notice',
                         'set_admin_pin','migrate_import')
  loop
    execute 'drop function if exists ' || r.sig || ' cascade';
  end loop;
end $$;

-- 이제 supabase-schema.sql 을 다시 실행하고, PIN 을 다시 등록하세요.
