"""The bootstrap must stop before mutation when identity or repository context is wrong."""

import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from scripts import setup_github


class SetupTests(unittest.TestCase):
    def test_wrong_account_stops_before_git_or_api_mutation(self):
        with patch('sys.argv', ['setup_github.py']), patch.object(setup_github.shutil, 'which', return_value='/bin/tool'), \
             patch.object(setup_github.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)), \
             patch.object(setup_github, 'run', return_value=json.dumps({'login': 'someone-else', 'id': 1})) as commands:
            with self.assertRaisesRegex(SystemExit, 'Expected GitHub account'):
                setup_github.main()
            commands.assert_called_once_with(['gh', 'api', 'user'])

    def test_missing_cli_returns_install_instruction_without_mutation(self):
        with patch('sys.argv', ['setup_github.py']), patch.object(setup_github.shutil, 'which', return_value=None), \
             patch.object(setup_github.subprocess, 'run') as commands:
            with self.assertRaisesRegex(SystemExit, 'winget install'):
                setup_github.main()
            commands.assert_not_called()

    def test_nested_repository_is_rejected(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(setup_github, 'ROOT', Path(folder)), \
             patch('sys.argv', ['setup_github.py']), patch.object(setup_github.shutil, 'which', return_value='/bin/tool'), \
             patch.object(setup_github.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)), \
             patch.object(setup_github, 'run', side_effect=[json.dumps({'login': 'BakedChicken77', 'id': 130414989}), '']) as commands:
            with self.assertRaisesRegex(SystemExit, 'Extract outside'):
                setup_github.main()
            self.assertFalse(any('push' in call.args[0] or 'create' in call.args[0] for call in commands.call_args_list))


if __name__ == '__main__':
    unittest.main()
