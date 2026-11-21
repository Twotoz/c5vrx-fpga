#!/usr/bin/env python3
"""Triversity: the web flasher site for GitHub Pages: web/ plus the newest
releases mirrored into firmware/<tag>/ with firmware/releases.json (asset
names, local_url, upstream url). Runs in GitHub Actions with GH_TOKEN.

    python tools/prepare_pages.py site [number of releases, default 5]
"""
import json, os, shutil, sys, urllib.request
from pathlib import Path

REPO = os.environ.get('GITHUB_REPOSITORY', 'Twotoz/c5vrx-fpga')


def get(url, binary=False):
    req = urllib.request.Request(url, headers={'Accept': 'application/octet-stream' if binary else 'application/vnd.github+json',
                                               'Authorization': f"Bearer {os.environ['GH_TOKEN']}"} if os.environ.get('GH_TOKEN') else {})
    with urllib.request.urlopen(req) as r:
        return r.read() if binary else json.load(r)


def main():
    site = Path(sys.argv[1] if len(sys.argv) > 1 else 'site')
    keep = int(sys.argv[2]) if len(sys.argv) > 2 else 5
    root = Path(__file__).resolve().parent.parent
    if site.exists():
        shutil.rmtree(site)
    shutil.copytree(root / 'web', site)
    fw = site / 'firmware'
    fw.mkdir()
    out = []
    rels = [r for r in get(f'https://api.github.com/repos/{REPO}/releases?per_page=30')
            if r['tag_name'].startswith('triversity-v') and not r['draft']][:keep]
    for r in rels:
        d = fw / r['tag_name']
        d.mkdir()
        assets = []
        for a in r['assets']:
            (d / a['name']).write_bytes(get(a['url'], binary=True))
            assets.append({'name': a['name'], 'local_url': f"firmware/{r['tag_name']}/{a['name']}",
                           'url': a['browser_download_url']})
        out.append({'tag': r['tag_name'], 'name': r['name'], 'published_at': r['published_at'], 'assets': assets})
        print('mirrored', r['tag_name'], len(assets), 'assets')
    (fw / 'releases.json').write_text(json.dumps(out, indent=1))


if __name__ == '__main__':
    main()
