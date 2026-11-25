"""Pytest bootstrap.

The suite must never touch the developer's database and must not depend on
their shell environment. Both settings are read at import time by
`app.config`, so they are pinned here, before any test module imports the app:

- the development keys are accepted by definition (the suite runs on them);
- the database is a throwaway file unless the caller points elsewhere with
  `DATABASE_URL` / `SECRETBOX_TEST_DATABASE_URL`. Several tests `DELETE` whole
  tables, so the default matters.
"""
from __future__ import annotations

import atexit
import os
import shutil
import tempfile
from pathlib import Path

os.environ["SECRETBOX_DEV"] = "1"

if os.environ.get("SECRETBOX_TEST_DATABASE_URL"):
    os.environ["DATABASE_URL"] = os.environ["SECRETBOX_TEST_DATABASE_URL"]
elif not os.environ.get("DATABASE_URL"):
    _database_dir = Path(tempfile.mkdtemp(prefix="secretbox-tests-"))
    os.environ["DATABASE_URL"] = f"sqlite:///{_database_dir / 'tests.db'}"
    atexit.register(shutil.rmtree, _database_dir, ignore_errors=True)
