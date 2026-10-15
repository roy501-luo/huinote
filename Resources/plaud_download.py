"""Reuse the user's installed Plaud collector, never its ASR/summary pipeline.
Only whitelisted metadata is written; signed URLs and credentials are discarded.
"""
import sys
import json
import hashlib
import subprocess
from pathlib import Path


def main():
    tool, destination, exclusion = map(Path, sys.argv[1:4])
    sys.path.insert(0, str(tool))
    from plaud_notes.config import get_settings
    from plaud_notes.collector import build_collector
    settings = get_settings()
    if len(sys.argv) > 4 and sys.argv[4] == "login":
        from plaud_notes.cli import cmd_login
        import argparse
        return cmd_login(argparse.Namespace())
    collector = build_collector(settings)
    known = set(json.loads(exclusion.read_text()))
    # Explicitly request all available records rather than the old tool's recent-days default.
    from plaud_notes.plaud_cn_client import PlaudCNAuthError
    from plaud_notes.plaud_client import PlaudAuthError
    refreshed_login = False
    try:
        files = collector.list_files(days=0, limit=0)
    except (PlaudCNAuthError, PlaudAuthError):
        from plaud_notes.cli import cmd_login
        import argparse
        if cmd_login(argparse.Namespace()) != 0:
            return 4
        refreshed_login = True
        collector = build_collector(settings)
        files = collector.list_files(days=0, limit=0)
    if len(sys.argv) > 5 and sys.argv[4] == "verify-one":
        files = [item for item in files if item.id == sys.argv[5]]
        if not files:
            return 3
    failures = 0
    for item in files:
        if item.id in known:
            continue
        folder = destination / hashlib.sha256(item.id.encode()).hexdigest()[:32]
        if (folder / 'meta.json').exists():
            continue
        try:
            folder.mkdir(parents=True, exist_ok=True)
            try:
                audio, _ = collector.download_audio(item.id, folder, stem='audio')
            except (PlaudCNAuthError, PlaudAuthError):
                if refreshed_login:
                    raise
                from plaud_notes.cli import cmd_login
                import argparse
                if cmd_login(argparse.Namespace()) != 0:
                    return 4
                refreshed_login = True
                collector = build_collector(settings)
                audio, _ = collector.download_audio(item.id, folder, stem='audio')
            staged = folder / 'audio.partial.mp3'
            subprocess.run(['ffmpeg', '-nostdin', '-v', 'error', '-y', '-i', str(audio),
                            '-vn', '-ac', '1', '-ar', '16000', '-b:a', '64k', str(staged)],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=600)
            staged.replace(folder / 'audio.mono.mp3')
            if item.created_datetime is None:
                raise ValueError('missing recording time')
            metadata = {'source': 'plaud', 'plaud_file': {'id': item.id, 'name': item.name,
                        'created_at': item.created_datetime.strftime('%Y-%m-%d %H:%M:%S')}}
            temporary = folder / 'meta.partial.json'
            temporary.write_text(json.dumps(metadata, ensure_ascii=False), encoding='utf-8')
            temporary.replace(folder / 'meta.json')
        except Exception:
            failures += 1
    return 1 if failures else 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception:
        sys.exit(2)
