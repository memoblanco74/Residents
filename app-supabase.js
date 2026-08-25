// ============================================================================
// نظام إدارة العمارة — Supabase backend layer
// This file replaces code.gs. It implements every function the frontend
// used to call as google.script.run.xxx(), talking to Supabase instead of
// Google Sheets, and exposes a `google.script.run` compatible shim so the
// original index.html JS does not need to change at all.
// ============================================================================

// ---- fill these in from Supabase > Project Settings > API -----------------
const SUPABASE_URL = 'https://YOUR-PROJECT-REF.supabase.co';
const SUPABASE_ANON_KEY = 'YOUR-ANON-PUBLIC-KEY';
// -----------------------------------------------------------------------------

const supabase = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

function ok(error) {
  if (error) throw new Error(error.message || String(error));
}

function unitLocaleCompare(a, b) {
  return String(a).localeCompare(String(b), undefined, { numeric: true });
}

// ============================================================================
// GAS_API — one entry per function the frontend used to call via
// google.script.run. Signatures match the original code.gs exactly.
// ============================================================================
const GAS_API = {

  // ----- auth / residents ---------------------------------------------------
  async loginResident(u, p) {
    const { data, error } = await supabase.rpc('login_resident', { p_unit: u, p_password: p });
    ok(error);
    return data;
  },

  async updateProfile(u, n, p, pw) {
    const { data, error } = await supabase.rpc('update_profile', { p_unit: u, p_name: n, p_phone: p, p_password: pw || null });
    ok(error);
    return data;
  },

  async getAllResidentsForRoleManagement() {
    const { data, error } = await supabase.rpc('get_all_residents_for_role_management');
    ok(error);
    return (data || []).sort((a, b) => unitLocaleCompare(a.unit, b.unit));
  },

  async setUnitRole(unit, newRole) {
    const { error } = await supabase.rpc('set_unit_role', { p_unit: unit, p_new_role: newRole });
    ok(error);
    return true;
  },

  async resetUnitPassword(unit, newPassword) {
    const { error } = await supabase.rpc('reset_unit_password', { p_unit: unit, p_new_password: newPassword });
    ok(error);
    return true;
  },

  async addNewUnit(unit, name, phone, password, role) {
    const { error } = await supabase.rpc('add_new_unit', { p_unit: unit, p_name: name, p_phone: phone, p_password: password, p_role: role });
    ok(error);
    return true;
  },

  async deleteUnit(unit) {
    const { error } = await supabase.rpc('delete_unit', { p_unit: unit });
    ok(error);
    return true;
  },

  // ----- announcements -------------------------------------------------------
  async addAnnouncement(t, c) {
    const { error } = await supabase.from('announcements').insert({ title: t.trim(), content: c.trim() });
    ok(error);
    return true;
  },

  async deleteAnnouncement(id) {
    const { error } = await supabase.from('announcements').delete().eq('id', id);
    ok(error);
    return true;
  },

  async updateAnnouncement(id, t, c) {
    if (!t.trim() || !c.trim()) throw new Error('العنوان والنص مطلوبان');
    const { error } = await supabase.from('announcements').update({ title: t.trim(), content: c.trim() }).eq('id', id);
    ok(error);
    return true;
  },

  async getLatestAnnouncements() {
    const { data, error } = await supabase.from('announcements').select('*').order('created_at', { ascending: false }).limit(5);
    ok(error);
    return (data || []).map(r => ({ id: r.id, title: r.title, content: r.content, date: r.created_at }));
  },

  // ----- surveys ---------------------------------------------------------------
  async addSurvey(q, o) {
    const { error } = await supabase.from('surveys').insert({ question: q.trim(), options: o, responses: [] });
    ok(error);
    return true;
  },

  async getActiveSurveys() {
    const { data, error } = await supabase.from('surveys').select('*').order('created_at', { ascending: false });
    ok(error);
    return (data || []).map(r => ({ id: r.id, question: r.question, options: r.options, responses: r.responses }));
  },

  async submitSurveyResponse(id, u, o) {
    const { data, error } = await supabase.from('surveys').select('responses').eq('id', id).single();
    if (error) return false;
    let r = data.responses || [];
    const idx = r.findIndex(a => a.unit === u);
    if (idx > -1) {
      if (r[idx].option === o) r.splice(idx, 1); else r[idx].option = o;
    } else {
      r.push({ unit: u, option: o });
    }
    const { error: upErr } = await supabase.from('surveys').update({ responses: r }).eq('id', id);
    if (upErr) return false;
    return true;
  },

  async deleteSurvey(id) {
    const { error } = await supabase.from('surveys').delete().eq('id', id);
    return !error;
  },

  async updateSurvey(id, q, o) {
    const { error } = await supabase.from('surveys').update({ question: q.trim(), options: o }).eq('id', id);
    return !error;
  },

  // ----- finances ----------------------------------------------------------
  async addTransaction(u, o, p) {
    const { error } = await supabase.from('finances').insert({ unit: u.trim(), amount_owed: parseFloat(o) || 0, amount_paid: parseFloat(p) || 0 });
    ok(error);
    return true;
  },

  async addExpense(desc, amt, fd, fn, mt) {
    let invoiceUrl = '';
    if (fd) {
      const bytes = atob(fd);
      const arr = new Uint8Array(bytes.length);
      for (let i = 0; i < bytes.length; i++) arr[i] = bytes.charCodeAt(i);
      const blob = new Blob([arr], { type: mt || 'application/octet-stream' });
      const path = `${Date.now()}_${fn}`;
      const { error: upErr } = await supabase.storage.from('invoices').upload(path, blob, { contentType: mt });
      ok(upErr);
      invoiceUrl = supabase.storage.from('invoices').getPublicUrl(path).data.publicUrl;
    }
    const { error } = await supabase.from('expenses').insert({ description: desc.trim(), amount: parseFloat(amt) || 0, invoice_url: invoiceUrl });
    ok(error);
    return true;
  },

  async addBulkDues(amt) {
    const { error } = await supabase.rpc('add_bulk_dues', { p_amount: parseFloat(amt) || 0 });
    ok(error);
    return true;
  },

  async getFinancesSummary(u) {
    const { data, error } = await supabase.rpc('get_finances_summary', { p_unit: u });
    ok(error);
    return data;
  },

  async getDetailedReports() {
    const { data, error } = await supabase.rpc('get_detailed_reports');
    ok(error);
    return data;
  },

  async getAllFinances() {
    const { data, error } = await supabase.from('finances').select('*');
    ok(error);
    return (data || []).map(r => ({ id: r.id, unit: r.unit, owed: r.amount_owed, paid: r.amount_paid, date: r.transaction_date, paidBy: r.paid_by || '', reference: r.reference || '' }));
  },

  async updateFinanceRecord(id, owed, paid) {
    const { error } = await supabase.from('finances').update({ amount_owed: parseFloat(owed) || 0, amount_paid: parseFloat(paid) || 0 }).eq('id', id);
    ok(error);
    return true;
  },

  async deleteFinanceRecord(id) {
    const { error } = await supabase.from('finances').delete().eq('id', id);
    ok(error);
    return true;
  },

  async getAdminDashboardSummary() {
    const { data, error } = await supabase.rpc('get_admin_dashboard_summary');
    ok(error);
    return data;
  },

  async markFinancePaid(id, paidBy, reference) {
    const { data } = await supabase.from('finances').select('amount_owed').eq('id', id).single();
    if (!data) return false;
    const { error } = await supabase.from('finances').update({ amount_paid: data.amount_owed, paid_by: String(paidBy).trim(), reference: String(reference).trim() }).eq('id', id);
    return !error;
  },

  async recordPaymentWithAmount(unit, totalOwed, totalPaid, actualPaid, paidBy, reference) {
    const { data, error } = await supabase.rpc('record_payment_with_amount', {
      p_unit: unit, p_total_owed: totalOwed, p_total_paid: totalPaid,
      p_actual_paid: actualPaid, p_paid_by: paidBy, p_reference: reference
    });
    ok(error);
    return data;
  },

  async recordMergedPayment(unitsSummary, totalPaid, paidBy, reference) {
    const { data, error } = await supabase.rpc('record_merged_payment', {
      p_units_summary: unitsSummary, p_total_paid: totalPaid, p_paid_by: paidBy, p_reference: reference
    });
    ok(error);
    return data;
  },

  // ----- payment requests ----------------------------------------------------
  async submitPaymentRequest(unit, amount, paidBy, reference) {
    const amt = parseFloat(amount) || 0;
    if (amt <= 0 || !String(paidBy).trim() || !String(reference).trim()) throw new Error('بيانات غير مكتملة');
    const { error } = await supabase.from('payment_requests').insert({
      unit: unit.trim(), amount: amt, paid_by: paidBy.trim(), reference: reference.trim(), status: 'pending'
    });
    ok(error);
    return true;
  },

  async getMyPaymentRequests(unit) {
    const { data, error } = await supabase.from('payment_requests').select('*').eq('unit', unit.trim()).order('created_at', { ascending: false });
    ok(error);
    return (data || []).map(mapPaymentRequest);
  },

  async getPendingPaymentRequestsCount() {
    const { count, error } = await supabase.from('payment_requests').select('*', { count: 'exact', head: true }).eq('status', 'pending');
    ok(error);
    return count || 0;
  },

  async getAllPaymentRequests() {
    const { data, error } = await supabase.from('payment_requests').select('*').order('created_at', { ascending: false });
    ok(error);
    return (data || []).map(mapPaymentRequest);
  },

  async approvePaymentRequest(id) {
    const { data, error } = await supabase.rpc('approve_payment_request', { p_id: id });
    ok(error);
    return data;
  },

  async rejectPaymentRequest(id, reason) {
    const { error } = await supabase.rpc('reject_payment_request', { p_id: id, p_reason: reason });
    ok(error);
    return true;
  },

  // ----- maintenance -----------------------------------------------------------
  async getMaintenanceSummary(unit) {
    const [{ data: m }, { data: s }] = await Promise.all([
      supabase.from('maintenance').select('paid_until_month').eq('unit', unit.trim()).maybeSingle(),
      supabase.from('settings').select('value').eq('key', 'maint_fee').maybeSingle()
    ]);
    return { status: m ? m.paid_until_month : null, fee: s ? s.value : '0' };
  },

  async getAllMaintenance() {
    const [{ data: residentsRows, error: e1 }, { data: maintRows, error: e2 }] = await Promise.all([
      supabase.from('residents').select('unit'),
      supabase.from('maintenance').select('*')
    ]);
    ok(e1); ok(e2);
    const mDict = {};
    (maintRows || []).forEach(m => { mDict[m.unit] = m.paid_until_month || ''; });
    const seen = {};
    const out = [];
    (residentsRows || []).forEach(r => {
      const u = String(r.unit).trim();
      if (u && !seen[u]) { seen[u] = true; out.push({ unit: u, paidUntil: mDict[u] || '' }); }
    });
    return out;
  },

  async setMaintenanceMonth(unit, newStr) {
    const { error } = await supabase.from('maintenance').upsert({ unit: unit.trim(), paid_until_month: newStr });
    ok(error);
    return true;
  },

  async setMaintFee(f) {
    const { error } = await supabase.from('settings').upsert({ key: 'maint_fee', value: String(f) });
    ok(error);
    return true;
  },

  async processMaintPayment(unit, monthsToAdd) {
    const { data, error } = await supabase.rpc('process_maint_payment', { p_unit: unit, p_months: parseInt(monthsToAdd) });
    ok(error);
    return data;
  },

  // ----- contacts --------------------------------------------------------------
  async addContact(name, phone, category, description) {
    if (!name.trim() || !phone.trim()) throw new Error('الاسم والهاتف مطلوبان');
    const { error } = await supabase.from('contacts').insert({ name: name.trim(), phone: phone.trim(), category: (category || '').trim(), description: (description || '').trim() });
    ok(error);
    return true;
  },

  async getAllContacts() {
    const { data, error } = await supabase.from('contacts').select('*');
    ok(error);
    return (data || [])
      .map(r => ({ id: r.id, name: r.name, phone: r.phone, category: r.category, description: r.description, createdAt: r.created_at }))
      .sort((a, b) => String(a.category).localeCompare(String(b.category), 'ar') || String(a.name).localeCompare(String(b.name), 'ar'));
  },

  async updateContact(id, name, phone, category, description) {
    if (!name.trim() || !phone.trim()) throw new Error('الاسم والهاتف مطلوبان');
    const { error } = await supabase.from('contacts').update({ name: name.trim(), phone: phone.trim(), category: (category || '').trim(), description: (description || '').trim() }).eq('id', id);
    ok(error);
    return true;
  },

  async deleteContact(id) {
    const { error } = await supabase.from('contacts').delete().eq('id', id);
    return !error;
  },

  // ----- tickets -----------------------------------------------------------------
  async submitTicket(unit, title, description) {
    if (!unit.trim() || !title.trim() || !description.trim()) throw new Error('العنوان والوصف مطلوبان');
    const { error } = await supabase.from('tickets').insert({ unit: unit.trim(), title: title.trim(), description: description.trim(), status: 'open' });
    ok(error);
    return true;
  },

  async getMyTickets(unit) {
    const { data, error } = await supabase.from('tickets').select('*').eq('unit', unit.trim());
    ok(error);
    return (data || []).map(mapTicket).sort((a, b) => new Date(b.createdAt) - new Date(a.createdAt));
  },

  async getAllTickets() {
    const { data, error } = await supabase.from('tickets').select('*');
    ok(error);
    const statusOrder = { open: 0, in_progress: 1, resolved: 2 };
    return (data || []).map(mapTicket).sort((a, b) => {
      const so = statusOrder[a.status] - statusOrder[b.status];
      return so !== 0 ? so : new Date(b.createdAt) - new Date(a.createdAt);
    });
  },

  async getOpenTicketsCount() {
    const { count, error } = await supabase.from('tickets').select('*', { count: 'exact', head: true }).neq('status', 'resolved');
    ok(error);
    return count || 0;
  },

  async updateTicketStatus(id, status, adminNote) {
    if (!['open', 'in_progress', 'resolved'].includes(status)) throw new Error('حالة غير صحيحة');
    const { error } = await supabase.from('tickets').update({
      status, admin_note: (adminNote || '').trim(), resolved_at: status === 'resolved' ? new Date().toISOString() : null
    }).eq('id', id);
    ok(error);
    return true;
  },

  async deleteTicket(id) {
    const { error } = await supabase.from('tickets').delete().eq('id', id);
    ok(error);
    return true;
  },

  // ----- accessories -----------------------------------------------------------
  async addAccessory(name, price) {
    const pr = parseFloat(price);
    if (!name.trim() || isNaN(pr) || pr < 0) throw new Error('اسم القطعة والسعر مطلوبان');
    const { error } = await supabase.from('accessories').insert({ name: name.trim(), price: pr });
    ok(error);
    return true;
  },

  async getAllAccessories() {
    const { data, error } = await supabase.from('accessories').select('*').order('created_at', { ascending: false });
    ok(error);
    return (data || []).map(r => ({ id: r.id, name: r.name, price: parseFloat(r.price) || 0, createdAt: r.created_at }));
  },

  async updateAccessory(id, name, price) {
    const pr = parseFloat(price);
    if (!name.trim() || isNaN(pr) || pr < 0) throw new Error('اسم القطعة والسعر مطلوبان');
    const { error } = await supabase.from('accessories').update({ name: name.trim(), price: pr }).eq('id', id);
    ok(error);
    return true;
  },

  async deleteAccessory(id) {
    const { error } = await supabase.from('accessories').delete().eq('id', id);
    ok(error);
    return true;
  },

  async requestAccessory(unit, accessoryId, quantity) {
    const { data, error } = await supabase.rpc('request_accessory', { p_unit: unit, p_accessory_id: accessoryId, p_quantity: parseInt(quantity) });
    ok(error);
    return data;
  },

  async getMyAccessoryRequests(unit) {
    const { data, error } = await supabase.from('accessory_requests').select('*').eq('unit', unit.trim()).order('created_at', { ascending: false });
    ok(error);
    return (data || []).map(mapAccessoryRequest);
  },

  async getAllAccessoryRequests() {
    const { data, error } = await supabase.from('accessory_requests').select('*').order('created_at', { ascending: false });
    ok(error);
    return (data || []).map(mapAccessoryRequest);
  },

  async deliverAccessoryQuantity(id, deliveredQty) {
    const { data, error } = await supabase.rpc('deliver_accessory_quantity', { p_id: id, p_delivered_qty: parseInt(deliveredQty) });
    ok(error);
    return data;
  },

  async deleteAccessoryRequest(id) {
    const { error } = await supabase.from('accessory_requests').delete().eq('id', id);
    ok(error);
    return true;
  },

  async getAccessoriesParticipationReport() {
    const { data, error } = await supabase.rpc('get_accessories_participation_report');
    ok(error);
    const list = (data && data.didNotRequest) || [];
    return { didNotRequest: list.slice().sort(unitLocaleCompare) };
  },
};

function mapPaymentRequest(r) {
  return { id: r.id, unit: r.unit, amount: r.amount, paidBy: r.paid_by, reference: r.reference, status: r.status, rejectReason: r.reject_reason, createdAt: r.created_at, reviewedAt: r.reviewed_at };
}
function mapTicket(r) {
  return { id: r.id, unit: r.unit, title: r.title, description: r.description, status: r.status, adminNote: r.admin_note, createdAt: r.created_at, resolvedAt: r.resolved_at };
}
function mapAccessoryRequest(r) {
  const qty = parseInt(r.quantity) || 0;
  const delivered = parseInt(r.delivered_quantity) || 0;
  return { id: r.id, accessoryId: r.accessory_id, accessoryName: r.accessory_name, unit: r.unit, quantity: qty, unitPrice: r.unit_price, total: r.total_price, status: r.status, createdAt: r.created_at, deliveredAt: r.delivered_at, deliveredQuantity: delivered, remaining: qty - delivered };
}

// ============================================================================
// google.script.run compatible shim — lets the unmodified frontend code work
// against GAS_API above without touching a single google.script.run call site.
// ============================================================================
function createRunner(successHandler, failureHandler) {
  return new Proxy({}, {
    get(_target, prop) {
      if (prop === 'withSuccessHandler') return fn => createRunner(fn, failureHandler);
      if (prop === 'withFailureHandler') return fn => createRunner(successHandler, fn);
      return (...args) => {
        const fn = GAS_API[prop];
        if (!fn) {
          const err = new Error('Unknown server function: ' + String(prop));
          console.error(err);
          if (failureHandler) failureHandler(err);
          return;
        }
        Promise.resolve()
          .then(() => fn(...args))
          .then(result => { if (successHandler) successHandler(result); })
          .catch(err => {
            console.error(err);
            if (failureHandler) failureHandler({ message: err.message || String(err) });
          });
      };
    }
  });
}

window.google = { script: { run: createRunner(null, null) } };
