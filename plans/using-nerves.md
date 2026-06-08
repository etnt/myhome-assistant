# Using Nerves with Erlang (Backup Plan)

> **Status**: Alternative/backup plan. The primary implementation uses
> ESP32-S3 + AtomVM (with the two-chip ESP32-H2 Zigbee offload being
> explored). This document captures the Nerves/Raspberry Pi migration
> path in case the current approach hits hard limits.

This document outlines strategies for using Nerves and embedded hardware
interfaces with Erlang on Raspberry Pi, with specific consideration for
migrating or extending the existing ESP32-S3 + AtomVM-based MyHome Assistant project.

## Current Project Context

Before discussing Nerves integration, it's important to understand what we have today:

**Hardware**: ESP32-S3 (single-chip solution)
- Dual-core Xtensa LX7 @ 240MHz
- 512KB SRAM, 8MB Flash
- Integrated 2.4GHz WiFi + BLE radio (shared, time-division multiplexing)
- Direct I2C/GPIO access
- USB serial console for development

**Runtime**: AtomVM (subset of Erlang/OTP)
- Lightweight VM (~200KB) designed for microcontrollers
- Limited OTP: gen_server, supervisor, basic stdlib
- No distributed Erlang, no code hot-loading
- Total firmware < 2MB (AtomVM + application)
- Boot time: ~2-3 seconds to application start

**Key Components**:
- `nifs/ble/ble_port.c` - ESP-IDF specific NimBLE C port driver
- `atomvm_sensors` dependency - I2C sensor drivers for AtomVM
- `tiny_httpd` - Minimal HTTP server (pure Erlang)
- NVS (Non-Volatile Storage) - Stores bulb pairing bonds
- Connect-on-demand BLE strategy to minimize WiFi interference

**Current Constraints**:
- 512KB RAM limits number of concurrent BLE connections (~2-3)
- Shared radio requires careful WiFi/BLE coexistence tuning
- AtomVM feature limitations (no crypto module, limited binary operations)
- Development requires USB cable connection for flashing
- No OTA updates currently implemented

## Known Gotchas & Differences

### 1. Binary Handling
**AtomVM**: Limited binary operations, no crypto module
**Nerves**: Full Erlang/OTP binary support + crypto

Your Hue BLE protocol code should work unchanged, but you gain access to:
```erlang
%% Now available in Nerves (not in AtomVM)
crypto:hash(sha256, Data),
crypto:strong_rand_bytes(16).
```

### 2. Process Limits
**AtomVM**: ~100 processes max (RAM constrained)
**Nerves**: Millions (only limited by RAM)

Your current architecture is already efficient (one process per bulb),
so no changes needed.

### 3. Boot Sequence
**AtomVM**: Application starts immediately, WiFi connects asynchronously
**Nerves**: System services (networking) start first, then your app

You may need to add a "wait for network" check:
```erlang
init([]) ->
    wait_for_network(),
    %% Now start HTTP server, etc
    ...

wait_for_network() ->
    case 'Elixir.VintageNet':get([<<"interface">>, <<"wlan0">>, <<"state">>]) of
        <<"configured">> -> ok;
        _ -> 
            timer:sleep(1000),
            wait_for_network()
    end.
```

### 4. GPIO Pin Numbers
**ESP32**: Uses GPIO numbers (e.g., GPIO21 for I2C SDA)
**Pi Zero 2 W**: Uses BCM numbers (e.g., GPIO2/3 for I2C)

Update your I2C bus references:
```erlang
%% ESP32 / AtomVM
{ok, I2C} = i2c:open("i2c0"),

%% Nerves / Pi
{ok, I2C} = 'Elixir.Circuits.I2C':open(<<"i2c-1">>).
```

### 5. Console Output
**AtomVM**: `io:format` goes to USB serial
**Nerves**: Logs go to RingLogger (in-memory buffer)

Access logs via IEx or `RingLogger.tail()`:
```bash
ssh nerves.local
iex> RingLogger.tail()
```

### 6. Crash Handling
**AtomVM**: System reboots on crash
**Nerves**: Supervisor restarts, system stays up

Your `rest_for_one` supervisor strategy works the same, but Nerves won't
reboot the whole device on app crash.

### 7. Time & Timezones
**AtomVM**: Basic `erlang:monotonic_time()`, no timezone support
**Nerves**: Full time/timezone support via `tzdata`

Your `myhome_time.erl` can be enhanced:
```erlang
%% Now you can use real timezone-aware time
'Elixir.DateTime':now(<<"Europe/Stockholm">>).
```

## Testing Strategy

### Local Development (Without Hardware)

1. **Host testing** - Most Erlang logic can be tested on your Mac:
   ```bash
   cd myhome-assistant
   rebar3 shell
   
   %% Mock hardware calls
   meck:new(ble, [non_strict]),
   meck:expect(ble, scan, fun() -> {ok, []} end),
   
   %% Run tests
   rebar3 proper
   ```

2. **QEMU emulation** (for Nerves-specific parts):
   ```bash
   # Not perfect, but can test boot sequence
   export MIX_TARGET=rpi0
   mix firmware
   # TODO: Nerves doesn't officially support QEMU for Pi yet
   ```

### On-Device Testing

1. **Serial console** (Pi UART):
   ```bash
   # Connect USB-to-TTL adapter to Pi GPIO 14/15
   screen /dev/tty.usbserial 115200
   ```

2. **Remote IEx shell**:
   ```bash
   ssh -t nerves.local /usr/bin/iex --remsh myhome@nerves.local
   
   # Now you can interact with running system
   iex> :myhome_hue_ble.get_state(:bulb_1)
   iex> :observer.start()  # Won't work over SSH, but can use :sys, :recon
   ```

3. **Keep PropEr tests**:
   Your existing property tests in `test/` should run unchanged.

## Recommended Migration Sequence

### Week 1: Proof of Concept
1. [ ] Set up Nerves toolchain
2. [ ] Create minimal Nerves project
3. [ ] Add your rebar3 app as dependency
4. [ ] Test that it compiles (even if hardware doesn't work yet)

### Week 2: I2C Sensors
1. [ ] Port `myhome_sensors.erl` to use Circuits.I2C
2. [ ] Test BME680, VEML6030 on actual Pi hardware
3. [ ] Verify readings match ESP32 values

### Week 3: BLE Stack (Hardest Part)
1. [ ] Choose BLE approach (BlueZ D-Bus port vs BlueHeron for scanning)
2. [ ] Write `ble_bluez_port` helper for Hue pairing/GATT
3. [ ] Test scanning for devices
4. [ ] Test encrypted pairing + GATT write to one Hue bulb

### Week 4: Full Integration
1. [ ] Port HTTP server (keep tiny_httpd or switch to Cowboy)
2. [ ] Test bulb control end-to-end
3. [ ] Set up OTA updates
4. [ ] Run side-by-side with ESP32 for validation

### Week 5: Migration
1. [ ] Export NVS data from ESP32 (bulb addresses)
2. [ ] Migrate BLE bonds (NVS → `/var/lib/bluetooth/`)
3. [ ] Import config to Pi DETS storage
4. [ ] Switch production traffic to Pi
5. [ ] Keep ESP32 as backup

> **Rollback strategy**: Nerves uses A/B firmware partitions. If a new
> firmware fails, call `Nerves.Runtime.revert()` or it auto-reverts on
> boot failure. Keep the ESP32 running in parallel during migration.

## Cost Analysis

### Hardware

| Component | ESP32-S3 | Pi Zero 2 W | Hybrid (Both) |
|-----------|----------|-------------|---------------|
| Board | $10 | $15 | $25 |
| Power supply | USB cable | 5V/2.5A adapter ($8) | Both |
| SD card | N/A | 16GB ($8) | $8 |
| Case | Optional ($3) | Optional ($5) | $8 |
| **Total** | **~$10** | **~$36** | **~$46** |

### Development Time (Estimates)

- **Status quo** (ESP32): 0 hours (it works!)
- **Pure Nerves migration**: 40-60 hours (learning curve + porting)
- **Hybrid setup**: 20-30 hours (simpler ESP32 firmware + Pi coordination)

## Conclusion & Next Steps

Given your project's current state:

### If < 5 bulbs and no scaling issues:
**Recommendation**: Keep ESP32 + AtomVM
- Add OTA updates to current system (using `esp:ota_*` APIs)
- Focus on automation rules and user experience

### If scaling or need advanced features:
**Recommendation**: Hybrid architecture
- Keep battle-tested ESP32 BLE code
- Add Pi for web UI, complex rules, logging
- Easy to add more ESP32s for range extension

### If want to learn Nerves:
**Recommendation**: Start with pure Nerves migration
- Good learning experience
- Future-proof architecture
- Opens door to Elixir ecosystem

### Immediate action items:

1. **Decision**: Pick one of the three architectures above
2. **Prototype**: Spend 4 hours on a minimal proof-of-concept
3. **Evaluate**: Does it meet your needs? Is it worth the complexity?

### Questions to answer before committing:

- How many bulbs do you actually need to control? (2? 5? 20?)
- Is 2-3 second boot time critical for your automation use-cases?
- Are you willing to maintain Elixir configuration alongside Erlang code?
- Do you have a Pi Zero 2 W to experiment with? (Or willing to buy one?)

---

## Appendix: Quick Reference

### Nerves Wrapper Example (Minimal)

```elixir
# mix.exs
defmodule MyhomeNerves.MixProject do
  use Mix.Project

  @target System.get_env("MIX_TARGET") || "host"

  def project do
    [
      app: :myhome_nerves,
      version: "0.1.0",
      target: @target,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {MyhomeNerves.Application, []}
    ]
  end

  defp deps do
    [
      # Nerves core
      {:nerves, "~> 1.10", runtime: false},
      {:shoehorn, "~> 0.9"},
      
      # Your Erlang app
      {:myhome_assistant, path: "../myhome-assistant"},
      
      # Hardware
      {:circuits_i2c, "~> 2.0"},
      {:blue_heron, "~> 0.4"},
      {:vintage_net_wifi, "~> 0.12"},
      
      # System
      {:nerves_runtime, "~> 0.13", targets: :rpi0},
      {:nerves_system_rpi0, "~> 1.24", runtime: false, targets: :rpi0}
    ]
  end
end
```

```elixir
# lib/myhome_nerves/application.ex
defmodule MyhomeNerves.Application do
  use Application

  def start(_type, _args) do
    children = [
      # Start your Erlang OTP application
      {:myhome_app, :start, [:normal, []]}
    ]
    
    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
```

That's it! Your Erlang code runs unchanged inside this tiny Elixir wrapper.

### Key Nerves Commands

```bash
# Set target device
export MIX_TARGET=rpi0

# Get dependencies
mix deps.get

# Build firmware
mix firmware

# Burn to SD card
mix burn

# Upload to running device via network
mix upload myhome_nerves.local

# SSH into device
ssh nerves.local

# Remote IEx shell
ssh -t nerves.local "/usr/bin/iex --remsh myhome@nerves.local"

# Generate upload script
mix firmware.gen.script
```

### BlueZ HCI Command Reference

Common HCI commands for BLE control from Erlang:

```erlang
%% LE Set Scan Enable
<<16#01, 16#0C, 16#20, 16#02, 16#01, 16#01>>

%% LE Create Connection (connect to device)
<<16#01, 16#0D, 16#20, 16#19, ...>>

%% Read GATT Characteristic
%% (sent after connection established)
<<16#02, Handle:16/little, ...>>
```

For production, use BlueHeron which abstracts these details.

---

**Document Version**: 1.0  
**Last Updated**: 2026-06-08  
**Target Hardware**: Raspberry Pi Zero 2 W / ESP32-S3  
**Nerves Version**: ~1.10  
**OTP Version**: 26+

The `Circuits.I2C` Elixir library is a wrapper around a pure C codebase that
communicates with the Linux `/dev/i2c-X` driver using Erlang NIFs.
You can call it directly from Erlang by appending `Elixir.` to the module name:

```erlang
-module(my_sensor).
-export([read_sensor/0]).

read_sensor() ->
    %% 1. Open the I2C bus (Nerves usually maps the GPIO pins to i2c-1)
    {ok, BusRef} = 'Elixir.Circuits.I2C':open(<<"i2c-1">>),

    %% 2. Read 2 bytes of data from your sensor at address 0x42
    {ok, <<HighByte, LowByte>>} = 'Elixir.Circuits.I2C':read(BusRef, 16#42, 2),

    %% 3. Process your raw binary data natively in Erlang
    Temperature = (HighByte bsl 8) bor LowByte,
    {ok, Temperature}.
```

**Note**: The `ale` library (Erlang Embedded Components Library) is sometimes
mentioned for native Erlang I2C/GPIO, but it is unmaintained since ~2019 and
targets OTP 20. Calling `Circuits.I2C` from Erlang (as shown above) is the
practical path on modern Nerves.

## Interacting with BLE in Erlang

Because Nerves includes the standard Linux Bluetooth subsystem (BlueZ),
there are several options for BLE. However, important caveats apply:

> **WARNING — Pi Zero 2 W Radio Coexistence**: The on-board Bluetooth on the
> Pi Zero 2 W shares the CYW43455 chip with WiFi over SDIO — the same class
> of coexistence problem as ESP32-S3. For reliable concurrent BLE + WiFi,
> consider a **dedicated USB BLE dongle** (e.g., nRF52840 dongle, ~$10).

> **WARNING — Hue BLE Pairing**: Philips Hue bulbs require LE Secure
> Connections (encrypted pairing with bonding). BlueHeron has limited
> pairing support. The most reliable approach on Linux is to use **BlueZ
> D-Bus API** via an Erlang port, or pre-pair with `bluetoothctl` and then
> access GATT characteristics directly.

### Option A: BlueZ D-Bus Port (Recommended for Hue)

The most robust path for encrypted BLE on Linux. Write a small C or Python
helper that talks to BlueZ over D-Bus, and communicate with it via an
Erlang port:

```erlang
-module(ble_bluez_port).
-export([start_link/0]).

start_link() ->
    %% Port to a helper script that wraps BlueZ D-Bus API
    Port = open_port({spawn_executable, "/usr/local/bin/ble_helper"},
                     [binary, {packet, 4}, use_stdio]),
    {ok, Port}.

%% Send JSON commands to the helper, receive JSON responses
scan(Port) ->
    port_command(Port, <<"{\"cmd\":\"scan\"}">>),
    receive {Port, {data, Response}} -> json:decode(Response) end.
```

The helper handles pairing, bonding persistence (`/var/lib/bluetooth/`),
and GATT read/write — all managed by BlueZ.

### Option B: Raw HCI via C NIF/Port

Erlang's `socket` module does **not** support `AF_BLUETOOTH` natively.
To use raw HCI, you need a small C NIF or port that calls
`hci_open_dev()` from BlueZ's `libbluetooth`:

```c
// ble_hci_nif.c — minimal HCI socket opener
#include <bluetooth/bluetooth.h>
#include <bluetooth/hci.h>
int open_hci() {
    int fd = hci_open_dev(0);  // hci0
    // ... set up scan parameters ...
    return fd;
}
```

This gives raw advertisement packets but does NOT handle pairing/GATT —
only useful for passive scanning (e.g., sensor beacons).

### Option C: BlueHeron (Limited)

BlueHeron is a pure Elixir BLE stack. It handles advertisements and basic
unencrypted GATT, but **does not currently support LE Secure Connections**
which Hue bulbs require. Usable for scanning and simple peripherals only:

```erlang
%% Start BlueHeron from Erlang (scanning only)
{ok, BlePid} = 'Elixir.BlueHeron':start_link([
    {config, 'Elixir.BlueHeron.Transport.UART':init(#{device => <<"/dev/ttyAMA0">>})}
]).
```


## How to Structure a Pure Erlang Nerves Project

### Path 1: The "Nerves Umbrella" (Recommended & Easiest)

You do not have to rewrite your code or abandon rebar3. Instead, you treat
your existing Erlang project as a dependency inside a tiny Nerves wrapper.

**Steps:**

1. **Keep your project intact:** Your Home Assistant core remains a standard
   rebar3 application in its own Git repository.

2. **Create a Nerves Wrapper:** You create a minimal Nerves project (which
   takes about 5 lines of Elixir setup configuration).

3. **Link your Erlang Code:** In the wrapper's `mix.exs` file, you point
   directly to your Erlang project. Mix natively understands rebar3 and will
   automatically fetch, compile, and bundle your entire rebar3 application,
   including any Erlang hex packages or C-node dependencies you use.

```elixir
# Inside the Nerves wrapper's mix.exs
defp deps do
  [
    {:nerves, "~> 1.10", runtime: false},
    {:my_home_assistant, git: "https://github.com"} 
    # ^ Mix automatically runs rebar3 to compile this!
  ]
end
```

**Why this is great:** You get to write 100% pure Erlang in your IDE, test
  it locally with `rebar3 shell`, and only use the Nerves wrapper when you
  want to compile the final `.img` file or push Over-The-Air (OTA) updates to the Pi.

### Path 2: Build a Custom Linux Firmware via Buildroot (Pure Erlang)

If you want a 100% Elixir-free pipeline where you only use rebar3 from start
to finish, you step away from Nerves and look at how Nerves is built under the hood: **Buildroot**.

Buildroot is an automated tool that compiles a tiny, custom embedded Linux
system from scratch. Nerves is essentially just Buildroot paired with an
Elixir deployment script.

**How it works:**

1. You configure Buildroot to target the Raspberry Pi Zero 2 W.
2. In the Buildroot menu, you check a box to include the official `erlang`
   package and `bluez` (for Bluetooth).
3. **The Release:** You use `rebar3 release` to build a self-contained target
   production release of your application.
4. **The Deployment:** You configure Buildroot to drop your rebar3 release
   folder straight into the `/root` directory of the target filesystem and
   add a line to `/etc/init.d/rcS` to run `./bin/my_home_assistant start` on boot.

**The Trade-off:**

**Pros:**
- Zero Elixir. Your pipeline is pure Erlang/rebar3.
- The resulting operating system is incredibly tiny (often under 30MB) and
  boots into your Erlang app in under 5 seconds.

**Cons:**
- You lose the out-of-the-box Nerves features.
- You have to handle your own Wi-Fi connection configurations via Linux configuration files.
- You have to set up your own SSH/Web mechanism if you want Over-The-Air updates.

### Interfacing with I2C and BLE via rebar3

If you choose the pure rebar3 / Buildroot path, you cannot easily drop in
Elixir hardware libraries. Instead, you use native Erlang tools:

**For I2C:**
- Use `Circuits.I2C` called from Erlang (the `ale` library is unmaintained).
  Alternatively, write a small NIF that wraps Linux `/dev/i2c-X` ioctl calls.

**For BLE:**
- Write a C port helper that opens HCI sockets (`hci_open_dev()` from
  `libbluetooth`) for scanning.
- For GATT/pairing (needed for Hue), use a port wrapping BlueZ's D-Bus API.
- Note: Erlang's `socket` module does NOT support `AF_BLUETOOTH`. A C
  port or NIF is required for raw HCI access.

## Decision Point

Before diving into implementation details, you need to choose your architecture:

### Option 1: Keep ESP32-S3 + AtomVM (Status Quo)

**When this makes sense:**
- Current system is working well
- Fast boot time is critical (automation responses)
- Single-chip simplicity is valued
- Don't need advanced OTP features
- Happy with current 2-3 bulb limit

**Limitations:**
- Stuck with AtomVM constraints (no distributed Erlang, limited crypto)
- RAM limits scalability
- Manual firmware updates via USB
- WiFi/BLE coexistence complexity

### Option 2: Migrate to Raspberry Pi + Nerves

**When this makes sense:**
- Need to control many more bulbs (10+)
- Want full Erlang/OTP features (distributed, hot-code loading, crypto)
- Need more compute for complex automation rules
- Want professional OTA update infrastructure
- Have power outlet available (Pi needs 5V/2A, ESP32 can run on battery)

**Trade-offs:**
- Slower boot time (~10-20s)
- Larger firmware (~50-100MB)
- More expensive hardware (~$30 vs ~$10)
- Need to port C NIFs or rewrite using Elixir libraries

### Option 3: Hybrid Architecture (ESP32 as BLE Gateway)

**When this makes sense:**
- Want best of both worlds
- Need many bulbs + complex logic on Pi, but also want direct hardware control
- ESP32 becomes dedicated BLE gateway, Pi orchestrates
- Can have multiple ESP32s for extended range

**Architecture:**
```
┌─────────────────────┐
│  Raspberry Pi       │
│  (Nerves/Erlang)    │
│  - Web UI           │
│  - Automation Rules │
│  - State Management │
└──────┬──────────────┘
       │ WiFi/Ethernet
       ├────────────┐
       │            │
┌──────▼─────┐  ┌──▼────────┐
│ ESP32 #1   │  │ ESP32 #2  │
│ (AtomVM)   │  │ (AtomVM)  │
│ BLE Bridge │  │ BLE Bridge│
└─────┬──────┘  └─────┬─────┘
  BLE │           BLE  │
  ────┼────────────────┼────
   Bulbs            Bulbs
```

Communication: ESP32s expose simple REST/MQTT API, Pi sends commands.

### Recommendation Matrix

| Requirement | ESP32 Alone | Pi + Nerves | Hybrid |
|-------------|-------------|-------------|--------|
| < 5 bulbs | ✅ Best | ⚠️ Overkill | ⚠️ Complex |
| 5-20 bulbs | ⚠️ Tight | ✅ Good | ✅ Best |
| 20+ bulbs | ❌ RAM limit | ✅ Good | ✅ Best |
| Battery powered | ✅ Yes | ❌ No | ⚠️ Pi needs power |
| Fast boot (<5s) | ✅ Yes | ⚠️ 5-8s | ⚠️ Pi slower |
| OTA updates | ❌ Manual | ✅ Built-in | ⚠️ Both need setup |
| Development ease | ⚠️ USB cable | ✅ SSH/Network | ⚠️ Multiple targets |
| Hardware cost | ✅ ~$10 | ⚠️ ~$35 | ⚠️ ~$45+ |

## Migration Path: ESP32 → Raspberry Pi + Nerves

If you choose to migrate to Nerves, here's the step-by-step path:

### Phase 1: Environment Setup

1. **Install Nerves toolchain**:
   ```bash
   # Install Elixir and hex
   brew install elixir
   mix local.hex --force
   mix local.rebar --force
   
   # Install Nerves bootstrap
   mix archive.install hex nerves_bootstrap
   ```

2. **Create Nerves project**:
   ```bash
   mix nerves.new myhome_nerves --target rpi0
   cd myhome_nerves
   ```

3. **Add your Erlang app as dependency** in `mix.exs`:
   ```elixir
   defp deps do
     [
       # Nerves dependencies
       {:nerves, "~> 1.10", runtime: false},
       {:shoehorn, "~> 0.9"},
       {:ring_logger, "~> 0.10"},
       {:toolshed, "~> 0.3"},
       
       # Hardware dependencies
       {:circuits_i2c, "~> 2.0"},
       {:blue_heron, "~> 0.4"},  # BLE stack
       {:vintage_net, "~> 0.13"},  # WiFi
       {:vintage_net_wifi, "~> 0.12"},
       
       # Your application
       {:myhome_assistant, path: "../myhome-assistant"},  # or git URL
       
       # Target-specific deps
       {:nerves_runtime, "~> 0.13", targets: @all_targets},
       {:nerves_pack, "~> 0.7", targets: @all_targets},
       {:nerves_system_rpi0, "~> 1.24", runtime: false, targets: :rpi0}
     ]
   end
   ```

### Phase 2: Port/Replace Hardware Interfaces

#### Hardware Abstraction Layer (HAL)

To keep the core application portable between ESP32/AtomVM and Nerves,
introduce a thin HAL behaviour that the business logic calls. Each platform
provides its own implementation:

```erlang
%% src/myhome_hal.erl — behaviour definition
-module(myhome_hal).
-callback i2c_open(Config :: map()) -> {ok, term()} | {error, term()}.
-callback i2c_read(Handle :: term(), Addr :: integer(), Len :: integer()) ->
    {ok, binary()} | {error, term()}.
-callback ble_scan(Duration :: integer()) -> {ok, [map()]} | {error, term()}.
-callback ble_connect(Addr :: binary(), AddrType :: integer()) ->
    {ok, integer()} | {error, term()}.
-callback storage_get(Namespace :: atom(), Key :: atom()) -> term() | undefined.
-callback storage_set(Namespace :: atom(), Key :: atom(), Value :: term()) -> ok.
```

```erlang
%% src/myhome_hal_atomvm.erl — ESP32 implementation (current code)
%% src/myhome_hal_nerves.erl — Nerves implementation (wraps Circuits.I2C, BlueZ port, DETS)
```

The active HAL module is selected at compile time via a rebar3 profile or
application env. This lets the rest of `myhome_sensors`, `myhome_hue_ble`,
etc. remain unchanged.

#### I2C Sensors Migration

**Current** (`src/myhome_sensors.erl` using AtomVM):
```erlang
-module(myhome_sensors).
{ok, Bme} = veml6030:open(#{i2c_bus => "i2c0"}),
{ok, Lux} = veml6030:read_lux(Bme).
```

**Nerves Option A** (Call Elixir Circuits.I2C from Erlang):
```erlang
-module(myhome_sensors_nerves).

init() ->
    {ok, I2CRef} = 'Elixir.Circuits.I2C':open(<<"i2c-1">>),
    {ok, I2CRef}.

read_veml6030(I2CRef) ->
    %% VEML6030 addr 0x10, ALS register 0x04
    {ok, <<LowByte, HighByte>>} = 'Elixir.Circuits.I2C':write_read(
        I2CRef, 16#10, <<16#04>>, 2
    ),
    Lux = (HighByte bsl 8) bor LowByte,
    {ok, Lux}.
```

**Nerves Option B** (Pure Erlang with direct `/dev/i2c` file ops):
```erlang
-module(myhome_sensors_raw).

init() ->
    %% Open Linux I2C device file directly
    {ok, Fd} = file:open(<<"/dev/i2c-1">>, [read, write, binary, raw]),
    %% Set slave address via ioctl (would need a small NIF for ioctl)
    {ok, Fd}.

%% In practice, Circuits.I2C called from Erlang is simpler.
%% A raw file approach requires ioctl calls that Erlang can't do natively.
```

#### BLE Stack Migration

**Current** (NimBLE C port in ESP-IDF):
- `nifs/ble/ble_port.c` - Custom ESP32 port driver
- `src/ble.erl` - Port owner, serializes commands
- Binary protocol over port communication

**Nerves Option A** (BlueZ D-Bus port - Recommended for Hue):

The most reliable approach for encrypted BLE (required by Hue bulbs).
BlueZ handles all the pairing complexity and bond persistence:

```erlang
%% myhome_ble_nerves.erl — port-based BlueZ D-Bus wrapper
-module(myhome_ble_nerves).
-behaviour(gen_server).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    %% Start port to BlueZ helper (Python or C, wraps D-Bus API)
    Port = open_port({spawn_executable, code:priv_dir(myhome_assistant) ++ "/bluez_helper"},
                     [binary, {packet, 4}, use_stdio]),
    {ok, #{port => Port, pending => #{}}}.

scan_start(Duration) ->
    gen_server:call(?MODULE, {scan_start, Duration}).

connect(Addr, AddrType) ->
    gen_server:call(?MODULE, {connect, Addr, AddrType}, 20000).

gatt_write(ConnHandle, ChrUUID, Data) ->
    gen_server:call(?MODULE, {gatt_write, ConnHandle, ChrUUID, Data}).

%% The port protocol mirrors your existing ble.erl opcodes,
%% so myhome_hue_ble.erl needs minimal changes.
```

> **Key advantage**: BlueZ automatically manages bond storage in
> `/var/lib/bluetooth/<adapter>/<device>/`. No manual bond migration needed
> after initial pairing.

**Nerves Option B** (BlueHeron - scanning only, no Hue pairing):

BlueHeron is a pure Elixir BLE stack. Useful for scanning and simple
unencrypted GATT, but **lacks LE Secure Connections** needed by Hue:

```erlang
%% Only suitable for passive scanning (sensor beacons, etc.)
scan() ->
    Cmd = 'Elixir.BlueHeron.HCI.Command.LEController.SetScanEnable':new(#{
        le_scan_enable => true,
        filter_duplicates => true
    }),
    'Elixir.BlueHeron.HCI':send_command(Pid, Cmd).
```

**Nerves Option B** (Raw HCI via C port - No Elixir deps):

Since Pi has BlueZ built-in, you can open HCI sockets from a C port helper.
Note: Erlang's `socket` module does NOT support `AF_BLUETOOTH` — a C port
or NIF is required:

```c
// hci_scan_port.c — opens raw HCI, sends scan results as Erlang port messages
#include <bluetooth/bluetooth.h>
#include <bluetooth/hci.h>
#include <bluetooth/hci_lib.h>

int main() {
    int dd = hci_open_dev(0);  // hci0
    // Enable LE scanning...
    // Read events and write to stdout in Erlang port binary format
}
```

```erlang
-module(myhome_ble_hci).

start_scan() ->
    Port = open_port({spawn_executable, "/usr/local/bin/hci_scan_port"},
                     [binary, {packet, 4}, use_stdio]),
    receive_loop(Port).

receive_loop(Port) ->
    receive
        {Port, {data, <<AddrType, Addr:6/binary, RSSI:8/signed, Rest/binary>>}} ->
            io:format("Device: ~s, RSSI: ~p~n", [format_mac(Addr), RSSI]),
            receive_loop(Port)
    after 5000 ->
        ok
    end.
```

> **Limitation**: Raw HCI scanning does not handle GATT or pairing.
> For Hue bulb control, use the BlueZ D-Bus approach from Phase 2 above.
```

### Phase 3: Networking & Configuration

#### WiFi Setup (VintageNet)

**Current** (`src/myhome_http.erl` - AtomVM WiFi):
```erlang
esp:wifi_set_config(sta, #{
    ssid => <<"MySSID">>,
    password => <<"password">>
})
```

**Nerves** (config/target.exs):
```elixir
# config/target.exs
config :vintage_net,
  regulatory_domain: "US",
  config: [
    {"wlan0",
     %{
       type: VintageNetWiFi,
       vintage_net_wifi: %{
         networks: [
           %{
             key_mgmt: :wpa_psk,
             ssid: "MySSID",
             psk: "password"
           }
         ]
       },
       ipv4: %{method: :dhcp}
     }}
  ]
```

Or for dynamic configuration from Erlang:
```erlang
%% Runtime WiFi configuration
'Elixir.VintageNet':configure(<<"wlan0">>, #{
    type => 'Elixir.VintageNetWiFi',
    vintage_net_wifi => #{
        networks => [#{
            key_mgmt => wpa_psk,
            ssid => <<"MySSID">>,
            psk => <<"password">>
        }]
    },
    ipv4 => #{method => dhcp}
}).
```

#### NVS → Persistent Storage

**Current** (ESP32 NVS):
```erlang
%% Store bulb address
esp:nvs_set_binary(my_app, bulb_1_addr, <<"AA:BB:CC:DD:EE:FF">>),

%% Read back
{ok, Addr} = esp:nvs_get_binary(my_app, bulb_1_addr).
```

**Nerves** (Use Application environment + persistence):

```erlang
%% Option A: Application env (lost on reboot unless saved)
application:set_env(myhome_assistant, bulb_1_addr, <<"AA:BB:CC:DD:EE:FF">>),
{ok, Addr} = application:get_env(myhome_assistant, bulb_1_addr).

%% Option B: DETS (disk-based ETS, persists across reboots)
-module(myhome_storage).

init() ->
    DataDir = "/root/data",  % Nerves writable partition
    filelib:ensure_dir(DataDir ++ "/"),
    {ok, Tab} = dets:open_file(bulbs, [
        {file, DataDir ++ "/bulbs.dets"},
        {type, set}
    ]),
    {ok, Tab}.

store_bulb(Tab, BulbId, Addr) ->
    ok = dets:insert(Tab, {BulbId, Addr}).

get_bulb(Tab, BulbId) ->
    case dets:lookup(Tab, BulbId) of
        [{BulbId, Addr}] -> {ok, Addr};
        [] -> {error, not_found}
    end.
```

**Migration script** to copy NVS → DETS:
```bash
# 1. Dump NVS from ESP32
curl http://192.168.1.115:8080/api/nvs/dump > nvs_backup.json

# 2. On Pi, parse JSON and populate DETS
# (create a one-time migration module)
```

### Phase 4: HTTP Server Migration

**Current** (`tiny_httpd` - pure Erlang, custom):
```erlang
tiny_httpd:start(8080, myhome_http_handler)
```

**Nerves** (Plug + Cowboy - Elixir standard):

Since your HTTP handler is pure Erlang, you can keep most logic, but wrap it in a Plug:

```elixir
# lib/myhome_web/router.ex
defmodule MyhomeWeb.Router do
  use Plug.Router

  plug :match
  plug :dispatch

  get "/api/status" do
    # Call your Erlang handler
    Result = :myhome_http_handler.handle_status(),
    json(conn, 200, Result)
  end

  post "/api/bulb/:id/power" do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    {:ok, Data} = Jason.decode(body)
    Result = :myhome_http_handler.handle_power(id, Data),
    json(conn, 200, Result)
  end

  defp json(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(data))
  end
end
```

Or **pure Erlang** using Cowboy directly:
```erlang
%% Keep tiny_httpd or port to Cowboy
Dispatch = cowboy_router:compile([
    {'_', [
        {"/api/status", myhome_http_handler, []}
    ]}
]),
{ok, _} = cowboy:start_clear(http, [{port, 8080}], #{
    env => #{dispatch => Dispatch}
}).
```

### Phase 5: Supervisor Tree (Minimal Changes)

Your supervision tree should work mostly as-is:

```erlang
%% src/myhome_top_sup.erl - UNCHANGED
init([]) ->
    {ok, {#{strategy => rest_for_one,
            intensity => 10,
            period => 60},
          [
            #{id => myhome_log,
              start => {myhome_log, start_link, []}},
            #{id => ble,
              start => {myhome_ble_nerves, start_link, []}},  % ← only module name changes
            #{id => myhome_event_bus,
              start => {myhome_event_bus, start_link, []}},
            #{id => myhome_sup,
              start => {myhome_sup, start_link, []}}
          ]}}.
```

The only change is swapping `ble.erl` (port-based) for `myhome_ble_nerves.erl` (BlueHeron or HCI-based).

### Phase 6: Building and Deploying

```bash
# Build firmware
export MIX_TARGET=rpi0
mix deps.get
mix firmware

# Burn to SD card (first time)
mix burn

# Or OTA update to running device
mix firmware.gen.script
./upload.sh myhome_nerves.local
```

**Development workflow**:
```bash
# SSH into device
ssh nerves.local

# Start IEx remote shell
ssh -t nerves.local /bin/sh -c "exec /usr/bin/iex --remsh myhome@nerves.local"

# Push code changes
mix firmware && mix upload myhome_nerves.local
```

## Hybrid Architecture Details

If you choose the hybrid approach (ESP32 as BLE gateway + Pi coordinator):

### ESP32 Gateway Firmware (Simplified)

Strip down the current ESP32 app to just:
- BLE scanning and connection management
- Simple REST API: `GET /bulbs`, `POST /bulb/:id/cmd`
- No automation rules, no complex logic
- Forward all commands from Pi to BLE, return responses

```erlang
%% Simplified ESP32 - just a BLE-to-HTTP bridge
handle_http_request(<<"POST">>, <<"/bulb/", BulbId/binary, "/power">>, Body) ->
    {ok, #{<<"on">> := OnOff}} = tiny_json:decode(Body),
    
    %% Send to BLE (existing code)
    ok = myhome_hue_ble:set_power(BulbId, OnOff),
    
    {200, <<"OK">>}.
```

### Pi Nerves Orchestrator

```erlang
-module(myhome_gateway_manager).

%% Manages multiple ESP32 gateways
-record(state, {
    gateways = #{}  % #{gateway_id => {url, bulb_list}}
}).

init([]) ->
    %% Discover ESP32 gateways via mDNS
    Gateways = discover_gateways(),
    {ok, #state{gateways = Gateways}}.

control_bulb(BulbId, Command) ->
    gen_server:call(?MODULE, {control, BulbId, Command}).

handle_call({control, BulbId, Command}, _From, State) ->
    %% Find which gateway owns this bulb
    {GatewayUrl, _} = maps:get(find_gateway(BulbId, State), State#state.gateways),
    
    %% Send HTTP request to ESP32
    Url = GatewayUrl ++ "/bulb/" ++ BulbId ++ "/power",
    Body = tiny_json:encode(Command),
    {ok, {{_, 200, _}, _, _}} = httpc:request(post, {Url, [], "application/json", Body}, [], []),
    
    {reply, ok, State}.
```

## Performance & Resource Comparison

| Metric | ESP32-S3 + AtomVM | Pi Zero 2 W + Nerves |
|--------|-------------------|----------------------|
| Boot time | 2-3 seconds | 5-8 seconds (custom Linux, not Raspbian) |
| Available RAM | ~400KB (512KB - system) | ~400MB (512MB - system) |
| Firmware size | 1.5-2MB | 50-100MB |
| Power consumption | ~80mA @ 3.3V (0.26W) | ~300mA @ 5V (1.5W) |
| Max BLE connections | 2-3 (RAM limited) | 10+ (BlueZ limit ~7 concurrent) |
| CPU for automation | ~50MHz available | ~800MHz available |
| OTA update time | N/A (not implemented) | ~30s (A/B partitions) |
| Development cycle | USB flash (~10s) | Network upload (~60s) |
| Storage for logs | ~100KB NVS | 1GB+ SD card |

## Dependency Migration Guide

| Current (AtomVM) | Nerves Equivalent | Notes |
|------------------|-------------------|-------|
| `tiny_httpd` | Plug + Cowboy | Industry standard, more features |
| `atomvm_sensors` | `circuits_i2c` | Lower-level, you reimplement sensor logic |
| NVS | DETS / Mnesia | DETS for key-value, Mnesia for complex |
| `esp:wifi_*` | VintageNet | Much more powerful (AP mode, routing, etc) |
| Port-based BLE | BlueZ D-Bus port | BlueHeron lacks Hue pairing support |
| `esp:nvs_*` | Application env + `:dets` | Need manual persistence |
| NVS BLE bonds | `/var/lib/bluetooth/` | Managed by BlueZ automatically |

