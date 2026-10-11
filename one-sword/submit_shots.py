#!/usr/bin/env python3
"""Queue every shot in shots.json on a ComfyUI server and download the results.

The workflows must be the LTX-2.5 I2V / FLF2V workflows exported in API format
(ComfyUI: Workflow -> Export (API)) into api/; files named *I2V* / *FLF2V* are
found automatically. Standard library only.

    python3 submit_shots.py --runpod-server <pod-id>  # = https://<pod-id>-8188.proxy.runpod.net
    python3 submit_shots.py --server http://127.0.0.1:8188
    python3 submit_shots.py --only 2C,2D --seed 77    # re-roll two shots
    python3 submit_shots.py --dry-run                 # check files and node mapping
"""
import argparse
import json
import mimetypes
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path

HERE = Path(__file__).resolve().parent
# RunPod's proxy may reject urllib's default user agent.
HEADERS = {'User-Agent': 'onesword-submit/1.0'}


class ServerError(Exception):
    pass


def request(server, path, data=None, content_type=None, timeout=60):
    headers = dict(HEADERS)
    if content_type:
        headers['Content-Type'] = content_type
    req = urllib.request.Request(server + path, data=data, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.read()
    except urllib.error.HTTPError as e:
        raise ServerError(f'{path}: HTTP {e.code}\n{e.read().decode(errors="replace")}') from None


def request_json(server, path, payload=None):
    data = None if payload is None else json.dumps(payload).encode()
    body = request(server, path, data, 'application/json' if data else None)
    return json.loads(body)


def upload_image(server, path, subfolder):
    """Upload a keyframe to ComfyUI's input folder; returns the LoadImage value."""
    boundary = uuid.uuid4().hex
    mime = mimetypes.guess_type(path.name)[0] or 'application/octet-stream'
    parts = []
    for name, value in (('type', 'input'), ('subfolder', subfolder), ('overwrite', 'true')):
        parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'.encode())
    parts.append(
        f'--{boundary}\r\nContent-Disposition: form-data; name="image"; filename="{path.name}"\r\n'
        f'Content-Type: {mime}\r\n\r\n'.encode() + path.read_bytes() + b'\r\n')
    parts.append(f'--{boundary}--\r\n'.encode())
    body = request(server, '/upload/image', b''.join(parts), f'multipart/form-data; boundary={boundary}')
    info = json.loads(body)
    return f'{info["subfolder"]}/{info["name"]}' if info.get('subfolder') else info['name']


def find(workflow, class_type, title=None, required=True):
    """Node ids of class_type whose title contains `title` (case-insensitive)."""
    ids = [nid for nid, node in workflow.items()
           if node.get('class_type') == class_type
           and (title is None or title.lower() in node.get('_meta', {}).get('title', '').lower())]
    if required and not ids:
        label = f'{class_type} titled "{title}"' if title else class_type
        raise SystemExit(f'Node not found in the API workflow: {label}. '
                         'Was it exported with Workflow -> Export (API) from an LTX-2.5 template?')
    return ids


def set_input(workflow, ids, name, value):
    for nid in ids:
        workflow[nid]['inputs'][name] = value


def find_api_workflow(mode):
    """api/<mode>.json, or the single api/*<MODE>*.json exported from ComfyUI."""
    exact = HERE / f'api/{mode}.json'
    if exact.is_file():
        return exact
    matches = [p for p in sorted((HERE / 'api').glob('*.json'))
               if f'-{mode}-' in f'-{p.stem.lower()}-'.replace('.', '-')]
    if len(matches) > 1:
        raise SystemExit(f'Several {mode.upper()} workflows in api/: {", ".join(p.name for p in matches)}. '
                         f'Choose one with --{mode}.')
    return matches[0] if matches else exact


def tune_keyframes(wf, strength):
    """Same keyframe settings as setup-comfyui-ltx25.sh, for workflows exported
    from an install that predates them (upstream strength 0.7, nearest resize)."""
    for node in wf.values():
        kind, inputs = node.get('class_type'), node.get('inputs', {})
        value = inputs.get('strength')
        # The I2V second pass is already 1.0 and stays there.
        if kind == 'LTXVImgToVideoInplace' and isinstance(value, (int, float)) and value < 1:
            inputs['strength'] = strength
        elif kind == 'LTXVAddGuide' and isinstance(value, (int, float)):
            inputs['strength'] = strength
        elif kind == 'ResizeImageMaskNode' and inputs.get('scale_method') == 'nearest-exact':
            inputs['scale_method'] = 'lanczos'


def build(template, shot, config, images):
    """Fill one shot into a copy of the API workflow."""
    wf = json.loads(json.dumps(template))
    if config.get('frame_strength') is not None:
        tune_keyframes(wf, config['frame_strength'])
    loads = find(wf, 'LoadImage')
    if shot['mode'] == 'flf2v':
        set_input(wf, find(wf, 'LoadImage', 'first'), 'image', images['first'])
        set_input(wf, find(wf, 'LoadImage', 'last'), 'image', images['last'])
    else:
        set_input(wf, find(wf, 'LoadImage', 'first', required=False) or loads, 'image', images['first'])
    prompt = f'{config["style"]} {shot["prompt"]}'.strip()
    set_input(wf, find(wf, 'PrimitiveStringMultiline', 'prompt'), 'value', prompt)
    set_input(wf, find(wf, 'PrimitiveInt', 'duration'), 'value', shot['duration'])
    set_input(wf, find(wf, 'PrimitiveInt', 'width'), 'value', shot.get('width', config['width']))
    set_input(wf, find(wf, 'PrimitiveInt', 'height'), 'value', shot.get('height', config['height']))
    set_input(wf, find(wf, 'PrimitiveInt', 'frame rate'), 'value', config['fps'])
    # The enhancer rewrites appearance details, and I2V must not fall back to T2V.
    set_input(wf, find(wf, 'PrimitiveBoolean', 'prompt enhance'), 'value', False)
    set_input(wf, find(wf, 'PrimitiveBoolean', 'text to video', required=False), 'value', False)
    set_input(wf, find(wf, 'RandomNoise'), 'noise_seed', shot['seed'])
    set_input(wf, find(wf, 'SaveVideo'), 'filename_prefix', f'{config["output_prefix"]}/{shot["id"]}')
    return wf


def wait_for(server, prompt_id, shot_id, poll):
    started = time.monotonic()
    while True:
        history = request_json(server, f'/history/{prompt_id}').get(prompt_id)
        status = (history or {}).get('status', {})
        if status.get('completed') or status.get('status_str') == 'error':
            if status.get('status_str') == 'error':
                messages = [m for m in status.get('messages', []) if m[0] == 'execution_error']
                detail = messages[0][1].get('exception_message', '').strip() if messages else ''
                raise ServerError(f'{shot_id} failed on the server. {detail}')
            return history.get('outputs', {})
        print(f'  {shot_id}: running/queued ({time.monotonic() - started:.0f}s)', flush=True)
        time.sleep(poll)


def download(server, outputs, shot_id, out_dir):
    files = [item for output in outputs.values() for items in output.values() if isinstance(items, list)
             for item in items if isinstance(item, dict) and 'filename' in item]
    if not files:
        raise ServerError(f'{shot_id}: the server reported no output file.')
    saved = []
    for index, item in enumerate(files):
        query = urllib.parse.urlencode({k: item.get(k, '') for k in ('filename', 'subfolder', 'type')})
        suffix = Path(item['filename']).suffix
        target = out_dir / (f'{shot_id}{suffix}' if index == 0 else f'{shot_id}-{index}{suffix}')
        target.write_bytes(request(server, f'/view?{query}', timeout=600))
        saved.append(target)
    return saved


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    target = ap.add_mutually_exclusive_group()
    target.add_argument('--server', default='http://127.0.0.1:8188', help='ComfyUI URL (default: %(default)s)')
    target.add_argument('--runpod-server', metavar='POD_ID',
                        help='RunPod pod id; uses https://POD_ID-8188.proxy.runpod.net')
    ap.add_argument('--shots', type=Path, default=HERE / 'shots.json')
    ap.add_argument('--i2v', type=Path, help='I2V workflow in API format (default: found in api/)')
    ap.add_argument('--flf2v', type=Path, help='FLF2V workflow in API format (default: found in api/)')
    ap.add_argument('--out', type=Path, default=HERE / 'output')
    ap.add_argument('--only', help='comma-separated shot ids, e.g. 1A,2E')
    ap.add_argument('--seed', type=int, help='override the seed of the selected shots (re-roll)')
    ap.add_argument('--force', action='store_true', help='regenerate shots that already have output')
    ap.add_argument('--no-wait', action='store_true', help='queue only; do not wait or download')
    ap.add_argument('--dry-run', action='store_true', help='check files and write the filled workflows only')
    ap.add_argument('--poll', type=float, default=10, help='seconds between status checks')
    args = ap.parse_args()
    if args.runpod_server:
        if not re.fullmatch(r'[A-Za-z0-9]+', args.runpod_server):
            raise SystemExit(f'--runpod-server takes only the pod id (e.g. abc123xyz), not "{args.runpod_server}". '
                             'Use --server for a full URL.')
        args.server = f'https://{args.runpod_server}-8188.proxy.runpod.net'
    server = args.server.rstrip('/')

    config = json.loads(args.shots.read_text(encoding='utf-8'))
    strength = config.get('frame_strength')
    if strength is not None and not (isinstance(strength, (int, float)) and 0 < strength <= 1):
        raise SystemExit('frame_strength in shots.json must be greater than 0 and at most 1, or null.')
    shots = config['shots']
    if args.only:
        wanted = [s.strip() for s in args.only.split(',') if s.strip()]
        unknown = set(wanted) - {s['id'] for s in shots}
        if unknown:
            raise SystemExit(f'Unknown shot ids: {", ".join(sorted(unknown))}')
        shots = [s for s in shots if s['id'] in wanted]
    if args.seed is not None:
        shots = [dict(s, seed=args.seed) for s in shots]
    args.out.mkdir(parents=True, exist_ok=True)
    if not args.force:
        done = {s['id'] for s in shots if any(args.out.glob(f'{s["id"]}.*'))}
        for shot_id in sorted(done):
            print(f'skip {shot_id}: output exists (use --force to regenerate)')
        shots = [s for s in shots if s['id'] not in done]

    # Check every input before queueing anything, so a missing keyframe does not
    # surface halfway through a long batch.
    keyframes = (args.shots.parent / config['keyframe_dir']).resolve()
    missing, templates = [], {}
    for shot in shots:
        if shot['mode'] not in ('i2v', 'flf2v'):
            raise SystemExit(f'{shot["id"]}: mode must be i2v or flf2v')
        for key in ('first', 'last') if shot['mode'] == 'flf2v' else ('first',):
            if not (keyframes / shot[key]).is_file():
                missing.append(f'{shot["id"]} {key}: {keyframes / shot[key]}')
        path = getattr(args, shot['mode']) or find_api_workflow(shot['mode'])
        if shot['mode'] not in templates:
            if not path.is_file():
                raise SystemExit(f'Missing API workflow {path}. In ComfyUI open the LTX-2.5 '
                                 f'{shot["mode"].upper()} workflow, then Workflow -> Export (API).')
            templates[shot['mode']] = json.loads(path.read_text(encoding='utf-8'))
    if missing:
        raise SystemExit('Missing keyframes:\n  ' + '\n  '.join(missing))
    if not shots:
        print('Nothing to do.')
        return

    if args.dry_run:
        preview = args.out / 'dry-run'
        preview.mkdir(exist_ok=True)
        for shot in shots:
            images = {k: f'{config["output_prefix"]}/{shot[k]}' for k in ('first', 'last') if k in shot}
            wf = build(templates[shot['mode']], shot, config, images)
            (preview / f'{shot["id"]}.json').write_text(json.dumps(wf, ensure_ascii=False, indent=2), encoding='utf-8')
        print(f'{len(shots)} shots OK. Filled workflows written to {preview}')
        return

    uploaded = {}
    queued = []
    for shot in shots:
        images = {}
        for key in ('first', 'last') if shot['mode'] == 'flf2v' else ('first',):
            name = shot[key]
            if name not in uploaded:
                uploaded[name] = upload_image(server, keyframes / name, config['output_prefix'])
            images[key] = uploaded[name]
        wf = build(templates[shot['mode']], shot, config, images)
        result = request_json(server, '/prompt', {'prompt': wf, 'client_id': uuid.uuid4().hex})
        if result.get('node_errors'):
            raise ServerError(f'{shot["id"]} rejected: {json.dumps(result["node_errors"], ensure_ascii=False)}')
        queued.append((shot, result['prompt_id']))
        print(f'queued {shot["id"]} ({shot["mode"]}, {shot["duration"]}s, seed {shot["seed"]}): {result["prompt_id"]}')

    if args.no_wait:
        return
    failed = []
    for shot, prompt_id in queued:
        try:
            saved = download(server, wait_for(server, prompt_id, shot['id'], args.poll), shot['id'], args.out)
            print(f'done {shot["id"]}: {", ".join(str(p) for p in saved)}')
        except ServerError as e:
            print(f'FAILED {e}', file=sys.stderr)
            failed.append(shot['id'])
    if failed:
        raise SystemExit(f'Failed shots: {", ".join(failed)}. Re-run with --only {",".join(failed)}')


if __name__ == '__main__':
    try:
        main()
    except ServerError as e:
        raise SystemExit(f'ERROR: {e}')
    except urllib.error.URLError as e:
        raise SystemExit(f'ERROR: cannot reach ComfyUI: {e.reason}')
