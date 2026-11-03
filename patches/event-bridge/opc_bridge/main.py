"""Process wiring: poller + deliverer + API threads, one graceful stop.

Failure policy at boot:
  * a missing notifier key or board key is fatal. Delivering as the wrong
    identity, or silently polling a board we cannot authenticate to, are both
    worse than a visibly crash-looping container.
  * a missing control key degrades the API (reads refused) but does not stop
    event delivery; health reports it as `degraded`.
"""

from __future__ import annotations

import signal
import sys
import threading
import time
import traceback
import urllib.request

from . import api, buzz, config, control, deliver, paperclip, poller, routes, store


def _log(message: str) -> None:
    print(f"[event-bridge] {message}", flush=True)


def _read_required(path, what: str) -> str:
    try:
        value = path.read_text().strip()
    except OSError as exc:
        raise SystemExit(f"[event-bridge] FATAL cannot read {what} at {path}: {exc.strerror}")
    if not value:
        raise SystemExit(f"[event-bridge] FATAL {what} at {path} is empty")
    return value


def _poller_loop(stop: threading.Event, cfg: config.Config, p: poller.Poller) -> None:
    next_reconcile = time.time() + cfg.reconcile_seconds
    while not stop.is_set():
        try:
            p.tick()
        except Exception:
            _log("poller tick failed:\n" + traceback.format_exc())
        if time.time() >= next_reconcile:
            try:
                p.reconcile()
            except Exception:
                _log("poller reconcile failed:\n" + traceback.format_exc())
            next_reconcile = time.time() + cfg.reconcile_seconds
        stop.wait(cfg.poll_interval)


def _deliver_loop(stop: threading.Event, d: deliver.Deliverer) -> None:
    while not stop.is_set():
        try:
            d.run_once()
        except Exception:
            _log("delivery pass failed:\n" + traceback.format_exc())
        stop.wait(1.0)


def _self_check(cfg: config.Config, s: store.Store) -> int:
    """Start the real API on a loopback port and ask it for health."""
    server = api.Api(cfg, s).make_server(("127.0.0.1", 0))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    host, port = server.server_address[:2]
    try:
        with urllib.request.urlopen(f"http://{host}:{port}/v1/health", timeout=5) as response:
            body = response.read().decode()
        _log(f"self-check health: {body}")
        return 0 if response.status == 200 else 1
    finally:
        server.shutdown()
        server.server_close()


def main(argv: list[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    cfg = config.load()
    s = store.Store(cfg.db_path)

    if "--self-check" in args:
        try:
            return _self_check(cfg, s)
        finally:
            s.close()

    pc = paperclip.Paperclip(cfg.paperclip_api_url, _read_required(cfg.paperclip_key_path, "board key"))
    buzz_client = buzz.Buzz(cfg.relay_url, cfg.notifier_key_path)

    recovered = s.recover_inflight()
    if recovered:
        _log(f"recovered {recovered} in-flight delivery row(s)")

    p = poller.Poller(cfg, s, pc, log=_log)
    d = deliver.Deliverer(cfg, s, buzz_client, log=_log)

    try:
        p.backfill_labels()
    except Exception:
        _log("label backfill failed:\n" + traceback.format_exc())

    # The control channel is resolved once (explicit env, existing name, or
    # created). Without it there is no authorization surface, so mutations are
    # refused — the endpoint still answers, it just cannot authorize.
    auth = None
    try:
        channel = buzz.resolve_control_channel(cfg, buzz_client, s)
        auth = control.OperatorAuth(cfg, buzz_client, s, channel)
        _log(f"control channel {channel}")
    except buzz.BuzzError as exc:
        _log(f"WARNING control channel unavailable ({exc.kind}); mutations disabled")

    table = routes.build(
        cfg, s, auth, backfill=p.backfill, backfill_labels=p.backfill_labels, paperclip=pc
    )

    try:
        control.reconcile_lock(cfg, s, pc, config.iso(config.now(cfg)))
    except Exception:
        _log("lock re-assertion failed:\n" + traceback.format_exc())

    stop = threading.Event()
    server = api.serve(api.Api(cfg, s, table))

    threads = [
        threading.Thread(target=_poller_loop, args=(stop, cfg, p), name="poller", daemon=True),
        threading.Thread(target=_deliver_loop, args=(stop, d), name="deliver", daemon=True),
    ]
    for thread in threads:
        thread.start()

    def _request_stop(signum, _frame) -> None:
        _log(f"signal {signum}: stopping")
        stop.set()

    signal.signal(signal.SIGTERM, _request_stop)
    signal.signal(signal.SIGINT, _request_stop)

    host, port = cfg.api_listen
    _log(f"started (api {host}:{port}, poll {cfg.poll_interval}s)")

    while not stop.is_set():
        stop.wait(1.0)

    for thread in threads:
        thread.join(timeout=5.0)
    server.shutdown()
    server.server_close()
    s.close()
    _log("stopped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
