-- =====================================================================
-- Polling Duty Attendance - Supabase (PostgreSQL) setup
-- Paste this whole file into Supabase > SQL Editor > New query > Run.
-- Safe to run again (it will not delete data). Default login: admin / admin123
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------- tables ----------
create table if not exists users (
  username text primary key,
  pwd      text not null,                       -- bcrypt hash, never plain text
  role     text not null default 'user',
  groups   jsonb not null default '[]'          -- allotted Polling Station numbers as strings, e.g. ["1/1","1/2"]
);
create table if not exists settings (
  id int primary key default 1 check (id = 1),
  enabled boolean not null default false,
  lat double precision, lng double precision,
  radius int not null default 200
);
create table if not exists attendance (
  k text primary key,                           -- 'T<elect id>' for polling station staff, 'R<s.no>' for reserve
  kind text not null, group_no text, idno bigint, role text,
  status text not null,
  lat double precision, lng double precision,
  marked_by text, marked_at bigint not null     -- epoch milliseconds
);
create table if not exists assignments (
  group_no text not null, role text not null, rid int not null,
  assigned_by text, assigned_at bigint,
  primary key (group_no, role)
);
create table if not exists distribution (
  group_no text not null, stage int not null, by_user text, at_time bigint,
  primary key (group_no, stage)
);
create table if not exists datasets (nm text primary key, body jsonb not null);   -- 'team' and 'reserve' employee data
create table if not exists audit_log (
  id bigserial primary key, at timestamptz not null default now(),
  username text, action text, details jsonb
);
create index if not exists attendance_kind_group on attendance (kind, group_no);

insert into settings (id) values (1) on conflict do nothing;
insert into users (username, pwd, role) values ('admin', extensions.crypt('admin123', extensions.gen_salt('bf', 8)), 'admin') on conflict do nothing;

-- ---------- the API (one function; every call checks user name + password) ----------
create or replace function public.api(fn text, a jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  me      users%rowtype;
  v_res   jsonb := null;
  v_x     jsonb;
  v_set   settings%rowtype;
  v_d     double precision;
  v_g     text;
  v_r     text;
  v_id    int;
  v_n     int;
  v_k     text;
  v_now   bigint := (extract(epoch from clock_timestamp()) * 1000)::bigint;
  v_role  text;
begin
  select * into me from users where username = a->>'u';
  if fn = 'login' then
    if not found or me.pwd <> crypt(coalesce(a->>'p', ''), me.pwd) then return null; end if;
    return jsonb_build_object('role', me.role, 'groups', me.groups);
  end if;
  if not found or me.pwd <> crypt(coalesce(a->>'p', ''), me.pwd) then raise exception 'Invalid login'; end if;

  if fn = 'settings' then
    select to_jsonb(s) - 'id' into v_res from settings s where id = 1;

  elsif fn = 'all' then
    v_res := jsonb_build_object(
      'att', coalesce((select jsonb_agg(jsonb_build_object('k', t.k, 'kind', t.kind, 'group_no', t.group_no, 'idno', t.idno, 'role', t.role,
                'status', t.status, 'lat', t.lat, 'lng', t.lng, 'marked_by', t.marked_by, 'marked_at', t.marked_at))
              from attendance t
              where me.role <> 'ro' or t.group_no in (select jsonb_array_elements_text(me.groups))), '[]'::jsonb),
      'asg', coalesce((select jsonb_agg(jsonb_build_object('group_no', t.group_no, 'role', t.role, 'rid', t.rid, 'assigned_by', t.assigned_by, 'assigned_at', t.assigned_at))
              from assignments t
              where me.role <> 'ro' or t.group_no in (select jsonb_array_elements_text(me.groups))), '[]'::jsonb),
      'dist', coalesce((select jsonb_agg(jsonb_build_object('group_no', t.group_no, 'stage', t.stage, 'by', t.by_user, 'time', t.at_time))
              from distribution t
              where me.role <> 'ro' or t.group_no in (select jsonb_array_elements_text(me.groups))), '[]'::jsonb));

  elsif fn = 'saveSettings' then
    if me.role <> 'admin' then raise exception 'Not allowed for your role'; end if;
    update settings set
      enabled = coalesce((a #>> '{s,enabled}')::boolean, false),
      lat     = nullif(a #>> '{s,lat}', '')::double precision,
      lng     = nullif(a #>> '{s,lng}', '')::double precision,
      radius  = coalesce(nullif(a #>> '{s,radius}', '')::int, 200)
    where id = 1;

  elsif fn = 'mark' then
    if not (me.role = any (array['admin', 'user'])) then raise exception 'Not allowed for your role'; end if;
    v_x := a->'x';
    if coalesce(v_x->>'status', '') <> all (array['Attended', 'Leave', 'Health Issues', 'Duties Cancelled', 'Changed to Reserve']) then
      raise exception 'Invalid status';
    end if;
    select * into v_set from settings where id = 1;
    if v_set.enabled and v_set.lat is not null then
      if (v_x->>'lat') is null or (v_x->>'lng') is null then raise exception 'Location is required'; end if;
      v_d := 12742000 * asin(least(1, sqrt(
               power(sin(radians((v_x->>'lat')::double precision - v_set.lat) / 2), 2)
             + cos(radians(v_set.lat)) * cos(radians((v_x->>'lat')::double precision))
               * power(sin(radians((v_x->>'lng')::double precision - v_set.lng) / 2), 2))));
      if v_d > v_set.radius then
        raise exception 'Outside allowed area (% m away, limit % m)', round(v_d)::int, v_set.radius;
      end if;
    end if;
    insert into attendance (k, kind, group_no, idno, role, status, lat, lng, marked_by, marked_at)
    values (v_x->>'k', v_x->>'kind', nullif(v_x->>'group_no', ''), (v_x->>'idno')::bigint, v_x->>'role', v_x->>'status',
            (v_x->>'lat')::double precision, (v_x->>'lng')::double precision, me.username, v_now)
    on conflict (k) do update set kind = excluded.kind, group_no = excluded.group_no, idno = excluded.idno, role = excluded.role,
      status = excluded.status, lat = excluded.lat, lng = excluded.lng, marked_by = excluded.marked_by, marked_at = excluded.marked_at;

  elsif fn = 'unmark' then
    if not (me.role = any (array['admin', 'user'])) then raise exception 'Not allowed for your role'; end if;
    v_k := coalesce(a->>'k', '');
    if v_k = '' then raise exception 'Key required'; end if;
    if left(v_k, 1) = 'R' then
      if exists (select 1 from assignments t where t.rid = substring(v_k from 2)::int) then
        raise exception 'Cannot roll back: this reserve staff is currently assigned to a polling station. Remove assignment first.';
      end if;
    end if;
    delete from attendance where k = v_k;

  elsif fn = 'assign' then
    if not (me.role = any (array['admin', 'sec'])) then raise exception 'Not allowed for your role'; end if;
    perform pg_advisory_xact_lock(7001);
    v_g := a->>'g'; v_r := a->>'r'; v_id := (a->>'id')::int;
    if not exists (select 1 from attendance t where t.k = 'R' || v_id and t.status = 'Attended') then
      raise exception 'Reserve staff is not present - cannot be assigned';
    end if;
    if exists (select 1 from attendance t where t.kind = 'T' and t.group_no = v_g and t.role = v_r and t.status = 'Attended') then
      raise exception 'That polling station member is already present';
    end if;
    if exists (select 1 from assignments t where t.rid = v_id and not (t.group_no = v_g and t.role = v_r)) then
      raise exception 'Reserve staff is already assigned to another polling station';
    end if;
    insert into assignments (group_no, role, rid, assigned_by, assigned_at) values (v_g, v_r, v_id, me.username, v_now)
    on conflict (group_no, role) do update set rid = excluded.rid, assigned_by = excluded.assigned_by, assigned_at = excluded.assigned_at;

  elsif fn = 'unassign' then
    if not (me.role = any (array['admin', 'sec'])) then raise exception 'Not allowed for your role'; end if;
    delete from assignments where group_no = a->>'g' and role = a->>'r';

  elsif fn = 'distSet' then
    if not (me.role = any (array['admin', 'sec', 'dist', 'ro'])) then raise exception 'Not allowed for your role'; end if;
    v_g := a->>'g';
    if me.role = 'ro' and not exists (select 1 from jsonb_array_elements_text(me.groups) x where x = v_g) then
      raise exception 'You can only update disbursement status for your allotted polling stations';
    end if;
    for v_n in select jsonb_array_elements_text(a->'st')::int loop
      if coalesce((a->>'v')::boolean, false) then
        insert into distribution (group_no, stage, by_user, at_time) values (v_g, v_n, me.username, v_now) on conflict do nothing;
      else
        delete from distribution where group_no = v_g and stage = v_n;
      end if;
    end loop;

  elsif fn = 'clear' then
    raise exception 'Clearing the entire database is disabled';

  elsif fn = 'dataGet' then
    select body into v_res from datasets where nm = a->>'nm';

  elsif fn = 'dataSave' then
    if me.role <> 'admin' then raise exception 'Not allowed for your role'; end if;
    insert into datasets (nm, body) values (a->>'nm', a->'body') on conflict (nm) do update set body = excluded.body;

  elsif fn = 'users' then
    if me.role <> 'admin' then raise exception 'Not allowed for your role'; end if;
    select coalesce(jsonb_agg(jsonb_build_object('username', u.username, 'role', u.role, 'groups', u.groups) order by u.username), '[]'::jsonb)
      into v_res from users u;

  elsif fn = 'addU' then
    if me.role <> 'admin' then raise exception 'Not allowed for your role'; end if;
    if coalesce(a->>'n', '') = '' then raise exception 'User name required'; end if;
    v_role := case when (a->>'r') = any (array['admin', 'user', 'ro', 'sec', 'dist', 'display']) then a->>'r' else 'user' end;
    if coalesce(a->>'np', '') <> '' then
      insert into users (username, pwd, role, groups) values (a->>'n', crypt(a->>'np', gen_salt('bf', 8)), v_role, coalesce(a->'g', '[]'::jsonb))
      on conflict (username) do update set pwd = excluded.pwd, role = excluded.role, groups = excluded.groups;
    else
      if not exists (select 1 from users where username = a->>'n') then raise exception 'A new user needs a password'; end if;
      update users set role = v_role, groups = coalesce(a->'g', '[]'::jsonb) where username = a->>'n';
    end if;

  elsif fn = 'delU' then
    if me.role <> 'admin' then raise exception 'Not allowed for your role'; end if;
    if a->>'n' = me.username then raise exception 'Cannot delete yourself'; end if;
    delete from users where username = a->>'n';

  elsif fn = 'report' then
    if not (me.role = any (array['admin', 'sec'])) then raise exception 'Not allowed for your role'; end if;
    v_res := jsonb_build_object('ok', true);

  else
    raise exception 'Unknown request';
  end if;

  if fn = any (array['saveSettings', 'mark', 'unmark', 'assign', 'unassign', 'distSet', 'dataSave', 'addU', 'delU']) then
    insert into audit_log (username, action, details) values (me.username, fn, a - 'u' - 'p' - 'np' - 'body');
  end if;
  return v_res;
end;
$$;

-- ---------- readable live reports (Supabase > Table Editor > Views, or SQL Editor) ----------
create or replace view report_team as
select (g->>'g') as ps, m->>0 as role, m->>1 as elect_id, m->>2 as name, m->>3 as designation, m->>4 as office, m->>5 as mandal, m->>6 as mobile,
       coalesce(t.status, 'Absent (not reported)') as status,
       case when t.marked_at is null then null else to_char(to_timestamp(t.marked_at / 1000.0) at time zone 'Asia/Kolkata', 'DD-Mon-YYYY HH24:MI') end as reported_at,
       t.marked_by, t.lat, t.lng, rr.nm as reserve_name, rr.mob as reserve_mobile, s.assigned_by
from datasets d
cross join lateral jsonb_array_elements(d.body) as g
cross join lateral jsonb_array_elements(g->'m') with ordinality as mm(m, ord)
left join attendance t on t.k = 'T' || (m->>1)
left join assignments s on s.group_no = (g->>'g') and s.role = m->>0
left join lateral (select e->>3 as nm, e->>9 as mob from datasets rd cross join lateral jsonb_array_elements(rd.body) as e
                   where rd.nm = 'reserve' and (e->>0)::int = s.rid limit 1) rr on true
where d.nm = 'team'
order by nullif(split_part(g->>'g', '/', 1), '')::int nulls last, nullif(split_part(g->>'g', '/', 2), '')::int nulls last, mm.ord;

create or replace view report_summary as
select t.ps, count(*) as team_size,
       count(*) filter (where t.status = 'Attended') as present,
       count(*) filter (where t.status not in ('Attended', 'Absent (not reported)')) as reason,
       count(*) filter (where t.status = 'Absent (not reported)') as absent,
       count(*) filter (where t.assigned_by is not null) as reserve_assigned,
       count(*) filter (where t.status = 'Attended' or t.assigned_by is not null) as covered,
       case when count(*) = count(*) filter (where t.status = 'Attended' or t.assigned_by is not null) then 'YES' else 'NO' end as team_complete,
       (select count(*) from distribution x where x.group_no = t.ps) || '/3' as distribution_stages
from report_team t group by t.ps
order by nullif(split_part(t.ps, '/', 1), '')::int nulls last, nullif(split_part(t.ps, '/', 2), '')::int nulls last;

create or replace view report_reserve as
select (e->>0)::int as sno, e->>1 as eid, e->>2 as emp_id, e->>3 as name, e->>4 as designation, e->>5 as office, e->>6 as work_mandal,
       e->>7 as residence_mandal, e->>8 as post, e->>9 as mobile,
       coalesce(t.status, 'Absent (not reported)') as status,
       case when t.marked_at is null then null else to_char(to_timestamp(t.marked_at / 1000.0) at time zone 'Asia/Kolkata', 'DD-Mon-YYYY HH24:MI') end as reported_at,
       t.marked_by, s.group_no as assigned_ps, s.role as assigned_role
from datasets d
cross join lateral jsonb_array_elements(d.body) as e
left join attendance t on t.k = 'R' || (e->>0)
left join assignments s on s.rid = (e->>0)::int
where d.nm = 'reserve'
order by sno;

-- ---------- lock the tables: the browser may ONLY call api() ----------
alter table users enable row level security;
alter table settings enable row level security;
alter table attendance enable row level security;
alter table assignments enable row level security;
alter table distribution enable row level security;
alter table datasets enable row level security;
alter table audit_log enable row level security;

revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke all on function public.api(text, jsonb) from public;
grant execute on function public.api(text, jsonb) to anon, authenticated;
alter default privileges in schema public revoke all on tables from anon, authenticated;
