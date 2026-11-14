# Mode - Läge (IoT Open edge app)

An IoT Open edge app that keeps one shared mode for the installation, which other Edge Apps take into account:
Hemma / Borta / Semester at home, or Patient / Städ / Konferens / Larmat in other premises. Each app does not have
to have its own idea of "away"; they all read the same function.

Technical names (keys, metadata, topics) are in English; the labels and the settings form are in Swedish.

## The function

| | |
|---|---|
| Type | `mode` |
| `topic_read` | `obj/mode/<mode_name>`, value = the state's number, `msg` = who or what changed it |
| `topic_write` | `set/obj/mode/<mode_name>`, a number (`1`), key (`away`) or label (`Borta`) |
| `mode.states` | `0:home:Hemma,1:away:Borta,2:vacation:Semester` (value:key:label) |
| `mode.name` | `<mode_name>`, `default` unless the installation has more than one mode |

Other apps refer to states by **key**, not by number, so states can be added or reordered without breaking them.
For example a [toolong](https://github.com/automateit-se/edge-app-toolong) instance with `active_modes = away, vacation`.

To read the mode in another app: find the function of type `mode` (and `mode.name`), subscribe to its
`topic_read`, and map the value to a key with `mode.states`.

## Settings

| Setting | Key | Meaning |
|---|---|---|
| Namn | `name` | the function's name (default *Läge*); a name changed in IoT Open is kept |
| Teknisk benämning | `mode_name` | used in the topics, default `default` |
| Lägen | `states` | value (0, 1, 2 ...), key (`home`, `away` ...), label (*Hemma*, *Borta* ...) |
| Startläge | `initial_state` | key of the state at the very first start; empty = the lowest value |

## Changing the mode

Send to `set/obj/mode/<mode_name>`, for example `{"value": "away", "msg": "Personal via knapp"}`. The `msg` is kept
in IoT Open's log, so it is clear who or what changed the mode. Ways to change it:

- a button in a dashboard or the [local dashboard](https://github.com/automateit-se/edge-app-local-dashboard)
  (with a PIN code there),
- a schedule in IoT Open's Scheduler (for example `armed` every night at 22:00),
- a KNX button or a rule.

Unknown values are refused and the current state is published again, so a dashboard that showed the wrong value goes
back.

## Without internet

The value is published **retained** on the edge client's local broker, so an app that starts without internet still
knows the mode. At start the app keeps the retained value; without one (a new broker) it takes the last value from
IoT Open, otherwise the initial state.

## Tests

```bash
lua5.3 tests/test_app.lua
```

## License

MIT
