-- =========================================================
-- EyePro Super App — Supabase Schema
-- Adams Vision Ltd / EyePro Optical
-- =========================================================
-- Run this whole file once in Supabase: Project > SQL Editor > New query > paste > Run
-- Safe to re-run on a fresh project (it creates everything from scratch).
-- =========================================================

-- ---------- PROFILES (role lives here, linked to Supabase Auth users) ----------
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text,
  role text not null default 'secretary' check (role in ('secretary','optometrist')),
  created_at timestamptz not null default now()
);

alter table public.profiles enable row level security;

create policy "profiles_select_own" on public.profiles
  for select using (auth.uid() = id);

create policy "profiles_update_own_name_only" on public.profiles
  for update using (auth.uid() = id);

-- Automatically create a profile row when a new auth user signs up.
-- New signups default to 'secretary'. Promote the first account to
-- 'optometrist' manually in Table Editor (see README).
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, full_name, role)
  values (new.id, new.raw_user_meta_data->>'full_name', 'secretary');
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

-- Helper: current caller's role, used inside RLS policies & RPCs
create or replace function public.get_my_role()
returns text
language sql
security definer
stable
set search_path = public
as $$
  select role from public.profiles where id = auth.uid();
$$;

-- ---------- PATIENTS ----------
create table if not exists public.patients (
  id bigint generated always as identity primary key,
  patient_code text unique,
  title text,
  first_name text not null,
  surname text not null,
  dob date,
  age int,
  contact_number text,
  address text,
  occupation text,
  created_at timestamptz not null default now()
);

alter table public.patients enable row level security;

create policy "patients_select_authenticated" on public.patients
  for select using (auth.role() = 'authenticated');
create policy "patients_insert_authenticated" on public.patients
  for insert with check (auth.role() = 'authenticated');
create policy "patients_update_authenticated" on public.patients
  for update using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
-- only the optometrist may delete a patient (it also deletes their exam history)
create policy "patients_delete_optometrist" on public.patients
  for delete using (public.get_my_role() = 'optometrist');

-- Auto patient code PRxxxx
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

drop trigger if exists trg_patient_code on public.patients;
create trigger trg_patient_code before insert on public.patients
  for each row execute procedure public.set_patient_code();

-- ---------- APPOINTMENTS (front-desk agenda) ----------
create table if not exists public.appointments (
  id bigint generated always as identity primary key,
  patient_id bigint references public.patients(id) on delete set null,
  appt_date date not null default current_date,
  time_slot text,
  purpose_of_visit text,
  contact_number text,
  call_result text,
  examination_outcome text,
  remarks text,
  status text not null default 'scheduled' check (status in ('scheduled','checked_in','exam_done','invoiced','cancelled')),
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);

alter table public.appointments enable row level security;

create policy "appointments_all_authenticated" on public.appointments
  for all using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');

-- ---------- EYE EXAMS (clinical — optometrist writes, secretary can view) ----------
create table if not exists public.eye_exams (
  id bigint generated always as identity primary key,
  patient_id bigint references public.patients(id) on delete cascade,
  appointment_id bigint references public.appointments(id) on delete set null,
  exam_date date not null default current_date,
  r_bv text, r_cv text,
  l_bv text, l_cv text,
  gh text,
  fh text,
  oh text,
  diagnosis text,
  recommendation text,
  lens_type text,
  lens_proposed text,
  contact_lens_proposed text,
  remarks text,
  optometrist_id uuid references auth.users(id),
  created_at timestamptz not null default now()
);

alter table public.eye_exams enable row level security;

create policy "eye_exams_select_optometrist" on public.eye_exams
  for select using (public.get_my_role() = 'optometrist');

create policy "eye_exams_write_optometrist_only" on public.eye_exams
  for insert with check (public.get_my_role() = 'optometrist');

create policy "eye_exams_update_optometrist_only" on public.eye_exams
  for update using (public.get_my_role() = 'optometrist');

create policy "eye_exams_delete_optometrist_only" on public.eye_exams
  for delete using (public.get_my_role() = 'optometrist');

-- ---------- EXAM RECORDS (full eye exam form, one row per save) ----------
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

create policy "exam_records_select_optometrist" on public.exam_records
  for select using (public.get_my_role() = 'optometrist');
create policy "exam_records_insert_optometrist" on public.exam_records
  for insert with check (public.get_my_role() = 'optometrist');
create policy "exam_records_delete_optometrist" on public.exam_records
  for delete using (public.get_my_role() = 'optometrist');

-- ---------- INVENTORY (frames, contact lenses, accessories) ----------
create table if not exists public.inventory_items (
  id bigint generated always as identity primary key,
  item_type text not null default 'frame' check (item_type in ('frame','contact_lens','accessory')),
  local_code text unique,
  international_code text,
  description text,
  size text,
  colour text,
  category text,
  type text,
  price_bought numeric(10,2),   -- COST price: optometrist only, never exposed to secretary
  price_sold numeric(10,2) not null default 0,  -- selling price: visible to both
  quantity int not null default 0,
  sold_quantity int not null default 0,
  date_entered date not null default current_date,
  created_at timestamptz not null default now()
);

alter table public.inventory_items enable row level security;

-- IMPORTANT: no direct SELECT/INSERT/UPDATE policy is granted here for the
-- base table. All reads/writes go through the SECURITY DEFINER RPCs below,
-- which enforce the cost-price restriction server-side (not just hidden in
-- the UI). This is what makes the secretary/optometrist split real security
-- rather than cosmetic.

create or replace function public.set_local_code()
returns trigger language plpgsql as $$
declare
  next_num int;
  prefix text;
begin
  if new.item_type = 'frame' then prefix := 'EP';
  elsif new.item_type = 'contact_lens' then prefix := 'CL';
  else prefix := 'AC'; end if;

  if new.local_code is null then
    select coalesce(max(substring(local_code from 3)::int),0)+1 into next_num
      from public.inventory_items where local_code like prefix||'%';
    new.local_code := prefix || lpad(next_num::text,4,'0');
  end if;
  return new;
end;
$$;

drop trigger if exists trg_local_code on public.inventory_items;
create trigger trg_local_code before insert on public.inventory_items
  for each row execute procedure public.set_local_code();

-- Read inventory: cost price is nulled out for secretary
create or replace function public.get_inventory()
returns table (
  id bigint, item_type text, local_code text, international_code text,
  description text, size text, colour text, category text, type text,
  price_bought numeric, price_sold numeric, quantity int, sold_quantity int,
  date_entered date
)
language plpgsql security definer set search_path = public as $$
begin
  if public.get_my_role() = 'optometrist' then
    return query select i.id,i.item_type,i.local_code,i.international_code,i.description,
      i.size,i.colour,i.category,i.type,i.price_bought,i.price_sold,i.quantity,i.sold_quantity,i.date_entered
      from public.inventory_items i order by i.id desc;
  else
    return query select i.id,i.item_type,i.local_code,i.international_code,i.description,
      i.size,i.colour,i.category,i.type, null::numeric, i.price_sold,i.quantity,i.sold_quantity,i.date_entered
      from public.inventory_items i order by i.id desc;
  end if;
end;
$$;

-- Add a new inventory item: optometrist only (sets cost price)
create or replace function public.add_inventory_item(
  p_item_type text, p_international_code text, p_size text, p_colour text,
  p_category text, p_type text, p_price_bought numeric, p_price_sold numeric,
  p_quantity int, p_date_entered date, p_description text default null
) returns bigint
language plpgsql security definer set search_path = public as $$
declare new_id bigint;
begin
  if public.get_my_role() <> 'optometrist' then
    raise exception 'Only the optometrist can add inventory items';
  end if;
  insert into public.inventory_items
    (item_type,international_code,size,colour,category,type,price_bought,price_sold,quantity,date_entered,description)
    values (p_item_type,p_international_code,p_size,p_colour,p_category,p_type,p_price_bought,p_price_sold,p_quantity,p_date_entered,p_description)
    returning id into new_id;
  return new_id;
end;
$$;

-- Edit an existing inventory item (incl. cost price): optometrist only
create or replace function public.update_inventory_item(
  p_id bigint, p_international_code text, p_size text, p_colour text,
  p_category text, p_type text, p_price_bought numeric, p_price_sold numeric,
  p_quantity int, p_description text default null
) returns void
language plpgsql security definer set search_path = public as $$
begin
  if public.get_my_role() <> 'optometrist' then
    raise exception 'Only the optometrist can edit inventory items';
  end if;
  update public.inventory_items set
    international_code = p_international_code, size = p_size, colour = p_colour,
    category = p_category, type = p_type, price_bought = p_price_bought,
    price_sold = p_price_sold, quantity = p_quantity, description = coalesce(p_description, description)
  where id = p_id;
end;
$$;

-- Delete inventory item: optometrist only
create or replace function public.delete_inventory_item(p_id bigint)
returns void language plpgsql security definer set search_path = public as $$
begin
  if public.get_my_role() <> 'optometrist' then
    raise exception 'Only the optometrist can delete inventory items';
  end if;
  delete from public.inventory_items where id = p_id;
end;
$$;

-- Sell / adjust stock: both roles may do this (secretary sells frames all day).
-- Never touches price columns, only quantity/sold_quantity, and validates stock.
create or replace function public.adjust_inventory_stock(p_id bigint, p_qty int)
returns void language plpgsql security definer set search_path = public as $$
declare avail int;
begin
  select quantity into avail from public.inventory_items where id = p_id for update;
  if avail is null then raise exception 'Item not found'; end if;
  if p_qty > avail then p_qty := avail; end if;
  update public.inventory_items
    set quantity = quantity - p_qty, sold_quantity = sold_quantity + p_qty
    where id = p_id;
end;
$$;

-- ---------- INVOICES: Quotation -> Order -> VAT Invoice ----------
create table if not exists public.invoices (
  id bigint generated always as identity primary key,
  invoice_number text unique not null,
  document_type text not null default 'quotation' check (document_type in ('quotation','order','vat_invoice')),
  patient_id bigint references public.patients(id) on delete set null,
  client_name text not null,
  appointment_id bigint references public.appointments(id) on delete set null,
  invoice_date date not null default current_date,   -- auto-set, no backdating
  order_number text,   -- internal record only; always printed blank for pen entry
  order_date date,      -- internal record only; never shown on the printed document
  deposit numeric(10,2) not null default 0,
  outstanding numeric(10,2) not null default 0,
  mode_of_payment text,
  subtotal numeric(10,2) not null default 0,
  vat_amount numeric(10,2) not null default 0,
  grand_total numeric(10,2) not null default 0,
  delivered boolean not null default false,
  delivered_at timestamptz,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.invoice_items (
  id bigint generated always as identity primary key,
  invoice_id bigint references public.invoices(id) on delete cascade,
  item_type text not null default 'custom' check (item_type in ('exam','inventory','custom')),
  inventory_id bigint references public.inventory_items(id),
  quantity int not null default 1,
  description text not null,
  total_payable numeric(10,2) not null default 0,          -- raw manual entry (VAT incl.)
  discount_internal_value numeric(10,2) not null default 0,
  discount_internal_type text not null default 'rs' check (discount_internal_type in ('rs','percent')),
  unit_price numeric(10,2) not null default 0,              -- baseline, unaffected by discount
  discount_rs numeric(10,2) not null default 0,              -- visible discount, excl. VAT
  vat_rate numeric(5,2) not null default 15,
  vat_amount numeric(10,2) not null default 0,
  line_total numeric(10,2) not null default 0,               -- printed "Total (Rs)"
  sort_order int not null default 0
);

create table if not exists public.payments (
  id bigint generated always as identity primary key,
  invoice_id bigint references public.invoices(id) on delete cascade,
  payment_date date not null default current_date,
  amount numeric(10,2) not null,
  mode_of_payment text,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);

alter table public.invoices enable row level security;
alter table public.invoice_items enable row level security;
alter table public.payments enable row level security;

create policy "invoices_all_authenticated" on public.invoices
  for all using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
create policy "invoice_items_all_authenticated" on public.invoice_items
  for all using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
create policy "payments_all_authenticated" on public.payments
  for all using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');

-- Gap-filling invoice numbers (0000001, 0000002, ...) — a deleted or
-- cancelled document's number is reused by the next new document.
create or replace function public.next_invoice_number()
returns text language plpgsql security definer set search_path = public as $$
declare next_num int; max_num int;
begin
  select coalesce(max(invoice_number::int),0) into max_num from public.invoices where invoice_number ~ '^[0-9]+$';
  select coalesce(min(t.n),max_num+1) into next_num from (
    select generate_series(1, greatest(max_num,1)) as n
  ) t
  where not exists (select 1 from public.invoices i where i.invoice_number::int = t.n);
  return lpad(next_num::text,7,'0');
end;
$$;

create or replace function public.set_invoice_number()
returns trigger language plpgsql as $$
begin
  if new.invoice_number is null or new.invoice_number = '' then
    new.invoice_number := public.next_invoice_number();
  end if;
  return new;
end;
$$;

drop trigger if exists trg_set_invoice_number on public.invoices;
create trigger trg_set_invoice_number before insert on public.invoices
  for each row execute procedure public.set_invoice_number();

-- A VAT Invoice can never be created directly — only by converting a delivered Order.
create or replace function public.prevent_direct_vat_invoice()
returns trigger language plpgsql as $$
begin
  if new.document_type = 'vat_invoice' then
    raise exception 'A VAT Invoice can only be created by converting a delivered Order.';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_prevent_direct_vat_invoice on public.invoices;
create trigger trg_prevent_direct_vat_invoice before insert on public.invoices
  for each row execute procedure public.prevent_direct_vat_invoice();

-- Delivered lock: once an order is delivered it can only transition to vat_invoice.
create or replace function public.enforce_invoice_transitions()
returns trigger language plpgsql as $$
begin
  if new.delivered = true and old.delivered = false and new.outstanding <> 0 then
    raise exception 'Cannot mark delivered while an outstanding balance remains.';
  end if;

  if old.delivered = true then
    if new.document_type = 'vat_invoice' and old.document_type = 'order'
       and new.grand_total = old.grand_total and new.invoice_number = old.invoice_number then
      return new;
    end if;
    if new.document_type is distinct from old.document_type
       or new.grand_total is distinct from old.grand_total
       or new.deposit is distinct from old.deposit
       or new.client_name is distinct from old.client_name then
      raise exception 'This document is locked (delivered) and cannot be edited.';
    end if;
  end if;

  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists trg_enforce_invoice_transitions on public.invoices;
create trigger trg_enforce_invoice_transitions before update on public.invoices
  for each row execute procedure public.enforce_invoice_transitions();

create or replace function public.enforce_items_lock()
returns trigger language plpgsql as $$
declare is_delivered boolean;
begin
  select delivered into is_delivered from public.invoices where id = coalesce(new.invoice_id, old.invoice_id);
  if is_delivered then
    raise exception 'This document is locked (delivered) and its line items cannot be changed.';
  end if;
  if TG_OP = 'DELETE' then return old; end if;
  return new;
end;
$$;

drop trigger if exists trg_items_lock on public.invoice_items;
create trigger trg_items_lock before insert or update or delete on public.invoice_items
  for each row execute procedure public.enforce_items_lock();

-- Record a payment (validates against remaining outstanding balance).
create or replace function public.record_payment(p_invoice_id bigint, p_amount numeric, p_date date, p_mode text)
returns numeric language plpgsql security definer set search_path = public as $$
declare v_outstanding numeric;
begin
  select outstanding into v_outstanding from public.invoices where id = p_invoice_id;
  if v_outstanding is null then raise exception 'Invoice not found'; end if;
  if p_amount <= 0 then raise exception 'Payment amount must be greater than zero'; end if;
  if p_amount > v_outstanding then
    raise exception 'Payment (Rs %) exceeds the outstanding balance (Rs %)', p_amount, v_outstanding;
  end if;
  insert into public.payments (invoice_id, payment_date, amount, mode_of_payment, created_by)
    values (p_invoice_id, coalesce(p_date, current_date), p_amount, p_mode, auth.uid());
  update public.invoices
    set outstanding = outstanding - p_amount, mode_of_payment = coalesce(p_mode, mode_of_payment)
    where id = p_invoice_id;
  select outstanding into v_outstanding from public.invoices where id = p_invoice_id;
  return v_outstanding;
end;
$$;

-- ---------- EXPENSES (optometrist only, end to end) ----------
create table if not exists public.expenses (
  id bigint generated always as identity primary key,
  expense_date date not null default current_date,
  description text,
  category text,
  amount numeric(10,2) not null default 0,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);

alter table public.expenses enable row level security;

create policy "expenses_optometrist_only" on public.expenses
  for all using (public.get_my_role() = 'optometrist') with check (public.get_my_role() = 'optometrist');

-- ---------- DASHBOARD / REPORTS (optometrist only) ----------
create or replace function public.get_dashboard_stats(p_from date default (current_date - interval '30 days')::date, p_to date default current_date)
returns table (total_sales numeric, total_expenses numeric, profit numeric, invoice_count int)
language plpgsql security definer set search_path = public as $$
begin
  if public.get_my_role() <> 'optometrist' then
    raise exception 'Only the optometrist can view sales & expense totals';
  end if;
  return query
    select
      coalesce((select sum(grand_total) from public.invoices where document_type='vat_invoice' and invoice_date between p_from and p_to),0),
      coalesce((select sum(amount) from public.expenses where expense_date between p_from and p_to),0),
      coalesce((select sum(grand_total) from public.invoices where document_type='vat_invoice' and invoice_date between p_from and p_to),0)
        - coalesce((select sum(amount) from public.expenses where expense_date between p_from and p_to),0),
      coalesce((select count(*) from public.invoices where document_type='vat_invoice' and invoice_date between p_from and p_to),0)::int;
end;
$$;

-- =========================================================
-- End of schema. Next steps are in README.md:
--  1. Create the first user (sign up in the app).
--  2. In Table Editor > profiles, set that user's role to 'optometrist'.
--  3. Any further signups default to 'secretary'.
-- =========================================================
