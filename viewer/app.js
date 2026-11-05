/* Plain browser JavaScript. All data arrives through a local script, not fetch. */
(function () {
  'use strict';
  const data = window.TonemappingSuite || { catalog: { implementations: [] }, clips: [] };
  const catalog = data.catalog || { implementations: [] };
  const clips = data.clips || [];
  const performance = ((data.performance || {}).results || []).map(row => Object.assign({ category: 'performance' }, row));
  const quality = ((data.quality || {}).results || []).map(row => Object.assign({ category: 'quality', testType: 'quality' }, row));
  const rows = performance.concat(quality);
  const byId = new Map((catalog.implementations || []).map(item => [item.id, item]));
  const clipById = new Map(clips.map(clip => [clip.id, clip]));
  const sources = { stock: 'Stock', emby: 'Emby', jellyfin: 'Jellyfin', plex: 'Plex' };
  const signals = { hlg: 'HLG', hdr10: 'HDR10', hdr10plus: 'HDR10+', 'dovi-p5': 'Dolby Vision P5' };
  const tests = { 'performance-isolated': 'Performance: Isolated', 'performance-transcode': 'Performance: Full Transcode', quality: 'Quality' };
  const backends = { software: 'Software', opencl: 'OpenCL', 'opencl-intel': 'OpenCL (Intel)', 'opencl-amd': 'OpenCL (AMD)', cuda: 'CUDA', vulkan: 'Vulkan' };
  const state = { page: 'results', clip: '', signal: 'hdr10', curve: '', test: 'performance-isolated', backend: '', source: '', view: 'table', compact: false, fullWidth: false, imageMode: 'original', absoluteGain: 8, signedGain: 2, split: 50, selected: new Set(), visibleFilters: new Set(), frame: 0, single: '' };
  const el = id => document.getElementById(id);
  const make = (tag, className, text) => { const node = document.createElement(tag); if (className) node.className = className; if (text !== undefined) node.textContent = text; return node; };
  const signedFilters = new Map();
  const differenceImages = new WeakMap();
  let tableNavigation = null;
  el('display-filters').replaceChildren();
  const implementation = row => byId.get(row.catalogImplementationId || row.implementationId) || row;
  const curveLabel = id => ((catalog.curves || []).find(curve => curve.id === id) || {}).label || id;
  const rowKey = row => row.implementationId;
  const label = row => {
    const name = row.implementationLabel || implementation(row).label || row.filter || row.implementationId;
    return String(row.testType || '').startsWith('performance-') ? name.replace(/\s*\(reference\)\s*$/i, '') : name;
  };
  const resultLabel = row => row.testType === 'quality' ? label(row) + ' · ' + (sources[row.source] || row.source) : label(row);
  const processing = row => {
    if (row.category !== 'performance' && !String(row.testType || '').startsWith('performance-')) return row.backend;
    if (row.processing) return row.processing;
    const settings = row.settings || {};
    const evidence = [row.openclVendor, (row.device || {}).vendor, settings.OpenCLVendor, settings.DeviceArgument, ...(settings.HardwareDeviceChain || [])].filter(Boolean).join(' ');
    if (row.backend === 'opencl' && /intel/i.test(evidence)) return 'opencl-intel';
    if (row.backend === 'opencl' && /amd|advanced micro/i.test(evidence)) return 'opencl-amd';
    return row.backend;
  };
  const settingsText = row => {
    const settings = row.settings || {};
    const options = settings.FilterOptions || settings.filterOptions || {};
    return [backends[processing(row)] || processing(row), options.tonemapping || options.tonemap || settings.curve || settings.Curve].filter(Boolean).join(' · ');
  };
  const finite = value => value !== null && value !== undefined && Number.isFinite(Number(value));
  const number = (value, digits = 1) => finite(value) ? Number(value).toFixed(digits) : '—';
  const time = value => { if (!finite(value)) return '—'; const seconds = Number(value); return Math.floor(seconds / 60) + ':' + (seconds % 60).toFixed(2).padStart(5, '0'); };
  const values = array => [...new Set(array.filter(value => value !== undefined && value !== null && value !== ''))];
  const matches = row => row.toneMappingType === state.signal && row.testType === state.test && (state.test !== 'quality' || row.curve === state.curve) && (!state.backend || processing(row) === state.backend) && (!state.source || row.source === state.source);
  const displayGain = () => state.imageMode === 'signed' ? state.signedGain : state.absoluteGain;
  function sourceNode(source) {
    return make('span', 'source-name', sources[source] || source);
  }
  function visibleSettings(value) {
    if (Array.isArray(value)) return value.map(visibleSettings);
    if (!value || typeof value !== 'object') return value;
    const result = {};
    Object.keys(value).filter(key => !/comparisonmode|alignment|targetluminancestatus/i.test(key)).forEach(key => { result[key] = visibleSettings(value[key]); });
    return result;
  }

  function rebuildSelect(id, available, labels, allowAll, disabled = false) {
    const node = el(id);
    const options = values(available);
    const text = value => typeof labels === 'function' ? labels(value) : (labels[value] || value);
    if ((!allowAll || state[id]) && !options.includes(state[id])) state[id] = allowAll ? '' : options[0] || '';
    node.replaceChildren();
    if (allowAll) { const option = make('option', '', 'All'); option.value = ''; node.append(option); }
    options.forEach(value => { const option = make('option', '', text(value)); option.value = value; node.append(option); });
    node.value = state[id];
    node.disabled = disabled || !options.length;
  }

  function synchronize(changed) {
    const order = ['test', 'signal', 'curve', 'backend', 'source'];
    const start = changed ? order.indexOf(changed) : 0;
    if (start <= 0) rebuildSelect('test', Object.keys(tests), tests, false);
    if (start <= 1) rebuildSelect('signal', ['hdr10', 'hdr10plus', 'hlg', 'dovi-p5'], signals, false);
    const profile = (catalog.qualityProfiles || []).find(item => item.toneMappingType === state.signal);
    if (start <= 2) rebuildSelect('curve', state.test === 'quality' && profile ? profile.curves : [], curveLabel, false);
    el('curve-control').hidden = state.test !== 'quality';
    const applicable = (catalog.implementations || []).filter(item => (item.toneMappingTypes || []).includes(state.signal) && (item.testTypes || []).includes(state.test) && (state.test !== 'quality' || (item.supportedCurves || []).includes(state.curve)));
    const performanceMode = state.test.startsWith('performance-');
    const backendApplicable = (item, backend) => item.backend === backend || performanceMode && backend.startsWith('opencl-') && item.backend === 'opencl';
    if (start <= 3) {
      const processingOptions = performanceMode ? ['software', 'opencl-intel', 'opencl-amd', 'cuda', 'vulkan'] : ['software', 'opencl', 'cuda', 'vulkan'];
      // Keep unidentified historical skipped runs reachable until they are replaced.
      if (performanceMode && performance.some(row => row.testType === state.test && row.toneMappingType === state.signal && processing(row) === 'opencl')) processingOptions.splice(3, 0, 'opencl');
      rebuildSelect('backend', processingOptions.filter(id => applicable.some(item => backendApplicable(item, id) && (performanceMode || id !== 'vulkan' || !(item.isReference || item.id === catalog.referenceImplementationId)))), backends, state.test === 'quality');
    }
    if (start <= 4) {
      rebuildSelect('source', Object.keys(sources).filter(id => applicable.some(item => item.source === id && (!state.backend || backendApplicable(item, state.backend) || state.test === 'quality' && item.id === catalog.referenceImplementationId))), sources, true);
    }
    state.clip = (clips.find(clip => clip.toneMappingType === state.signal) || {}).id || '';
    if (start <= 2) state.frame = 0;
    const clip = clipById.get(state.clip);
    el('clip-context').textContent = clip ? [((clip.expected || {}).width || '?') + ' × ' + ((clip.expected || {}).height || '?'), number(clip.durationSeconds, 2) + ' s source'].join(' · ') : 'Download media and run comparisons to get started.';
    render();
  }

  function assetUrl(path) {
    if (!path) return '';
    let normalized = String(path).replace(/\\/g, '/');
    const imageBase = String((window.TonemappingHosting || {}).imageBaseUrl || '').replace(/\/$/, '');
    if (imageBase && normalized.startsWith('assets/images/')) {
      if (!/^https?:\/\//i.test(imageBase) || /[?#]/.test(imageBase)) throw new Error('Image storage must use an HTTP(S) base URL without a query or fragment.');
      normalized = imageBase + '/' + normalized.slice('assets/images/'.length);
    }
    if (/^file:/i.test(normalized)) return normalized;
    const url = /^[a-z]:\//i.test(normalized) ? 'file:///' + normalized : normalized.startsWith('//') ? 'file:' + normalized : normalized;
    return encodeURI(url).replace(/#/g, '%23').replace(/\?/g, '%3F');
  }

  function executionInfo(row) {
    const execution = row.execution || {}; const generation = row.generation || {};
    const sample = (row.samples || []).find(item => item.valid !== false) || (row.samples || [])[0] || {};
    const preflight = (row.preflight || {}).run || (row.preflight || {}).Run || {};
    const run = sample.loopRun || sample.transcodeRun || sample.run || generation;
    const planned = row.plannedCommand || (row.plannedRuns || [])[0] || {};
    const filePath = run.filePath || run.FilePath || planned.filePath || planned.FilePath || preflight.filePath || preflight.FilePath;
    const args = run.arguments || run.Arguments || planned.arguments || planned.Arguments || preflight.arguments || preflight.Arguments;
    const recordedCommand = run.commandLine || run.CommandLine || '';
    const preflightCommand = preflight.commandLine || preflight.CommandLine || '';
    const completeCommand = [generation.commandLine, recordedCommand, preflightCommand].find(command => typeof command === 'string' && /^\s*&(?:\s|$)/.test(command));
    const argumentLine = Array.isArray(args) ? args.map(windowsArgument).join(' ') : recordedCommand && !/^\s*&(?:\s|$)/.test(recordedCommand) ? recordedCommand : '';
    const reconstructed = filePath && (Array.isArray(args) || argumentLine) ? powerShellCommand(filePath, argumentLine) : '';
    const logFiles = run.logPaths || run.LogFiles || {};
    const oldLogs = Array.isArray(row.logPaths) ? row.logPaths[row.logPaths.length - 1] || {} : row.logPaths || {};
    const preflightLogs = preflight.logPaths || preflight.LogFiles || {};
    const preflightExecution = preflight.execution || {};
    return {
      commandLine: execution.commandLine || completeCommand || reconstructed || '',
      log: execution.log || generation.log || logFiles.Log || logFiles.StdErr || logFiles.stderr || oldLogs.Log || oldLogs.StdErr || preflightExecution.log || preflight.log || preflightLogs.Log || preflightLogs.StdErr || '',
      graph: execution.graph || generation.graph || logFiles.Graph || preflightExecution.graph || preflight.graph || preflightLogs.Graph || ''
    };
  }

  function windowsArgument(value) {
    if (String(value) && !/[\s"]/.test(String(value))) return String(value);
    let result = '"'; let slashes = 0;
    for (const character of String(value)) {
      if (character === '\\') { slashes++; continue; }
      result += '\\'.repeat(character === '"' ? slashes * 2 + 1 : slashes) + character;
      slashes = 0;
    }
    return result + '\\'.repeat(slashes * 2) + '"';
  }

  function powerShellCommand(filePath, argumentLine) {
    const quote = value => "'" + String(value).replace(/'/g, "''") + "'";
    const executable = /^[a-z0-9_:/\\.\-]+$/i.test(String(filePath)) ? String(filePath) : quote(filePath);
    // Match the runner's PS5.1/CRT contract, including empty argv and quotes.
    if (/%[A-Za-z_][A-Za-z0-9_()]*%|[\r\n|;]|\\+"/.test(argumentLine)) {
      return '& { $i = New-Object Diagnostics.ProcessStartInfo; $i.FileName = ' + quote(filePath) + '; $i.Arguments = ' + quote(argumentLine) + '; $i.UseShellExecute = $false; $p = [Diagnostics.Process]::Start($i); $p.WaitForExit(); $p.Dispose() }';
    }
    return '& ' + executable + ' --% ' + argumentLine;
  }

  function showExecutionDialog(row, kind) {
    const info = executionInfo(row); const dialog = el('execution-dialog'); const body = el('execution-dialog-body'); body.replaceChildren();
    dialog.className = kind === 'graph' ? 'execution-dialog graph-dialog' : 'execution-dialog command-dialog';
    el('execution-dialog-title').textContent = label(row) + (kind === 'graph' ? ' · Execution graph' : ' · FFmpeg command');
    if (kind === 'graph') {
      const frame = make('iframe', 'execution-graph'); frame.title = label(row) + ' native FFmpeg execution graph'; frame.src = assetUrl(info.graph); body.append(frame);
    } else {
      body.append(make('p', 'muted', 'Copy this command into Windows PowerShell. It contains the recorded executable and arguments.'));
      const command = make('textarea', 'execution-command'); command.readOnly = true; command.value = info.commandLine; command.setAttribute('aria-label', 'Copyable FFmpeg command'); command.spellcheck = false;
      const tools = make('div', 'command-tools'); const copy = make('button', 'action-button', 'Copy command'); copy.type = 'button'; const status = make('span', 'muted'); status.setAttribute('aria-live', 'polite');
      copy.addEventListener('click', async () => {
        command.focus(); command.select();
        try {
          if (window.navigator && window.navigator.clipboard && window.navigator.clipboard.writeText) await window.navigator.clipboard.writeText(command.value);
          else if (!document.execCommand || !document.execCommand('copy')) throw new Error('Use the selected command');
          status.textContent = 'Copied';
        } catch (_) { status.textContent = 'Command selected. Press Ctrl+C to copy.'; }
      });
      tools.append(copy, status); body.append(command, tools);
      if (row.settings) {
        const details = make('details', 'recorded-settings'); details.append(make('summary', '', 'Recorded settings'));
        const settings = make('pre'); settings.textContent = JSON.stringify(visibleSettings(row.settings), null, 2); details.append(settings); body.append(details);
      }
    }
    if (dialog.showModal) dialog.showModal(); else dialog.setAttribute('open', '');
  }

  function resultActions(row) {
    const info = executionInfo(row); const group = make('div', 'result-actions'); group.setAttribute('aria-label', label(row) + ' execution details');
    const command = make('button', 'action-button', 'Command'); command.type = 'button'; command.disabled = !info.commandLine; command.title = info.commandLine ? 'View and copy the FFmpeg command' : 'No command recorded in this report'; command.addEventListener('click', () => showExecutionDialog(row, 'command'));
    const log = make(info.log ? 'a' : 'button', 'action-button', 'Log');
    if (info.log) { log.href = assetUrl(info.log); log.target = '_blank'; log.rel = 'noopener'; log.title = 'Open the recorded FFmpeg log in a new window'; }
    else { log.type = 'button'; log.disabled = true; log.title = 'No FFmpeg log recorded in this report'; }
    const graph = make('button', 'action-button', 'Graph'); graph.type = 'button'; graph.disabled = !info.graph; graph.title = info.graph ? 'Open the native FFmpeg execution graph' : 'No native execution graph recorded in this report'; graph.addEventListener('click', () => showExecutionDialog(row, 'graph'));
    group.append(command, log, graph); return group;
  }

  function render() {
    el('results-page').hidden = state.page !== 'results';
    el('configuration-page').hidden = state.page !== 'configuration';
    el('show-results').classList.toggle('active', state.page === 'results');
    el('show-configuration').classList.toggle('active', state.page === 'configuration');
    el('show-results').setAttribute('aria-pressed', String(state.page === 'results'));
    el('show-configuration').setAttribute('aria-pressed', String(state.page === 'configuration'));
    if (state.page === 'configuration') { renderConfiguration(); return; }
    const isQuality = state.test === 'quality';
    el('results-page').classList.toggle('full-width', isQuality && state.fullWidth);
    el('performance-panel').hidden = isQuality;
    el('quality-panel').hidden = !isQuality;
    if (isQuality) renderQuality(); else renderPerformance();
    renderDiagnostics();
  }

  function renderPerformance() {
    const selected = performance.filter(row => matches(row));
    const completed = selected.filter(row => row.status === 'completed' && finite(row.fps) && Number(row.fps) > 0).sort((a, b) => Number(b.fps) - Number(a.fps));
    const fastest = completed.length ? Number(completed[0].fps) : 1;
    el('performance-title').textContent = tests[state.test] || state.test;
    el('speed-heading').hidden = state.test === 'performance-isolated';
    el('mapped-heading').hidden = state.test === 'performance-isolated';
    el('performance-count').textContent = completed.length + ' completed';
    const doviIsolated = state.test === 'performance-isolated' && state.signal === 'dovi-p5';
    el('dovi-test-method').hidden = !doviIsolated;
    el('isolated-test-method').hidden = state.test !== 'performance-isolated' || doviIsolated;
    el('transcode-test-method').hidden = state.test !== 'performance-transcode';
    el('performance-note').textContent = doviIsolated ? 'Each result identifies its isolated method: the eight-state sequence with changing metadata, or a single-frame loop with constant metadata. Expand the test method for details.' : state.test === 'performance-isolated' ? 'FPS uses the extra looped-frame cost after subtracting a one-frame run. GPU frames are uploaded before the loop. Repeated frames preserve HDR metadata; they do not measure changing-metadata cost. Expand the test method for details.' : 'FPS includes decoding, tone mapping at native resolution, 720p scaling and encoding. GPU routes pass every decoded frame through tone mapping five times; Mapped FPS counts those passes. Expand the test method for details, and see the recorded command and settings for each route.';
    if (doviIsolated) {
      const measured = completed.filter(row => (row.isolatedMethod || {}).mode === 'dovi-eight-state');
      el('dovi-method-status').textContent = !measured.length ? 'Proposed method' : measured.length === completed.length ? 'Recorded method' : 'Mixed methods';
      el('dovi-method-report').textContent = !measured.length ? completed.length ? 'The displayed scores use single-frame loops with constant metadata. The eight-state method below has not been applied to these scores.' : 'No scored eight-state result is shown for this selection. The method below is proposed.' : measured.length + ' of ' + completed.length + ' displayed scored results record the eight-state method.' + (measured.length < completed.length ? ' The remaining results use single-frame loops; compare the method labels before ranking them.' : ' Each result records its self-test and timing counts.');
      const fixedWorkloads = completed.filter(row => (row.isolatedMethod || {}).timingPolicy === 'fixed-workload');
      el('dovi-timing-policy-report').textContent = fixedWorkloads.length ? fixedWorkloads.length + ' of ' + completed.length + ' displayed scored results use fixed configured workloads, identical on every machine.' + (fixedWorkloads.length < completed.length ? ' Other rows retain their recorded timing policy.' : '') : !timeSized.length ? completed.length ? 'The displayed scores use their recorded explicit or single-frame timing windows.' : 'No scored result is shown for this selection.' : timeSized.length + ' of ' + completed.length + ' displayed scored results were recorded with the earlier time-sized policy.' + (timeSized.length < completed.length ? ' The others use explicit or single-frame windows.' : ' Per-result frame counts and observed durations are shown below.');
    }
    const body = el('performance-body'); body.replaceChildren();
    completed.forEach(row => {
      const tr = make('tr');
      const sourceCell = make('td'); sourceCell.append(sourceNode(row.source)); tr.append(sourceCell);
      const name = make('td'); name.append(make('div', 'filter-name', label(row)));
      name.append(make('div', 'filter-detail', settingsText(row))); tr.append(name);
      if (doviIsolated) {
        const method = row.isolatedMethod || {};
        const dynamic = method.mode === 'dovi-eight-state';
        const description = dynamic ? [finite(method.states) ? method.states + ' metadata states' : 'Eight-state loop', finite(method.repetitionsPerState) ? method.repetitionsPerState + ' frames/state' : '', method.aggregation === 'median' ? 'median' : ''].filter(Boolean).join(' · ') : 'Single-frame loop · constant metadata';
        name.append(make('div', 'filter-detail isolated-method-detail', description));
        if (finite(method.shortFrames) && finite(method.longFrames)) {
          const policy = method.timingPolicy === 'fixed-workload' ? 'Fixed workload' : method.timingPolicy === 'time-sized-v2' ? 'Time-sized windows' : method.timingPolicy === 'explicit-windows' ? 'Explicit windows' : Number(method.shortFrames) === 960 && Number(method.longFrames) === 5120 ? 'Earlier fixed windows' : 'Earlier recorded windows';
          name.append(make('div', 'filter-detail isolated-method-detail', policy + ': short ' + method.shortFrames + ' / long ' + method.longFrames + ' frames'));
          const valid = (row.samples || []).filter(sample => sample.valid !== false);
          const durationRange = key => {
            const durations = valid.map(sample => sample[key]).filter(finite).map(Number);
            if (!durations.length) return '';
            const low = Math.min(...durations); const high = Math.max(...durations);
            return number(low, 2) + (number(low, 2) === number(high, 2) ? '' : '–' + number(high, 2)) + ' s';
          };
          const shortTime = durationRange('shortWallSeconds'); const longTime = durationRange('longWallSeconds');
          if (shortTime || longTime) name.append(make('div', 'filter-detail isolated-method-detail', [shortTime && 'Short ' + shortTime, longTime && 'long ' + longTime].filter(Boolean).join(' · ')));
        }
        const selfTest = method.selfTest;
        if (dynamic && selfTest) {
          const check = make('div', 'filter-detail isolated-self-test', 'Metadata sequence check: ' + (selfTest.passed === true ? 'passed' : 'not passed'));
          check.title = selfTest.passed === true ? 'The sampled metadata sequence was verified before timing.' : 'The sampled metadata sequence could not be verified; interpret this score with care.'; name.append(check);
        }
      }
      if (finite(row.spread)) {
        const spread = make('div', 'filter-detail spread-detail', 'Spread ' + number(row.spread, 1) + '% · ' + (row.validSamples || (row.samples || []).length) + ' valid runs');
        spread.title = '(max FPS − min FPS) / max FPS × 100; variation across repeated runs';
        spread.setAttribute('aria-label', spread.textContent + '. ' + spread.title); name.append(spread);
      }
      name.append(resultActions(row));
      tr.append(make('td', 'fps', number(row.fps, 0)));
      if (state.test !== 'performance-isolated') tr.append(make('td', '', finite(row.mappedFps) ? number(row.mappedFps, 0) : '—'));
      if (state.test !== 'performance-isolated') tr.append(make('td', '', finite(row.speed) ? number(row.speed, 1) + '×' : '—'));
      tr.append(make('td', '', finite(row.durationSeconds) ? number(row.durationSeconds, 2) + ' s' : '—'));
      const barCell = make('td'); const track = make('div', 'bar-track'); const fill = make('div', 'bar-fill');
      fill.style.width = (100 * Number(row.fps) / fastest).toFixed(2) + '%'; track.append(fill); barCell.append(track); tr.append(barCell); body.append(tr);
    });
    el('performance-empty').hidden = completed.length > 0;
    el('performance-empty').textContent = selected.length ? 'No completed measurements for this selection. Expand the run details below for skipped or failed pipelines.' : 'No measurements for this selection. Run the benchmark launcher.';
    el('performance-table').hidden = completed.length === 0;
  }

  function renderConfiguration() {
    const body = el('capabilities-body'); body.replaceChildren();
    (catalog.implementations || []).forEach(item => {
      const row = make('tr'); const source = make('td'); source.append(sourceNode(item.source));
      const filterCell = make('td'); filterCell.append(make('div', 'filter-name', item.label || item.filter || item.id));
      const runs = rows.filter(run => (run.catalogImplementationId || run.implementationId) === item.id);
      const statuses = ['completed', 'skipped', 'failed'].map(status => { const count = runs.filter(run => run.status === status).length; return count ? count + ' ' + status : ''; }).filter(Boolean);
      const runtime = statuses.length ? 'Latest reports: ' + statuses.join(' · ') : item.pipelineStatus === 'blocked' ? 'Pipeline unavailable; no exported runs' : 'No exported runs';
      filterCell.append(make('div', 'runtime-status', runtime));
      row.append(source, filterCell, make('td', '', backends[item.backend] || item.backend));
      Object.keys(signals).forEach(id => {
        const supported = (item.toneMappingTypes || []).includes(id);
        const cell = make('td', 'signal-capability', supported ? '\u2713' : '-');
        const description = signals[id] + ': ' + (supported ? 'supported' : 'unsupported');
        cell.title = description; cell.setAttribute('aria-label', description); row.append(cell);
      });
      if (item.notes) row.title = item.notes;
      body.append(row);
    });
    const container = el('configuration-values'); container.replaceChildren();
    const configuration = visibleSettings(data.configuration);
    if (!configuration) { container.append(make('p', 'muted', 'Configuration values were not included in this export. Run 07-OpenResults.cmd to refresh them.')); return; }
    const table = make('table', 'configuration-table'); const valuesBody = make('tbody');
    const flatten = (value, path) => {
      if (value && typeof value === 'object' && !Array.isArray(value)) { Object.keys(value).forEach(key => flatten(value[key], path.concat(key))); return; }
      if (value === null || value === undefined || (typeof value === 'string' && !value.trim()) || (Array.isArray(value) && !value.length)) return;
      const row = make('tr'); row.append(make('th', '', path.join(' · ')), make('td', '', Array.isArray(value) ? value.join(', ') : String(value))); valuesBody.append(row);
    };
    flatten(configuration, []); table.append(valuesBody); container.append(table);
  }

  function frameTimestamp(frame) { return finite(frame.timestampSeconds) ? Number(frame.timestampSeconds) : (finite(frame.timeSeconds) ? Number(frame.timeSeconds) : null); }
  function framePosition(frame, index) { return { timestamp: frameTimestamp(frame), number: finite(frame.index) ? Number(frame.index) : index + 1, displayNumber: frame.keyframeIndex || frame.index || index + 1, index }; }
  function imagePath(frame) {
    if (!frame) return '';
    if (state.imageMode === 'signed') return frame.diffSignedDisplay && Number(frame.signedDisplayGain) === state.signedGain ? frame.diffSignedDisplay : frame.diffSigned || frame.signedDifference || '';
    if (state.imageMode === 'absolute') return frame.diffAbsoluteDisplay && Number(frame.absoluteDisplayGain) === state.absoluteGain ? frame.diffAbsoluteDisplay : frame.diffAbsolute || frame.absoluteDifference || '';
    return frame.image || frame.imagePath || '';
  }
  function metricText(frame) {
    const metrics = (frame || {}).metrics || {};
    const score = metrics.psnrY !== undefined ? metrics.psnrY : metrics.psnrAvg;
    const psnr = score === 'inf' || score === 'Infinity' ? 'Y PSNR ∞' : finite(score) ? 'Y PSNR ' + number(score, 2) + ' dB' : '';
    const ssim = finite(metrics.ssimAll) ? 'SSIM ' + number(metrics.ssimAll, 4) : '';
    return [psnr, ssim].filter(Boolean).join(' · ');
  }
  function frameAt(row, position) {
    if (!row || !position) return undefined;
    const frames = row.frames || [];
    // Legacy timed reports keep strict time matching. New reports use frame numbers.
    if (position.timestamp !== null && frames.some(frame => frameTimestamp(frame) !== null)) return frames.find(frame => frameTimestamp(frame) !== null && Math.abs(frameTimestamp(frame) - position.timestamp) <= 0.001);
    return frames.find((frame, index) => (finite(frame.index) ? Number(frame.index) : index + 1) === position.number);
  }
  function imageNode(path, alt, frame, row) {
    const img = make('img'); img.alt = alt; img.loading = 'lazy';
    if (frame) differenceImages.set(img, { frame, row });
    updateImageDisplay(img, path, frame, row);
    return img;
  }
  function updateImageDisplay(img, path, frame, row) {
    if (path && img.dataset.assetPath !== path) { img.src = assetUrl(path); img.dataset.assetPath = path; }
    img.style.filter = '';
    if (state.imageMode === 'absolute' && frame) {
      const precomputed = path === frame.diffAbsoluteDisplay && Number(frame.absoluteDisplayGain) === state.absoluteGain;
      if (!precomputed) img.style.filter = 'brightness(' + state.absoluteGain + ')';
      img.dataset.displayGain = String(state.absoluteGain);
      img.style.background = '#000';
    }
    if (state.imageMode === 'signed' && frame) {
      const precomputed = path === frame.diffSignedDisplay && Number(frame.signedDisplayGain) === state.signedGain;
      const recorded = Number(frame.signedGain || ((row || {}).settings || {}).signedGain || ((data.quality || {}).settings || {}).signedGain || 8);
      const recordedGain = Number.isFinite(recorded) && recorded > 0 ? recorded : 8;
      if (!precomputed && recordedGain !== state.signedGain) img.style.filter = signedGainFilter(state.signedGain, recordedGain);
      img.dataset.displayGain = String(state.signedGain); img.style.background = '#808080';
    }
  }
  function updateDisplayGain() {
    el('gain-label').textContent = '×' + displayGain();
    el('quality-content').querySelectorAll('img').forEach(img => {
      const entry = differenceImages.get(img);
      if (entry) updateImageDisplay(img, imagePath(entry.frame), entry.frame, entry.row);
    });
  }
  function signedGainFilter(gain, recordedGain) {
    const key = gain + '-' + recordedGain;
    if (!signedFilters.has(key)) {
      const id = 'signed-display-gain-' + key.replace(/[^0-9-]/g, '-');
      const svg = tag => document.createElementNS('http://www.w3.org/2000/svg', tag);
      const filter = svg('filter'); filter.setAttribute('id', id); filter.setAttribute('color-interpolation-filters', 'sRGB'); filter.setAttribute('x', '0%'); filter.setAttribute('y', '0%'); filter.setAttribute('width', '100%'); filter.setAttribute('height', '100%');
      const transfer = svg('feComponentTransfer'); const factor = gain / recordedGain;
      ['R', 'G', 'B'].forEach(channel => { const component = svg('feFunc' + channel); component.setAttribute('type', 'linear'); component.setAttribute('slope', String(factor)); component.setAttribute('intercept', String((128 / 255) * (1 - factor))); transfer.append(component); });
      filter.append(transfer); el('display-filters').append(filter); signedFilters.set(key, 'url(#' + id + ')');
    }
    return signedFilters.get(key);
  }
  function card(row, frame, options = {}) {
    const figure = make('figure', 'image-card' + (options.single ? ' single-image-card' : '') + (options.table ? ' table-image-card' : '')); const path = imagePath(frame);
    if (path) figure.append(imageNode(path, resultLabel(row), frame, row)); else figure.append(make('div', 'empty', 'Image unavailable at this frame.'));
    const caption = make('figcaption', 'image-caption');
    if (!options.table) caption.append(make('span', 'caption-name', resultLabel(row)));
    const metric = metricText(frame); const settings = settingsText(row);
    if (metric) caption.append(make('span', 'metric', metric));
    if (options.single && settings) caption.append(make('span', 'single-image-info', settings));
    if (caption.children.length) figure.append(caption);
    if (!options.table && !options.single) { if (settings) figure.append(make('div', 'quality-settings', settings)); if (!state.compact) figure.append(resultActions(row)); }
    return figure;
  }

  function compareImages(current, currentFrame, leftRow, referenceFrame) {
    const compare = make('div', 'compare-image'); compare.append(imageNode(currentFrame.image || currentFrame.imagePath, resultLabel(current)));
    const overlay = make('div', 'compare-overlay'); overlay.append(imageNode(referenceFrame.image || referenceFrame.imagePath, label(leftRow))); compare.append(overlay);
    const divider = make('div', 'compare-divider'); divider.tabIndex = 0; divider.setAttribute('role', 'slider'); divider.setAttribute('aria-label', 'Image comparison divider'); divider.setAttribute('aria-orientation', 'horizontal'); divider.setAttribute('aria-valuemin', '0'); divider.setAttribute('aria-valuemax', '100');
    const move = value => {
      state.split = Math.max(0, Math.min(100, value)); overlay.style.clipPath = 'inset(0 ' + (100 - state.split) + '% 0 0)'; divider.style.left = state.split + '%';
      divider.setAttribute('aria-valuenow', String(Math.round(state.split))); divider.setAttribute('aria-valuetext', Math.round(state.split) + '% ' + label(leftRow));
    };
    let pointer = null;
    const point = event => { const rect = compare.getBoundingClientRect(); if (rect.width > 0) move(100 * (event.clientX - rect.left) / rect.width); };
    divider.addEventListener('pointerdown', event => { if (event.button !== undefined && event.button !== 0) return; pointer = event.pointerId; divider.setPointerCapture(pointer); divider.focus(); event.preventDefault(); point(event); });
    divider.addEventListener('pointermove', event => { if (pointer !== null && pointer === event.pointerId) point(event); });
    const release = event => { if (pointer === event.pointerId) { if (divider.hasPointerCapture(pointer)) divider.releasePointerCapture(pointer); pointer = null; } };
    divider.addEventListener('pointerup', release); divider.addEventListener('pointercancel', release); divider.addEventListener('lostpointercapture', () => { pointer = null; });
    divider.addEventListener('keydown', event => {
      const step = event.shiftKey ? 10 : 1;
      const targets = { ArrowLeft: state.split - step, ArrowRight: state.split + step, Home: 0, End: 100 };
      if (Object.prototype.hasOwnProperty.call(targets, event.key)) { event.preventDefault(); move(targets[event.key]); }
    });
    move(state.split); compare.append(divider, make('span', 'compare-label left', resultLabel(leftRow)), make('span', 'compare-label right', resultLabel(current)), make('div', 'compare-info', [settingsText(current), metricText(currentFrame)].filter(Boolean).join(' · '))); return compare;
  }

  function renderQuality() {
    tableNavigation = null;
    const completed = quality.filter(row => matches(row) && row.status === 'completed' && (row.frames || []).length);
    // The reference remains available when backend/source narrowing selects a competitor.
    const reference = quality.find(row => row.clipId === state.clip && row.curve === state.curve && row.status === 'completed' && (row.isReference || row.implementationId === catalog.referenceImplementationId));
    const options = completed.slice();
    if (reference && !options.some(row => row.implementationId === reference.implementationId)) options.unshift(reference);
    options.sort((a, b) => Number(b === reference) - Number(a === reference));
    const allowed = new Set(options.map(rowKey));
    state.selected = new Set([...state.selected].filter(id => allowed.has(id)));
    allowed.forEach(id => { if (!state.visibleFilters.has(id)) state.selected.add(id); });
    state.visibleFilters = allowed;
    const picker = el('filter-picker'); picker.replaceChildren();
    options.forEach(row => {
      const labelNode = make('label'); const check = make('input'); check.type = 'checkbox'; check.checked = state.selected.has(rowKey(row));
      check.addEventListener('change', () => { if (check.checked) state.selected.add(rowKey(row)); else state.selected.delete(rowKey(row)); renderQuality(); });
      labelNode.append(check, document.createTextNode(resultLabel(row))); picker.append(labelNode);
    });
    const selected = options.filter(row => state.selected.has(rowKey(row)));
    const timelineFrames = (options.length && reference || options[0] || {}).frames || [];
    const positions = timelineFrames.map(framePosition);
    state.frameCount = positions.length;
    state.frame = Math.max(0, Math.min(state.frame, Math.max(0, positions.length - 1)));
    const currentPosition = positions[state.frame];
    const timed = positions.length && positions.every(position => position.timestamp !== null);
    const updateFrameLabels = () => {
      const position = positions[state.frame];
      el('time-slider').max = String(Math.max(0, positions.length - 1)); el('time-slider').value = String(state.frame);
      el('timeline-title').textContent = timed ? 'Source time' : 'Keyframe';
      el('time-label').textContent = position ? timed ? time(position.timestamp) : 'Keyframe ' + position.displayNumber : '';
      el('frame-label').textContent = positions.length ? (state.frame + 1) + ' / ' + positions.length + ' keyframes' : 'No keyframes';
      el('previous-image').disabled = !selected.length || state.frame === 0;
      el('next-image').disabled = !selected.length || state.frame >= positions.length - 1;
    };
    updateFrameLabels();
    el('timeline').hidden = !positions.length || state.view === 'table';
    ['previous-image', 'next-image'].forEach((id, index) => {
      const description = (index ? 'Next' : 'Previous') + (state.view === 'table' ? ' keyframe row' : ' keyframe');
      el(id).title = description; el(id).setAttribute('aria-label', description);
    });
    el('quality-panel').classList.toggle('compact-layout', state.compact);
    el('compact-layout').checked = state.compact;
    el('full-width').checked = state.fullWidth;
    el('check-all-filters').disabled = !allowed.size || selected.length === allowed.size;
    el('check-no-filters').disabled = !selected.length;
    el('quality-note').textContent = data.hosting ? 'Images: 1080p WebP, quality 95. Metrics describe agreement with libplacebo measured on the native 4K sources.' : 'Metrics describe agreement with libplacebo. Every quality image uses native source dimensions.';
    el('quality-empty').hidden = selected.length > 0;
    el('quality-empty').textContent = options.length ? 'Select at least one filter to show its images.' : 'No images for this selection. Run 06-RunQuality.cmd.';
    el('absolute-gain-control').hidden = state.imageMode === 'original'; el('absolute-gain').value = String(displayGain()); el('gain-label').textContent = '×' + displayGain();
    el('image-explanation').textContent = state.imageMode === 'signed' ? 'Gray means identical. Brighter means higher; darker means lower.' : state.imageMode === 'absolute' ? 'Black means identical. Display gain leaves raw differences and metrics unchanged.' : 'Original SDR outputs. Drag the divider in Single-image to compare against the reference.';
    el('view-buttons').querySelectorAll('button').forEach(button => button.classList.toggle('active', button.dataset.view === state.view));
    const content = el('quality-content'); content.replaceChildren();
    if (!selected.length) return;
    if (state.view === 'table') {
      const scroll = make('div', 'table-scroll quality-table-scroll'); scroll.tabIndex = 0; scroll.setAttribute('role', 'region'); scroll.setAttribute('aria-label', 'Quality keyframes'); const table = make('table', 'quality-table'); table.style.minWidth = (40 + selected.length * 230) + 'px'; const head = make('thead'); const hr = make('tr'); hr.append(make('th', 'frame-column', timed ? 'Source time' : 'Frame'));
      selected.forEach(row => { const th = make('th', '', resultLabel(row)); th.append(make('div', 'filter-detail', settingsText(row))); if (!state.compact) th.append(resultActions(row)); hr.append(th); }); head.append(hr); table.append(head); const body = make('tbody');
      positions.forEach((position, index) => { const tr = make('tr', index === state.frame ? 'selected-frame' : ''); tr.append(make('td', 'frame-column', timed ? time(position.timestamp) : String(position.displayNumber))); selected.forEach(row => { const td = make('td'); const frame = frameAt(row, position); if (imagePath(frame)) td.append(card(row, frame, { table: true })); else td.textContent = 'Image unavailable'; tr.append(td); }); body.append(tr); });
      table.append(body); scroll.append(table); content.append(scroll);
      const rowTop = index => Math.max(0, body.children[index].getBoundingClientRect().top - scroll.getBoundingClientRect().top + scroll.scrollTop - head.getBoundingClientRect().height - (scroll.clientTop || 0));
      const markFrame = index => { state.frame = index; [...body.children].forEach((row, i) => row.classList.toggle('selected-frame', i === index)); updateFrameLabels(); };
      const alignHeader = () => {
        const headerHeight = head.getBoundingClientRect().height;
        scroll.style.scrollPaddingTop = headerHeight + 'px';
        // Let the last row reach the same top position as every earlier row.
        const lastRow = body.children[body.children.length - 1];
        scroll.style.paddingBottom = Math.max(0, scroll.clientHeight - headerHeight - lastRow.getBoundingClientRect().height) + 'px';
      };
      tableNavigation = step => {
        const index = Math.max(0, Math.min(positions.length - 1, state.frame + step));
        markFrame(index); alignHeader(); scroll.scrollTo({ top: rowTop(index), behavior: 'smooth' });
      };
      scroll.addEventListener('scroll', () => {
        if (!positions.length) return;
        // Follow the nearest row top after wheel, keyboard or arrow navigation.
        const top = scroll.scrollTop;
        const nearest = [...body.children].reduce((best, _, index) => Math.abs(rowTop(index) - top) < Math.abs(rowTop(best) - top) ? index : best, 0);
        markFrame(nearest);
      });
      alignHeader();
      if (state.frame) scroll.scrollTop = rowTop(state.frame);
    } else if (state.view === 'single') {
      if (!selected.some(row => rowKey(row) === state.single)) state.single = rowKey(selected.find(row => row !== reference) || selected[0]);
      const tabs = make('div', 'tabs');
      selected.forEach(row => { const tab = make('div', 'filter-tab'); const button = make('button', rowKey(row) === state.single ? 'active' : '', resultLabel(row)); button.addEventListener('click', () => { state.single = rowKey(row); renderQuality(); }); tab.append(button); tabs.append(tab); });
      content.append(tabs);
      const current = selected.find(row => rowKey(row) === state.single);
      const currentFrame = frameAt(current, currentPosition); const referenceFrame = reference && frameAt(reference, currentPosition);
      if (state.imageMode !== 'original' || !referenceFrame || !imagePath(currentFrame)) content.append(card(current, currentFrame, { single: true }));
      else content.append(compareImages(current, currentFrame, reference, referenceFrame));
    } else {
      const grid = make('div', 'image-grid' + (selected.length === 1 ? ' one' : selected.length >= 5 ? ' three' : ''));
      selected.forEach(row => grid.append(card(row, frameAt(row, currentPosition)))); content.append(grid);
    }
  }

  function renderDiagnostics() {
    const failures = rows.filter(row => matches(row) && row.status !== 'completed');
    el('diagnostics').hidden = failures.length === 0;
    el('diagnostics').classList.toggle('compact-layout', state.test === 'quality' && state.compact);
    const unscoredSources = values(failures.map(row => row.source)).map(source => (sources[source] || source) + ' ' + failures.filter(row => row.source === source).length);
    el('diagnostic-summary').textContent = failures.length + ' skipped or failed pipelines' + (unscoredSources.length ? ' · ' + unscoredSources.join(' · ') : '');
    const measured = rows.some(row => matches(row) && row.status === 'completed' && (state.test === 'quality' ? (row.frames || []).length > 0 : finite(row.fps) && Number(row.fps) > 0));
    if (failures.length && !measured) el('diagnostics').open = true;
    const body = el('diagnostic-body'); body.replaceChildren();
    failures.forEach(row => { const div = make('div', 'diagnostic-row'); const heading = make('div', 'diagnostic-heading'); heading.append(sourceNode(row.source), make('strong', '', label(row) + ' · ' + row.status)); div.append(heading, make('div', '', row.reason || row.error || 'See the saved run log.')); if (state.test !== 'quality' || !state.compact) div.append(resultActions(row)); body.append(div); });
  }

  ['test', 'signal', 'curve', 'backend', 'source'].forEach(id => el(id).addEventListener('change', () => { state[id] = el(id).value; synchronize(id); }));
  const navigate = page => { state.page = page; render(); window.scrollTo({ top: 0, behavior: 'auto' }); };
  ['results', 'configuration'].forEach(page => el('show-' + page).addEventListener('click', () => navigate(page)));
  el('viewer-home').addEventListener('click', event => { event.preventDefault(); navigate('results'); });
  el('skip-to-comparisons').addEventListener('click', () => { state.page = 'results'; render(); });
  const applyTheme = theme => {
    document.documentElement.dataset.theme = theme;
    const dark = theme === 'dark';
    el('theme-toggle').setAttribute('aria-label', dark ? 'Switch to light mode' : 'Switch to dark mode');
    el('theme-toggle').title = dark ? 'Switch to light mode' : 'Switch to dark mode';
    el('theme-toggle').setAttribute('aria-pressed', String(dark));
    el('theme-toggle').firstElementChild.textContent = dark ? '☀' : '☾';
  };
  let savedTheme;
  try { savedTheme = window.localStorage.getItem('tonemapping-theme'); } catch (_) { /* file:// privacy settings may deny storage */ }
  applyTheme(savedTheme === 'dark' || savedTheme === 'light' ? savedTheme : 'light');
  el('theme-toggle').addEventListener('click', () => {
    const theme = document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark'; applyTheme(theme);
    try { window.localStorage.setItem('tonemapping-theme', theme); } catch (_) { /* toggle still works without persistence */ }
  });
  el('image-mode').addEventListener('change', () => { state.imageMode = el('image-mode').value; renderQuality(); });
  el('absolute-gain').addEventListener('input', () => { const gain = Number(el('absolute-gain').value); if (Number.isFinite(gain) && gain >= 1 && gain <= 32) { if (state.imageMode === 'signed') state.signedGain = gain; else state.absoluteGain = gain; updateDisplayGain(); } });
  el('check-all-filters').addEventListener('click', () => { state.visibleFilters.forEach(id => state.selected.add(id)); renderQuality(); });
  el('check-no-filters').addEventListener('click', () => { state.selected.clear(); renderQuality(); });
  el('compact-layout').addEventListener('change', () => { state.compact = el('compact-layout').checked; renderQuality(); renderDiagnostics(); });
  el('full-width').addEventListener('change', () => { state.fullWidth = el('full-width').checked; render(); });
  const navigateImage = step => { if (state.view === 'table' && tableNavigation) tableNavigation(step); else { state.frame = Math.max(0, Math.min(Math.max(0, (state.frameCount || 0) - 1), state.frame + step)); renderQuality(); } };
  el('previous-image').addEventListener('click', () => navigateImage(-1));
  el('next-image').addEventListener('click', () => navigateImage(1));
  el('view-buttons').querySelectorAll('button').forEach(button => button.addEventListener('click', () => { state.view = button.dataset.view; renderQuality(); }));
  el('time-slider').addEventListener('input', () => { state.frame = Number(el('time-slider').value); renderQuality(); });
  el('execution-dialog-close').addEventListener('click', () => { const dialog = el('execution-dialog'); if (dialog.close) dialog.close(); else dialog.removeAttribute('open'); });
  el('export-context').textContent = data.exportedUtc ? 'Exported ' + new Date(data.exportedUtc).toLocaleString() : 'No exported results';
  const system = (data.performance || {}).system || {};
  const systemNames = value => {
    if (Array.isArray(value)) return values(value.map(systemNames)).join(', ');
    if (typeof value === 'string') return value.trim();
    if (!value || typeof value !== 'object') return '';
    return systemNames(value.Name || value.name || value.Caption || value.caption || value.Model || value.model);
  };
  const cpu = systemNames(system.cpuModel || system.CpuModel || system.cpu || system.Cpu || system.CPU);
  const gpu = systemNames(system.gpu || system.Gpu || system.GPU || system.gpuModel || system.GpuModel);
  const os = systemNames(system.os || system.Os || system.OS);
  el('system-info').textContent = [cpu && 'CPU: ' + cpu, gpu && 'GPU: ' + gpu, os && 'OS: ' + os].filter(Boolean).join(' · ');
  synchronize();
  window.TonemappingViewer = { state, refresh: render };
})();
