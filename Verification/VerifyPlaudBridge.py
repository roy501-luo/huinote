"""Offline checks for login recovery. No credentials or network access."""
import importlib.util
import json
import sys
import tempfile
import types
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('bridge', Path(__file__).resolve().parents[1] / 'Resources/plaud_download.py')
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)
class AuthError(Exception): pass
class Client:
    calls = 0
    def list_files(self, **kwargs):
        self.calls += 1
        if self.calls == 1: raise AuthError('expired')
        return []
for login_result in (0, 1):
    client = Client(); logins = []
    def login(args):
        logins.append(True)
        return login_result
    modules = {'plaud_notes': types.ModuleType('plaud_notes')}
    for name, attrs in {
        'config': {'get_settings': lambda: object()},
        'collector': {'build_collector': lambda settings: client},
        'plaud_cn_client': {'PlaudCNAuthError': AuthError},
        'plaud_client': {'PlaudAuthError': AuthError},
        'cli': {'cmd_login': login},
    }.items():
        module = types.ModuleType('plaud_notes.' + name)
        module.__dict__.update(attrs); modules[module.__name__] = module
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory); known = root/'known.json'; known.write_text('[]')
        with patch.dict(sys.modules, modules), patch.object(sys, 'argv', ['bridge', directory, directory, str(known)]):
            result = bridge.main()
        assert len(logins) == 1
        assert result == (0 if login_result == 0 else 4)
        assert client.calls == (2 if login_result == 0 else 1)
print('PASS expired-login recovery, one retry, cancelled-login status (offline simulation)')
