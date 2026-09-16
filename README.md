# SmartThings Edge Driver - Aqara Ceiling Light T1M

Lua Edge driver exposing the **Aqara Ceiling Light T1M (CL-L02D)** as a single
SmartThings device with two independently controllable lights:

| Component   | Physical part          | Zigbee endpoint | Capabilities                        |
| ----------- | ---------------------- | --------------- | ----------------------------------- |
| `main`      | Tunable white panel    | `0x01`          | switch, switchLevel, colorTemperature |
| `outerRing` | RGB ambient ring       | `0x02`          | switch, switchLevel, colorControl     |

## Device facts

- Zigbee model: `lumi.light.acn032`
- Manufacturer name: `LUMI` on most firmware, `Aqara` on some (both are fingerprinted)
- Mains-powered Zigbee **router** (no battery), 40 W, panel 2700-6500 K
- Endpoint `0x01` = white panel, endpoint `0x02` = RGB ring
- Both endpoints expose On/Off `0x0006`, Level `0x0008`, Color Control `0x0300`

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

## Installation

### Option 1 - From the shared channel (no tooling required)

1. Open the channel invitation link and sign in with your Samsung account:
   <https://bestow-regional.api.smartthings.com/invite/akMXbwVwgAlb>
2. Select your hub and **enroll** it in the channel.
3. Install the driver from the channel (the app will also auto-update it when
   new versions are published).

### Option 2 - Build and deploy from source (developers)

Requires the [SmartThings CLI](https://github.com/SmartThingsCommunity/smartthings-cli)
and a SmartThings hub.

```bash
# Build, upload and assign to a channel in one step
smartthings edge:drivers:package --channel <CHANNEL_ID> ./aqara-t1m-driver

# Enroll your hub in the channel and install
smartthings edge:channels:enroll <HUB_ID> --channel <CHANNEL_ID>
smartthings edge:drivers:install --hub <HUB_ID> --channel <CHANNEL_ID> <DRIVER_ID>
```

First time only: create a channel with `smartthings edge:channels:create`.

### Pairing the light

Put the T1M into pairing mode by power-cycling it **5x** (~1 s on/off each
time), then add it via *Scan nearby* in the SmartThings app. To watch the
driver logs while pairing:

```bash
smartthings edge:drivers:logcat <DRIVER_ID> --hub-address <HUB_IP>
```

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
  `MoveToColor` to endpoint `0x02`.

## Known limitations / next steps

- **Built-in ring effects** (`flow1`, `flow2`, `fading`, `hopping`,
  `breathing`, `rolling`) and per-segment control live in Aqara's private
  cluster `0xFCC0` (attributes `0x051F`/`0x0520`/`0x0521`/`0x0522`/`0x0523`).
  They are out of scope for v1 but can be added as a custom capability or
  preferences.
- The T1 (`lumi.light.acn031`, `HCXDD12LM`) shares the same converter
  definition upstream; add a fingerprint if you want to support it too.
