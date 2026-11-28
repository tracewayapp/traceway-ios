#!/usr/bin/env python3
"""End-to-end check of the iOS SDK against a running Traceway server.

Runs the scripted app (Tests/TracewayTests/E2EScriptTests.swift, the real
client on this machine), follows its E2E_PHASE lines and asserts through the
dashboard API what the server holds at each point, the same phases as the
Flutter SDK's end-to-end check:

  1. before the exception: breadcrumbs, taps included, are NOT on the server
     (ring buffer); the session is
  2. after it: the issue, its breadcrumbs, the tap with the selector of the
     view, the HTTP span, the session and a wireframe replay clip
  3. a recording trigger from the app's local settings (navigation
     /users/{id}, a tap on #open-profile, a log line) starts a capture: the
     session lists the trigger as a recording reason, logs stream while it
     runs and not after, and replay segments stream
  4. a capture started from the dashboard API: its lookback comes up, logs
     stream, and cancelling it stops them
  5. a remote rule whose click step is the selector the server recorded for
     a tap: the server accepts it and the app matches it on the next tap;
     a second rule sets replay.images to off
  6. the app saves its buffer going to the background and is killed; the
     next start resumes the session, reports the earlier run's crash with
     its iOS stack trace, and its first error brings up what the killed run
     had buffered; the session's traceway.replay.images, wifi at its start,
     is now off
  7. metrics: the SDK's app.* ones a run without UIKit makes (session, user,
     the crash, requests) and app-defined ones (Traceway.metric and count)
     reach the server, and the project's Mobile Performance dashboard
     charts them

The replay is the wireframe gallery's recording when --gallery points at one
(CI/wireframe/run.py --gh-run fetches it), else a synthetic screen.

  python3 CI/e2e/run.py --base http://127.0.0.1:8092 --email .. --password .. \\
      [--project "iOS App"] [--gallery ~/.cache/tw-wireframe/ios] [--swift swift]
"""
import argparse, datetime, json, os, shutil, subprocess, sys, tempfile, threading, time
import urllib.error, urllib.parse, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, '..', '..'))
JOURNEY_CAPTURE_SECONDS = 20


class Api:
    def __init__(self, base, email, password, project_name):
        self.base = base.rstrip('/')
        self.jwt = None
        status, body = self.call('POST', '/api/login', {'email': email, 'password': password}, project=False)
        if status != 200:
            sys.exit(f'login failed: {status} {body}')
        self.jwt = body['token']
        ios = [p for p in body['projects'] if p['framework'] == 'ios'
               and (not project_name or p['name'] == project_name)]
        if not ios:
            sys.exit('no iOS project in this account')
        self.project = ios[0]
        status, projects = self.call('GET', '/api/projects', project=False)
        for p in projects if isinstance(projects, list) else (projects or {}).get('data') or []:
            if p.get('id') == self.project['id'] and p.get('token'):
                self.project['token'] = p['token']

    def call(self, method, path, body=None, project=True):
        url = self.base + path
        if project:
            url += ('&' if '?' in url else '?') + 'projectId=' + self.project['id']
        headers = {'Content-Type': 'application/json'}
        if self.jwt:
            headers['Authorization'] = 'Bearer ' + self.jwt
        req = urllib.request.Request(url, method=method, headers=headers,
                                     data=None if body is None else json.dumps(body).encode())
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                raw = r.read()
                return r.status, (json.loads(raw) if raw else None)
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode(errors='replace')[:400]

    def page(self, path, since, extra=None):
        now = datetime.datetime.now(datetime.timezone.utc)
        size = 500 if path == '/api/logs' else 100
        body = {'fromDate': since.isoformat(), 'toDate': (now + datetime.timedelta(minutes=5)).isoformat(),
                'pagination': {'page': 1, 'pageSize': size}}
        body.update(extra or {})
        status, data = self.call('POST', path, body)
        if status != 200:
            sys.exit(f'{path} -> {status} {data}')
        return data['data'] or []


class Check:
    def __init__(self):
        self.failed = []

    def __call__(self, ok, what, detail=''):
        print(('  PASS  ' if ok else '  FAIL  ') + what + (f'   [{detail}]' if detail else ''), flush=True)
        if not ok:
            self.failed.append(what)
        return ok


def event_name(record):
    return (record.get('logAttributes') or {}).get('event.name') or ''


def attrs(record):
    return record.get('logAttributes') or {}


def snapshot(api, since, instance):
    logs = [r for r in api.page('/api/logs', since)
            if (r.get('resourceAttributes') or {}).get('service.instance.id') == instance]
    names = {}
    for r in logs:
        name = event_name(r)
        names.setdefault('(console)' if name in ('', 'browser.console') else name, []).append(r)
    # Span search rows carry no resource attributes: the run's spans are the
    # SDK's since it started.
    spans = [s for s in api.page('/api/spans/search', since) if s.get('scopeName') == 'traceway-ios']
    issues = api.page('/api/exception-stack-traces', since, {'orderBy': 'last_seen'})
    sessions = [s for s in api.page('/api/sessions', since)
                if (s.get('attributes') or {}).get('service.instance.id') == instance]
    return names, spans, issues, sessions


def bodies(names):
    return [r.get('body') for r in names.get('(console)', [])]


def recording(api, session):
    started = urllib.parse.quote(session['startedAt'])
    status, rec = api.call('GET', f"/api/sessions/{session['id']}/recording?startedAt={started}")
    return (rec or {}).get('events') or [] if isinstance(rec, dict) else []


def is_rrweb(events):
    return bool(events) and events[0].get('type') == 4 and any(e.get('type') == 2 for e in events)


# The SDK's metrics a run without UIKit makes; the others need screens, frames and the main thread.
SCRIPT_METRICS = {'app.session', 'app.user', 'app.user.affected', 'app.crash', 'app.request.duration',
                  'app.request.failed', 'app.request.failed.total'}


def check_metrics(api, since, check):
    """Phase 7: the SDK's app.* metrics and app-defined ones, and the project's default dashboard."""
    print('\n[7] metrics and the Mobile Performance dashboard', flush=True)
    time.sleep(12)  # the server writes client metrics every 10 s
    # Client metrics are kept per minute, stamped at its start.
    metrics_since = since.replace(second=0, microsecond=0)

    def metric(query):
        now = datetime.datetime.now(datetime.timezone.utc)
        status, body = api.call('POST', '/api/metrics/query', {
            'queries': [query], 'from': metrics_since.isoformat(),
            'to': (now + datetime.timedelta(minutes=2)).isoformat(), 'wholeRange': True})
        if status != 200:
            return {'_error': f'{status} {body}'}
        series = ((body or {}).get('results') or [{}])[0].get('series') or {}
        return {k: sum(p.get('value') or 0 for p in v) for k, v in series.items() if v}

    def one(name, aggregation, group_by=None):
        return metric({'name': name, 'aggregation': aggregation, **({'groupBy': group_by} if group_by else {})})

    def total(series):
        # An ungrouped series is keyed `__all__`.
        return sum(v for k, v in series.items() if k != '_error')

    sessions_n, users = total(one('app.session', 'sum')), total(one('app.user', 'sum'))
    check(sessions_n == 1 and users == 1, 'one session and one user: the resumed run counted neither again',
          f'{sessions_n:.0f} sessions, {users:.0f} users')
    crashes = total(one('app.crash', 'sum'))
    check(crashes == 1, "the earlier run's crash is counted", f'{crashes:.0f}')
    affected = one('app.user.affected', 'sum', 'issue')
    check('crash' in affected, 'the user is counted as affected by the crash', f'{affected}')
    hosts = one('app.request.duration', 'count', 'host')
    check(hosts.get('api.example.com') == 1, 'the request duration, by host', f'{hosts}')
    checkout, cart = total(one('e2e.checkout', 'p75')), total(one('e2e.cart_add', 'sum'))
    check(1100 <= checkout <= 1350 and cart == 3, 'app-defined metrics arrive (Traceway.metric, Traceway.count)',
          f'p75 {checkout:.0f}, count {cart:.0f}')

    status, listing = api.call('GET', '/api/dashboards')
    boards = (listing or {}).get('dashboards') or [] if isinstance(listing, dict) else []
    board = [b for b in boards if b.get('templateKey') == 'mobile-performance']
    check(len(board) == 1, 'the project came with the Mobile Performance dashboard', f'{[b.get("name") for b in boards]}')
    if not board:
        return
    status, detail = api.call('GET', f"/api/dashboards/{board[0]['id']}")
    widgets = (detail or {}).get('widgets') or [] if isinstance(detail, dict) else []
    missing, uikit = [], []
    for w in widgets:
        config = json.loads(w['config']) if isinstance(w['config'], str) else w['config']
        sources = config.get('sources', [])
        if not any(src.get('name') in SCRIPT_METRICS for src in sources):
            uikit.append(w['title'])
            continue
        if not any(total(metric({k: v for k, v in src.items() if k in ('name', 'aggregation', 'groupBy')}))
                   for src in sources):
            missing.append(w['title'])
    print(f'        {len(widgets)} widgets, {len(uikit)} chart what only a UIKit app measures', flush=True)
    check(widgets and len(uikit) < len(widgets) and not missing,
          'every widget of the dashboard that charts what the script sends has data', f'empty: {missing}')


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--base', required=True, help='the Traceway server, e.g. http://127.0.0.1:8092')
    ap.add_argument('--email', required=True)
    ap.add_argument('--password', required=True)
    ap.add_argument('--project', default='')
    ap.add_argument('--gallery', default='', help='a wireframe gallery directory to replay as the screen')
    ap.add_argument('--swift', default=os.environ.get('SWIFT', 'swift'))
    ap.add_argument('--out', default=os.path.expanduser('~/.cache/tw-ios-e2e/run'))
    args = ap.parse_args()

    api = Api(args.base, args.email, args.password, args.project)
    token = api.project.get('token')
    if not token:
        sys.exit('the project token is not readable through the API')
    dsn = f"{token}@{args.base}"
    check = Check()
    since = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=5)
    status, rules = api.call('GET', '/api/sdk-config/rules')
    for rule in ((rules or {}).get('data') or []) if isinstance(rules, dict) else []:
        api.call('DELETE', f"/api/sdk-config/rules/{rule['id']}")
    os.makedirs(args.out, exist_ok=True)
    state = os.path.join(args.out, 'state')
    control = os.path.join(args.out, 'control')
    for d in (state, control):
        shutil.rmtree(d, ignore_errors=True)
        os.makedirs(d)

    print('building the tests', flush=True)
    subprocess.run([args.swift, 'build', '--build-tests', '-j', '2'], cwd=REPO, check=True,
                   stdout=subprocess.DEVNULL)
    bin_path = subprocess.run([args.swift, 'build', '--show-bin-path'], cwd=REPO, check=True,
                              capture_output=True, text=True).stdout.strip().splitlines()[-1]
    bundle = os.path.join(bin_path, 'TracewayPackageTests.xctest')
    # `swift test` holds the test's output until it ends: run the bundle itself.
    if sys.platform == 'darwin':
        test_command = ['xcrun', 'xctest', '-XCTest', 'TracewayTests.E2EScriptTests/testScript', bundle]
    else:
        test_command = [bundle, 'TracewayTests.E2EScriptTests/testScript']

    phases, lines = {}, []
    proc = None

    def launch(scenario):
        nonlocal proc
        phases.clear()
        env = dict(os.environ, TRACEWAY_E2E_DSN=dsn, E2E_CONTROL_DIR=control, E2E_STATE_DIR=state,
                   E2E_SCENARIO=scenario)
        if args.gallery:
            env['E2E_GALLERY'] = os.path.abspath(args.gallery)
        proc = subprocess.Popen(test_command, cwd=REPO,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors='replace', env=env)

        def pump(stream):
            with open(os.path.join(args.out, f'app-{scenario}.log'), 'w') as log:
                for line in stream:
                    lines.append(line.rstrip())
                    log.write(line)
                    if 'E2E_PHASE ' in line:
                        rest = line.split('E2E_PHASE ', 1)[1].strip()
                        name = rest.split(' ')[0]
                        values = dict(kv.split('=', 1) for kv in rest.split(' ')[1:] if '=' in kv)
                        phases[name] = (time.time(), values)
                        print('app: ' + rest, flush=True)

        threading.Thread(target=pump, args=(proc.stdout,), daemon=True).start()

    def wait_phase(name, timeout):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if name in phases:
                return phases[name][1]
            if proc.poll() is not None and name not in phases:
                time.sleep(0.5)
                if name in phases:
                    return phases[name][1]
                break
            time.sleep(0.2)
        print('\n'.join(lines[-60:]))
        sys.exit(f'app never reached phase {name}')

    def go(name):
        open(os.path.join(control, f'{name}.go'), 'w').close()

    def finish():
        if proc is not None and proc.poll() is None:
            try:
                proc.wait(timeout=60)
            except subprocess.TimeoutExpired:
                proc.kill()

    try:
        launch('main')
        start = wait_phase('start', 300)
        instance, session_id = start['instance'], start['session']

        # ---- 1. quiet phase ------------------------------------------------
        wait_phase('breadcrumbs_done', 60)
        time.sleep(6)
        print('\n[1] before the exception: breadcrumbs must still be on the device')
        names, spans, issues, sessions = snapshot(api, since, instance)
        check('session.start' in names, 'session.start was sent (control records always stream)')
        for breadcrumb in ('(console)', 'browser.navigation', 'traceway.action', 'e2e_event',
                           'browser.user_action.click'):
            check(breadcrumb not in names, f'no {breadcrumb} record on the server yet')
        check(not spans, 'no HTTP span on the server yet', f'{len(spans)} spans')
        check(not issues, 'no issue yet', f'{len(issues)}')
        check(len(sessions) == 1, 'the session exists', f'{len(sessions)} sessions')
        images = (sessions[0].get('attributes') or {}).get('traceway.replay.images') if sessions else None
        check(images == 'wifi', 'the session names the replay images policy it started with, Wi-Fi only by default',
              f'{images}')
        go('breadcrumbs_done')

        # ---- 2. the exception ----------------------------------------------
        wait_phase('exception_sent', 120)
        time.sleep(6)
        print('\n[2] after the exception: issue, breadcrumbs, tap, span, session and clip')
        names, spans, issues, sessions = snapshot(api, since, instance)
        check(len(names.get('exception', [])) == 1, 'one exception record', f"{len(names.get('exception', []))}")
        check('e2e breadcrumb log' in bodies(names), 'the log breadcrumb was flushed')
        nav = [(attrs(r).get('navigation.action'), attrs(r).get('url.full')) for r in names.get('browser.navigation', [])]
        check(any(p == '/checkout' for _, p in nav) and len(nav) >= 2, 'navigation breadcrumbs flushed', str(nav))
        clicks = names.get('browser.user_action.click', [])
        pay = [attrs(r) for r in clicks if attrs(r).get('app.widget.id') == 'pay']
        check(len(pay) == 1, 'the tap was flushed with the breadcrumbs', f'{len(clicks)} clicks')
        pay = pay[0] if pay else {}
        check(pay.get('browser.css_selector') == 'UIButton#pay' and pay.get('browser.tag_name') == 'UIButton',
              'the tap names the view', f"{pay.get('browser.css_selector')}")
        check(pay.get('app.widget.text') == 'Pay now' and pay.get('app.screen.name') == '/checkout',
              'the tap carries the shown text and the screen', f"{pay.get('app.widget.text')} {pay.get('app.screen.name')}")
        actions = names.get('traceway.action', [])
        check(len(actions) == 1, 'the custom action was flushed', f'{len(actions)}')
        check(len(names.get('e2e_event', [])) == 1, 'the tracked event was flushed')
        check(len(spans) == 1 and spans[0].get('name') == 'GET', 'the HTTP client span was flushed', f'{len(spans)} spans')

        check(len(issues) == 1, 'one issue', f'{len(issues)} issues')
        record = attrs(names['exception'][0]) if names.get('exception') else {}
        exception_id = record.get('traceway.exception.id')
        status, detail = api.call('POST', f'/api/exception-stack-traces/by-id/{exception_id}', {})
        check(status == 200, 'the issue is addressable by the SDK-generated exception id', f'{status}')
        detail = detail if isinstance(detail, dict) else {}
        exc = detail.get('exception') or {}
        stack = exc.get('stackTrace', '')
        check('CheckoutError' in stack and 'payment of 1999 declined' in stack, 'the stack trace has the error line',
              stack[:120])
        issue_attrs = exc.get('attributes') or {}
        check(issue_attrs.get('os.name') == 'ios' and issue_attrs.get('user.id') == 'e2e-user'
              and issue_attrs.get('service.instance.id') == instance, 'the issue carries device, user and instance',
              json.dumps({k: issue_attrs.get(k) for k in ('os.name', 'user.id', 'service.instance.id')}))
        check(exc.get('appVersion') == 'e2e-1.0.0', 'the issue carries the app version', f"{exc.get('appVersion')}")
        check(detail.get('sessionId') == session_id, 'the issue is linked to the session')
        check(issue_attrs.get('traceway.replay.status') == 'requested', 'the replay status is requested',
              f"{issue_attrs.get('traceway.replay.status')}")
        events = (detail.get('sessionRecording') or {}).get('events') or []
        check(is_rrweb(events), 'the issue has a wireframe clip: a Meta event, then a full snapshot',
              f'{len(events)} events')
        if events and not args.gallery:
            wireframe = json.dumps(events)
            check('data:image/' not in wireframe, 'over-budget synthetic wireframe uploads no raster data URLs')
            check(all(f'im p{i}' in wireframe for i in range(4)) and 'width:64px;height:64px' in wireframe
                  and 'Pay now' in wireframe, 'uploaded layout keeps all four picture boxes and checkout text')
        if events:
            span = (events[-1]['timestamp'] - events[0]['timestamp']) / 1000
            check(0 < span <= 31, 'the clip covers the 30 s before the exception at most', f'{span:.1f}s')

        until = (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(minutes=5)).isoformat()
        status, timeline = api.call('GET', f"/api/sessions/{session_id}/timeline?from={urllib.parse.quote(since.isoformat())}"
                                           f"&to={urllib.parse.quote(until)}")
        text = json.dumps(timeline)
        check(status == 200 and 'e2e breadcrumb log' in text and '/checkout' in text and 'api.example.com' in text,
              'the session timeline shows the log, navigation and network breadcrumbs', f'{status}')
        check('UIButton#pay' in text, 'the session timeline shows the tap with its selector')
        go('exception_sent')

        # ---- 3. a recording trigger from local settings --------------------
        wait_phase('journey_started', 60)
        time.sleep(10)
        print('\n[3] recording trigger: navigation /users/{id} -> tap #open-profile -> log')
        names, spans, issues, sessions = snapshot(api, since, instance)
        fired = [attrs(r) for r in names.get('traceway.trigger.fired', [])
                 if attrs(r).get('traceway.trigger.id') == 'e2e-open-profile']
        check(len(fired) == 1, 'the trigger fired once', f'{len(fired)}')
        started = [attrs(r) for r in names.get('traceway.capture.started', [])
                   if attrs(r).get('traceway.capture.source') == 'trigger']
        check(len(started) == 1, 'a capture started on the device', f'{len(started)}')
        profile = [attrs(r) for r in names.get('browser.user_action.click', [])
                   if attrs(r).get('app.widget.id') == 'open-profile']
        check(len(profile) == 1 and profile[0].get('browser.css_selector') == 'UIButton#open-profile'
              and profile[0].get('app.screen.name') == '/users/42', 'the journey tap was uploaded with the lookback')
        check(any(b and 'Profile loaded for 42' in b for b in bodies(names)), 'the journey log line was uploaded')
        ticks = [b for b in bodies(names) if b and b.startswith('e2e journey tick')]
        check(len(ticks) >= 5, 'logs stream while the capture runs', f'{len(ticks)} ticks')
        status, session_detail = api.call('POST', f'/api/sessions/{session_id}', {})
        reasons = ((session_detail or {}).get('session') or {}).get('recordingReasons') or [] \
            if isinstance(session_detail, dict) else []
        journey = [r for r in reasons if r.get('triggerId') == 'e2e-open-profile']
        check(bool(journey) and journey[0].get('sequence') ==
              'navigation(/users/{id}) → click(#open-profile) → log(Profile loaded)',
              'the session lists the trigger as a recording reason, with its sequence',
              journey[0].get('sequence') if journey else json.dumps(reasons)[:300])

        wait_phase('journey_done', 120)
        time.sleep(8)
        names, spans, issues, sessions = snapshot(api, since, instance)
        ticks = [b for b in bodies(names) if b and b.startswith('e2e journey tick')]
        last = max([int(t.rsplit(' ', 1)[1]) for t in ticks] or [-1])
        check(JOURNEY_CAPTURE_SECONDS - 6 <= last <= JOURNEY_CAPTURE_SECONDS + 1, 'streaming ended with the capture',
              f'last streamed tick {last}')
        check('e2e after journey' not in bodies(names), 'logs are buffered again after the capture')
        segments = recording(api, sessions[0]) if sessions else []
        check(is_rrweb(segments), 'the session recording replays in rrweb', f'{len(segments)} events')
        snapshots = sum(1 for e in segments if e.get('type') == 2)
        check(snapshots >= 2, 'the session has the error clip and the streamed segments', f'{snapshots} full snapshots')
        if not args.gallery:
            check(any('url(data:image/png;base64,iVBOR' in json.dumps(event) for event in segments),
                  'a later independently playable segment retains its small PNG')
        go('journey_done')

        # ---- 4. a capture from the dashboard -------------------------------
        wait_phase('await_capture', 60)
        print('\n[4] a capture started from the dashboard, then cancelled')
        status, capture = api.call('POST', '/api/sdk-config/captures', {
            'target': {'kind': 'instance', 'value': instance}, 'durationMinutes': 5,
            'lookbackSeconds': 60, 'replay': True, 'label': 'e2e'})
        check(status in (200, 201), 'capture created through the dashboard API', f'{status} {capture if status >= 300 else ""}')
        capture_id = (capture or {}).get('id') if isinstance(capture, dict) else None
        go('await_capture')
        wait_phase('capture_running', 90)
        time.sleep(4)
        names, spans, issues, sessions = snapshot(api, since, instance)
        remote = [attrs(r) for r in names.get('traceway.capture.started', [])
                  if attrs(r).get('traceway.capture.source') == 'remote']
        check(len(remote) == 1 and remote[0].get('traceway.capture.id') == capture_id, 'the app started the capture',
              f'{len(remote)}')
        check(all(f'e2e pre-capture tick {i}' in bodies(names) for i in range(3)) and 'e2e after journey' in bodies(names),
              'the lookback brought up what was buffered')
        remote_ticks = [b for b in bodies(names) if b and b.startswith('e2e remote tick')]
        check(len(remote_ticks) >= 10, 'logs stream during the capture', f'{len(remote_ticks)}')
        tagged = [r for r in names.get('(console)', []) if capture_id and capture_id in attrs(r).get('traceway.capture.ids', '')]
        check(len(tagged) >= 10, 'streamed records carry the capture id', f'{len(tagged)}')
        status, listing = api.call('GET', '/api/sdk-config/captures')
        mine = [c for c in ((listing or {}).get('data') or []) if c.get('id') == capture_id] if isinstance(listing, dict) else []
        check(bool(mine) and (mine[0].get('status') or '').lower() == 'collecting', 'the dashboard sees the capture collecting',
              mine[0].get('status') if mine else str(listing)[:200])
        status, _ = api.call('DELETE', f'/api/sdk-config/captures/{capture_id}')
        check(status in (200, 204), 'capture cancelled', f'{status}')
        go('capture_running')
        wait_phase('capture_cancelled', 90)
        time.sleep(6)
        names, spans, issues, sessions = snapshot(api, since, instance)
        check('e2e after cancel' not in bodies(names), 'logs are buffered again after the cancel')

        # ---- 5. a rule built from the selector the server recorded ---------
        print('\n[5] a remote rule whose click step is the selector the server recorded')
        selector = pay.get('browser.css_selector') or 'UIButton#pay'
        status, body = api.call('POST', '/api/sdk-config/rules', {
            'name': 'e2e remote click', 'enabled': True, 'conditions': {},
            'settings': {'signals': {'custom': {'mode': 'stream', 'sampleRate': 1}},
                         'triggers': [{'id': 'e2e-remote-pay', 'name': 'Pay tapped',
                                       'steps': [{'match': {'event': {'type': 'click', 'value': selector}}}],
                                       'actions': [{'type': 'emit', 'eventName': 'e2e_paid'}]}]},
        })
        check(status in (200, 201), f'the server accepts the recorded selector {selector!r} in a rule',
              f'{status} {body if status >= 300 else ""}')
        status, body = api.call('POST', '/api/sdk-config/rules', {
            'name': 'e2e replay images off', 'enabled': True, 'conditions': {},
            'settings': {'replay': {'images': 'off'}}})
        check(status in (200, 201), 'the server accepts a rule that turns replay images off',
              f'{status} {body if status >= 300 else ""}')
        go('capture_cancelled')
        wait_phase('rule_tapped', 90)
        time.sleep(6)
        names, spans, issues, sessions = snapshot(api, since, instance)
        remote_fired = [r for r in names.get('traceway.trigger.fired', []) if attrs(r).get('traceway.trigger.id') == 'e2e-remote-pay']
        check(len(remote_fired) == 1, 'the app matched the next tap against it', f'{len(remote_fired)}')
        check(len(names.get('e2e_paid', [])) == 1, 'the rule streamed its event', f"{len(names.get('e2e_paid', []))}")
        check(len(issues) == 1, 'still one issue', f'{len(issues)}')
        go('rule_tapped')

        # ---- 6. killed in the background, restarted ------------------------
        killed = wait_phase('killed', 60)
        finish()
        print('\n[6] the buffer outlives a kill in the background')
        names, spans, issues, sessions = snapshot(api, since, instance)
        check('e2e before kill' not in bodies(names), 'the killed run sent its buffer nowhere')
        launch('resume')
        resumed = wait_phase('resumed', 300)
        check(resumed.get('session') == killed.get('session') == session_id, 'the next start continued the session',
              f"{resumed.get('session')}")
        check(resumed.get('instance') == instance, 'the instance id survives the restart')
        wait_phase('resume_done', 90)
        time.sleep(6)
        names, spans, issues, sessions = snapshot(api, since, instance)
        restored = [r for r in names.get('(console)', []) if r.get('body') == 'e2e before kill']
        check(len(restored) == 1 and attrs(restored[0]).get('session.id') == session_id,
              "its error brought up the log the killed run had buffered", f'{len(restored)}')
        crashes = [attrs(r) for r in names.get('exception', []) if attrs(r).get('traceway.crash') in (True, 'true')]
        check(len(crashes) == 1, "the earlier run's crash was reported", f'{len(crashes)}')
        crash_stack = crashes[0].get('exception.stacktrace', '') if crashes else ''
        # The server symbolicates the binary-image frames; without the build's
        # dSYM uploaded a frame names its image and offset.
        check(crash_stack.startswith('Fatal Signal SIGSEGV (11)')
              and ('TracewayExample+0x460' in crash_stack
                   or '2dd71042118432be8f92dd4e3d3fe24a 0x460 TracewayExample' in crash_stack),
              'the crash carries its iOS stack trace, symbolicated by the server', crash_stack[:160])
        messages = names.get('traceway.message', [])
        check(any((r.get('body') or '') == 'e2e after restart' or 'e2e after restart' in json.dumps(r) for r in messages),
              'the message after the restart was sent', f'{len(messages)} messages')
        check(len(issues) >= 3, 'the crash, the message and the second error are issues', f'{len(issues)}')
        session = next((s for s in sessions if s['id'] == session_id), {})
        images = (session.get('attributes') or {}).get('traceway.replay.images')
        check(images == 'off', 'the rule turned replay images off: the resumed session says so', f'{images}')
        go('resume_done')
        finish()

        # ---- 7. metrics and the default dashboard --------------------------
        check_metrics(api, since, check)
    finally:
        if proc is not None and proc.poll() is None:
            proc.kill()

    with open(os.path.join(args.out, 'result.json'), 'w') as f:
        json.dump({'instance': instance, 'session': session_id, 'project': api.project['id'],
                   'failed': check.failed}, f, indent=1)
    print(f"\n{'all checks passed' if not check.failed else f'{len(check.failed)} check(s) failed'}")
    sys.exit(1 if check.failed else 0)


if __name__ == '__main__':
    main()
