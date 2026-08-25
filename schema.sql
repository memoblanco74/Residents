-- ============================================================================
-- نظام إدارة العمارة — Supabase schema
-- Run this whole file once in the Supabase SQL editor (Project > SQL Editor).
-- It creates all tables, enables RLS, and adds the RPC functions that hold
-- the business rules that used to live in code.gs (last-admin protection,
-- password hashing, payment allocation, maintenance math, etc).
-- ============================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- TABLES
-- ---------------------------------------------------------------------------

create table if not exists residents (
  id         uuid primary key default gen_random_uuid(),
  name       text not null default '',
  phone      text not null default '',
  unit       text not null unique,
  password   text not null,
  role       text not null default 'resident' check (role in ('admin','resident'))
);

create table if not exists announcements (
  id         uuid primary key default gen_random_uuid(),
  title      text not null,
  content    text not null,
  created_at timestamptz not null default now()
);

create table if not exists finances (
  id               uuid primary key default gen_random_uuid(),
  unit             text not null,
  amount_owed      numeric not null default 0,
  amount_paid      numeric not null default 0,
  transaction_date timestamptz not null default now(),
  paid_by          text default '',
  reference        text default ''
);

create table if not exists expenses (
  id          uuid primary key default gen_random_uuid(),
  description text not null,
  amount      numeric not null default 0,
  date        timestamptz not null default now(),
  invoice_url text default ''
);

create table if not exists surveys (
  id         uuid primary key default gen_random_uuid(),
  question   text not null,
  options    jsonb not null default '[]',
  responses  jsonb not null default '[]',
  created_at timestamptz not null default now()
);

create table if not exists maintenance (
  unit             text primary key,
  paid_until_month text
);

create table if not exists payment_requests (
  id            uuid primary key default gen_random_uuid(),
  unit          text not null,
  amount        numeric not null,
  paid_by       text not null,
  reference     text not null,
  status        text not null default 'pending' check (status in ('pending','approved','rejected')),
  reject_reason text default '',
  created_at    timestamptz not null default now(),
  reviewed_at   timestamptz
);

create table if not exists contacts (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  phone       text not null,
  category    text default '',
  description text default '',
  created_at  timestamptz not null default now()
);

create table if not exists tickets (
  id           uuid primary key default gen_random_uuid(),
  unit         text not null,
  title        text not null,
  description  text not null,
  status       text not null default 'open' check (status in ('open','in_progress','resolved')),
  admin_note   text default '',
  created_at   timestamptz not null default now(),
  resolved_at  timestamptz
);

create table if not exists accessories (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  price      numeric not null default 0,
  created_at timestamptz not null default now()
);

create table if not exists accessory_requests (
  id                 uuid primary key default gen_random_uuid(),
  accessory_id       uuid,
  accessory_name     text not null,
  unit               text not null,
  quantity           integer not null,
  unit_price         numeric not null default 0,
  total_price        numeric not null default 0,
  status             text not null default 'requested',
  created_at         timestamptz not null default now(),
  delivered_at       timestamptz,
  delivered_quantity integer not null default 0
);

-- replaces PropertiesService (currently just holds maint_fee)
create table if not exists settings (
  key   text primary key,
  value text
);
insert into settings(key, value) values ('maint_fee', '0') on conflict (key) do nothing;

create index if not exists idx_finances_unit on finances(unit);
create index if not exists idx_tickets_unit on tickets(unit);
create index if not exists idx_payment_requests_unit on payment_requests(unit);
create index if not exists idx_accessory_requests_unit on accessory_requests(unit);

-- ---------------------------------------------------------------------------
-- ROW LEVEL SECURITY
-- Every table below is open to the anon key (same trust model the Apps
-- Script version had: any client that can call the API can read/write).
-- `residents` is the one exception — it holds password hashes, so it has NO
-- open policies. It's only ever touched through the SECURITY DEFINER
-- functions below, and the anon key is only granted SELECT on the safe
-- (non-password) columns.
-- ---------------------------------------------------------------------------

alter table residents enable row level security;
create policy residents_select_safe_cols on residents for select using (true);
revoke select on residents from anon, authenticated;
grant select (id, name, phone, unit, role) on residents to anon, authenticated;
-- no insert/update/delete policies on purpose — only RPC functions below can write

do $$
declare
  t text;
begin
  foreach t in array array['announcements','finances','expenses','surveys','maintenance',
                            'payment_requests','contacts','tickets','accessories',
                            'accessory_requests','settings']
  loop
    execute format('alter table %I enable row level security;', t);
    execute format('drop policy if exists %I_all on %I;', t, t);
    execute format('create policy %I_all on %I for all using (true) with check (true);', t, t);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- STORAGE (invoice attachments for expenses)
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('invoices', 'invoices', true)
on conflict (id) do nothing;

drop policy if exists invoices_public_read on storage.objects;
create policy invoices_public_read on storage.objects for select
  using (bucket_id = 'invoices');

drop policy if exists invoices_anon_upload on storage.objects;
create policy invoices_anon_upload on storage.objects for insert
  with check (bucket_id = 'invoices');

-- ---------------------------------------------------------------------------
-- RPC FUNCTIONS — anything touching residents, or with invariants / multi-row
-- math (last-admin protection, FIFO payment allocation, maintenance dates).
-- All are SECURITY DEFINER so they can read/write `residents` regardless of
-- the column grants/RLS above.
-- ---------------------------------------------------------------------------

create or replace function hash_pw(p text)
returns text language sql immutable as $$
  select encode(digest(p, 'sha256'), 'hex');
$$;

-- ===== auth / residents =====================================================

create or replace function login_resident(p_unit text, p_password text)
returns jsonb language plpgsql security definer as $$
declare r residents;
begin
  select * into r from residents where unit = trim(p_unit) and password = hash_pw(trim(p_password));
  if found then
    return jsonb_build_object('success', true, 'role', r.role, 'unit', r.unit, 'name', r.name, 'phone', r.phone);
  end if;
  return jsonb_build_object('success', false);
end $$;

create or replace function update_profile(p_unit text, p_name text, p_phone text, p_password text default null)
returns jsonb language plpgsql security definer as $$
begin
  if p_password is not null and trim(p_password) <> '' then
    update residents set name = trim(p_name), phone = trim(p_phone), password = hash_pw(trim(p_password))
      where unit = trim(p_unit);
  else
    update residents set name = trim(p_name), phone = trim(p_phone) where unit = trim(p_unit);
  end if;
  if not found then
    return jsonb_build_object('success', false);
  end if;
  return jsonb_build_object('success', true, 'name', p_name, 'phone', p_phone);
end $$;

create or replace function get_all_residents_for_role_management()
returns table(unit text, name text, phone text, role text)
language sql security definer as $$
  select unit, coalesce(name,''), coalesce(phone,''), role from residents;
$$;

create or replace function set_unit_role(p_unit text, p_new_role text)
returns boolean language plpgsql security definer as $$
declare
  v_role text := case when p_new_role = 'admin' then 'admin' else 'resident' end;
  v_admin_count int;
begin
  if v_role <> 'admin' then
    select count(*) into v_admin_count from residents where role = 'admin';
    if v_admin_count <= 1 and exists (select 1 from residents where unit = trim(p_unit) and role = 'admin') then
      raise exception 'لا يمكن إزالة آخر أدمن في النظام';
    end if;
  end if;
  update residents set role = v_role where unit = trim(p_unit);
  if not found then
    raise exception 'الوحدة غير موجودة';
  end if;
  return true;
end $$;

create or replace function reset_unit_password(p_unit text, p_new_password text)
returns boolean language plpgsql security definer as $$
begin
  if trim(coalesce(p_new_password,'')) = '' then
    raise exception 'كلمة السر مطلوبة';
  end if;
  update residents set password = hash_pw(trim(p_new_password)) where unit = trim(p_unit);
  if not found then
    raise exception 'الوحدة غير موجودة';
  end if;
  return true;
end $$;

create or replace function add_new_unit(p_unit text, p_name text, p_phone text, p_password text, p_role text)
returns boolean language plpgsql security definer as $$
begin
  if trim(coalesce(p_unit,'')) = '' or trim(coalesce(p_password,'')) = '' then
    raise exception 'رقم الوحدة وكلمة السر مطلوبان';
  end if;
  if exists (select 1 from residents where unit = trim(p_unit)) then
    raise exception 'رقم الوحدة موجود بالفعل';
  end if;
  insert into residents(name, phone, unit, password, role)
  values (trim(coalesce(p_name,'')), trim(coalesce(p_phone,'')), trim(p_unit), hash_pw(trim(p_password)),
          case when p_role = 'admin' then 'admin' else 'resident' end);
  return true;
end $$;

create or replace function delete_unit(p_unit text)
returns boolean language plpgsql security definer as $$
declare
  v_role text;
  v_admin_count int;
begin
  select role into v_role from residents where unit = trim(p_unit);
  if not found then
    raise exception 'الوحدة غير موجودة';
  end if;
  if v_role = 'admin' then
    select count(*) into v_admin_count from residents where role = 'admin';
    if v_admin_count <= 1 then
      raise exception 'لا يمكن حذف آخر أدمن في النظام';
    end if;
  end if;
  delete from residents where unit = trim(p_unit);
  return true;
end $$;

-- ===== finances ==============================================================

create or replace function add_bulk_dues(p_amount numeric)
returns boolean language plpgsql security definer as $$
declare u text;
begin
  for u in select distinct unit from residents where unit is not null and unit <> '' loop
    insert into finances(unit, amount_owed, amount_paid, transaction_date)
    values (u, coalesce(p_amount,0), 0, now());
  end loop;
  return true;
end $$;

create or replace function get_finances_summary(p_unit text)
returns jsonb language plpgsql security definer as $$
declare
  v_owed numeric := 0; v_paid numeric := 0; v_total_col numeric := 0; v_total_spent numeric := 0;
  v_maint_debt numeric := 0; v_fee numeric := 0; v_paid_until text; v_has_record boolean := false;
  v_months_behind int; v_total_debt numeric; v_net numeric;
begin
  select coalesce(sum(amount_owed),0), coalesce(sum(amount_paid),0) into v_owed, v_paid
    from finances where unit = trim(p_unit);
  select coalesce(sum(amount_paid),0) into v_total_col from finances;
  select coalesce(sum(amount),0) into v_total_spent from expenses;
  select value::numeric into v_fee from settings where key = 'maint_fee';
  v_fee := coalesce(v_fee, 0);

  select paid_until_month into v_paid_until from maintenance where unit = trim(p_unit);
  if found then
    v_has_record := true;
    if v_paid_until is not null and v_paid_until <> '' then
      v_months_behind := (extract(year from now())::int - split_part(v_paid_until,'-',1)::int) * 12
                        + (extract(month from now())::int - split_part(v_paid_until,'-',2)::int);
      if v_months_behind > 0 then
        v_maint_debt := v_months_behind * v_fee;
      end if;
    end if;
  end if;
  if not v_has_record then
    v_maint_debt := v_fee;
  end if;

  v_total_debt := v_owed + v_maint_debt;
  v_net := v_total_debt - v_paid;

  return jsonb_build_object(
    'meOwed', greatest(v_net, 0),
    'mePaid', v_paid,
    'myBalance', case when v_net < 0 then abs(v_net) else 0 end,
    'bBalance', v_total_col - v_total_spent
  );
end $$;

create or replace function get_detailed_reports()
returns jsonb language plpgsql security definer as $$
declare v_col numeric; v_spent numeric; v_tx jsonb; v_res jsonb;
begin
  select coalesce(sum(amount_paid),0) into v_col from finances;
  select coalesce(sum(amount),0) into v_spent from expenses;

  select coalesce(jsonb_agg(row_to_json(t) order by t.rawDate desc), '[]'::jsonb) into v_tx from (
    select 'in' as type, ('تحصيل من ' || unit) as desc, amount_paid as amt,
           transaction_date as rawDate, coalesce(paid_by,'') as paidBy, coalesce(reference,'') as ref, null as "invoiceUrl"
      from finances where amount_paid > 0
    union all
    select 'out' as type, description as desc, amount as amt,
           date as rawDate, '' as paidBy, '' as ref, invoice_url as "invoiceUrl"
      from expenses
  ) t;

  select coalesce(jsonb_agg(jsonb_build_object('unit', unit, 'bal', sum(amount_paid) - sum(amount_owed))), '[]'::jsonb)
    into v_res from finances group by unit;
  -- the group by above only returns one row's aggregate in this shape; rebuild correctly:
  select coalesce(jsonb_agg(jsonb_build_object('unit', u, 'bal', bal)), '[]'::jsonb) into v_res
    from (select unit as u, sum(amount_paid) - sum(amount_owed) as bal from finances group by unit) s;

  return jsonb_build_object('col', v_col, 'spent', v_spent, 'bal', v_col - v_spent,
                             'transactions', v_tx, 'residents', v_res);
end $$;

create or replace function get_admin_dashboard_summary()
returns jsonb language plpgsql security definer as $$
declare
  v_total_units int; v_total_col numeric; v_total_spent numeric; v_fee numeric;
  v_late int := 0; v_pending int; v_open_tickets int;
  rec record;
begin
  select count(distinct unit) into v_total_units from residents where unit is not null and unit <> '';
  select coalesce(sum(amount_paid),0) into v_total_col from finances;
  select coalesce(sum(amount),0) into v_total_spent from expenses;
  select value::numeric into v_fee from settings where key = 'maint_fee';
  v_fee := coalesce(v_fee, 0);

  for rec in
    select r.unit as unit,
           coalesce((select sum(amount_owed) from finances f where f.unit = r.unit), 0)
             - coalesce((select sum(amount_paid) from finances f where f.unit = r.unit), 0) as net_debt,
           (select paid_until_month from maintenance m where m.unit = r.unit) as paid_until
    from (select distinct unit from residents where unit is not null and unit <> '') r
  loop
    declare v_maint_late boolean := false; v_exp date;
    begin
      if rec.paid_until is not null and rec.paid_until <> '' then
        v_exp := to_date(rec.paid_until || '-01', 'YYYY-MM-DD');
        if v_exp < date_trunc('month', now())::date then
          v_maint_late := true;
        end if;
      elsif v_fee > 0 then
        v_maint_late := true;
      end if;
      if rec.net_debt > 0 or v_maint_late then
        v_late := v_late + 1;
      end if;
    end;
  end loop;

  select count(*) into v_pending from payment_requests where status = 'pending';
  select count(*) into v_open_tickets from tickets where status <> 'resolved';

  return jsonb_build_object('totalUnits', v_total_units, 'lateUnits', v_late,
                             'treasuryBalance', v_total_col - v_total_spent,
                             'pendingRequests', v_pending, 'openTickets', v_open_tickets);
end $$;

-- shared FIFO allocation core, used by record_payment_with_amount & approve_payment_request
create or replace function record_payment_core(p_unit text, p_total_owed numeric, p_total_paid numeric,
                                                p_actual_paid numeric, p_paid_by text, p_reference text)
returns jsonb language plpgsql security definer as $$
declare
  v_remaining numeric := p_total_owed - p_total_paid;
  v_to_settle numeric; v_overpaid numeric; v_allocated numeric := 0;
  rec record; v_to_pay numeric;
begin
  v_to_settle := least(p_actual_paid, v_remaining);
  v_overpaid := greatest(p_actual_paid - v_remaining, 0);

  for rec in
    select id, amount_owed, amount_paid from finances
      where unit = trim(p_unit) and (amount_owed - amount_paid) > 0
      order by transaction_date asc
  loop
    exit when v_allocated >= v_to_settle;
    v_to_pay := least(rec.amount_owed - rec.amount_paid, v_to_settle - v_allocated);
    update finances set amount_paid = amount_paid + v_to_pay, paid_by = p_paid_by, reference = p_reference
      where id = rec.id;
    v_allocated := v_allocated + v_to_pay;
  end loop;

  if v_overpaid > 0 then
    insert into finances(unit, amount_owed, amount_paid, transaction_date, paid_by, reference)
    values (trim(p_unit), 0, v_overpaid, now(), p_paid_by, p_reference || ' (رصيد زيادة)');
  end if;

  return jsonb_build_object('overpaid', v_overpaid, 'underpaid', greatest(v_remaining - p_actual_paid, 0));
end $$;

create or replace function record_payment_with_amount(p_unit text, p_total_owed numeric, p_total_paid numeric,
                                                        p_actual_paid numeric, p_paid_by text, p_reference text)
returns jsonb language sql security definer as $$
  select record_payment_core(p_unit, p_total_owed, p_total_paid, p_actual_paid, p_paid_by, p_reference);
$$;

create or replace function record_merged_payment(p_units_summary jsonb, p_total_paid numeric,
                                                  p_paid_by text, p_reference text)
returns jsonb language plpgsql security definer as $$
declare
  v_remaining_pool numeric := p_total_paid;
  v_details jsonb := '[]'::jsonb;
  elem jsonb; v_unit text; v_unit_net numeric; v_allocated_for_unit numeric; v_settled numeric;
  rec record; v_to_pay numeric; v_last_unit text;
begin
  for elem in select * from jsonb_array_elements(p_units_summary) loop
    v_unit := trim(elem->>'unit');
    v_unit_net := greatest(coalesce((elem->>'totalOwed')::numeric,0) - coalesce((elem->>'totalPaid')::numeric,0), 0);
    v_allocated_for_unit := least(v_unit_net, v_remaining_pool);
    v_remaining_pool := v_remaining_pool - v_allocated_for_unit;
    v_settled := 0;
    for rec in
      select id, amount_owed, amount_paid from finances
        where unit = v_unit and (amount_owed - amount_paid) > 0
        order by transaction_date asc
    loop
      exit when v_settled >= v_allocated_for_unit;
      v_to_pay := least(rec.amount_owed - rec.amount_paid, v_allocated_for_unit - v_settled);
      update finances set amount_paid = amount_paid + v_to_pay, paid_by = p_paid_by, reference = p_reference
        where id = rec.id;
      v_settled := v_settled + v_to_pay;
    end loop;
    v_details := v_details || jsonb_build_object('unit', v_unit, 'allocated', v_allocated_for_unit, 'extra', 0);
    v_last_unit := v_unit;
  end loop;

  if v_remaining_pool > 0 and jsonb_array_length(p_units_summary) > 0 then
    insert into finances(unit, amount_owed, amount_paid, transaction_date, paid_by, reference)
    values (v_last_unit, 0, v_remaining_pool, now(), p_paid_by, p_reference || ' (رصيد زيادة)');
    v_details := jsonb_set(v_details, array[(jsonb_array_length(v_details)-1)::text, 'extra'], to_jsonb(v_remaining_pool));
  end if;

  return jsonb_build_object('details', v_details);
end $$;

create or replace function approve_payment_request(p_id uuid)
returns jsonb language plpgsql security definer as $$
declare
  pr payment_requests;
  v_owed numeric; v_paid numeric; v_result jsonb;
begin
  select * into pr from payment_requests where id = p_id;
  if not found then raise exception 'الطلب غير موجود'; end if;
  if pr.status <> 'pending' then raise exception 'هذا الطلب تمت مراجعته من قبل'; end if;

  select coalesce(sum(amount_owed),0), coalesce(sum(amount_paid),0) into v_owed, v_paid
    from finances where unit = pr.unit;

  v_result := record_payment_core(pr.unit, v_owed, v_paid, pr.amount, pr.paid_by, pr.reference);

  update payment_requests set status = 'approved', reviewed_at = now() where id = p_id;
  return v_result;
end $$;

create or replace function reject_payment_request(p_id uuid, p_reason text)
returns boolean language plpgsql security definer as $$
begin
  if not exists (select 1 from payment_requests where id = p_id) then
    raise exception 'الطلب غير موجود';
  end if;
  if (select status from payment_requests where id = p_id) <> 'pending' then
    raise exception 'هذا الطلب تمت مراجعته من قبل';
  end if;
  update payment_requests set status = 'rejected', reject_reason = coalesce(p_reason,''), reviewed_at = now()
    where id = p_id;
  return true;
end $$;

-- ===== maintenance ===========================================================

create or replace function process_maint_payment(p_unit text, p_months int)
returns boolean language plpgsql security definer as $$
declare
  v_fee numeric; v_total numeric; v_current text; v_base date; v_new date; v_new_str text;
begin
  if p_months is null or p_months <= 0 then return false; end if;
  select value::numeric into v_fee from settings where key = 'maint_fee';
  v_fee := coalesce(v_fee, 0);
  v_total := v_fee * p_months;

  select paid_until_month into v_current from maintenance where unit = trim(p_unit);
  v_base := date_trunc('month', now())::date;
  if v_current is not null and v_current <> '' then
    if to_date(v_current || '-01', 'YYYY-MM-DD') > v_base then
      v_base := to_date(v_current || '-01', 'YYYY-MM-DD');
    end if;
  end if;
  v_new := v_base + (p_months || ' months')::interval;
  v_new_str := to_char(v_new, 'YYYY-MM');

  insert into maintenance(unit, paid_until_month) values (trim(p_unit), v_new_str)
    on conflict (unit) do update set paid_until_month = v_new_str;

  if v_total > 0 then
    insert into finances(unit, amount_owed, amount_paid, transaction_date)
    values (trim(p_unit), v_total, v_total, now());
  end if;
  return true;
end $$;

-- ===== accessories ===========================================================

create or replace function request_accessory(p_unit text, p_accessory_id uuid, p_quantity int)
returns jsonb language plpgsql security definer as $$
declare a accessories; v_total numeric;
begin
  if p_quantity is null or p_quantity <= 0 then raise exception 'الكمية غير صحيحة'; end if;
  select * into a from accessories where id = p_accessory_id;
  if not found then raise exception 'نوع القطعة غير موجود، ربما تم حذفه'; end if;
  v_total := a.price * p_quantity;
  insert into accessory_requests(accessory_id, accessory_name, unit, quantity, unit_price, total_price, status, delivered_quantity)
  values (a.id, a.name, trim(p_unit), p_quantity, a.price, v_total, 'requested', 0);
  return jsonb_build_object('accessoryName', a.name, 'unitPrice', a.price, 'quantity', p_quantity, 'total', v_total);
end $$;

create or replace function deliver_accessory_quantity(p_id uuid, p_delivered_qty int)
returns jsonb language plpgsql security definer as $$
declare rec accessory_requests; v_remaining int; v_new_delivered int; v_status text;
begin
  if p_delivered_qty is null or p_delivered_qty <= 0 then raise exception 'الكمية غير صحيحة'; end if;
  select * into rec from accessory_requests where id = p_id;
  if not found then raise exception 'الطلب غير موجود'; end if;
  v_remaining := rec.quantity - rec.delivered_quantity;
  if v_remaining <= 0 then raise exception 'تم تسليم هذا الطلب بالكامل من قبل'; end if;
  if p_delivered_qty > v_remaining then
    raise exception 'الكمية المدخلة أكبر من المتبقي (%)', v_remaining;
  end if;
  v_new_delivered := rec.delivered_quantity + p_delivered_qty;
  v_status := case when v_new_delivered >= rec.quantity then 'delivered' else 'partially_delivered' end;
  update accessory_requests set delivered_quantity = v_new_delivered, delivered_at = now(), status = v_status
    where id = p_id;
  return jsonb_build_object('delivered', p_delivered_qty, 'totalDelivered', v_new_delivered,
                             'remaining', rec.quantity - v_new_delivered, 'status', v_status);
end $$;

create or replace function get_accessories_participation_report()
returns jsonb language plpgsql security definer as $$
declare v_not_requested jsonb;
begin
  select coalesce(jsonb_agg(unit), '[]'::jsonb) into v_not_requested from (
    select distinct unit from residents where unit is not null and unit <> ''
    except
    select distinct unit from accessory_requests
  ) s;
  return jsonb_build_object('didNotRequest', v_not_requested);
end $$;

-- ---------------------------------------------------------------------------
-- GRANTS — let the anon (browser) key call all of the above
-- ---------------------------------------------------------------------------
grant execute on all functions in schema public to anon, authenticated;
