// Image Renamer — modernized macOS UI prototype
// Original design; not a recreation of any branded/proprietary UI.

const { useState, useEffect, useRef, useMemo, useCallback } = React;

// ---------- Mock content for the active-image preview ----------
const MOCK_QUEUE = [
  { id: 1, name: "IMG_2471.HEIC",          size: "3.2 MB", caption: "a golden retriever sitting on a wooden dock at sunset",     proposed: "golden-retriever-dock-sunset",            swatch: ["#E8B66A", "#6E3A16", "#F1D9A8"] },
  { id: 2, name: "IMG_2472.HEIC",          size: "4.1 MB", caption: "two espresso cups on a marble counter with scattered beans", proposed: "two-espresso-cups-marble-counter",        swatch: ["#3E2B22", "#E7DCCB", "#8A5A40"] },
  { id: 3, name: "DSC_0481.JPG",           size: "5.8 MB", caption: "a narrow cobblestone street in a mediterranean village",     proposed: "cobblestone-street-mediterranean",        swatch: ["#C9B28A", "#7B6850", "#EFE6D3"] },
  { id: 4, name: "DSC_0482.JPG",           size: "6.0 MB", caption: "a mountain lake reflecting pine trees at dawn",              proposed: "mountain-lake-pine-reflection",           swatch: ["#4E6E7A", "#1B2B2E", "#B8CDD2"] },
  { id: 5, name: "Screenshot 2025-12-29.png", size: "820 KB", caption: "a minimalist dashboard with charts on a dark background",  proposed: "minimalist-dashboard-dark-charts",        swatch: ["#111418", "#7A8CF7", "#E5E7EB"] },
  { id: 6, name: "IMG_2490.HEIC",          size: "2.9 MB", caption: "a stack of vintage hardcover books on a reading desk",       proposed: "vintage-hardcover-books-desk",            swatch: ["#6B2F27", "#D9C28F", "#2E1E18"] },
  { id: 7, name: "IMG_2491.HEIC",          size: "3.5 MB", caption: "a bicycle leaning on a pastel pink wall with ivy",           proposed: "bicycle-pastel-pink-wall-ivy",            swatch: ["#F0B9B0", "#5F8A4B", "#E7D9D3"] },
  { id: 8, name: "IMG_2492.HEIC",          size: "4.4 MB", caption: "a bowl of ramen with soft egg and green onions",             proposed: "ramen-bowl-soft-egg-onions",              swatch: ["#C95A3B", "#F2D774", "#2A1E18"] },
  { id: 9, name: "DSC_0501.JPG",           size: "7.1 MB", caption: "foggy redwood forest with light beams through branches",     proposed: "foggy-redwood-forest-light-beams",        swatch: ["#3A4A3A", "#B4A478", "#DDE2D4"] },
  { id: 10, name: "DSC_0502.JPG",          size: "5.3 MB", caption: "a ceramic teapot and two cups on a wooden tray",             proposed: "ceramic-teapot-wooden-tray",              swatch: ["#D7C9A8", "#6B4A2B", "#F4ECD8"] },
  { id: 11, name: "IMG_2500.HEIC",         size: "3.8 MB", caption: "a surfer walking towards the ocean at blue hour",            proposed: "surfer-ocean-blue-hour",                  swatch: ["#1F3A58", "#E8A96B", "#0C1A2A"] },
  { id: 12, name: "IMG_2501.HEIC",         size: "4.0 MB", caption: "a modern concrete staircase with linear shadows",            proposed: "concrete-staircase-linear-shadows",       swatch: ["#BEB8AE", "#3C3A37", "#EAE6E0"] },
];

const LANGUAGES = [
  { id: "english", label: "English", flag: "EN" },
  { id: "french",  label: "French",  flag: "FR" },
  { id: "spanish", label: "Spanish", flag: "ES" },
  { id: "german",  label: "German",  flag: "DE" },
];

const ENGINES = [
  { id: "ollama", label: "Ollama",     hint: "Local inference via Ollama server",   needsServer: true },
  { id: "openai", label: "OpenAI API", hint: "OpenAI-compatible endpoint",          needsServer: true },
  { id: "coreml", label: "Core ML",    hint: "On-device Apple Silicon model",       needsServer: false },
];

const MODELS_BY_ENGINE = {
  ollama: ["llava:13b", "llava:7b", "llava-llama3:8b", "bakllava:7b", "moondream:1.8b"],
  openai: ["gpt-4o", "gpt-4o-mini", "gpt-4-vision-preview"],
  coreml: ["FastViT-T8 (bundled)", "MobileCLIP-S0 (bundled)"],
};

// ---------- Small primitives ----------
function Segmented({ value, onChange, options, dense }) {
  return (
    <div className={`seg ${dense ? "seg--dense" : ""}`} role="tablist">
      {options.map((opt) => (
        <button
          key={opt.id}
          role="tab"
          aria-selected={value === opt.id}
          className={`seg__item ${value === opt.id ? "is-active" : ""}`}
          onClick={() => onChange(opt.id)}
        >
          {opt.flag && <span className="seg__flag">{opt.flag}</span>}
          {opt.label}
        </button>
      ))}
    </div>
  );
}

function Field({ label, hint, children, align = "center" }) {
  return (
    <div className={`field field--${align}`}>
      <div className="field__label">
        <span>{label}</span>
        {hint && <span className="field__hint">{hint}</span>}
      </div>
      <div className="field__control">{children}</div>
    </div>
  );
}

function Icon({ name, size = 16 }) {
  const s = size;
  const props = { width: s, height: s, viewBox: "0 0 24 24", fill: "none", stroke: "currentColor", strokeWidth: 1.6, strokeLinecap: "round", strokeLinejoin: "round" };
  const paths = {
    folder:   <><path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/></>,
    image:    <><rect x="3" y="4" width="18" height="16" rx="2"/><circle cx="9" cy="10" r="1.6"/><path d="m21 16-5-5-8 8"/></>,
    sparkle:  <><path d="M12 3v4M12 17v4M3 12h4M17 12h4M6.3 6.3l2.8 2.8M14.9 14.9l2.8 2.8M17.7 6.3l-2.8 2.8M9.1 14.9l-2.8 2.8"/></>,
    stop:     <><rect x="5" y="5" width="14" height="14" rx="2"/></>,
    play:     <><path d="M7 4.5v15l13-7.5z"/></>,
    refresh:  <><path d="M3 12a9 9 0 1 0 3-6.7"/><path d="M3 4v5h5"/></>,
    globe:    <><circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3a14 14 0 0 1 0 18M12 3a14 14 0 0 0 0 18"/></>,
    check:    <><path d="m5 12 5 5 9-11"/></>,
    link:     <><path d="M10 14a5 5 0 0 0 7 0l3-3a5 5 0 0 0-7-7l-1 1"/><path d="M14 10a5 5 0 0 0-7 0l-3 3a5 5 0 0 0 7 7l1-1"/></>,
    dot:      <><circle cx="12" cy="12" r="4"/></>,
    spark2:   <><path d="M12 2l1.8 5.7L19.5 9l-4.7 3.4L16.6 18 12 14.8 7.4 18l1.8-5.6L4.5 9l5.7-1.3z"/></>,
    cog:      <><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3h.1a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8v.1a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z"/></>,
    chevron:  <><path d="m6 9 6 6 6-6"/></>,
    terminal: <><path d="m4 7 5 5-5 5"/><path d="M12 19h8"/></>,
    close:    <><path d="M6 6l12 12M18 6 6 18"/></>,
    lock:     <><rect x="5" y="11" width="14" height="9" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/></>,
    clock:    <><circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/></>,
    zap:      <><path d="M13 2 3 14h7l-1 8 10-12h-7z"/></>,
  };
  return <svg {...props} aria-hidden="true">{paths[name]}</svg>;
}

// ---------- Main App ----------
function ImageRenamerApp({ tweaks, onTweaksChange }) {
  const [engine, setEngine]       = useState("ollama");
  const [language, setLanguage]   = useState("english");
  const [translation, setTranslation] = useState("ai");
  const [model, setModel]         = useState("llava:13b");
  const [server, setServer]       = useState("http://127.0.0.1:11434");
  const [connected, setConnected] = useState(true);
  const [connecting, setConnecting] = useState(false);
  const [force, setForce]         = useState(false);
  const [showDebug, setShowDebug] = useState(false);

  const [folder, setFolder]       = useState("~/Pictures/Iceland Trip 2025");
  const [queue, setQueue]         = useState(MOCK_QUEUE);
  const [processingIndex, setProcessingIndex] = useState(-1);
  const [doneIds, setDoneIds]     = useState(new Set());
  const [status, setStatus]       = useState({ id: 0, text: "" });

  const isProcessing = processingIndex >= 0;
  const total = queue.length;
  const processed = doneIds.size;
  const percent = total > 0 ? Math.round((processed / total) * 100) : 0;

  const current = processingIndex >= 0 ? queue[processingIndex] : null;
  const lastDone = useMemo(() => {
    const ids = [...doneIds];
    return ids.length ? queue.find((q) => q.id === ids[ids.length - 1]) : null;
  }, [doneIds, queue]);

  // Engine change -> update model list + server placeholder
  useEffect(() => {
    const list = MODELS_BY_ENGINE[engine];
    setModel(list[0]);
    if (engine === "ollama")  setServer("http://127.0.0.1:11434");
    if (engine === "openai")  setServer("http://localhost:8887");
  }, [engine]);

  // Mock processing loop
  const procRef = useRef(null);
  useEffect(() => {
    if (processingIndex < 0) return;
    const item = queue[processingIndex];
    if (!item) { setProcessingIndex(-1); return; }

    setStatus({ id: item.id, text: "Encoding image…" });
    const timers = [];
    timers.push(setTimeout(() => setStatus({ id: item.id, text: "Running vision model…" }), 450));
    timers.push(setTimeout(() => setStatus({ id: item.id, text: "Sanitizing filename…" }), 1100));
    timers.push(setTimeout(() => {
      setDoneIds((s) => new Set(s).add(item.id));
      if (processingIndex + 1 < queue.length) {
        setProcessingIndex(processingIndex + 1);
      } else {
        setProcessingIndex(-1);
        setStatus({ id: 0, text: "Batch complete." });
      }
    }, 1600));
    procRef.current = timers;
    return () => timers.forEach(clearTimeout);
  }, [processingIndex]);

  const startRename = () => {
    setDoneIds(new Set());
    setProcessingIndex(0);
  };
  const stopRename = () => {
    procRef.current?.forEach(clearTimeout);
    setProcessingIndex(-1);
    setStatus({ id: 0, text: "Stopped by user." });
  };
  const resetQueue = () => {
    setDoneIds(new Set());
    setProcessingIndex(-1);
    setStatus({ id: 0, text: "" });
  };

  const handleConnect = () => {
    setConnecting(true);
    setConnected(false);
    setTimeout(() => { setConnecting(false); setConnected(true); }, 900);
  };

  const selectFolder = () => {
    // mock folder picker
    const options = [
      { path: "~/Pictures/Iceland Trip 2025", n: 12 },
      { path: "~/Downloads/camera-roll-oct", n: 47 },
      { path: "~/Desktop/scans",              n: 6 },
    ];
    const next = options[(options.findIndex((o) => o.path === folder) + 1) % options.length];
    setFolder(next.path);
    resetQueue();
  };

  const modelList = MODELS_BY_ENGINE[engine];
  const engineMeta = ENGINES.find((e) => e.id === engine);

  return (
    <div className="app" data-density={tweaks.density} data-layout={tweaks.layout}>
      <Sidebar
        engine={engine} setEngine={setEngine}
        language={language} setLanguage={setLanguage}
        translation={translation} setTranslation={setTranslation}
        model={model} setModel={setModel} modelList={modelList}
        server={server} setServer={setServer}
        connected={connected} connecting={connecting}
        onConnect={handleConnect}
        engineMeta={engineMeta}
        folder={folder} onSelectFolder={selectFolder}
        force={force} setForce={setForce}
        isProcessing={isProcessing}
        onStart={startRename} onStop={stopRename}
        total={total} processed={processed}
      />
      <Workspace
        folder={folder}
        queue={queue}
        processingIndex={processingIndex}
        doneIds={doneIds}
        current={current}
        lastDone={lastDone}
        status={status}
        isProcessing={isProcessing}
        percent={percent}
        total={total}
        processed={processed}
        language={language}
        showDebug={showDebug}
        setShowDebug={setShowDebug}
        engine={engine}
      />
    </div>
  );
}

// ---------- Sidebar ----------
function Sidebar(props) {
  const {
    engine, setEngine,
    language, setLanguage,
    translation, setTranslation,
    model, setModel, modelList,
    server, setServer,
    connected, connecting, onConnect,
    engineMeta,
    folder, onSelectFolder,
    force, setForce,
    isProcessing,
    onStart, onStop,
    total, processed,
  } = props;

  const canRun = total > 0 && processed < total && !isProcessing;

  return (
    <aside className="rail">
      <header className="rail__header">
        <div className="rail__mark" aria-hidden="true">
          <Icon name="spark2" size={18}/>
        </div>
        <div className="rail__title">
          <div className="rail__app">Image Renamer</div>
          <div className="rail__sub">Vision-powered renaming</div>
        </div>
      </header>

      <section className="rail__section">
        <div className="rail__section-title">Inference</div>

        <Field label="Engine">
          <div className="engine-grid">
            {ENGINES.map((e) => (
              <button
                key={e.id}
                className={`engine ${engine === e.id ? "is-active" : ""}`}
                onClick={() => setEngine(e.id)}
              >
                <span className="engine__label">{e.label}</span>
                <span className="engine__hint">{e.hint}</span>
              </button>
            ))}
          </div>
        </Field>

        <Field label="Model">
          <div className="select">
            <select value={model} onChange={(e) => setModel(e.target.value)}>
              {modelList.map((m) => <option key={m} value={m}>{m}</option>)}
            </select>
            <Icon name="chevron" size={14}/>
          </div>
          <button className="btn btn--ghost btn--icon-only" title="Refresh models" aria-label="Refresh models">
            <Icon name="refresh" size={15}/>
          </button>
        </Field>

        {engineMeta.needsServer && (
          <Field label="Server" align="start">
            <div className="server">
              <div className={`server__input ${connected ? "is-ok" : ""}`}>
                <span className={`dot ${connecting ? "dot--pulse" : connected ? "dot--ok" : "dot--warn"}`}/>
                <input
                  value={server}
                  onChange={(e) => { setServer(e.target.value); }}
                  spellCheck={false}
                  autoCapitalize="off"
                />
                <button className="server__test" onClick={onConnect} disabled={connecting}>
                  {connecting ? "Connecting…" : connected ? "Connected" : "Connect"}
                </button>
              </div>
            </div>
          </Field>
        )}
      </section>

      <section className="rail__section">
        <div className="rail__section-title">Output language</div>
        <div className="lang-grid">
          {LANGUAGES.map((l) => (
            <button
              key={l.id}
              className={`lang ${language === l.id ? "is-active" : ""}`}
              onClick={() => setLanguage(l.id)}
            >
              <span className="lang__flag">{l.flag}</span>
              <span className="lang__label">{l.label}</span>
            </button>
          ))}
        </div>

        <Field label="Translator">
          <Segmented
            value={translation}
            onChange={setTranslation}
            options={[
              { id: "ai",    label: "AI model" },
              { id: "apple", label: "Apple Translate" },
            ]}
          />
        </Field>
      </section>

      <section className="rail__section rail__section--tight">
        <div className="rail__section-title">Source</div>
        <button className="folder" onClick={onSelectFolder}>
          <div className="folder__icon"><Icon name="folder" size={18}/></div>
          <div className="folder__body">
            <div className="folder__path" title={folder}>{folder}</div>
            <div className="folder__meta">
              <span>{total} images</span>
              <span className="folder__dot">·</span>
              <span>HEIC, JPG, PNG</span>
            </div>
          </div>
          <div className="folder__chev"><Icon name="chevron" size={14}/></div>
        </button>

        <label className="check">
          <input type="checkbox" checked={force} onChange={(e) => setForce(e.target.checked)} />
          <span className="check__box"><Icon name="check" size={12}/></span>
          <span className="check__label">
            Force rename
            <span className="check__hint">Re-run on files already renamed</span>
          </span>
        </label>
      </section>

      <div className="rail__spacer"/>

      <footer className="rail__footer">
        {isProcessing ? (
          <button className="btn btn--stop" onClick={onStop}>
            <Icon name="stop" size={14}/> Stop
          </button>
        ) : (
          <button className="btn btn--primary" onClick={onStart} disabled={!canRun}>
            <Icon name="sparkle" size={14}/> Rename {total} {total === 1 ? "image" : "images"}
          </button>
        )}
        <div className="rail__footer-hint">
          {processed > 0 && !isProcessing && `${processed}/${total} renamed — press to run remaining`}
          {processed === 0 && !isProcessing && "Runs locally — nothing leaves your Mac"}
          {isProcessing && "Working… you can stop at any time"}
        </div>
      </footer>
    </aside>
  );
}

// ---------- Workspace (right side) ----------
function Workspace(props) {
  const {
    folder, queue, processingIndex, doneIds, current, lastDone,
    status, isProcessing, percent, total, processed,
    language, showDebug, setShowDebug, engine,
  } = props;

  const focus = current || lastDone || queue[0];
  const focusState = current
    ? "processing"
    : (lastDone && processed === total)
      ? "done"
      : lastDone ? "recent" : "idle";

  return (
    <main className="workspace">
      <WorkspaceHeader
        folder={folder}
        total={total}
        processed={processed}
        isProcessing={isProcessing}
        percent={percent}
      />

      <div className="workspace__grid">
        <FocusPanel
          item={focus}
          state={focusState}
          status={status}
          language={language}
          engine={engine}
        />
        <QueuePanel
          queue={queue}
          processingIndex={processingIndex}
          doneIds={doneIds}
          total={total}
          processed={processed}
        />
      </div>

      <DebugStrip show={showDebug} setShow={setShowDebug} status={status}/>
    </main>
  );
}

function WorkspaceHeader({ folder, total, processed, isProcessing, percent }) {
  return (
    <div className="wsh">
      <div className="wsh__crumb">
        <Icon name="folder" size={14}/>
        <span className="wsh__root">Pictures</span>
        <span className="wsh__sep">/</span>
        <span className="wsh__leaf">{folder.split("/").pop()}</span>
      </div>

      <div className="wsh__progress">
        <div className="wsh__progress-track">
          <div
            className={`wsh__progress-fill ${isProcessing ? "is-animated" : ""}`}
            style={{ width: `${percent}%` }}
          />
        </div>
        <div className="wsh__progress-text">
          <span className="wsh__progress-num">{processed}</span>
          <span className="wsh__progress-den">/ {total}</span>
          <span className="wsh__progress-pct">· {percent}%</span>
        </div>
      </div>
    </div>
  );
}

// ---------- Focus (currently/last processed image) ----------
function FocusPanel({ item, state, status, language, engine }) {
  if (!item) return null;
  const showCaption = state !== "idle";

  const badge =
    state === "processing" ? { tone: "live",  text: status.text || "Analyzing…" } :
    state === "done"       ? { tone: "done",  text: "Batch complete" } :
    state === "recent"     ? { tone: "recent",text: "Last renamed" } :
                             { tone: "idle",  text: "Preview" };

  const ext = item.name.split(".").pop().toLowerCase();

  return (
    <section className="focus">
      <div className="focus__head">
        <span className={`pill pill--${badge.tone}`}>
          {state === "processing" && <span className="pill__live"/>}
          {badge.text}
        </span>
        <div className="focus__meta">
          <span>{item.size}</span>
          <span className="focus__dot">·</span>
          <span>{ext.toUpperCase()}</span>
        </div>
      </div>

      <div className={`preview ${state === "processing" ? "is-processing" : ""}`}>
        <div className="preview__image" style={{
          background: `
            radial-gradient(120% 80% at 20% 10%, ${item.swatch[0]} 0%, transparent 55%),
            radial-gradient(100% 70% at 80% 90%, ${item.swatch[1]} 0%, transparent 60%),
            radial-gradient(90% 90% at 50% 50%, ${item.swatch[2]}aa 0%, transparent 70%),
            linear-gradient(140deg, ${item.swatch[1]}, ${item.swatch[0]})
          `
        }}>
          {state === "processing" && (
            <>
              <div className="preview__scan"/>
              <div className="preview__grid"/>
            </>
          )}
          <div className="preview__ext">{ext.toUpperCase()}</div>
          <div className="preview__swatches">
            {item.swatch.map((c, i) => (
              <span key={i} className="preview__swatch" style={{ background: c }}/>
            ))}
          </div>
        </div>
      </div>

      <div className="rename">
        <div className="rename__row">
          <div className="rename__col rename__col--from">
            <div className="rename__label">Original</div>
            <div className="rename__name">{item.name}</div>
          </div>
          <div className="rename__arrow">
            <Icon name="sparkle" size={16}/>
          </div>
          <div className="rename__col rename__col--to">
            <div className="rename__label">Proposed · <em>{language}</em></div>
            <div className={`rename__name rename__name--to ${state === "processing" ? "is-typing" : ""}`}>
              {state === "processing" ? <TypingName target={item.proposed}/> : item.proposed}
              <span className="rename__ext">.{ext}</span>
            </div>
          </div>
        </div>

        {showCaption && (
          <div className="rename__caption">
            <span className="rename__caption-label">
              <Icon name="terminal" size={12}/> caption
            </span>
            <span className="rename__caption-text">{item.caption}</span>
          </div>
        )}
      </div>
    </section>
  );
}

function TypingName({ target }) {
  const [shown, setShown] = useState("");
  useEffect(() => {
    setShown("");
    let i = 0;
    const tick = () => {
      i += 1;
      setShown(target.slice(0, i));
      if (i < target.length) setTimeout(tick, 28);
    };
    const t = setTimeout(tick, 200);
    return () => clearTimeout(t);
  }, [target]);
  return <>{shown}<span className="caret">|</span></>;
}

// ---------- Queue ----------
function QueuePanel({ queue, processingIndex, doneIds, total, processed }) {
  const listRef = useRef(null);
  useEffect(() => {
    if (processingIndex < 0) return;
    const el = listRef.current?.children[processingIndex];
    if (el && el.scrollIntoViewIfNeeded) el.scrollIntoViewIfNeeded();
  }, [processingIndex]);

  return (
    <section className="queue">
      <div className="queue__head">
        <div className="queue__title">Queue</div>
        <div className="queue__stats">
          <span className="queue__count">{processed} of {total}</span>
        </div>
      </div>
      <ol className="queue__list" ref={listRef}>
        {queue.map((q, i) => {
          const isDone = doneIds.has(q.id);
          const isNow  = processingIndex === i;
          const state = isDone ? "done" : isNow ? "now" : "pending";
          return (
            <li key={q.id} className={`qi qi--${state}`}>
              <div className="qi__status">
                {state === "done" && <Icon name="check" size={13}/>}
                {state === "now"  && <span className="qi__spinner"/>}
                {state === "pending" && <span className="qi__num">{i + 1}</span>}
              </div>
              <div
                className="qi__thumb"
                style={{ background: `linear-gradient(135deg, ${q.swatch[0]}, ${q.swatch[1]})` }}
              />
              <div className="qi__body">
                <div className="qi__from">{q.name}</div>
                <div className="qi__to">
                  {isDone || isNow ? (
                    <>→ <span className="qi__proposed">{q.proposed}</span></>
                  ) : (
                    <span className="qi__waiting">Waiting</span>
                  )}
                </div>
              </div>
              <div className="qi__size">{q.size}</div>
            </li>
          );
        })}
      </ol>
    </section>
  );
}

// ---------- Debug ----------
function DebugStrip({ show, setShow, status }) {
  return (
    <div className={`debug ${show ? "is-open" : ""}`}>
      <button className="debug__toggle" onClick={() => setShow(!show)}>
        <Icon name="terminal" size={13}/>
        <span>Translation debug log</span>
        <span className={`debug__chev ${show ? "is-open" : ""}`}><Icon name="chevron" size={12}/></span>
      </button>
      {show && (
        <pre className="debug__body">
{`[12:04:17] TranslationService loaded
[12:04:17] Encoder inputs: input_ids=multiArray[1,256] int32, attention_mask=multiArray[1,256] int32
[12:04:17] Decoder inputs: decoder_input_ids=multiArray[1,256] int32, encoder_hidden_states=multiArray[1,256,1024] float32
[12:04:18] Translate request target=French token=__fra_Latn__ text=a golden retriever sitting on a wooden dock…
[12:04:18] Encoder source token=__eng_Latn__ id=256047
[12:04:19] Decoder target token=__fra_Latn__ langId=256057 bosId=0 padId=1 eosId=2
[12:04:19] Translation path=greedySeq2Seq output=un golden retriever assis sur un quai en bois…
${status.text ? `[now] ${status.text}` : ""}`}
        </pre>
      )}
    </div>
  );
}

// ---------- Tweaks panel ----------
function TweaksPanel({ tweaks, onTweaksChange, onClose }) {
  return (
    <div className="tweaks">
      <div className="tweaks__head">
        <span className="tweaks__title"><Icon name="cog" size={13}/> Tweaks</span>
        <button className="tweaks__close" onClick={onClose} aria-label="Close"><Icon name="close" size={13}/></button>
      </div>
      <div className="tweaks__body">
        <div className="tweaks__row">
          <div className="tweaks__label">Accent</div>
          <div className="tweaks__swatches">
            {[
              { id: "violet", hue: 265 },
              { id: "blue",   hue: 235 },
              { id: "teal",   hue: 195 },
              { id: "green",  hue: 150 },
              { id: "amber",  hue:  55 },
              { id: "coral",  hue:  25 },
            ].map((a) => (
              <button
                key={a.id}
                className={`tw-swatch ${tweaks.accent === a.id ? "is-active" : ""}`}
                onClick={() => onTweaksChange({ ...tweaks, accent: a.id, accentHue: a.hue })}
                style={{ background: `oklch(0.62 0.15 ${a.hue})` }}
                aria-label={a.id}
              />
            ))}
          </div>
        </div>
        <div className="tweaks__row">
          <div className="tweaks__label">Density</div>
          <Segmented
            value={tweaks.density}
            onChange={(v) => onTweaksChange({ ...tweaks, density: v })}
            options={[
              { id: "comfy",   label: "Comfy" },
              { id: "compact", label: "Compact" },
            ]}
          />
        </div>
        <div className="tweaks__row">
          <div className="tweaks__label">Theme</div>
          <Segmented
            value={tweaks.theme}
            onChange={(v) => onTweaksChange({ ...tweaks, theme: v })}
            options={[
              { id: "light", label: "Light" },
              { id: "dark",  label: "Dark" },
            ]}
          />
        </div>
        <div className="tweaks__row">
          <div className="tweaks__label">Layout</div>
          <Segmented
            value={tweaks.layout}
            onChange={(v) => onTweaksChange({ ...tweaks, layout: v })}
            options={[
              { id: "split",  label: "Split" },
              { id: "stack",  label: "Stack" },
            ]}
          />
        </div>
      </div>
    </div>
  );
}

Object.assign(window, { ImageRenamerApp, TweaksPanel });
