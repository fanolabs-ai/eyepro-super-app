# EyePro Super App

A single-page practice management app for **Adams Vision Ltd / EyePro Optical**, covering the full patient journey:

**Appointment → Check-in → Eye Examination → Invoicing**, plus **Inventory** (frames, contact lenses, accessories) and **Reports**.

Two roles, enforced in the database (not just hidden in the UI):

| | Secretary | Optometrist |
|---|---|---|
| Appointments, Patients | Full access | Full access |
| Eye Exam | View only | View + edit |
| Inventory | View selling price & stock, sell items via invoicing | Full access incl. cost price, add/edit/delete items |
| Invoicing | Full access | Full access |
| Reports (Total Sales / Total Expenses / Profit) | No access | Full access |
| Expenses | No access | Full access |

The **cost price of frames is never sent to the secretary's browser at all** — it's enforced by a Postgres function (`get_inventory()`), not just hidden with CSS. Even opening dev tools won't reveal it.

## Updating an existing project

Run these once, in order, in Supabase's SQL Editor (skip ones you've already run):

1. `schema.sql` — only for a brand-new project. If you already have one running, don't re-run this.
2. `migration_v2_invoicing.sql` — the Quotation/Order/VAT Invoice engine. Skip if already applied.
3. `migration_v3_inventory_lines.sql` — adds inventory-linked line items back into the invoice builder (see below). Safe to run even if you're not sure — it only adds columns/loosens a constraint, it won't touch existing data.

4. `migration_v4_exam_records.sql` — the full Eye Exam form storage (`exam_records`) and the new patient-number format. Run it before using the Eye Exams tab.

Then replace `index.html` with the version in this folder and redeploy (push to GitHub — Vercel picks it up automatically).

## 1. Create the Supabase project

1. Go to https://supabase.com, create a free project (pick a region close to Mauritius, e.g. Frankfurt or Mumbai).
2. In **Project Settings → API**, copy the **Project URL** and the **anon public key**.
3. Go to **SQL Editor → New query**, paste the entire contents of `schema.sql` from this folder, and click **Run**. This creates all tables, security policies, and functions in one go.

## 2. Configure the app

Open `index.html` and edit these two lines near the top of the `<script>` block:

```js
const SUPABASE_URL = 'YOUR_SUPABASE_URL';
const SUPABASE_ANON_KEY = 'YOUR_SUPABASE_ANON_KEY';
```

Paste in the values from step 1. The anon key is meant to be public in client-side code — real protection comes from the database policies in `schema.sql`, not from hiding this key.

By default, Supabase requires email confirmation for new sign-ups. For an internal team tool, you may want to turn this off: **Authentication → Providers → Email → uncheck "Confirm email"**.

## 3. Create your first user (the optometrist)

1. Open the app, go to the **New Account** tab, and sign up with your own email/password.
2. In Supabase, go to **Table Editor → profiles**, find your row, and change `role` from `secretary` to `optometrist`.
3. Log out and back in — you'll now see Reports and full inventory access.
4. Have the secretary sign up their own account afterwards; new sign-ups default to `secretary` automatically.

There's no separate "manage users" screen in the app on purpose — role changes are a rare, deliberate action, so they're done directly in Supabase's Table Editor rather than exposed as a feature that could be misused.

## 4. Put it on GitHub

```bash
cd eyepro-super-app
git init
git add .
git commit -m "EyePro Super App"
git branch -M main
git remote add origin https://github.com/fanolabs-ai/eyepro-super-app.git
git push -u origin main
```

(Create the empty repo on GitHub first, or use `gh repo create fanolabs-ai/eyepro-super-app --private --source=. --push`.)

## 5. Deploy to Vercel

1. Go to https://vercel.com, **Add New → Project**, import the GitHub repo you just pushed.
2. Framework preset: **Other** (it's a static site — no build step needed).
3. Deploy. Vercel will serve `index.html` directly.
4. Every future `git push` to `main` auto-redeploys.

## How the workflow ties together

1. **Appointments** — secretary books a patient in, or picks an existing one. Status starts as `scheduled`.
2. **Check In** — when the patient arrives, click *Check In* (status → `checked_in`).
3. **Start Exam** — appears once checked in; opens the Eye Exam form for the optometrist to fill in (R/L refraction, GH/FH/OH, diagnosis, recommendation, lens proposals). Saving sets status → `exam_done`.
4. **Invoice** — appears once the exam is done. Opens the invoice builder pre-filled with the patient, with **Eye Examination — Rs 700 (0% VAT)** included by default (untick if not needed). The secretary adds frames/contact lenses/accessories from Inventory (selling price only), quantities, and 15% VAT is applied to goods automatically. Choose **Quotation**, **Order**, or **Invoice**:
   - Quotation/Order: no stock is deducted (nothing has been sold yet).
   - Invoice: stock is deducted automatically and the appointment is marked `invoiced`.
5. **Print** — any saved document can be printed/PDF'd from the Invoicing list, with the EyePro logo and Adams Vision Ltd details on the header.

## Invoicing: Quotation → Order → VAT Invoice

- **Add Quotation** and **Add Order** are two separate, differently-coloured buttons — a VAT Invoice can never be created directly.
- Every document (quotation or order) gets a 7-digit invoice number the moment it's created (`0000001`, `0000002`, ...). Deleting a document frees its number for the next one created.
- Each line item is one of three kinds:
  - **Eye Examination** — fixed Rs 700, 0% VAT, not editable.
  - **Select from Inventory** — type a few letters of a product's code or name into the search box and pick it from the results; its selling price fills in automatically, multiplied by quantity. Pulls from the same Inventory used elsewhere in the app.
  - **Enter Description** — free text, with a manually typed VAT-inclusive Total Payable.
  For the last two, an optional Internal Discount (Rs or %) is available — Unit Price, Discount, VAT Amount and Total all compute live using your exact formulas.
- **Billing Client** and **product search** are both type-ahead fields (not long dropdowns) — start typing a patient's name/code/phone or a product's code/name and pick from the matches. This scales fine with hundreds of patients or inventory items.
- Stock is deducted automatically the moment a new **Order** (not a Quotation) is created with inventory-linked lines. Editing an order afterwards does not re-adjust stock — a known simplification, flagged here in case you add/change items on an existing order and need to double check stock by hand.
- **Convert to Order** keeps the same invoice number.
- Once an order's outstanding balance reaches zero, **Mark Delivered** appears — this locks the document (no further edits). Once delivered, **Convert to VAT Invoice** appears. A VAT Invoice is the final state.
- **Payments**: set an initial Deposit when creating/editing a document; log further instalments any time from the **Payments** button, which opens a timeline page and won't let you record more than the remaining outstanding balance. A **Settle Outstanding in Full** button on that page fills the amount field with the exact balance owed, so clearing a balance is one click plus a mode of payment.
- **Printing**: shows the centred EyePro Optical / Adams Vision Ltd header, the document title (Order/Quotation/VAT Invoice) underlined, Invoice Number & Date, blank Order Number/Date lines for pen entry, client name, a 6-column item table (Description, Unit Price, Discount, VAT%, VAT Amount, Total), the Sub-total/VAT/Grand Total summary, and either "PAID IN FULL" or the Deposit/Outstanding lines plus mode of payment.

## Outstanding balances

Outstanding amounts are surfaced in three places so nothing slips through:
- A red count badge on the **Invoicing** sidebar item whenever any document has money owed.
- A **Total Outstanding** stat card and an "Outstanding Balances" list on the **Dashboard**, each row with a one-click **Clear** button straight to that document's payment page.
- In the Invoicing list itself, the Outstanding column is shown in red when non-zero, plain "Rs 0.00" badge when settled.

## Other notes

- This is a single static HTML file by design (`index.html`) — no build tools, no server to maintain. `logo.png` is used exactly as provided (not modified) for the header and printed invoices.
- Local codes: frames get `EP0001`, `EP0002`…, contact lenses `CL0001`…, accessories `AC0001`…, auto-assigned on save.
- If you ever need a third role, or want the optometrist to manage users from inside the app instead of Supabase's Table Editor, that's a small addition — just ask.

## Eye Examination form & records

- **Eye Exams** tab lists every saved record (date/time, patient no., surname, name, date of birth). Filter by name, surname, patient number or date of birth. Click a record to open it in the form, read-only.
- **Start Exam** (on a checked-in appointment), **New Exam** (Patients tab or Eye Exams tab) opens the full form: History (Personal details), Previous Rx, New Examination, and the Lens accordion (Spec Lens / Contact Lens).
- **Every save is a new record** with its own date and time. **Edit** loads an old record and saves your changes as a *new* record for the same patient; the original is never overwritten, so you can compare a patient's eyes over the years (the date chips above the form jump between a patient's records).
- **Delete** asks "Do you want to delete this?" first. Only the optometrist can create, edit or delete; the secretary can view and print.
- **Print** shows name, surname, patient number, record date and the Spec Lens and Contact Lens refraction tables only. Use the browser's "Save as PDF" in the print dialog for a PDF.
- **Patient numbers** for new patients look like `EP-PN-001JA26` (EP-PN, a 3-digit number 001-999, 2-letter month, 2-digit year). The number is the smallest unused one for that month. Existing patients keep their old numbers.
