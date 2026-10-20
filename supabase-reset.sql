-- ════════════════════════════════════════════════════════════════
--  ⚠ 웨이브넷 스케줄(wn_) 전체 초기화 — 되돌릴 수 없습니다.
--
--  이 데이터베이스에는 다른 앱(시흥영업팀 스케줄 등)이 함께 들어있습니다.
--  이 파일은 wn_ 로 시작하는 것만 지웁니다. 다른 앱은 건드리지 않습니다.
--
--  먼저 무엇이 지워질지 확인하세요:
--
--    select table_name from information_schema.tables
--     where table_schema='public' and table_name like 'wn\_%';
--
--  Google 시트는 건드리지 않으므로, 지워도 시트에서 다시 이전할 수 있습니다.
-- ════════════════════════════════════════════════════════════════

do $reset$
declare r record;
begin
  -- 함수: 인자 구성이 달라도 지워지도록 이름으로 찾아 지운다 (wn_ 만)
  for r in
    select p.oid::regprocedure::text as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname like 'wn\_%'
  loop
    execute 'drop function if exists ' || r.sig || ' cascade';
  end loop;

  -- 테이블: wn_ 로 시작하는 것만
  for r in
    select table_name as t from information_schema.tables
     where table_schema = 'public' and table_type = 'BASE TABLE'
       and table_name like 'wn\_%'
  loop
    execute format('drop table if exists public.%I cascade', r.t);
    raise notice '지움: %', r.t;
  end loop;
end
$reset$;

-- 이제 supabase-schema.sql 을 실행하고, PIN 을 다시 등록하세요.
