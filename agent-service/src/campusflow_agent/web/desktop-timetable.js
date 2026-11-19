(() => {
  if (document.documentElement.dataset.platform !== 'windows') return;
  const root = document.querySelector('#windowsTimetableRoot');
  if (!root) return;

  const weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
  const shanghai = new Intl.DateTimeFormat('en-CA', {
    timeZone: 'Asia/Shanghai', year: 'numeric', month: '2-digit', day: '2-digit',
  });
  const shanghaiTime = new Intl.DateTimeFormat('zh-CN', {
    timeZone: 'Asia/Shanghai', hour: '2-digit', minute: '2-digit', hourCycle: 'h23',
  });
  const timetablePath = '/api/v1/me/timetable';
  const json = (method, data) => ({method, headers: {'Content-Type': 'application/json'}, body: JSON.stringify(data)});
  const dateKey = (value = new Date()) => shanghai.format(value);
  const utcDate = value => new Date(`${value}T00:00:00Z`);
  const asKey = date => date.toISOString().slice(0, 10);
  const shiftDay = (value, count) => {
    const date = utcDate(value);
    date.setUTCDate(date.getUTCDate() + count);
    return asKey(date);
  };
  const monday = value => shiftDay(value, -((utcDate(value).getUTCDay() + 6) % 7));
  const shiftMonth = (value, count) => {
    const date = utcDate(value.slice(0, 7) + '-01');
    date.setUTCMonth(date.getUTCMonth() + count);
    return asKey(date);
  };
  const courseKey = value => JSON.stringify([
    value.date, value.title.trim(), value.start_time, value.end_time,
    value.location?.trim() ?? '', value.teacher?.trim() ?? '',
  ]);
  const overlaps = (left, right) => left.date === right.date &&
    left.start_time < right.end_time && right.start_time < left.end_time;
  const courseOrder = (left, right) => left.start_time.localeCompare(right.start_time) || left.title.localeCompare(right.title, 'zh-CN');
  const activeOwner = () => {
    const source = window.CampusFlowWindows?.user;
    return (typeof source === 'function' ? source() : source)?.user_id ?? '';
  };
  const current = ticket => Boolean(ticket && state === ticket && ticket.owner === activeOwner());
  const api = (...args) => window.CampusFlowWindows.api(...args);

  let state;
  root.innerHTML = `
    <header class="wt-header">
      <h1>课表与日历</h1>
      <div class="wt-actions">
        <button type="button" data-wt-action="import">导入课程</button>
        <button type="button" data-wt-action="create">添加课程</button>
        <button type="button" data-wt-action="save" class="wt-primary">保存课表</button>
      </div>
    </header>
    <div class="wt-feedback" aria-live="polite"><span data-wt="status"></span><button type="button" data-wt-action="refresh">刷新</button></div>
    <div class="wt-layout">
      <section class="wt-card wt-calendar" aria-label="课程与任务日历">
        <div class="wt-toolbar">
          <h2 data-wt="month"></h2>
          <div class="wt-actions">
            <button type="button" data-wt-action="week" aria-pressed="false">周</button>
            <button type="button" data-wt-action="month" aria-pressed="true">月</button>
            <button type="button" data-wt-action="today">今天</button>
            <button type="button" data-wt-action="prev" aria-label="上一期">‹</button>
            <button type="button" data-wt-action="next" aria-label="下一期">›</button>
          </div>
        </div>
        <div class="wt-weekdays" aria-hidden="true">${weekdays.map(day => `<span>${day}</span>`).join('')}</div>
        <div class="wt-days" data-wt="days"></div>
      </section>
      <section class="wt-card wt-agenda" aria-labelledby="wtAgendaTitle">
        <h2 id="wtAgendaTitle"></h2>
        <div data-wt="agenda"></div>
      </section>
    </div>
    <dialog class="wt-dialog" data-wt="editor" aria-labelledby="wtEditorTitle">
      <form data-wt="courseForm">
        <h2 id="wtEditorTitle">添加课程</h2>
        <div class="wt-fields">
          <label class="wt-wide">课程名称<input name="title" required maxlength="100"></label>
          <label class="wt-wide">日期<input name="date" type="date" required min="0001-01-01" max="9999-12-31"></label>
          <label>开始时间<input name="start_time" type="time" required></label>
          <label>结束时间<input name="end_time" type="time" required></label>
          <label>地点<input name="location" maxlength="120"></label>
          <label>教师<input name="teacher" maxlength="80"></label>
        </div>
        <p class="wt-dialog-note" data-wt="editorNote" aria-live="polite"></p>
        <div class="wt-actions wt-dialog-actions">
          <button type="button" data-wt-action="remove" class="wt-danger">从草稿移除</button>
          <button type="button" data-wt-action="closeEditor">取消</button>
          <button type="submit" class="wt-primary">应用到草稿</button>
        </div>
      </form>
    </dialog>
    <dialog class="wt-dialog wt-import" data-wt="importer" aria-labelledby="wtImportTitle">
      <div class="wt-toolbar"><h2 id="wtImportTitle">导入课程</h2><button type="button" data-wt-action="closeImport">关闭</button></div>
      <form data-wt="importForm" class="wt-import-form">
        <label>杭电助手课表订阅链接<input name="url" type="password" autocomplete="off" required maxlength="4096" placeholder="粘贴订阅地址"></label>
        <button type="submit">预览订阅</button>
      </form>
      <p class="wt-dialog-note" data-wt="importNote" aria-live="polite">选择核对过的课程后加入当前草稿。</p>
      <div data-wt="importRows" class="wt-import-rows"></div>
      <div class="wt-actions wt-dialog-actions"><button type="button" data-wt-action="importApply" class="wt-primary" disabled>加入草稿</button></div>
    </dialog>`;

  const ui = Object.fromEntries([...root.querySelectorAll('[data-wt]')].map(element => [element.dataset.wt, element]));
  const actions = Object.fromEntries([...root.querySelectorAll('[data-wt-action]')].map(element => [element.dataset.wtAction, element]));

  function createState(owner) {
    const pending = readPending(owner);
    return {
      owner, date: dateKey(), view: 'month', base: null, entries: pending?.entries ?? [], tasks: [], busy: false,
      dirty: false, stale: false, pending, status: pending ? '有一笔课表保存待核对。' : '', editIndex: -1, correcting: null, importRows: [],
      importing: false, importRequest: 0, taskError: false,
    };
  }

  const storageKey = owner => `campusflow.windows.timetable:${encodeURIComponent(owner)}`;

  function readPending(owner) {
    try {
      const value = JSON.parse(localStorage.getItem(storageKey(owner)) ?? 'null');
      return value && typeof value.operation_id === 'string' && Array.isArray(value.entries) ? value : null;
    } catch { return null; }
  }

  function remember(ticket, pending) {
    try {
      if (pending) localStorage.setItem(storageKey(ticket.owner), JSON.stringify(pending));
      else localStorage.removeItem(storageKey(ticket.owner));
    } catch {
      if (pending) return false;
    }
    ticket.pending = pending;
    return true;
  }

  function canEdit(ticket) {
    return Boolean(ticket.base && !ticket.busy && !ticket.pending && !ticket.stale);
  }

  function courseRows(ticket, date) {
    return ticket.entries.map((course, index) => ({...course, index}))
      .filter(course => course.date === date).sort(courseOrder);
  }

  function taskRows(ticket, date) {
    return ticket.tasks.filter(task => {
      if (!task.start_at) return false;
      const start = new Date(task.start_at);
      return Number.isFinite(start.getTime()) && dateKey(start) === date;
    }).sort((left, right) => Date.parse(left.start_at) - Date.parse(right.start_at));
  }

  function node(tag, label, className) {
    const element = document.createElement(tag);
    element.textContent = label;
    if (className) element.className = className;
    return element;
  }

  function paint(ticket) {
    ui.status.textContent = ticket.status || (ticket.dirty ? '有未保存的课程修改' : '');
    actions.save.disabled = ticket.busy || !ticket.pending && (!ticket.dirty || ticket.stale || !ticket.base);
    actions.save.textContent = ticket.pending ? '核对保存回执' : '保存课表';
    actions.refresh.disabled = ticket.busy || Boolean(ticket.pending);
    actions.create.disabled = actions.import.disabled = !canEdit(ticket);
    actions.month.setAttribute('aria-pressed', String(ticket.view === 'month'));
    actions.week.setAttribute('aria-pressed', String(ticket.view === 'week'));
    const [year, month, day] = ticket.date.split('-').map(Number);
    ui.month.textContent = `${year} 年 ${month} 月`;
    document.querySelector('#wtAgendaTitle').textContent = `${month} 月 ${day} 日 ${weekdays[(utcDate(ticket.date).getUTCDay() + 6) % 7]}`;
    const anchor = ticket.view === 'month' ? monday(ticket.date.slice(0, 7) + '-01') : monday(ticket.date);
    const count = ticket.view === 'month' ? 42 : 7;
    ui.days.replaceChildren();
    for (let index = 0; index < count; index += 1) {
      const value = shiftDay(anchor, index);
      const courses = courseRows(ticket, value).length;
      const tasks = taskRows(ticket, value).length;
      const button = node('button', '', 'wt-day');
      button.type = 'button';
      button.dataset.date = value;
      button.setAttribute('aria-label', `${value}，${courses} 节课，${tasks} 项待办`);
      button.setAttribute('aria-pressed', String(value === ticket.date));
      if (value === dateKey()) button.setAttribute('aria-current', 'date');
      button.classList.toggle('wt-other-month', value.slice(0, 7) !== ticket.date.slice(0, 7));
      button.append(node('strong', Number(value.slice(8))));
      if (courses) button.append(node('span', `${courses} 节课`, 'wt-course-count'));
      if (tasks) button.append(node('span', `${tasks} 项待办`, 'wt-task-count'));
      ui.days.append(button);
    }

    ui.agenda.replaceChildren();
    if (!ticket.base) {
      ui.agenda.append(node('p', '等待读取课程。', 'wt-muted'));
      return;
    }
    const courses = courseRows(ticket, ticket.date);
    const tasks = taskRows(ticket, ticket.date);
    if (!courses.length && !tasks.length) ui.agenda.append(node('p', '这天没有已安排的课程或待办。', 'wt-muted'));
    for (const course of courses) {
      const row = node('article', '', 'wt-row');
      row.append(node('span', `${course.start_time}–${course.end_time}`, 'wt-time'), node('strong', course.title));
      const description = [course.location, course.teacher].filter(Boolean).join(' · ');
      if (description) row.append(node('span', description, 'wt-muted'));
      const edit = node('button', '编辑课程');
      edit.type = 'button';
      edit.dataset.editCourse = course.index;
      edit.disabled = !canEdit(ticket);
      row.append(edit);
      ui.agenda.append(row);
    }
    for (const task of tasks) {
      const row = node('article', '', 'wt-row');
      row.append(node('span', task.start_at ? shanghaiTime.format(new Date(task.start_at)) : '全天', 'wt-time'),
        node('strong', task.title), node('span', task.status === 'completed' ? '待办 · 已完成' : '待办', 'wt-muted'));
      ui.agenda.append(row);
    }
    if (ticket.taskError) ui.agenda.append(node('p', '暂时未能读取待办，课程仍可查看。', 'wt-muted'));
  }

  async function reload(ticket, {showStatus = true} = {}) {
    ticket.busy = true;
    if (showStatus) ticket.status = '正在读取课程与待办…';
    paint(ticket);
    const [snapshot, planning] = await Promise.allSettled([
      api(timetablePath, {cache: 'no-store'}), api('/api/v1/planning', {cache: 'no-store'}),
    ]);
    if (!current(ticket)) return;
    ticket.busy = false;
    if (snapshot.status === 'fulfilled' && Array.isArray(snapshot.value?.entries) && snapshot.value.revision) {
      ticket.base = snapshot.value.revision;
      ticket.entries = ticket.pending?.entries ?? snapshot.value.entries;
      ticket.dirty = false;
      ticket.stale = false;
      if (showStatus) ticket.status = '';
    } else {
      ticket.status = snapshot.reason?.message ?? '暂时无法读取服务器课表。';
      ticket.stale = true;
    }
    ticket.taskError = planning.status === 'rejected';
    if (!ticket.taskError) ticket.tasks = planning.value?.tasks ?? [];
    paint(ticket);
  }

  async function submitSave(ticket, retry) {
    if (ticket.busy) return;
    if (!ticket.pending) {
      if (!ticket.dirty || !canEdit(ticket)) return;
      if (!ticket.entries.length && !window.confirm('保存后将清空服务器课表。继续保存吗？')) return;
      const operationId = window.CampusFlowWindows.uuid();
      const request = {entries: ticket.entries, expected_revision: ticket.base,
        operation_id: operationId, confirm_clear: ticket.entries.length === 0};
      if (!remember(ticket, request)) {
        ticket.status = '无法保存本机操作记录。请启用本地存储后重试。';
        paint(ticket);
        return;
      }
    }
    const request = ticket.pending;
    ticket.busy = true;
    ticket.status = retry ? '正在核对保存回执…' : '正在保存课程…';
    paint(ticket);
    try {
      let receipt;
      if (retry) {
        try { receipt = await api(`${timetablePath}/operations/${encodeURIComponent(request.operation_id)}`, {cache: 'no-store'}); }
        catch (error) {
          if (error.status !== 404) throw error;
        }
        if (!current(ticket)) return;
      }
      receipt ??= await api(timetablePath, json('PUT', request));
      if (!current(ticket)) return;
      if (receipt?.status !== 'applied' || receipt.operation_id !== request.operation_id ||
          receipt.previous_revision !== request.expected_revision || receipt.entry_count !== request.entries.length) {
        throw new Error('未收到匹配的保存回执。请再次核对。');
      }
      remember(ticket, null);
      ticket.status = '课表已保存。';
      await reload(ticket, {showStatus: false});
    } catch (error) {
      if (!current(ticket)) return;
      ticket.busy = false;
      if ([400, 409, 422].includes(error.status)) {
        remember(ticket, null);
        ticket.stale = error.status === 409;
        ticket.status = error.status === 409 ? '服务器课表已变化。已保留本页草稿，刷新后请重新核对。' : error.message;
      } else ticket.status = '暂未核实保存结果。请使用「核对保存回执」继续。';
      paint(ticket);
    }
  }

  function openEditor(ticket, index = -1, correctedIndex = null) {
    if (!canEdit(ticket)) return;
    const course = ticket.entries[index];
    ticket.editIndex = index;
    ticket.correcting = correctedIndex;
    ui.courseForm.reset();
    ui.courseForm.elements.date.value = course?.date ?? ticket.date;
    for (const key of ['title', 'start_time', 'end_time', 'location', 'teacher']) {
      ui.courseForm.elements[key].value = course?.[key] ?? '';
    }
    document.querySelector('#wtEditorTitle').textContent = course ? '编辑课程' : '添加课程';
    ui.editorNote.textContent = '';
    actions.remove.hidden = !course;
    ui.editor.showModal();
  }

  function changeDraft(ticket, entries) {
    ticket.entries = entries;
    ticket.dirty = true;
    ticket.status = '';
    paint(ticket);
  }

  function importEntry(result) {
    return result.corrected ?? result.row.entry;
  }

  function importClassification(entry, others) {
    if (!entry || others.some(course => courseKey(course) === courseKey(entry))) return '已有相同记录';
    if (others.some(course => overlaps(course, entry))) return '时间重叠';
    return '';
  }

  ui.courseForm.addEventListener('submit', event => {
    event.preventDefault();
    const ticket = state;
    if (!current(ticket) || !canEdit(ticket)) return;
    const entry = Object.fromEntries([...new FormData(ui.courseForm)].map(([key, value]) => [key, value.trim()]));
    if (!entry.title || entry.end_time <= entry.start_time) {
      ui.editorNote.textContent = '请填写课程名称，结束时间须晚于开始时间。';
      return;
    }
    if (ticket.correcting !== null) {
      const result = ticket.importRows[ticket.correcting];
      if (!result) return;
      const classification = importClassification(entry, ticket.entries);
      result.corrected = entry;
      result.status = classification === '已有相同记录' ? classification : '';
      result.overlap = classification === '时间重叠';
      result.selected = !classification;
      ui.editor.close();
      paintImportedRows(ticket);
      return;
    }
    const others = ticket.entries.filter((_, index) => index !== ticket.editIndex);
    if (others.some(course => courseKey(course) === courseKey(entry))) {
      ui.editorNote.textContent = '这条课程已在课表中。';
      return;
    }
    if (others.some(course => overlaps(course, entry)) && !window.confirm('这门课程与已有课程时间重叠。仍然加入草稿吗？')) return;
    const entries = [...ticket.entries];
    if (ticket.editIndex < 0) entries.push(entry);
    else entries[ticket.editIndex] = entry;
    ticket.date = entry.date;
    ui.editor.close();
    changeDraft(ticket, entries);
  });

  function resetImport(ticket) {
    ticket.importRequest += 1;
    ticket.importRows = [];
    ticket.importing = false;
    ui.importForm.reset();
    ui.importForm.querySelector('button').disabled = false;
    ui.importRows.replaceChildren();
    actions.importApply.disabled = true;
    ui.importNote.textContent = '选择核对过的课程后加入当前草稿。';
  }

  function renderImport(ticket, preview) {
    const seen = new Set(ticket.entries.map(courseKey));
    ticket.importRows = preview.rows.map(row => {
      if (row.status !== 'ready' || !row.entry) return {row, status: '需要手动核对', canCorrect: true};
      const key = courseKey(row.entry);
      if (seen.has(key)) return {row, status: '已有相同记录'};
      seen.add(key);
      return {row, overlap: ticket.entries.some(course => overlaps(course, row.entry))};
    });
    paintImportedRows(ticket);
    const warnings = preview.warnings?.join('；');
    ui.importNote.textContent = `${preview.calendar_name || '课表订阅'} · ${ticket.importRows.length} 条记录${warnings ? `。${warnings}` : ''}`;
  }

  function paintImportedRows(ticket) {
    ui.importRows.replaceChildren();
    for (const [index, result] of ticket.importRows.entries()) {
      const row = node('div', '', 'wt-import-row');
      const label = node('label', '');
      const input = document.createElement('input');
      input.type = 'checkbox';
      input.value = index;
      input.disabled = Boolean(result.status);
      input.checked = !result.status && (result.selected ?? !result.overlap);
      const value = importEntry(result) ?? result.row.input;
      const title = value?.title || `课程记录 ${index + 1}`;
      const time = value?.date ? `${value.date} ${value.start_time || ''}–${value.end_time || ''}` : '';
      const details = [time, value?.location, result.status, result.overlap && '与已有课程重叠',
        ...result.row.issues.map(issue => issue.message)].filter(Boolean).join(' · ');
      const copy = node('span', title);
      if (details) copy.append(node('small', details));
      label.append(input, copy);
      row.append(label);
      if (result.canCorrect) {
        const button = node('button', '修正');
        button.type = 'button';
        button.dataset.correctImport = index;
        row.append(button);
      }
      ui.importRows.append(row);
    }
    actions.importApply.disabled = !ui.importRows.querySelector('input:checked');
  }

  function updateImportedSelection() {
    const ticket = state;
    if (!current(ticket)) return;
    for (const input of ui.importRows.querySelectorAll('input')) {
      ticket.importRows[Number(input.value)].selected = input.checked;
    }
    actions.importApply.disabled = !ui.importRows.querySelector('input:checked');
  }

  ui.importForm.addEventListener('submit', async event => {
    event.preventDefault();
    const ticket = state;
    if (!current(ticket) || !canEdit(ticket) || ticket.importing) return;
    const button = ui.importForm.querySelector('button');
    const request = ++ticket.importRequest;
    ticket.importing = button.disabled = actions.importApply.disabled = true;
    ticket.importRows = [];
    ui.importRows.replaceChildren();
    ui.importNote.textContent = '正在读取课表订阅…';
    try {
      const preview = await api('/api/v1/schedule-subscriptions/preview', json('POST', {url: ui.importForm.elements.url.value.trim()}));
      if (current(ticket) && request === ticket.importRequest) renderImport(ticket, preview);
    } catch {
      if (current(ticket) && request === ticket.importRequest) ui.importNote.textContent = '无法预览订阅。请检查链接或稍后重试。';
    } finally {
      if (current(ticket) && request === ticket.importRequest) {
        ticket.importing = button.disabled = false;
        ui.importForm.elements.url.value = '';
      }
    }
  });

  ui.importRows.addEventListener('change', updateImportedSelection);
  ui.importer.addEventListener('close', () => { if (state) resetImport(state); });
  root.addEventListener('click', event => {
    const ticket = state;
    if (!ticket || !current(ticket)) return;
    const target = event.target.closest('button');
    if (!target) return;
    if (target.dataset.date) {
      ticket.date = target.dataset.date;
      paint(ticket);
      ui.days.querySelector(`[data-date="${ticket.date}"]`)?.focus();
      return;
    }
    if (target.dataset.editCourse) {
      openEditor(ticket, Number(target.dataset.editCourse));
      return;
    }
    if (target.dataset.correctImport && canEdit(ticket)) {
      const index = Number(target.dataset.correctImport);
      const result = ticket.importRows[index];
      openEditor(ticket, -1, index);
      const course = importEntry(result) ?? result.row.input;
      for (const key of ['date', 'title', 'start_time', 'end_time', 'location', 'teacher']) {
        ui.courseForm.elements[key].value = course?.[key] ?? '';
      }
      document.querySelector('#wtEditorTitle').textContent = '修正导入记录';
      ui.editorNote.textContent = '核对后仅加入当前日期的一次课程。';
      return;
    }
    switch (target.dataset.wtAction) {
      case 'create': openEditor(ticket); return;
      case 'closeEditor': ui.editor.close(); return;
      case 'remove':
        if (!canEdit(ticket) || ticket.editIndex < 0) return;
        changeDraft(ticket, ticket.entries.filter((_, index) => index !== ticket.editIndex));
        ui.editor.close(); return;
      case 'import': resetImport(ticket); ui.importer.showModal(); return;
      case 'closeImport': ui.importer.close(); return;
      case 'importApply': {
        if (!canEdit(ticket)) return;
        const entries = [...ui.importRows.querySelectorAll('input:checked')]
          .map(input => importEntry(ticket.importRows[Number(input.value)]));
        if (ticket.entries.length + entries.length > 500) {
          ui.importNote.textContent = '课表最多保存 500 条课程，请减少选择。';
          return;
        }
        if (entries.some((course, index) => importClassification(course, [...ticket.entries, ...entries.slice(0, index)]) === '已有相同记录')) {
          ui.importNote.textContent = '所选课程含相同记录，请取消重复项。';
          return;
        }
        if (entries.some((course, index) => importClassification(course, [...ticket.entries, ...entries.slice(0, index)]) === '时间重叠') &&
            !window.confirm('所选课程之间存在时间重叠。仍然加入草稿吗？')) return;
        changeDraft(ticket, [...ticket.entries, ...entries]);
        ui.importer.close(); return;
      }
      case 'save': void submitSave(ticket, Boolean(ticket.pending)); return;
      case 'refresh':
        if (!ticket.dirty || window.confirm('重新读取会舍弃本页尚未保存的课程修改。继续刷新吗？')) void reload(ticket);
        return;
      case 'today': ticket.date = dateKey(); break;
      case 'week': case 'month': ticket.view = target.dataset.wtAction; break;
      case 'prev': case 'next': {
        const step = target.dataset.wtAction === 'prev' ? -1 : 1;
        ticket.date = ticket.view === 'week' ? shiftDay(ticket.date, 7 * step) : shiftMonth(ticket.date, step);
        break;
      }
      default: return;
    }
    paint(ticket);
  });

  function onDesktopView(event) {
    const {tab, userId} = event.detail ?? {};
    const owner = userId ?? activeOwner();
    if (state && (state.owner !== owner || tab === 'logout')) {
      resetImport(state);
      if (ui.editor.open) ui.editor.close();
      if (ui.importer.open) ui.importer.close();
      state = undefined;
    }
    if (tab !== 'timetable' || !owner || !window.CampusFlowWindows) return;
    if (state?.dirty || state?.busy || state?.pending && state.base) return;
    state ??= createState(owner);
    void reload(state, {showStatus: !state.pending});
  }

  document.addEventListener('campusflow:desktop-view', onDesktopView);
})();
