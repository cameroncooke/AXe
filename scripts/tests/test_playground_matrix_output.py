#!/usr/bin/env python3
"""The Playground matrix refuses result folders that scripts/build.sh deletes."""
import contextlib
import importlib.util
import io
from pathlib import Path
import sys
import unittest
from unittest import mock
import uuid

SCRIPTS = Path(__file__).resolve().parent.parent
ROOT = SCRIPTS.parent
sys.path.insert(0, str(SCRIPTS))
spec = importlib.util.spec_from_file_location('playground_matrix', SCRIPTS / 'test-playground-matrix.py')
matrix = importlib.util.module_from_spec(spec)
spec.loader.exec_module(matrix)


class MatrixOutputTests(unittest.TestCase):
    def test_output_inside_wiped_build_folders_is_refused(self):
        for folder in ('build_products', 'build_derived_data'):
            output = ROOT / folder / ('matrix-check-' + uuid.uuid4().hex)
            argv = ['test-playground-matrix.py', '--axe', sys.executable, '--iphone', str(uuid.uuid4()),
                    '--duo', str(uuid.uuid4()), '--ipad', str(uuid.uuid4()), '--output', str(output)]
            stderr = io.StringIO()
            with self.subTest(folder=folder), contextlib.redirect_stderr(stderr), \
                    mock.patch.object(sys, 'argv', argv):
                with self.assertRaises(SystemExit) as raised:
                    matrix.main()
                self.assertEqual(raised.exception.code, 2)
                self.assertIn('must not be inside ' + folder, stderr.getvalue())
                self.assertFalse(output.exists())


if __name__ == '__main__':
    unittest.main()
