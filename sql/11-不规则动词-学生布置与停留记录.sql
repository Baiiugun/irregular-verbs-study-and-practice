-- 不规则动词专用表；沿用现有 Supabase Auth 和 public.is_teacher()。
-- 在 Supabase Studio 的 SQL Editor 新建查询，完整运行本文件。可重复运行。
-- 不保存学生答案、打字内容或按键，只保存姓名缩写、布置和访问时段。
-- 不修改其他系统的表、词库或学生记录。
begin;
set local lock_timeout = '5s';
do $$ begin
 if to_regprocedure('public.is_teacher()') is null then raise exception 'Existing public.is_teacher() is required'; end if;
end $$;
create table if not exists public.iv_students(
 id uuid primary key default gen_random_uuid(),
 name text not null unique check(name ~ '^[A-Z][A-Z0-9_-]{0,23}$'),
 created_at timestamptz not null default clock_timestamp()
);
create table if not exists public.iv_assignments(
 id uuid primary key default gen_random_uuid(),
 student_id uuid not null references public.iv_students(id) on delete cascade,
 assignment_date date not null,
 level text not null check(level in ('junior','senior')),
 start_number integer not null check(start_number>=1),
 end_number integer not null,
 note text not null default '' check(length(note)<=300),
 updated_at timestamptz not null default clock_timestamp(),
 unique(student_id,assignment_date,level),
 check(end_number>=start_number and end_number<=case when level='junior' then 98 else 128 end)
);
create table if not exists public.iv_visits(
 id uuid primary key,
 student_id uuid not null references public.iv_students(id) on delete cascade,
 write_token uuid not null,
 entered_at timestamptz not null default clock_timestamp(),
 last_seen_at timestamptz not null default clock_timestamp(),
 last_active_at timestamptz not null default clock_timestamp(),
 ended_at timestamptz,
 active_ms bigint not null default 0 check(active_ms>=0),
 reported_ms bigint not null default 0 check(reported_ms>=0),
 last_seq bigint not null default 0,
 is_visible boolean not null default true
);
create index if not exists iv_visits_student_time_idx on public.iv_visits(student_id,entered_at desc);
create index if not exists iv_visits_entered_idx on public.iv_visits(entered_at desc);
alter table public.iv_students enable row level security;
alter table public.iv_assignments enable row level security;
alter table public.iv_visits enable row level security;
revoke all on public.iv_students,public.iv_assignments,public.iv_visits from public,anon,authenticated;
grant select on public.iv_students,public.iv_assignments,public.iv_visits to authenticated;
drop policy if exists iv_teacher_read_students on public.iv_students;
create policy iv_teacher_read_students on public.iv_students for select to authenticated using(public.is_teacher());
drop policy if exists iv_teacher_read_assignments on public.iv_assignments;
create policy iv_teacher_read_assignments on public.iv_assignments for select to authenticated using(public.is_teacher());
drop policy if exists iv_teacher_read_visits on public.iv_visits;
create policy iv_teacher_read_visits on public.iv_visits for select to authenticated using(public.is_teacher());

create or replace function public.iv_require_teacher() returns void
language plpgsql security definer set search_path=public,pg_temp as $$
begin
 if auth.uid() is null or not coalesce(public.is_teacher(),false) then raise exception 'Teacher login required' using errcode='42501'; end if;
end $$;
revoke all on function public.iv_require_teacher() from public,anon;
grant execute on function public.iv_require_teacher() to authenticated;

create or replace function public.iv_begin_visit(p_name text,p_visit_id uuid,p_secret uuid,p_day date)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare n text:=upper(btrim(p_name)); s public.iv_students; v public.iv_visits;
begin
 if n is null or n !~ '^[A-Z][A-Z0-9_-]{0,23}$' or p_visit_id is null or p_secret is null or p_day is null then raise exception 'Invalid student name or visit'; end if;
 insert into public.iv_students(name) values(n) on conflict(name) do update set name=excluded.name returning * into s;
 select * into v from public.iv_visits where id=p_visit_id for update;
 if found then
  if v.student_id<>s.id or v.write_token<>p_secret then raise exception 'Invalid visit token' using errcode='42501'; end if;
 else
  insert into public.iv_visits(id,student_id,write_token) values(p_visit_id,s.id,p_secret) returning * into v;
 end if;
 return jsonb_build_object('student_id',s.id,'name',s.name,'visit_id',v.id,'entered_at',v.entered_at,'assignments',
  (select coalesce(jsonb_agg(jsonb_build_object('id',a.id,'date',a.assignment_date,'level',a.level,'start',a.start_number,'end',a.end_number,'note',a.note) order by a.assignment_date desc,a.level),'[]'::jsonb)
   from public.iv_assignments a where a.student_id=s.id and a.assignment_date between p_day-7 and p_day+7));
end $$;
revoke all on function public.iv_begin_visit(text,uuid,uuid,date) from public;
grant execute on function public.iv_begin_visit(text,uuid,uuid,date) to anon,authenticated;

create or replace function public.iv_get_assignments(p_visit_id uuid,p_secret uuid,p_day date)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare v public.iv_visits;
begin
 select * into v from public.iv_visits where id=p_visit_id and write_token=p_secret;
 if not found then raise exception 'Invalid visit token' using errcode='42501'; end if;
 return (select coalesce(jsonb_agg(jsonb_build_object('id',a.id,'date',a.assignment_date,'level',a.level,'start',a.start_number,'end',a.end_number,'note',a.note) order by a.assignment_date desc,a.level),'[]'::jsonb)
  from public.iv_assignments a where a.student_id=v.student_id and a.assignment_date between p_day-7 and p_day+7);
end $$;
revoke all on function public.iv_get_assignments(uuid,uuid,date) from public;
grant execute on function public.iv_get_assignments(uuid,uuid,date) to anon,authenticated;

create or replace function public.iv_ping_visit(p_visit_id uuid,p_secret uuid,p_seq bigint,p_total_ms bigint,p_visible boolean,p_finished boolean default false)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare v public.iv_visits; t timestamptz:=clock_timestamp(); delta bigint; cap_ms bigint;
begin
 if p_seq is null or p_seq<1 or p_total_ms is null or p_total_ms<0 or p_total_ms>604800000 or p_visible is null then raise exception 'Invalid visit heartbeat'; end if;
 select * into v from public.iv_visits where id=p_visit_id and write_token=p_secret for update;
 if not found then raise exception 'Invalid visit token' using errcode='42501'; end if;
 if p_seq<=v.last_seq then return jsonb_build_object('active_ms',v.active_ms,'accepted',false); end if;
 if p_total_ms<v.reported_ms then raise exception 'Visit time cannot decrease'; end if;
 cap_ms:=greatest(0,floor(extract(epoch from(t-v.last_seen_at))*1000)::bigint)+2000;
 delta:=least(p_total_ms-v.reported_ms,cap_ms);
 update public.iv_visits set active_ms=active_ms+delta,reported_ms=p_total_ms,last_seq=p_seq,last_seen_at=t,
  last_active_at=case when p_visible or delta>0 then t else last_active_at end,is_visible=p_visible,
  ended_at=case when p_finished then t when p_visible then null else ended_at end
 where id=p_visit_id returning * into v;
 return jsonb_build_object('active_ms',v.active_ms,'accepted',true);
end $$;
revoke all on function public.iv_ping_visit(uuid,uuid,bigint,bigint,boolean,boolean) from public;
grant execute on function public.iv_ping_visit(uuid,uuid,bigint,bigint,boolean,boolean) to anon,authenticated;

create or replace function public.iv_teacher_add_student(p_name text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare n text:=upper(btrim(p_name)); s public.iv_students;
begin
 perform public.iv_require_teacher();
 if n is null or n !~ '^[A-Z][A-Z0-9_-]{0,23}$' then raise exception 'Invalid student abbreviation'; end if;
 insert into public.iv_students(name) values(n) on conflict(name) do update set name=excluded.name returning * into s;
 return jsonb_build_object('id',s.id,'name',s.name);
end $$;
revoke all on function public.iv_teacher_add_student(text) from public,anon;
grant execute on function public.iv_teacher_add_student(text) to authenticated;

create or replace function public.iv_teacher_assign(p_name text,p_date date,p_level text,p_start integer,p_end integer,p_note text default '')
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare s jsonb; a public.iv_assignments;
begin
 perform public.iv_require_teacher();
 if p_date is null or p_level is null or p_level not in ('junior','senior') or p_start is null or p_end is null or p_start<1 or p_end<p_start or p_end>(case when p_level='junior' then 98 else 128 end) or length(coalesce(p_note,''))>300 then raise exception 'Invalid assignment range'; end if;
 s:=public.iv_teacher_add_student(p_name);
 insert into public.iv_assignments(student_id,assignment_date,level,start_number,end_number,note)
 values((s->>'id')::uuid,p_date,p_level,p_start,p_end,coalesce(p_note,''))
 on conflict(student_id,assignment_date,level) do update set start_number=excluded.start_number,end_number=excluded.end_number,note=excluded.note,updated_at=clock_timestamp()
 returning * into a;
 return jsonb_build_object('id',a.id,'name',s->>'name','date',a.assignment_date,'level',a.level,'start',a.start_number,'end',a.end_number);
end $$;
revoke all on function public.iv_teacher_assign(text,date,text,integer,integer,text) from public,anon;
grant execute on function public.iv_teacher_assign(text,date,text,integer,integer,text) to authenticated;

create or replace function public.iv_teacher_unassign(p_assignment uuid)
returns boolean language plpgsql security definer set search_path=public,pg_temp as $$
begin perform public.iv_require_teacher();delete from public.iv_assignments where id=p_assignment;return found;end $$;
revoke all on function public.iv_teacher_unassign(uuid) from public,anon;
grant execute on function public.iv_teacher_unassign(uuid) to authenticated;

create or replace function public.iv_teacher_overview(p_from date,p_to date,p_timezone text default 'UTC')
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare t timestamptz:=clock_timestamp(); tz text:=coalesce(p_timezone,'UTC');
begin
 perform public.iv_require_teacher();
 if p_from is null or p_to is null or p_to<p_from or p_to-p_from>366 then raise exception 'Invalid date range'; end if;
 if not exists(select 1 from pg_timezone_names where name=tz) then raise exception 'Invalid timezone'; end if;
 return jsonb_build_object('server_time',t,
 'students',(select coalesce(jsonb_agg(jsonb_build_object('id',s.id,'name',s.name,'created_at',s.created_at) order by s.name),'[]'::jsonb) from public.iv_students s),
 'assignments',(select coalesce(jsonb_agg(jsonb_build_object('id',a.id,'student_id',a.student_id,'date',a.assignment_date,'level',a.level,'start',a.start_number,'end',a.end_number,'note',a.note) order by a.assignment_date desc),'[]'::jsonb) from public.iv_assignments a where a.assignment_date between p_from and p_to),
 'visits',(select coalesce(jsonb_agg(jsonb_build_object('id',v.id,'student_id',v.student_id,'entered_at',v.entered_at,'last_active_at',v.last_active_at,'last_seen_at',v.last_seen_at,'ended_at',v.ended_at,'active_ms',v.active_ms,'online',v.is_visible and v.ended_at is null and v.last_seen_at>t-interval '50 seconds') order by v.entered_at desc),'[]'::jsonb)
   from(select * from public.iv_visits where entered_at>=(p_from::timestamp at time zone tz) and entered_at<((p_to+1)::timestamp at time zone tz) order by entered_at desc limit 5000)v));
end $$;
revoke all on function public.iv_teacher_overview(date,date,text) from public,anon;
grant execute on function public.iv_teacher_overview(date,date,text) to authenticated;

create or replace function public.iv_teacher_delete_student(p_student uuid,p_confirm_name text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare s public.iv_students; n_visits integer; n_assignments integer;
begin
 perform public.iv_require_teacher();
 select * into s from public.iv_students where id=p_student for update;
 if not found then raise exception 'Student not found'; end if;
 if upper(btrim(coalesce(p_confirm_name,'')))<>s.name then raise exception 'Confirmation must match the complete student abbreviation'; end if;
 select count(*) into n_visits from public.iv_visits where student_id=s.id;
 select count(*) into n_assignments from public.iv_assignments where student_id=s.id;
 delete from public.iv_students where id=s.id;
 return jsonb_build_object('deleted',true,'visits',n_visits,'assignments',n_assignments);
end $$;
revoke all on function public.iv_teacher_delete_student(uuid,text) from public,anon;
grant execute on function public.iv_teacher_delete_student(uuid,text) to authenticated;
notify pgrst,'reload schema';
commit;
select 'iv database setup complete' as status;
