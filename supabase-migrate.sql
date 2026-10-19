-- ════════════════════════════════════════════════════════════════
--  일회용: Google Sheets → Supabase 데이터 이전 함수
--
--  supabase-schema.sql 을 먼저 실행한 뒤, 이 파일을 SQL Editor 에서 실행하세요.
--  이전이 끝나면 맨 아래 안내대로 삭제하는 것을 권합니다.
-- ════════════════════════════════════════════════════════════════

create or replace function public.migrate_import(
  p_pin     text,
  p_data    jsonb,
  p_replace boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_emp int; v_ann int; v_log int;
  v_raw_ann int; v_ins_ann int; v_orphan_ann int;
begin
  perform public.assert_admin(p_pin, true);

  -- 실수로 두 번 돌려 데이터가 섞이는 것을 막는다.
  if not p_replace then
    if exists (select 1 from public.employees) or exists (select 1 from public.annuals) then
      raise exception '이미 데이터가 있습니다. 전부 지우고 다시 넣으려면 p_replace 를 true 로 호출하세요.';
    end if;
  else
    delete from public.annuals;
    delete from public.employees;
    delete from public.change_logs;
  end if;

  -- ── 직원: 기존 ID 를 글자 그대로 보존한다 ──
  insert into public.employees (id, name, team, color, retired, retired_at)
  select e->>'id',
         coalesce(e->>'name', ''),
         coalesce(e->>'team', ''),
         coalesce(nullif(e->>'color',''), '#3B6FE8'),
         lower(coalesce(e->>'retired','')) in ('true','t','1','y','yes'),
         case when coalesce(e->>'retiredAt','') ~ '^\d{4}-\d{2}-\d{2}'
              then left(e->>'retiredAt',10)::date else null end
    from jsonb_array_elements(coalesce(p_data->'employees', '[]'::jsonb)) e
   where coalesce(e->>'id','') <> ''
     and coalesce(e->>'name','') <> ''
  on conflict (id) do nothing;

  -- ── 연차/휴일근무 ──
  -- 시트에 같은 직원/같은 날짜가 두 번 들어있을 수 있다. 그대로 넣으면
  -- Postgres 가 "ON CONFLICT DO UPDATE 가 같은 행을 두 번 건드린다"며 거부하므로
  -- 먼저 distinct on 으로 추려낸다. 여러 건이면 시트에서 뒤에 있는 것을 쓴다.
  select count(*) into v_raw_ann
    from jsonb_array_elements(coalesce(p_data->'annuals', '[]'::jsonb)) a
   where coalesce(a->>'empId','') <> ''
     and coalesce(a->>'type','')  <> ''
     and coalesce(a->>'date','')  ~ '^\d{4}-\d{2}-\d{2}';

  insert into public.annuals (emp_id, emp_name, date, type)
  select distinct on (emp_id, d) emp_id, emp_name, d, type
    from (
      select a->>'empId'                   as emp_id,
             coalesce(a->>'empName','')    as emp_name,
             left(a->>'date',10)::date     as d,
             a->>'type'                    as type,
             ord
        from jsonb_array_elements(coalesce(p_data->'annuals', '[]'::jsonb))
             with ordinality as t(a, ord)
       where coalesce(a->>'empId','') <> ''
         and coalesce(a->>'type','')  <> ''
         and coalesce(a->>'date','')  ~ '^\d{4}-\d{2}-\d{2}'
    ) s
   order by emp_id, d, ord desc
  on conflict (emp_id, date)
    do update set type = excluded.type, emp_name = excluded.emp_name;

  get diagnostics v_ins_ann = row_count;

  -- ── 연차 공지 ──
  if p_data ? 'notice' then
    insert into public.settings (key, value, updated_at)
      values ('cal_notice', coalesce(p_data->>'notice',''), now())
      on conflict (key) do update set value = excluded.value, updated_at = now();
  end if;

  -- ── 변경이력 ──
  -- dt 는 migrate.html 이 오프셋 포함 ISO-8601 로 정규화해서 보낸다.
  -- (기존 GAS 는 UTC 로 기록했으므로 그쪽에서 Z 를 붙여 변환한다)
  insert into public.change_logs (dt, author, description)
  select case when coalesce(l->>'dt','') ~ '^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}'
              then (l->>'dt')::timestamptz else now() end,
         coalesce(l->>'by',''),
         coalesce(l->>'desc','')
    from jsonb_array_elements(coalesce(p_data->'logs', '[]'::jsonb)) l
   where coalesce(l->>'desc','') <> '';

  select count(*) into v_emp from public.employees;
  select count(*) into v_ann from public.annuals;
  select count(*) into v_log from public.change_logs;

  -- 삭제된 직원을 참조하는 연차 건수 (정상일 수 있음 — 이름으로 표시된다)
  select count(*) into v_orphan_ann
    from public.annuals a
   where not exists (select 1 from public.employees e where e.id = a.emp_id);

  return jsonb_build_object(
    'ok', true,
    'employees', v_emp,
    'annuals', v_ann,
    'logs', v_log,
    'dup_annuals', greatest(v_raw_ann - v_ins_ann, 0),  -- 중복이라 합쳐진 건수
    'orphan_annuals', v_orphan_ann);                    -- 삭제된 직원을 참조하는 건수
end;
$$;

grant execute on function public.migrate_import(text,jsonb,boolean) to anon, authenticated;

-- ════════════════════════════════════════════════════════════════
--  이전 완료 후 — 이 함수는 더 필요 없으므로 지우세요
--
--    drop function public.migrate_import(text,jsonb,boolean);
-- ════════════════════════════════════════════════════════════════
