"""OPC event bridge package.

Modules by responsibility:
  config    environment -> frozen Config, plus the injectable clock
  events    the versioned event contract and deterministic ids
  store     sqlite state: cursor, outbox, policy, audit
  paperclip Paperclip REST client
  buzz      buzz CLI client (tags, channels, messages)
  poller    issue transitions, baseline, reconcile, backfill
  deliver   at-least-once outbox
  policy    precedence resolver and hard safety rules
  control   tracks, admission, allocation, force stop, operator auth
  health    run classification and reminders
  api       internal HTTP control/read surface
  main      process wiring
"""

__version__ = "0.1.0"
