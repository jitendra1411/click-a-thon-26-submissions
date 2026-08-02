/* Dependency-free canvas charts, clickpy-flavoured (yellow on near-black). */
(function () {
  const NICE = [1, 1.2, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10];
  const YELLOW = "#FAFF69";   // clickpy signature yellow
  const ORANGE = "#ffd770";   // secondary series (users)
  const GRID = "#343431";
  const MUTED = "#808691";
  const FG = "#f2f2f2";
  const CARD = "#181818";

  function setup(canvas, h) {
    const dpr = window.devicePixelRatio || 1;
    const w = canvas.clientWidth || 600;
    const ht = h || canvas.clientHeight || 160;
    canvas.width = w * dpr;
    canvas.height = ht * dpr;
    canvas.style.height = ht + "px";
    const ctx = canvas.getContext("2d");
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    return { ctx, w, h: ht };
  }

  function niceMax(v) {
    if (v <= 0) return 1;
    const exp = Math.floor(Math.log10(v));
    const base = Math.pow(10, exp);
    const f = v / base;
    let nice = NICE[NICE.length - 1];
    for (const n of NICE) { if (f <= n) { nice = n; break; } }
    return nice * base;
  }

  function fmtAxis(v) {
    if (v >= 1e6) return (v / 1e6).toFixed(v % 1e6 === 0 ? 0 : 1) + "M";
    if (v >= 1e3) return (v / 1e3).toFixed(v % 1e3 === 0 ? 0 : 1) + "k";
    return String(Math.round(v));
  }

  function truncate(s, n) {
    return s.length > n ? s.slice(0, n - 1) + "…" : s;
  }

  function gridLines(ctx, w, h, opts) {
    ctx.strokeStyle = opts.grid || GRID;
    ctx.fillStyle = opts.muted || MUTED;
    ctx.font = "10px system-ui";
    ctx.lineWidth = 1;
    ctx.beginPath();
    for (let i = 0; i <= opts.ticks; i++) {
      const y = opts.padT + (h - opts.padT - opts.padB) * (i / opts.ticks);
      ctx.moveTo(opts.padL, y);
      ctx.lineTo(w - opts.padR, y);
    }
    ctx.stroke();
    for (let i = 0; i <= opts.ticks; i++) {
      // max at the top (i=0), min at the bottom (i=ticks)
      const val = opts.maxV - (opts.maxV - opts.minV) * i / opts.ticks;
      const y = opts.padT + (h - opts.padT - opts.padB) * (i / opts.ticks);
      ctx.textAlign = "right";
      ctx.fillText(fmtAxis(val), opts.padL - 6, y + 3);
    }
  }

  /* Line chart with hover crosshair + tooltip. Returns { redraw, destroy }.
     labels: string[]; series: {name, color, values}[] */
  function drawLineChart(canvas, labels, series, opts) {
    opts = opts || {};
    const { ctx, w, h } = setup(canvas, opts.height || 150);
    const padL = 40, padR = 10, padT = 10, padB = 22;
    const H = { x: 0, hover: -1 };
    let maxV = 1;
    series.forEach(s => s.values.forEach(v => { if (v != null && v > maxV) maxV = v; }));
    maxV = niceMax(maxV);
    const X = i => padL + (w - padL - padR) * (labels.length <= 1 ? 0.5 : i / (labels.length - 1));
    const Y = v => padT + (h - padT - padB) * (1 - v / maxV);
    const fmtT = opts.fmtT || (i => labels[i]);
    // Detect a significant decline: current value has dropped > 40% from the
    // max seen in the previous `window` points (peak-decline popup).
    const declineWindow = opts.declineWindow || 6;
    const declinePct = opts.declinePct || 0.4;
    function declineAt(i, values) {
      if (i <= 0 || values[i] == null) return null;
      const lo = Math.max(0, i - declineWindow);
      let peak = 0;
      for (let j = lo; j < i; j++) if (values[j] != null && values[j] > peak) peak = values[j];
      if (peak <= 0) return null;
      const drop = (peak - values[i]) / peak;
      return drop >= declinePct ? { peak, drop } : null;
    }

    function render() {
      ctx.clearRect(0, 0, w, h);
      if (!labels.length) return;
      gridLines(ctx, w, h, { padL, padR, padT, padB, ticks: 4, minV: 0, maxV });
      series.forEach(s => {
        ctx.strokeStyle = s.color;
        ctx.lineWidth = 2;
        ctx.beginPath();
        s.values.forEach((v, i) => i ? ctx.lineTo(X(i), Y(v)) : ctx.moveTo(X(i), Y(v)));
        ctx.stroke();
        ctx.globalAlpha = 0.10;
        ctx.beginPath();
        s.values.forEach((v, i) => i ? ctx.lineTo(X(i), Y(v)) : ctx.moveTo(X(i), Y(v)));
        ctx.lineTo(X(s.values.length - 1), Y(0));
        ctx.lineTo(X(0), Y(0));
        ctx.closePath();
        ctx.fillStyle = s.color;
        ctx.fill();
        ctx.globalAlpha = 1;
      });
      // x labels: at most 6, evenly spaced
      ctx.fillStyle = MUTED;
      ctx.textAlign = "center";
      const step = Math.max(1, Math.ceil(labels.length / 6));
      for (let i = 0; i < labels.length; i += step) {
        ctx.fillText(labels[i], X(i), h - 7);
      }
      // legend
      series.forEach((s, si) => {
        const lx = padL + si * 120;
        ctx.fillStyle = s.color;
        ctx.fillRect(lx, 4, 10, 3);
        ctx.fillStyle = MUTED;
        ctx.textAlign = "left";
        ctx.fillText(s.name, lx + 14, 8);
      });
      // hover crosshair
      if (H.hover >= 0 && H.hover < labels.length) {
        const x = X(H.hover);
        ctx.strokeStyle = YELLOW;
        ctx.globalAlpha = 0.35;
        ctx.beginPath();
        ctx.moveTo(x, padT);
        ctx.lineTo(x, h - padB);
        ctx.stroke();
        ctx.globalAlpha = 1;
        series.forEach(s => {
          ctx.fillStyle = s.color;
          ctx.beginPath();
          ctx.arc(x, Y(s.values[H.hover]), 3, 0, Math.PI * 2);
          ctx.fill();
        });
      }
    }

    function onMove(e) {
      const r = canvas.getBoundingClientRect();
      const x = e.clientX - r.left;
      let idx = -1;
      if (labels.length) {
        idx = Math.round((x - padL) / (w - padL - padR) * (labels.length - 1));
        idx = Math.max(0, Math.min(labels.length - 1, idx));
      }
      H.hover = idx;
      render();
      const lines = series.map(s => s.name + ": " + (s.values[idx] == null ? "—" : s.values[idx].toLocaleString()));
      // Persistent, clickable decline notice: the tooltip is pointer-events:none
      // and redraws every mousemove, so it can never hold a working link.
      const sess = series.find(s => s.name === "sessions");
      const decl = sess ? declineAt(idx, sess.values) : null;
      if (opts.onDecline) opts.onDecline(decl ? {
        label: labels[idx], value: sess.values[idx],
        peak: decl.peak, drop: decl.drop,
      } : null);
      showTip(e, labels[idx] ? fmtT(idx) : "", lines);
    }
    function onLeave() {
      H.hover = -1; hideTip(); render();
      if (opts.onDecline) opts.onDecline(null);
    }

    canvas.addEventListener("mousemove", onMove);
    canvas.addEventListener("mouseleave", onLeave);
    render();
    return { redraw: render, destroy: () => {
      canvas.removeEventListener("mousemove", onMove);
      canvas.removeEventListener("mouseleave", onLeave);
    } };
  }

  /* Vertical bars (e.g. video type) with hover tooltip. */
  function drawBarChart(canvas, labels, values, opts) {
    opts = opts || {};
    const { ctx, w, h } = setup(canvas, opts.height || 150);
    const padL = 40, padR = 8, padT = 10, padB = 26;
    const H = { hover: -1 };
    const maxV = niceMax(Math.max(1, ...values));
    const n = labels.length;
    const gap = (w - padL - padR) / Math.max(1, n);
    const bw = Math.max(4, Math.min(30, gap * 0.62));
    const X = i => padL + i * gap + (gap - bw) / 2;
    const BH = v => (h - padT - padB) * (v / maxV);

    function render() {
      ctx.clearRect(0, 0, w, h);
      gridLines(ctx, w, h, { padL, padR, padT, padB, ticks: 3, minV: 0, maxV });
      labels.forEach((lab, i) => {
        const x = X(i);
        ctx.fillStyle = H.hover === i ? "#FDFF88" : YELLOW;
        ctx.globalAlpha = H.hover === i ? 1 : 0.85;
        ctx.fillRect(x, h - padB - BH(values[i]), bw, BH(values[i]));
        ctx.globalAlpha = 1;
        ctx.fillStyle = MUTED;
        ctx.textAlign = "center";
        ctx.font = "10px system-ui";
        ctx.save();
        ctx.translate(x + bw / 2, h - padB + 5);
        ctx.rotate(-Math.PI / 4);
        ctx.textAlign = "right";
        ctx.fillText(truncate(String(lab), 18), 0, 0);
        ctx.restore();
      });
    }

    function onMove(e) {
      const r = canvas.getBoundingClientRect();
      const x = e.clientX - r.left;
      const i = Math.floor((x - padL) / gap);
      H.hover = i >= 0 && i < n ? i : -1;
      render();
      if (H.hover >= 0) {
        showTip(e, truncate(String(labels[H.hover]), 24), ["peak: " + values[H.hover].toLocaleString()]);
      } else hideTip();
    }
    function onLeave() { H.hover = -1; hideTip(); render(); }
    canvas.addEventListener("mousemove", onMove);
    canvas.addEventListener("mouseleave", onLeave);
    render();
    return { redraw: render, destroy: () => {
      canvas.removeEventListener("mousemove", onMove);
      canvas.removeEventListener("mouseleave", onLeave);
    } };
  }

  /* Horizontal bars (platforms) with hover highlight + value readout. */
  function drawBarChartH(canvas, labels, values, opts) {
    opts = opts || {};
    const { ctx, w, h } = setup(canvas, opts.height || 150);
    const H = { hover: -1 };
    const padL = Math.min(150, Math.max(86, (Math.max(...labels.map(l => String(l).length)) * 7) + 18));
    const padR = 56, padT = 6, padB = 6;
    const maxV = niceMax(Math.max(1, ...values));
    const n = labels.length;
    const rowH = (h - padT - padB) / Math.max(1, n);
    const barH = Math.max(3, Math.min(30, rowH * 0.72));
    const Y = i => padT + i * rowH + (rowH - barH) / 2;

    function render() {
      ctx.clearRect(0, 0, w, h);
      ctx.font = "10px system-ui";
      labels.forEach((lab, i) => {
        const y = Y(i);
        ctx.fillStyle = H.hover === i ? "#FDFF88" : YELLOW;
        ctx.globalAlpha = H.hover === i ? 1 : 0.88;
        const bw = (w - padL - padR) * (values[i] / maxV);
        ctx.fillRect(padL, y, Math.max(1, bw), barH);
        ctx.globalAlpha = 1;
        ctx.fillStyle = H.hover === i ? FG : MUTED;
        ctx.textAlign = "right";
        ctx.fillText(truncate(String(lab), 24), padL - 8, y + barH / 2 + 3);
        ctx.fillStyle = MUTED;
        ctx.textAlign = "left";
        ctx.fillText(fmtAxis(values[i]), padL + Math.max(1, bw) + 6, y + barH / 2 + 3);
      });
    }

    function onMove(e) {
      const r = canvas.getBoundingClientRect();
      const y = e.clientY - r.top;
      const i = Math.floor((y - padT) / rowH);
      H.hover = i >= 0 && i < n ? i : -1;
      render();
      if (H.hover >= 0) {
        showTip(e, truncate(String(labels[H.hover]), 24), ["peak: " + values[H.hover].toLocaleString()]);
      } else hideTip();
    }
    function onLeave() { H.hover = -1; hideTip(); render(); }
    canvas.addEventListener("mousemove", onMove);
    canvas.addEventListener("mouseleave", onLeave);
    render();
    return { redraw: render, destroy: () => {
      canvas.removeEventListener("mousemove", onMove);
      canvas.removeEventListener("mouseleave", onLeave);
    } };
  }

  /* clickpy punch-card: rows = weekdays, cols = hours. */
  function drawHeatmap(canvas, weekdays, grid, opts) {
    opts = opts || {};
    const { ctx, w, h } = setup(canvas, opts.height || 190);
    const padL = 34, padR = 8, padT = 16, padB = 20;
    const maxV = Math.max(1, ...grid.flat());
    const scale = opts.scale || "sqrt";
    const cw = (w - padL - padR) / 24;
    const ch = (h - padT - padB) / 7;
    const CELL = (v) => {
      const t = scale === "linear" ? v / maxV : Math.sqrt(v / maxV);
      const r = Math.round(0xFA + (0xFF - 0xFA) * t);
      const g = Math.round(0xFF * t);
      const b = Math.round(0x69 + (0x88 - 0x69) * t);
      return `rgb(${r},${g},${b})`;
    };

    function render() {
      ctx.clearRect(0, 0, w, h);
      ctx.font = "10px system-ui";
      ctx.textAlign = "right";
      weekdays.forEach((d, i) => {
        ctx.fillStyle = MUTED;
        ctx.fillText(d, padL - 6, padT + i * ch + ch / 2 + 3);
        for (let hr = 0; hr < 24; hr++) {
          const v = grid[i][hr] || 0;
          ctx.fillStyle = CELL(v);
          ctx.fillRect(padL + hr * cw + 1, padT + i * ch + 1, cw - 2, ch - 2);
        }
      });
      ctx.textAlign = "center";
      ctx.fillStyle = MUTED;
      [0, 6, 12, 18, 23].forEach(hr => {
        ctx.fillText(String(hr).padStart(2, "0") + ":00", padL + hr * cw + cw / 2, h - 6);
      });
      ctx.textAlign = "left";
      ctx.fillStyle = MUTED;
      ctx.fillText(scale + " scale · peak " + fmtAxis(maxV), padL + 2, padT - 5);
    }

    function onMove(e) {
      const r = canvas.getBoundingClientRect();
      const x = e.clientX - r.left;
      const y = e.clientY - r.top;
      const hr = Math.floor((x - padL) / cw);
      const dow = Math.floor((y - padT) / ch);
      if (hr >= 0 && hr < 24 && dow >= 0 && dow < 7) {
        const v = grid[dow][hr] || 0;
        showTip(e, weekdays[dow] + " " + String(hr).padStart(2, "0") + ":00", ["peak sessions: " + v.toLocaleString()]);
      } else hideTip();
    }
    canvas.addEventListener("mousemove", onMove);
    canvas.addEventListener("mouseleave", hideTip);
    render();
    return { redraw: render, destroy: () => {
      canvas.removeEventListener("mousemove", onMove);
      canvas.removeEventListener("mouseleave", hideTip);
    } };
  }

  function drawSparkline(canvas, values, opts) {
    opts = opts || {};
    const { ctx, w, h } = setup(canvas, opts.height || 34);
    if (!values.length) return;
    const maxV = niceMax(Math.max(1, ...values));
    const X = i => (w - 2) * (values.length <= 1 ? 0.5 : i / (values.length - 1)) + 1;
    const Y = v => h - 3 - (h - 6) * (v / maxV);
    ctx.clearRect(0, 0, w, h);
    ctx.strokeStyle = YELLOW;
    ctx.lineWidth = 1.4;
    ctx.beginPath();
    values.forEach((v, i) => i ? ctx.lineTo(X(i), Y(v)) : ctx.moveTo(X(i), Y(v)));
    ctx.stroke();
    ctx.globalAlpha = 0.18;
    ctx.beginPath();
    values.forEach((v, i) => i ? ctx.lineTo(X(i), Y(v)) : ctx.moveTo(X(i), Y(v)));
    ctx.lineTo(X(values.length - 1), h - 3);
    ctx.lineTo(X(0), h - 3);
    ctx.closePath();
    ctx.fillStyle = YELLOW;
    ctx.fill();
    ctx.globalAlpha = 1;
  }

  const tip = document.createElement("div");
  tip.id = "chart-tip";
  tip.style.cssText = "position:fixed;z-index:50;display:none;pointer-events:none;" +
    "background:#181818;border:1px solid #3a3a3a;border-radius:6px;color:#f2f2f2;" +
    "font:12px ui-sans-serif,system-ui,sans-serif;padding:7px 10px;box-shadow:0 4px 16px rgba(0,0,0,.55);max-width:320px;";
  document.body.appendChild(tip);
  function showTip(e, title, lines) {
    const bits = [];
    if (title) bits.push("<b style='color:#FAFF69'>" + title + "</b>");
    lines.forEach(l => bits.push("<span style='color:#c9c9c9'>" + l + "</span>"));
    tip.innerHTML = bits.join("<br>");
    tip.style.display = "block";
    const tw = tip.offsetWidth, th = tip.offsetHeight;
    let x = e.clientX + 14, y = e.clientY + 14;
    if (x + tw > window.innerWidth - 8) x = e.clientX - tw - 14;
    if (y + th > window.innerHeight - 8) y = e.clientY - th - 14;
    tip.style.left = x + "px";
    tip.style.top = y + "px";
  }
  function hideTip() { tip.style.display = "none"; }

  window.ChartUI = { drawLineChart, drawBarChart, drawBarChartH, drawHeatmap, drawSparkline, hideTip };
})();
