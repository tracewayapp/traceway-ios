#!/usr/bin/env python3
"""Checks the wireframe gallery's recording, the way the Flutter SDK's
wireframe suite checks its own.

The gallery (Tests/TracewayTests/WireframeGalleryTests.swift) runs on the iOS
Simulator: it shows every kind of UIKit and SwiftUI view, records the screen
with the real WireframeRecorder while scenarios take it through its states,
and at every checkpoint saves the picture the app drew. CI uploads what it
wrote as the `wireframe-gallery` artifact. This script then checks:

  1. structure: rrweb events in time order, a Meta event and a full
     snapshot first, mutations and touches;
  2. every mutation applies, played through a strict model of rrweb's
     replayer (a node added twice, a missing parent or sibling fails);
  3. at every checkpoint the replayed page shows the texts the scenario
     expects and none it must hide; no secret appears anywhere; animations
     recorded at least the mutations they asked for;
  4. visual (replay.mjs, in Playwright): rrweb-player renders every
     checkpoint, compared with the app's picture (fidelity: SSIM, edge
     alignment, color) and with the accepted baseline rendering;
  5. size: the bytes each scenario recorded, against the baseline.

  # The gallery of a CI run (needs gh):
  python3 CI/wireframe/run.py --gh-run 123456789

  # A gallery on disk (WIREFRAME_GALLERY_OUT of a local simulator run):
  python3 CI/wireframe/run.py --dir .build/wireframe-gallery

  --update-baseline  accepts the run as the new baseline (review report.html)
  --out DIR          where the run's files and report.html go

Needs Node with Playwright (--playwright), Chromium (--chromium) and
rrweb-player (--rrweb-player, default the dashboard's copy in
../traceway/frontend/node_modules).
"""
import argparse, html, json, os, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, '..', '..'))
SCREEN_NODE_ID = 8


class Check:
    def __init__(self):
        self.failures = []

    def __call__(self, ok, what, detail=''):
        print(('  PASS  ' if ok else '  FAIL  ') + what + (f'   [{detail}]' if detail else ''), flush=True)
        if not ok:
            self.failures.append(what + (f' [{detail}]' if detail else ''))
        return ok


# ---- rrweb, strictly --------------------------------------------------------------

class Mirror:
    """rrweb's replayer, strictly: see Tests/TracewayTests/WireframeTestSupport.swift."""

    def __init__(self):
        self.nodes = {}
        self.errors = []

    def _build(self, n, parent, with_children):
        nid = n['id']
        if nid in self.nodes:
            self.errors.append(f'id {nid} added while on the page')
        node = {'id': nid, 'tag': n.get('tagName') if n['type'] == 2 else None,
                'text': n.get('textContent') if n['type'] == 3 else None,
                'attrs': dict(n.get('attributes') or {}), 'children': [], 'parent': parent}
        self.nodes[nid] = node
        if with_children:
            for child in n.get('childNodes') or []:
                node['children'].append(self._build(child, node, True))
        return node

    def _unmap(self, node):
        self.nodes.pop(node['id'], None)
        for c in node['children']:
            self._unmap(c)

    def full(self, node):
        self.nodes = {}
        self._build(node, None, True)

    def mutation(self, d, at):
        for key in ('removes', 'adds', 'texts', 'attributes'):
            if not isinstance(d.get(key), list):
                self.errors.append(f'{at}: {key} is not a list')
                return
        for r in d['removes']:
            node, parent = self.nodes.get(r['id']), self.nodes.get(r['parentId'])
            if node is None or parent is None or node not in parent['children']:
                self.errors.append(f'{at}: bad remove {r}')
                continue
            parent['children'].remove(node)
            self._unmap(node)
        for a in d['adds']:
            parent = self.nodes.get(a['parentId'])
            if parent is None:
                self.errors.append(f'{at}: add under missing {a["parentId"]}')
                continue
            node = self._build(a['node'], parent, False)
            nxt = a.get('nextId')
            if nxt is None:
                parent['children'].append(node)
            elif nxt in self.nodes and self.nodes[nxt] in parent['children']:
                parent['children'].insert(parent['children'].index(self.nodes[nxt]), node)
            else:
                self.errors.append(f'{at}: add before missing {nxt}')
                parent['children'].append(node)
        for t in d['texts']:
            node = self.nodes.get(t['id'])
            if node is None or node['tag'] is not None:
                self.errors.append(f'{at}: bad text {t["id"]}')
                continue
            node['text'] = t['value']
        for a in d['attributes']:
            node = self.nodes.get(a['id'])
            if node is None:
                self.errors.append(f'{at}: attributes of missing {a["id"]}')
                continue
            for k, v in a['attributes'].items():
                if v is None:
                    node['attrs'].pop(k, None)
                else:
                    node['attrs'][k] = v

    def texts(self):
        out = []

        def walk(n):
            if n['text'] is not None:
                out.append(n['text'])
            for c in n['children']:
                walk(c)
        screen = self.nodes.get(SCREEN_NODE_ID)
        if screen:
            walk(screen)
        return out


def play(events, moments):
    """Plays [events] and returns the text on screen at each moment (ms)."""
    mirror = Mirror()
    shown = {}
    pending = sorted(moments.items(), key=lambda kv: kv[1])
    for i, e in enumerate(events):
        while pending and pending[0][1] < e['timestamp']:
            name, _ = pending.pop(0)
            shown[name] = mirror.texts()
        if e['type'] == 2:
            mirror.full(e['data']['node'])
        elif e['type'] == 3 and e['data'].get('source') == 0:
            mirror.mutation(e['data'], f'event {i}')
        elif e['type'] == 3 and e['data'].get('source') == 2 and e['data'].get('id') not in mirror.nodes:
            mirror.errors.append(f'event {i}: touch on a node not on the page')
    for name, _ in pending:
        shown[name] = mirror.texts()
    return mirror, shown


# ---- checks -----------------------------------------------------------------------

def check_recording(check, events, run):
    cps = run['checkpoints']
    size = len(json.dumps(events))
    kinds = {}
    for e in events:
        key = e['type'] if e['type'] != 3 else f"3.{e['data'].get('source')}"
        kinds[key] = kinds.get(key, 0) + 1
    print(f'  ...  {len(events)} events, {size // 1024} KB as JSON: {kinds}', flush=True)
    check(bool(events) and events[0]['type'] == 4 and len(events) > 1 and events[1]['type'] == 2,
          'the recording starts with a meta event and a full snapshot')
    check(all(e['type'] in (2, 3, 4, 5) for e in events), 'every event is an rrweb event',
          str({e['type'] for e in events}))
    stamps = [e['timestamp'] for e in events]
    check(stamps == sorted(stamps), 'events are in time order')
    if cps:
        check(bool(events) and events[0]['timestamp'] <= cps[0]['at'] and
              events[-1]['timestamp'] >= cps[-1]['at'], 'the recording covers the whole gallery')
    check(kinds.get('3.0', 0) > 8, 'the screen changes are mutations', f"{kinds.get('3.0', 0)} mutations")
    check(kinds.get('3.2', 0) > 4, 'touches are recorded', f"{kinds.get('3.2', 0)} touch interactions")
    check(kinds.get('3.6', 0) > 4, 'drags are recorded as touch moves', f"{kinds.get('3.6', 0)} moves")
    return {'events': len(events), 'bytes': size, 'kinds': kinds}


def check_checkpoints(check, events, run, sample):
    cps = run['checkpoints']
    mirror, shown = play(events, {cp['name']: cp['at'] + sample for cp in cps})
    check(not mirror.errors, 'every mutation applies as rrweb replays it', '; '.join(mirror.errors[:5]))
    mutations = sorted(e['timestamp'] for e in events if e['type'] == 3 and e['data'].get('source') == 0)
    results = {}
    previous = 0
    for cp in cps:
        name = cp['name']
        problems = []
        joined = '\n'.join(shown.get(name, []))
        missing = [w for w in cp['shows'] if w not in joined]
        leaked = [h for h in cp['hides'] if h in joined]
        if missing:
            problems.append(f'missing {missing}')
        if leaked:
            problems.append(f'shows {leaked}')
        count = sum(1 for t in mutations if previous < t <= cp['at'])
        if cp.get('minMutations') and count < cp['minMutations']:
            problems.append(f'{count} mutations since the last checkpoint, wanted {cp["minMutations"]}')
        previous = cp['at']
        check(not problems, f'replay at {name} shows that screen', '; '.join(problems))
        results[name] = {'problems': problems, 'mutations': count}
    text = json.dumps(events, ensure_ascii=False)
    leaked = [s for s in run['secrets'] if s in text]
    check(not leaked, 'no secret appears anywhere in the recording', f'leaked {leaked}' if leaked else
          f'{len(run["secrets"])} secrets')
    return results


def scenario_bytes(events, run):
    starts = sorted(run.get('scenarios') or [], key=lambda s: s['at'])
    out = {}
    for i, s in enumerate(starts):
        end = starts[i + 1]['at'] if i + 1 < len(starts) else float('inf')
        chosen = [e for e in events if s['at'] <= e['timestamp'] < end]
        out[s['id']] = {'bytes': len(json.dumps(chosen)), 'events': len(chosen),
                        'mutations': sum(1 for e in chosen if e['type'] == 3 and e['data'].get('source') == 0)}
    return out


def evaluate_visual(check, visual, baseline, args):
    known = baseline.get('checkpoints', {})
    floors = {'ssim': args.floor_ssim, 'edges': args.floor_edges, 'color': args.floor_color}
    verdicts = {}
    for name, v in visual['checkpoints'].items():
        problems = []
        fid = v.get('fidelity') or {}
        base = (known.get(name) or {}).get('fidelity') or {}
        for metric, floor in floors.items():
            value = fid.get(metric)
            if value is None:
                problems.append(f'no {metric}')
                continue
            if value < floor:
                problems.append(f'{metric} {value:.3f} below the floor {floor}')
            if metric in base and value < base[metric] - args.tolerance:
                problems.append(f'{metric} {value:.3f} fell from {base[metric]:.3f}')
        golden = v.get('golden')
        if golden is not None and golden['changed'] > args.max_change:
            problems.append(f'{golden["changed"] * 100:.2f}% of pixels changed from the baseline')
        verdicts[name] = problems
        check(not problems, f'visual {name}', '; '.join(problems) if problems else
              f'ssim {fid.get("ssim", 0):.3f} edges {fid.get("edges", 0):.3f} color {fid.get("color", 0):.3f}'
              + (f', {golden["changed"] * 100:.2f}% changed' if golden else ''))
    for problem in visual.get('problems', []):
        check(False, 'replay', problem)
    return verdicts


def check_sizes(check, sizes, baseline, args):
    known = baseline.get('scenarios', {})
    for sid, size in sizes.items():
        base = (known.get(sid) or {}).get('bytes')
        if base is None or args.update_baseline:
            continue
        check(size['bytes'] <= base * 1.5 + 20000, f'scenario {sid} records about as much as before',
              f'{size["bytes"] // 1024} KB, baseline {base // 1024} KB')


# ---- report -------------------------------------------------------------------------

def write_report(out, run, stats, sizes, text_results, visual, verdicts, baseline, check, key):
    e = html.escape
    known = baseline.get('checkpoints', {})
    rows = []
    for cp in run['checkpoints']:
        name = cp['name']
        v = visual.get('checkpoints', {}).get(name, {})
        fid = v.get('fidelity') or {}
        base = (known.get(name) or {}).get('fidelity') or {}
        golden = v.get('golden')
        problems = (text_results.get(name) or {}).get('problems', []) + verdicts.get(name, [])

        def metric(k):
            value = fid.get(k)
            if value is None:
                return '–'
            delta = '' if k not in base else f' <small>({value - base[k]:+.3f})</small>'
            return f'{value:.3f}{delta}'

        def img(p):
            return (f'<a href="{p}"><img src="{p}" loading="lazy"></a>' if os.path.exists(os.path.join(out, p))
                    else '<span class="none">–</span>')
        rows.append(f'''<tr class="{'fail' if problems else 'pass'}" id="{e(name)}">
<th><b>{e(name)}</b><br><span class="badge">{'FAIL' if problems else 'PASS'}</span>
<table class="m"><tr><td>SSIM</td><td>{metric('ssim')}</td></tr><tr><td>edges</td><td>{metric('edges')}</td></tr>
<tr><td>color</td><td>{metric('color')}</td></tr>
<tr><td>changed</td><td>{'–' if golden is None else f"{golden['changed'] * 100:.2f}%"}</td></tr>
<tr><td>mutations</td><td>{(text_results.get(name) or {}).get('mutations', '–')}</td></tr></table>
{''.join(f'<div class="p">{e(p)}</div>' for p in problems)}</th>
<td>{img(f'app/{name}.png')}</td><td>{img(f'replay/{name}.png')}</td>
<td>{img(f'delta/{name}.png')}</td><td>{img(f'baseline/{name}.png')}</td><td>{img(f'diff/{name}.png')}</td></tr>''')
    size_rows = ''.join(
        f'<tr><td>{e(sid)}</td><td>{s["bytes"] // 1024} KB</td><td>{s["events"]}</td><td>{s["mutations"]}</td>'
        f'<td>{(baseline.get("scenarios", {}).get(sid) or {}).get("bytes", 0) // 1024} KB</td></tr>'
        for sid, s in sizes.items())
    failures = ''.join(f'<li>{e(f)}</li>' for f in check.failures)
    passed = not check.failures
    with open(os.path.join(out, 'report.html'), 'w') as f:
        f.write(f'''<!doctype html><meta charset="utf-8"><title>iOS wireframe gallery</title>
<style>
body{{font:14px system-ui;margin:16px;color:#222}} h1{{margin:0 0 4px}}
.sum{{padding:10px 14px;border-radius:8px;margin:12px 0;background:{'#e8f5e9' if passed else '#ffebee'}}}
table.r{{border-collapse:collapse}} table.r>tbody>tr>td,table.r>tbody>tr>th{{vertical-align:top;padding:6px;border-bottom:1px solid #ddd}}
table.r th{{text-align:left;width:190px;font-weight:normal}} img{{width:200px;border:1px solid #ccc;display:block}}
tr.fail>th .badge{{background:#c62828}} .badge{{background:#2e7d32;color:#fff;border-radius:4px;padding:1px 6px;font-size:11px}}
table.m td{{padding:0 8px 0 0;font-size:12px}} .p{{color:#c62828;font-size:12px;margin-top:4px}} .none{{color:#aaa}}
label{{margin-right:12px}} table.s td{{padding:2px 10px}}
</style>
<h1>iOS wireframe gallery</h1>
<div>{e(run.get('device', ''))} iOS {e(run.get('os', ''))} · {len(run['checkpoints'])} checkpoints ·
{stats.get('events', 0)} events · {stats.get('bytes', 0) // 1024} KB · baseline {e(key)}</div>
<div class="sum"><b>{'PASSED' if passed else f'FAILED: {len(check.failures)} check(s)'}</b><ul>{failures}</ul></div>
<label><input type="checkbox" id="onlyfail"> failures only</label>
<p>Columns: what the app drew · the replay (rrweb-player at 1:1) · where they differ (brighter is more) ·
the accepted baseline rendering · the replay's changes from it (red; yellow is anti-aliasing).
SSIM, edges and color compare the replay with the app (1 is identical; in brackets the change from the baseline).</p>
<table class="r"><tr><th></th><th>App</th><th>Replay</th><th>App vs replay</th><th>Baseline</th><th>Changes</th></tr>
{''.join(rows)}</table>
<h2>Size per scenario</h2><table class="s"><tr><th>scenario</th><th>bytes</th><th>events</th><th>mutations</th><th>baseline</th></tr>{size_rows}</table>
{'<h2>Dashboard</h2><img src="dashboard/session-page.png" style="width:100%">' if os.path.exists(os.path.join(out, 'dashboard', 'session-page.png')) else ''}
<script>document.getElementById('onlyfail').onchange=e=>document.querySelectorAll('tr.pass').forEach(r=>r.style.display=e.target.checked?'none':'')</script>
''')


# ---- main -------------------------------------------------------------------------

def fetch(args, out):
    """Copies the gallery into [out]: from --dir, or the artifact of --gh-run."""
    if args.dir:
        source = os.path.abspath(args.dir)
    else:
        source = tempfile.mkdtemp(prefix='tw-gallery-')
        subprocess.run(['gh', 'run', 'download', str(args.gh_run), '-n', 'wireframe-gallery', '-D', source,
                        '-R', args.repo], check=True)
    if os.path.abspath(source) != os.path.abspath(out):
        for name in ('events.json', 'run.json'):
            shutil.copy(os.path.join(source, name), os.path.join(out, name))
        shutil.rmtree(os.path.join(out, 'app'), ignore_errors=True)
        shutil.copytree(os.path.join(source, 'app'), os.path.join(out, 'app'))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    where = ap.add_mutually_exclusive_group(required=True)
    where.add_argument('--dir', help='a gallery directory (events.json, run.json, app/)')
    where.add_argument('--gh-run', help='a CI run whose wireframe-gallery artifact to check')
    ap.add_argument('--repo', default='tracewayapp/traceway-ios')
    ap.add_argument('--out', default=os.path.expanduser('~/.cache/tw-wireframe/ios'))
    ap.add_argument('--baseline', default=os.path.join(HERE, 'baseline'))
    ap.add_argument('--update-baseline', action='store_true')
    ap.add_argument('--tolerance', type=float, default=0.03, help='how far a fidelity metric may fall')
    ap.add_argument('--max-change', type=float, default=0.002, help='share of pixels that may change from the baseline')
    ap.add_argument('--floor-ssim', type=float, default=0.5)
    ap.add_argument('--floor-edges', type=float, default=0.3)
    ap.add_argument('--floor-color', type=float, default=0.6)
    ap.add_argument('--playwright', default=os.environ.get('PLAYWRIGHT_DIR', os.path.expanduser('~/Work/workspace/js-client/node_modules/playwright')))
    ap.add_argument('--rrweb-player', default=os.path.join(REPO, '..', 'traceway', 'frontend', 'node_modules', 'rrweb-player'))
    ap.add_argument('--chromium', default=shutil.which('chromium') or '/usr/bin/chromium')
    ap.add_argument('--no-visual', action='store_true', help='skip the rendering in rrweb-player')
    args = ap.parse_args()

    out = os.path.abspath(args.out)
    os.makedirs(out, exist_ok=True)
    fetch(args, out)
    with open(os.path.join(out, 'events.json')) as f:
        events = json.load(f)
    with open(os.path.join(out, 'run.json')) as f:
        run = json.load(f)
    key = f"ios-{int(run['width'])}x{int(run['height'])}"
    baseline_dir = os.path.join(args.baseline, key)
    baseline = {}
    if os.path.exists(os.path.join(baseline_dir, 'baseline.json')):
        with open(os.path.join(baseline_dir, 'baseline.json')) as f:
            baseline = json.load(f)

    check = Check()
    sample = run.get('sampleMs', 150)
    stats = check_recording(check, events, run)
    text_results = check_checkpoints(check, events, run, sample)
    sizes = scenario_bytes(events, run)
    check_sizes(check, sizes, baseline, args)

    visual, verdicts = {'checkpoints': {}}, {}
    if not args.no_visual:
        subprocess.run(['node', os.path.join(HERE, 'replay.mjs'), '--out', out, '--playwright', args.playwright,
                        '--rrweb-player', os.path.abspath(args.rrweb_player), '--chromium', args.chromium,
                        '--sample', str(sample), '--baseline', baseline_dir], check=True)
        with open(os.path.join(out, 'visual.json')) as f:
            visual = json.load(f)
        verdicts = evaluate_visual(check, visual, baseline, args)

    if args.update_baseline:
        os.makedirs(baseline_dir, exist_ok=True)
        for cp in run['checkpoints']:
            replay_png = os.path.join(out, 'replay', f"{cp['name']}.png")
            if os.path.exists(replay_png):
                shutil.copy(replay_png, os.path.join(baseline_dir, f"{cp['name']}.png"))
        with open(os.path.join(baseline_dir, 'baseline.json'), 'w') as f:
            json.dump({'checkpoints': visual.get('checkpoints', {}), 'scenarios': sizes}, f, indent=1, sort_keys=True)
        print(f'  ...  baseline written to {baseline_dir}')

    write_report(out, run, stats, sizes, text_results, visual, verdicts, baseline, check, key)
    print(f'\nreport: {os.path.join(out, "report.html")}')
    if check.failures:
        print(f'{len(check.failures)} check(s) failed')
        sys.exit(1)
    print('all checks passed')


if __name__ == '__main__':
    main()
