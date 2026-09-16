# SmartThings Edge Driver - Aqara Ceiling Light T1M

Lua Edge driver exposing the **Aqara Ceiling Light T1M (CL-L02D)** as a single
SmartThings device with two independently controllable lights:

| Component   | Physical part          | Zigbee endpoint | Capabilities                        |
| ----------- | ---------------------- | --------------- | ----------------------------------- |
| `main`      | Tunable white panel    | `0x01`          | switch, switchLevel, colorTemperature |
| `outerRing` | RGB ambient ring       | `0x02`          | switch, switchLevel, colorControl     |

## Verified device facts

- Zigbee model: `lumi.light.acn032`
- Manufacturer name: `LUMI` (some firmware reports `Aqara`)
- Mains-powered Zigbee **router** (no battery), 40 W, panel 2700-6500 K
- Endpoint `1` = white panel (On/Off `0x0006`, Level `0x0008`, Color `0x0300`)
- Endpoint `2` = RGB ring (On/Off `0x0006`, Level `0x0008`, Color `0x0300`)

Sources: zigbee-herdsman-converters (`src/devices/lumi.ts`, model `CL-L02D`,
endpoints `{white: 1, rgb: 2}`), ZHA device handler
`zhaquirks/xiaomi/aqara/light_acn.py` (quirk replaces endpoint 1 and 2), and
Zigbee2MQTT device notes.

> **Note on Thread:** some write-ups claim the T1M ships in Thread mode and
> must be switched to Zigbee first. The unit tested here is **Zigbee-only** —
> it has no Thread radio — so no protocol switch is needed. If your unit does
> expose a protocol setting in the Aqara Home app, set it to **Zigbee**; either
> way no Aqara hub is required after pairing.

## Review of the proposed dev plan

The architecture (two components, endpoint `0x01`/`0x02` mapping, cluster
mapping, profile and fingerprint values) is **correct**. A few implementation
details were wrong and are fixed in this driver:

1. **`component_to_endpoint` / `endpoint_to_component` are not driver-template
   fields.** They must be registered at runtime in the `init` lifecycle
   handler:
   ```lua
   device:set_component_to_endpoint_fn(component_to_endpoint)
   device:set_endpoint_to_component_fn(endpoint_to_component)
   ```
   Passing them as keys on `driver_template` silently does nothing, so every
   command would go to endpoint `0x01` and the ring would be uncontrollable.

2. **The custom `device_init` reporting block should be removed.** It only sent
   `configure_reporting` (no binding, so reports would never arrive) and ran on
   `init` instead of `doConfigure`. The library's default `do_configure`
   already binds and configures reporting for the device's endpoints. The
   driver now overrides `doConfigure` only to call `device:configure()` and to
   read the panel's physical color-temperature range.

3. **Manufacturer string.** Fingerprinting only on `LUMI` can miss units whose
   firmware reports `Aqara`; both are now registered.

4. **`config.yml` / profile / fingerprint structure** were already valid
   (`config.yml`, `permissions.zigbee`, `deviceProfileName` matching the
   profile `name`, `categories: Light`).

5. **Thread-mode caveat** was missing from the plan; in practice this device
   is Zigbee-only (see note above).

## Layout

```
aqara-t1m-driver/
├── config.yml
├── fingerprints.yml
├── profiles/
│   └── aqara-t1m-profile.yml
└── src/
    └── init.lua
```

## Package & install

Requires the [SmartThings CLI](https://github.com/SmartThingsCommunity/smartthings-cli).

```bash
# 1. Package the driver
smartthings edge:drivers:package ./aqara-t1m-driver

# 2. Create a channel (once) and assign the driver to it
smartthings edge:channels:create
smartthings edge:channels:assign

# 3. Enroll your hub in the channel and install the driver
smartthings edge:channels:enroll
smartthings edge:drivers:install

# 4. Watch logs while pairing
smartthings edge:drivers:logcat --hub-address <HUB_IP>
```

Then put the T1M into pairing mode (power-cycle it 5x, ~1 s on/off each time)
and add it with *Scan nearby* in the SmartThings app.

## Behavior notes

- **Instant brightness changes.** The T1M firmware ramps brightness over
  ~1.5 s and reports intermediate levels, which made the app slider jump back
  and step down. The driver overrides `switchLevel.setLevel` to send
  `MoveToLevelWithOnOff` with transition time `0`, so the level changes in a
  single report.
- **Ring color is driven via CIE XY.** The T1M ring only accepts `MoveToColor`
  (XY), not Hue/Saturation. The SmartThings default `colorControl` handler
  sends Hue/Saturation, so this driver overrides `setColor`/`setHue`/
  `setSaturation` to convert SmartThings hue/saturation to XY and send
  `MoveToColor` to endpoint `0x02`. If the color wheel still has no effect on
  some firmware, the next fallback is Aqara's private cluster `0xFCC0`.

## Known limitations / next steps

- **Built-in ring effects** (`flow1`, `flow2`, `fading`, `hopping`,
  `breathing`, `rolling`) and per-segment control live in Aqara's private
  cluster `0xFCC0` (attributes `0x051F`/`0x0520`/`0x0521`/`0x0522`/`0x0523`).
  They are out of scope for v1 but can be added as a custom capability or
  preferences.
- The T1 (`lumi.light.acn031`, `HCXDD12LM`) shares the same converter
  definition upstream; add a fingerprint if you want to support it too.
