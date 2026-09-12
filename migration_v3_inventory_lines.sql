-- =========================================================
-- EyePro Super App — Migration v3: Inventory-linked invoice lines
-- Run this AFTER migration_v2_invoicing.sql (in Supabase SQL Editor).
-- Adds back the ability to select a line item straight from Inventory
-- (frames / contact lenses / accessories) inside a Quotation/Order,
-- alongside "Eye Examination" and "Enter Description".
-- =========================================================

alter table public.invoice_items add column if not exists inventory_id bigint references public.inventory_items(id);
alter table public.invoice_items add column if not exists quantity int not null default 1;

alter table public.invoice_items drop constraint if exists invoice_items_item_type_check;
alter table public.invoice_items add constraint invoice_items_item_type_check check (item_type in ('exam','inventory','custom'));

-- Note: public.adjust_inventory_stock(p_id, p_qty) already exists from the
-- original schema.sql and is unchanged — the app calls it once, when a
-- brand-new Order (not a Quotation, and not a later edit) is created with
-- inventory-linked lines, to deduct stock.
