"""Process entry point.

Task 1 only proves the wiring: env is parsed, the state directory and schema
exist, and the process exits cleanly. The threads are added by the tasks that
implement them (poller, deliverer, health, api).
"""

from __future__ import annotations

import sys

from . import config, store


def main(argv: list[str] | None = None) -> int:
    del argv  # no arguments yet; `opc-control` is the operator surface
    cfg = config.load()
    s = store.Store(cfg.db_path)
    try:
        print(
            f"[event-bridge] schema v{s.schema_version()} ready at {cfg.db_path}",
            flush=True,
        )
    finally:
        s.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
