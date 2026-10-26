-- =========================================================
-- EyePro Super App — Migration v5: optometrist-only clinical data
-- Run in Supabase SQL Editor (after migration_v4).
--  * Eye examination data (exam_records and the older eye_exams table)
--    can only be READ by the optometrist. The secretary gets nothing back
--    from the database for these tables, not just a hidden tab.
--  * Secretary keeps full access to patients' personal details
--    (create / view / edit), but only the optometrist can DELETE a
--    patient, because deleting a patient also deletes their exam history.
-- =========================================================

drop policy if exists "exam_records_select_all" on public.exam_records;
create policy "exam_records_select_optometrist" on public.exam_records
  for select using (public.get_my_role() = 'optometrist');

drop policy if exists "eye_exams_select_all" on public.eye_exams;
create policy "eye_exams_select_optometrist" on public.eye_exams
  for select using (public.get_my_role() = 'optometrist');

drop policy if exists "patients_all_authenticated" on public.patients;
create policy "patients_select_authenticated" on public.patients
  for select using (auth.role() = 'authenticated');
create policy "patients_insert_authenticated" on public.patients
  for insert with check (auth.role() = 'authenticated');
create policy "patients_update_authenticated" on public.patients
  for update using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
create policy "patients_delete_optometrist" on public.patients
  for delete using (public.get_my_role() = 'optometrist');
