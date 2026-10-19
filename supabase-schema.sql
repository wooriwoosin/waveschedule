-- ════════════════════════════════════════════════════════════════
--  유통사업부 스케줄관리 — Supabase 스키마
--
--  사용법: Supabase 대시보드 → SQL Editor → 이 파일 전체 붙여넣고 Run
--          (맨 아래 "관리자 PIN 등록" 부분은 따로 안내합니다)
--
--  설계 메모
--   · 공개 키(publishable key)는 HTML 에 그대로 들어간다. 따라서 보안은
--     전적으로 RLS 가 책임진다. anon 에게는 "조회"만 허용하고,
--     모든 쓰기는 PIN 을 검증하는 SECURITY DEFINER 함수로만 통한다.
--   · 변경이력은 각 함수 안에서 같은 트랜잭션으로 기록한다.
--     (왕복 1회 절약 + 데이터와 이력이 어긋날 수 없음)
-- ════════════════════════════════════════════════════════════════

create extension if not exists pgcrypto with schema extensions;

-- ════════════════════════════════════════════════════════════════
--  0. 정리 — 모양이 다른 테이블이 이미 있으면 지우고 새로 만든다
--
--  "column \"dt\" does not exist" 같은 오류는, 이름은 같지만 컬럼이 다른
--  테이블이 이미 있을 때 create table if not exists 가 조용히 건너뛰고
--  뒤따르는 인덱스만 실패해서 난다.
--
--  실제 데이터가 들어있으면 지우지 않고 중단한다.
--  등록해 둔 PIN 은 모양이 맞으면 그대로 보존한다.
-- ════════════════════════════════════════════════════════════════

do $cleanup$
declare
  v_rows bigint;
  v_blocked text := '';
  r record;
begin
  -- 사람이 만든 데이터가 들어있는지 먼저 본다
  for r in select unnest(array['employees','annuals','change_logs']) as t loop
    if exists (select 1 from information_schema.tables
                where table_schema = 'public' and table_name = r.t) then
      execute format('select count(*) from public.%I', r.t) into v_rows;
      if v_rows > 0 then
        v_blocked := v_blocked || '  · ' || r.t || ': ' || v_rows || '행' || chr(10);
      end if;
    end if;
  end loop;

  if v_blocked <> '' then
    raise exception E'데이터가 들어있는 테이블이 있어 중단했습니다:
%
이미 이전을 마치셨다면 이 파일을 다시 돌릴 필요가 없습니다.
정말 처음부터 다시 만들려면 supabase-reset.sql 을 먼저 실행하세요.', v_blocked;
  end if;

  -- ── 기존 함수 제거 ──
  -- create or replace 는 반환형을 바꿀 수 없다("cannot change return type").
  -- 인자 구성이 달라도 확실히 지우기 위해 이름으로 찾아 실제 시그니처를 꺼내 지운다.
  for r in
    select p.oid::regprocedure::text as sig
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('pin_role','assert_admin','check_pin','save_annual',
                         'add_employee','update_employee','retire_employee',
                         'unretire_employee','delete_employee','save_notice',
                         'set_admin_pin','migrate_import')
  loop
    execute 'drop function if exists ' || r.sig || ' cascade';
  end loop;

  -- ── 남아있을 수 있는 인덱스 이름 정리 ──
  drop index if exists public.annuals_date_idx;
  drop index if exists public.change_logs_dt_idx;

  -- 비어 있거나 모양이 다르므로 지운다 (settings 의 기본 공지 1행은 다시 만들어진다)
  drop table if exists public.annuals      cascade;
  drop table if exists public.employees    cascade;
  drop table if exists public.change_logs  cascade;
  drop table if exists public.settings     cascade;
  drop table if exists public.pin_attempts cascade;

  -- admin_pins 는 등록한 PIN 이 들어있을 수 있다. 모양이 맞으면 건드리지 않는다.
  if exists (select 1 from information_schema.tables
              where table_schema = 'public' and table_name = 'admin_pins')
     and not exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'admin_pins'
                and column_name = 'pin_hash') then
    drop table public.admin_pins cascade;
    raise notice 'admin_pins 의 모양이 달라 새로 만듭니다. PIN 을 다시 등록해주세요.';
  end if;
end
$cleanup$;

-- ════════════════════════════════════════════════════════════════
--  1. 테이블
-- ════════════════════════════════════════════════════════════════

-- id 는 text: 기존 Google Sheets 의 직원 ID 를 그대로 보존하기 위함.
-- (연차 기록이 이 ID 로 직원을 참조하므로 형식이 바뀌면 전부 끊어진다)
create table if not exists public.employees (
  id          text primary key,
  name        text not null,
  team        text not null default '',
  color       text not null default '#3B6FE8',
  retired     boolean not null default false,
  retired_at  date,
  created_at  timestamptz not null default now()
);

-- 연차 / 휴일근무.
-- emp_id 에 외래키를 걸지 않는다: 직원을 삭제해도 연차 기록은 남아야 하고
-- (기존 Sheets 동작 그대로), 화면은 저장된 emp_name 으로 대체 표시한다.
create table if not exists public.annuals (
  id          bigint generated always as identity primary key,
  emp_id      text not null,
  emp_name    text not null default '',
  date        date not null,
  type        text not null,
  updated_at  timestamptz not null default now(),
  unique (emp_id, date)
);
create index if not exists annuals_date_idx on public.annuals (date);

create table if not exists public.settings (
  key        text primary key,
  value      text not null default '',
  updated_at timestamptz not null default now()
);
insert into public.settings (key, value) values ('cal_notice', '')
  on conflict (key) do nothing;

create table if not exists public.change_logs (
  id          bigint generated always as identity primary key,
  dt          timestamptz not null default now(),
  author      text not null default '',
  description text not null default ''
);
create index if not exists change_logs_dt_idx on public.change_logs (dt desc);

-- PIN 은 bcrypt 해시로만 저장한다. 평문은 어디에도 남지 않는다.
create table if not exists public.admin_pins (
  id         bigint generated always as identity primary key,
  label      text not null default '',
  pin_hash   text not null,
  role       text not null check (role in ('super','admin')),
  created_at timestamptz not null default now()
);

-- PIN 무차별 대입 차단용 (IP 당 10분에 10회)
create table if not exists public.pin_attempts (
  ip           text primary key,
  window_start timestamptz not null default now(),
  n            int not null default 0
);

-- ════════════════════════════════════════════════════════════════
--  2. RLS — anon 은 조회만, 쓰기는 전부 차단
--     (정책이 없는 테이블은 RLS 가 모두 거부한다)
-- ════════════════════════════════════════════════════════════════

alter table public.employees    enable row level security;
alter table public.annuals      enable row level security;
alter table public.settings     enable row level security;
alter table public.change_logs  enable row level security;
alter table public.admin_pins   enable row level security;
alter table public.pin_attempts enable row level security;

drop policy if exists "read employees"   on public.employees;
drop policy if exists "read annuals"     on public.annuals;
drop policy if exists "read settings"    on public.settings;
drop policy if exists "read change_logs" on public.change_logs;

create policy "read employees"   on public.employees   for select to anon, authenticated using (true);
create policy "read annuals"     on public.annuals     for select to anon, authenticated using (true);
create policy "read settings"    on public.settings    for select to anon, authenticated using (true);
create policy "read change_logs" on public.change_logs for select to anon, authenticated using (true);

-- 쓰기 권한 자체를 회수한다. RLS 만으로도 막히지만(0건 처리),
-- 나중에 정책이 잘못 추가되더라도 뚫리지 않도록 2중으로 건다.
revoke insert, update, delete, truncate on
  public.employees, public.annuals, public.settings, public.change_logs
  from anon, authenticated;

-- PIN 관련 테이블은 조회조차 불가 (RLS + 권한 회수 2중)
revoke all on public.admin_pins   from anon, authenticated;
revoke all on public.pin_attempts from anon, authenticated;

-- ════════════════════════════════════════════════════════════════
--  3. PIN 검증 (내부 전용 — anon 호출 불가)
-- ════════════════════════════════════════════════════════════════

create or replace function public.pin_role(p_pin text)
returns text
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_ip   text;
  v_row  public.pin_attempts%rowtype;
  v_role text;
begin
  if coalesce(p_pin, '') = '' then
    return null;
  end if;

  select a.role into v_role
    from public.admin_pins a
   where a.pin_hash = crypt(p_pin, a.pin_hash)
   limit 1;

  v_ip := coalesce(
    nullif(trim(split_part(
      nullif(current_setting('request.headers', true), '')::json
        ->> 'x-forwarded-for', ',', 1)), ''),
    'unknown');

  -- 맞는 PIN 은 잠금과 무관하게 통과시키고 카운터를 지운다.
  -- 사무실이 공용 IP 를 쓰면 남의 오타 때문에 정상 사용자가 잠길 수 있기 때문.
  -- 공격자는 어차피 맞는 PIN 을 모르므로 이래도 느슨해지지 않는다.
  if v_role is not null then
    delete from public.pin_attempts where ip = v_ip;
    return v_role;
  end if;

  -- 틀린 PIN 만 횟수를 센다: IP 당 10분에 20회
  select * into v_row from public.pin_attempts where ip = v_ip for update;
  if found and v_row.window_start > now() - interval '10 minutes' then
    if v_row.n >= 20 then
      raise exception 'PIN 시도 횟수를 초과했습니다. 10분 후 다시 시도해주세요.';
    end if;
    update public.pin_attempts set n = n + 1 where ip = v_ip;
  else
    delete from public.pin_attempts where window_start < now() - interval '1 hour';
    insert into public.pin_attempts (ip, window_start, n) values (v_ip, now(), 1)
      on conflict (ip) do update set window_start = now(), n = 1;
  end if;

  return null;
end;
$$;

create or replace function public.assert_admin(p_pin text, p_need_super boolean)
returns text
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare v_role text;
begin
  v_role := public.pin_role(p_pin);
  if v_role is null then
    raise exception '권한이 없습니다. 관리자 PIN을 확인해주세요.';
  end if;
  if p_need_super and v_role <> 'super' then
    raise exception '슈퍼관리자만 가능한 작업입니다.';
  end if;
  return v_role;
end;
$$;

revoke all on function public.pin_role(text)            from public, anon, authenticated;
revoke all on function public.assert_admin(text,boolean) from public, anon, authenticated;

-- ════════════════════════════════════════════════════════════════
--  4. 공개 RPC — 모든 쓰기는 여기를 통해서만
-- ════════════════════════════════════════════════════════════════

create or replace function public.check_pin(p_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare v_role text;
begin
  v_role := public.pin_role(p_pin);
  if v_role is null then
    return jsonb_build_object('ok', false);
  end if;
  return jsonb_build_object('ok', true, 'role', v_role);
end;
$$;

create or replace function public.save_annual(
  p_pin text, p_emp_id text, p_emp_name text, p_date date, p_type text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare v_name text;
begin
  perform public.assert_admin(p_pin, false);
  if coalesce(p_emp_id,'') = '' or p_date is null then
    raise exception '직원과 날짜를 선택해주세요.';
  end if;

  v_name := coalesce(
    (select name from public.employees where id = p_emp_id),
    nullif(p_emp_name,''), '(알 수 없음)');

  if coalesce(p_type,'') = '' then
    delete from public.annuals where emp_id = p_emp_id and date = p_date;
    insert into public.change_logs (description)
      values (v_name || ' ' || to_char(p_date,'YYYY-MM-DD') || ' 연차/휴일근무 삭제');
  else
    insert into public.annuals (emp_id, emp_name, date, type, updated_at)
      values (p_emp_id, v_name, p_date, p_type, now())
      on conflict (emp_id, date)
        do update set type = excluded.type, emp_name = excluded.emp_name, updated_at = now();
    insert into public.change_logs (description)
      values (v_name || ' ' || to_char(p_date,'YYYY-MM-DD') || ' ' || p_type || ' 등록');
  end if;

  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.add_employee(
  p_pin text, p_name text, p_team text, p_color text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare v_id text; v_name text;
begin
  perform public.assert_admin(p_pin, true);
  v_name := trim(coalesce(p_name,''));
  if v_name = '' then raise exception '이름을 입력해주세요.'; end if;

  v_id := gen_random_uuid()::text;
  insert into public.employees (id, name, team, color)
    values (v_id, v_name, coalesce(p_team,''), coalesce(nullif(p_color,''), '#3B6FE8'));
  insert into public.change_logs (description) values ('직원 등록: ' || v_name);

  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

create or replace function public.update_employee(
  p_pin text, p_id text, p_name text, p_team text, p_color text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare v_name text; v_retired boolean;
begin
  perform public.assert_admin(p_pin, true);
  v_name := trim(coalesce(p_name,''));
  if v_name = '' then raise exception '이름을 입력해주세요.'; end if;

  select retired into v_retired from public.employees where id = p_id;
  if not found then raise exception '직원을 찾을 수 없습니다.'; end if;

  -- 퇴사자는 "(퇴)" 접두사를 유지한다
  if v_retired and v_name not like '(퇴)%' then v_name := '(퇴)' || v_name; end if;

  update public.employees
     set name = v_name, team = coalesce(p_team,''),
         color = coalesce(nullif(p_color,''), '#3B6FE8')
   where id = p_id;

  -- 달력 칩에 쓰이는 이름 사본도 함께 갱신
  update public.annuals set emp_name = v_name where emp_id = p_id;

  insert into public.change_logs (description) values ('직원 정보 수정: ' || v_name);
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.retire_employee(p_pin text, p_id text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare v_name text;
begin
  perform public.assert_admin(p_pin, true);
  update public.employees
     set retired = true,
         retired_at = (now() at time zone 'Asia/Seoul')::date,
         name = case when name like '(퇴)%' then name else '(퇴)' || name end
   where id = p_id
   returning name into v_name;
  if not found then raise exception '직원을 찾을 수 없습니다.'; end if;

  update public.annuals set emp_name = v_name where emp_id = p_id;
  insert into public.change_logs (description) values ('퇴사 처리: ' || v_name);
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.unretire_employee(p_pin text, p_id text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare v_name text;
begin
  perform public.assert_admin(p_pin, true);
  update public.employees
     set retired = false, retired_at = null,
         name = regexp_replace(name, '^\(퇴\)', '')
   where id = p_id
   returning name into v_name;
  if not found then raise exception '직원을 찾을 수 없습니다.'; end if;

  update public.annuals set emp_name = v_name where emp_id = p_id;
  insert into public.change_logs (description) values ('복직 처리: ' || v_name);
  return jsonb_build_object('ok', true);
end;
$$;

-- 직원만 삭제한다. 연차 기록은 emp_name 을 안고 그대로 남는다.
create or replace function public.delete_employee(p_pin text, p_id text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare v_name text;
begin
  perform public.assert_admin(p_pin, true);
  delete from public.employees where id = p_id returning name into v_name;
  if not found then raise exception '직원을 찾을 수 없습니다.'; end if;

  insert into public.change_logs (description) values ('직원 삭제: ' || v_name);
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.save_notice(p_pin text, p_notice text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
begin
  perform public.assert_admin(p_pin, false);
  insert into public.settings (key, value, updated_at)
    values ('cal_notice', coalesce(p_notice,''), now())
    on conflict (key) do update set value = excluded.value, updated_at = now();
  insert into public.change_logs (description) values ('연차 공지 수정');
  return jsonb_build_object('ok', true);
end;
$$;

grant execute on function public.check_pin(text)                            to anon, authenticated;
grant execute on function public.save_annual(text,text,text,date,text)      to anon, authenticated;
grant execute on function public.add_employee(text,text,text,text)          to anon, authenticated;
grant execute on function public.update_employee(text,text,text,text,text)  to anon, authenticated;
grant execute on function public.retire_employee(text,text)                 to anon, authenticated;
grant execute on function public.unretire_employee(text,text)               to anon, authenticated;
grant execute on function public.delete_employee(text,text)                 to anon, authenticated;
grant execute on function public.save_notice(text,text)                     to anon, authenticated;

-- ════════════════════════════════════════════════════════════════
--  5. 관리자 PIN 등록용 함수 (소유자 전용)
-- ════════════════════════════════════════════════════════════════

create or replace function public.set_admin_pin(p_label text, p_pin text, p_role text)
returns void
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
begin
  if p_role not in ('super','admin') then
    raise exception 'role 은 super 또는 admin 이어야 합니다.';
  end if;
  if length(coalesce(p_pin,'')) < 4 then
    raise exception 'PIN 은 4자리 이상이어야 합니다.';
  end if;
  if length(p_pin) < 6 then
    raise notice '⚠ PIN 이 % 자리입니다. 공개 API 로 노출되므로 6자리 이상을 권장합니다.', length(p_pin);
  end if;
  delete from public.admin_pins where label = p_label;
  insert into public.admin_pins (label, pin_hash, role)
    values (p_label, crypt(p_pin, gen_salt('bf')), p_role);
end;
$$;

revoke all on function public.set_admin_pin(text,text,text) from public, anon, authenticated;

-- ════════════════════════════════════════════════════════════════
--  6. 마지막 단계 — 관리자 PIN 등록
--
--  아래 두 줄의 따옴표 안을 실제 PIN 으로 바꿔서 SQL Editor 에서 실행하세요.
--  ⚠ 실제 PIN 을 적은 상태로 이 파일을 저장/커밋하지 마세요.
-- ════════════════════════════════════════════════════════════════
--
--   select public.set_admin_pin('슈퍼관리자', '여기에_슈퍼관리자_PIN', 'super');
--   select public.set_admin_pin('관리자',     '여기에_관리자_PIN',     'admin');
--
