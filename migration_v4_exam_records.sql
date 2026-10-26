-- =========================================================
-- EyePro Super App — Migration v4: Eye exam records + patient numbers
-- Run in Supabase SQL Editor (after the earlier migrations).
--  1. New patient numbers: EP-PN-<001-999><2-letter month><2-digit year>
--     e.g. EP-PN-001JA26 (JA FE MR AP MY JN JL AU SE OC NO DE).
--     The number is the smallest unused one for that month/year.
--     Existing patients keep their current numbers.
--  2. exam_records: every save is a new, dated record per patient.
--     Records cannot be updated (editing saves a new record); only the
--     optometrist can add or delete them.
-- =========================================================

create or replace function public.set_patient_code()
returns trigger language plpgsql as $$
declare
  mcodes text[] := array['JA','FE','MR','AP','MY','JN','JL','AU','SE','OC','NO','DE'];
  suffix text;
  next_num int;
begin
  if new.patient_code is null then
    suffix := mcodes[extract(month from current_date)::int] || to_char(current_date,'YY');
    select g into next_num from generate_series(1,999) g
      where not exists (select 1 from public.patients where patient_code = 'EP-PN-' || lpad(g::text,3,'0') || suffix)
      order by g limit 1;
    if next_num is null then raise exception 'No patient numbers left for this month'; end if;
    new.patient_code := 'EP-PN-' || lpad(next_num::text,3,'0') || suffix;
  end if;
  return new;
end;
$$;

create table if not exists public.exam_records (
  id bigint generated always as identity primary key,
  patient_id bigint not null references public.patients(id) on delete cascade,
  appointment_id bigint references public.appointments(id) on delete set null,
  recorded_at timestamptz not null default now(),
  data jsonb not null default '{}'::jsonb,
  optometrist_id uuid references auth.users(id)
);

create index if not exists exam_records_patient_idx on public.exam_records (patient_id, recorded_at desc);

alter table public.exam_records enable row level security;

create policy "exam_records_select_all" on public.exam_records
  for select using (auth.role() = 'authenticated');
create policy "exam_records_insert_optometrist" on public.exam_records
  for insert with check (public.get_my_role() = 'optometrist');
create policy "exam_records_delete_optometrist" on public.exam_records
  for delete using (public.get_my_role() = 'optometrist');
