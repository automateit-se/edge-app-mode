# Changelog

## Unreleased

## 0.1.1

- An unknown mode value or an invalid state stopped the app: the edge client's log has no `log.w`. Warnings are
  now written with `log.i` as `warning: ...`, and the tests use a log without `w`.

## 0.1.0

- First version. One function of type `mode` for the installation: `obj/mode/<mode_name>` (value = the state's
  number, `msg` = who or what changed it) and `set/obj/mode/<mode_name>` (a number, key or label).
- States with value, key (English) and label (Swedish), as `mode.states = 0:home:Hemma,1:away:Borta,...`.
- The value is published retained on the local broker. At start the retained value is kept; without one, the last
  value in IoT Open, otherwise the initial state.
- Unknown values are refused and the current state published again.
