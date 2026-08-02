(function () {
  const $ = id => document.getElementById(id);
  let filters = null;

  // The dashboard is IST by contract: from/to are Asia/Kolkata wall-clock.
  function istDate(s) {
    const [d, t = "00:00"] = s.split("T");
    return new Date(d + "T" + t + ":00+05:30");
  }

  function fmtIST(d) {
    const p = n => String(n).padStart(2, "0");
    return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}`;
  }

  async function getJSON(url) {
    const r = await fetch(url);
    const j = await r.json();
    if (!r.ok) throw new Error(j.error || r.statusText);
    return j;
  }

  // --- multi-select (checkbox dropdown) ------------------------------------
  function multiSelect(root, items, labelOf, allLabel, opts) {
    opts = opts || {};
    const sel = new Set();
    root.innerHTML = "";
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = "msel-btn";
    btn.textContent = allLabel;
    root.appendChild(btn);
    const panel = document.createElement("div");
    panel.className = "msel-panel";
    panel.hidden = true;
    const list = document.createElement("div");
    list.className = "msel-list";
    panel.appendChild(list);
    root.appendChild(panel);

    const addRow = (value, label) => {
      const lab = document.createElement("label");
      lab.className = "msel-row";
      const cb = document.createElement("input");
      cb.type = "checkbox";
      cb.value = value;
      cb.addEventListener("change", () => {
        if (cb.checked) sel.add(value); else sel.delete(value);
        btn.textContent = sel.size === 0 ? allLabel
          : `${sel.size} selected`;
        if (opts.onChange) opts.onChange();
      });
      const sp = document.createElement("span");
      sp.textContent = label;
      lab.appendChild(cb); lab.appendChild(sp);
      list.appendChild(lab);
    };
    const allRow = document.createElement("button");
    allRow.type = "button";
    allRow.className = "msel-all";
    allRow.textContent = allLabel;
    allRow.addEventListener("click", () => {
      sel.clear();
      list.querySelectorAll("input").forEach(cb => cb.checked = false);
      btn.textContent = allLabel;
      if (opts.onChange) opts.onChange();
    });
    panel.insertBefore(allRow, list);
    items.forEach(it => addRow(it.value, it.label));

    btn.addEventListener("click", () => {
      const willShow = panel.hidden;
      document.querySelectorAll(".msel-panel").forEach(p => p.hidden = true);
      panel.hidden = !willShow;
    });
    document.addEventListener("click", (e) => {
      if (!root.contains(e.target)) panel.hidden = true;
    });
    list.addEventListener("click", (e) => e.stopPropagation());

    root.getValue = () => {
      if (sel.size === 0) return "all";
      return [...sel].map(v => v === "" ? "__empty__" : v).join(",");
    };
    root.setValues = (vals) => {
      sel.clear();
      (vals || []).forEach(v => sel.add(v));
      list.querySelectorAll("input").forEach(cb => cb.checked = sel.has(cb.value));
      btn.textContent = sel.size === 0 ? allLabel : `${sel.size} selected`;
    };
    root.reset = () => root.setValues([]);
    return root;
  }

  async function initFilters() {
    try {
    filters = await getJSON("/api/filters");
    } catch (e) {
      throw e;
    }
    if (filters.sol) {
      const v = /v(\d)/.exec(filters.sol);
      if (v) $("sol-select").value = "v" + v[1];
    }
    multiSelect($("f-platform"), filters.platforms.map(v => ({ value: v, label: v })), p => p, "All platforms", { onChange: load });
    multiSelect($("f-country"), filters.countries.map(v => ({ value: v, label: v })), c => c, "All countries", { onChange: load });
    multiSelect($("f-vtype"), (filters.video_types || []).map(v => ({ value: v, label: v || "(unknown)" })), v => v, "All video types", { onChange: load });
    const contentSel = $("f-content");
    contentSel.innerHTML = "";
    const all = document.createElement("option"); all.value = "all"; all.textContent = "All contents"; contentSel.appendChild(all);
    (filters.contents || []).forEach(c => {
      const op = document.createElement("option");
      op.value = c.content_id; op.textContent = `${c.title} (${c.content_id})`;
      contentSel.appendChild(op);
    });
    const from = istDate(filters.day_min + "T00:00");
    const to = istDate(filters.day_max + "T23:59");
    $("f-from").value = fmtIST(from);
    $("f-to").value = fmtIST(to);
    if (filters.tz) $("tz-label").textContent = filters.tz.replace("Asia/Kolkata", "IST (Asia/Kolkata)");
    if (filters.cov_min) $("cov-label").textContent = `${filters.cov_min} → ${filters.cov_max} ${filters.tz || ""}`.trim();
    if (to - from <= 6 * 3600 * 1000) {
      $("f-grain-n").value = "1";
      $("f-grain-u").value = "m";
    }
  }

  function currentQuery() {
    const p = id => {
      const el = $(id);
      return el && el.getValue ? el.getValue() : (el ? el.value : "all");
    };
    return new URLSearchParams({
      from: p("f-from"), to: p("f-to"),
      grain: p("f-grain-n") + p("f-grain-u"),
      platform: p("f-platform"), country: p("f-country"),
      video_type: p("f-vtype"), content_id: p("f-content"),
    }).toString();
  }

  async function load() {
    const q = currentQuery();
    $("f-error").textContent = "loading…";
    try {
      const [kpis, series, bd, hm] = await Promise.all([
        getJSON("/api/kpis?" + q), getJSON("/api/series?" + q), getJSON("/api/breakdown?" + q),
        getJSON("/api/heatmap?" + q),
      ]);
      $("k-peak").textContent = kpis.peak_sessions.toLocaleString();
      $("k-peak-min").textContent = kpis.peak_minute || "";
      $("k-users").textContent = kpis.peak_users == null ? "—" : kpis.peak_users.toLocaleString();
      $("k-avg").textContent = kpis.avg_sessions.toLocaleString();
      $("k-latest").textContent = kpis.latest_sessions.toLocaleString();
      $("k-latest-min").textContent = kpis.latest_minute || "";
      $("k-open").textContent = kpis.open_sessions.toLocaleString();
      $("k-points").textContent = kpis.points;
      const src = $("src-label");
      if (src) {
        src.textContent = kpis.source === "hourly_kpis"
          ? "hourly snapshots (finalized)"
          : "minute_sessions (exact)";
      }
      // Earliest/latest timestamp actually loaded by this query.
      if (series.buckets && series.buckets.length) {
        const first = series.buckets[0];
        const last = series.buckets[series.buckets.length - 1];
        const hm = s => (s.length > 16 ? s.slice(11, 16) : s);
        $("cov-label").textContent = `${hm(first)} → ${hm(last)} IST`;
      }
      const labels = series.buckets.map(b => b.length > 16 ? b.slice(11, 16) : b);
      const seriesList = [
        { name: "sessions", color: "#FAFF69", values: series.sessions },
      ];
      if (series.users && series.users.some(v => v != null && v > 0)) {
        seriesList.push({ name: "users", color: "#ffd770", values: series.users });
      }
      ChartUI.drawLineChart($("c-series"), labels, seriesList, {
        onDecline: (d) => {
        },
      });
      ChartUI.drawSparkline($("c-spark"), series.sessions);
      ChartUI.drawBarChartH($("c-platform"), bd.by_platform.map(r => r.platform), bd.by_platform.map(r => r.peak));
      ChartUI.drawBarChart($("c-vtype"), bd.by_video_type.map(r => r.video_type), bd.by_video_type.map(r => r.peak));
      ChartUI.drawHeatmap($("c-heatmap"), hm.weekdays, hm.grid);
      const tb = $("t-content").querySelector("tbody");
      tb.innerHTML = bd.by_content.map(r =>
        `<tr><td>${escapeHtml(r.title)}</td><td>${r.peak.toLocaleString()}</td>` +
        `<td>${r.peak_minute ? escapeHtml(r.peak_minute.slice(11)) : "—"}</td></tr>`).join("");
      $("f-error").textContent = "";
    } catch (e) {
      $("f-error").textContent = "Error: " + e.message;
    }
  }

  function escapeHtml(s) {
    return String(s ?? "").replace(/[&<>"']/g, c => ({
      "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
    }[c]));
  }

  // Solution switcher: /v1/ and /v2/ are served by the same frontend.
  function currentSol() {
    const m = location.pathname.match(/^\/(v1|v2)\//);
    if (m) return m[1];
    // Root serves the default DB (CH_DB). Derive from the filters response
    // when available, else fall back to v2 (the primary solution).
    if (filters && filters.sol) {
      const v = /v(\d)/.exec(filters.sol);
      if (v) return "v" + v[1];
    }
    return "v2";
  }

  const solSel = $("sol-select");
  solSel.value = currentSol();
  document.body.dataset.sol = solSel.value;
  solSel.addEventListener("change", () => {
    const target = "/" + solSel.value + "/";
    if (location.pathname.startsWith(target)) return;
    location.href = target;
  });

  $("f-apply").addEventListener("click", load);
  ["f-grain-n", "f-grain-u", "f-content"].forEach(id =>
    $(id).addEventListener("change", load));

  initFilters().then(load).catch(e => { $("f-error").textContent = "Init error: " + e.message; });
})();
