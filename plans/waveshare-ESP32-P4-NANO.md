# Explore how to run AtomVM on both the P4 and C6 chip

By default, the Waveshare ESP32-P4-NANO connects the host ESP32-P4 to the
ESP32-C6 coprocessor using a high-speed SDIO interface.

* **The Default Factory Stack:** The ESP32-C6 typically runs Espressif’s
  closed/semi-monolithic ESP-Hosted slave firmware, turning the C6 into
  a dumb Wi-Fi/Bluetooth modem for the P4.

* **Our Proposed Stack:** To run AtomVM on both chips, we must wipe the
  factory slave firmware from the ESP32-C6 and flash a standalone build
  of AtomVM directly to it.

## The Architecture: Mailboxes & Ports

Instead of nodes being aware of each other's entire Erlang runtimes,
we treat the connection like an asynchronous mailbox.

```
+----------------------------------+          +----------------------------------+
|          ESP32-P4 Node           |          |          ESP32-C6 Node           |
|                                  |          |                                  |
|  [Erlang Processes]              |          |              [Erlang Processes]  |
|         |                        |          |                        ^         |
|         v (cast/send)            |  Serial  |                        | (send)  |
|   [Buffer GenServer]             |  or SPI  |              [Buffer GenServer]  |
|         |                        |  Traces  |                        ^         |
|         v                        |          |                        |         |
|  [AtomVM Native SPI/UART Port] --+----------> [AtomVM Native SPI/UART Port]    |
+----------------------------------+          +----------------------------------+
```

1. The Erlang Client Interface: A regular Erlang process sends a standard
   message or calls a function: buffer_api:cast(c6_node, {turn_on, led_1}).

2. The Serialization Layer: The buffer API serializes the Erlang term into
   a binary payload using Erlang's standard external term format (term_to_binary/1).

3. The Transport Layer: The binary data is sent down to a lightweight AtomVM
   hardware port (UART or SPI).

4. The Receiving Layer: The opposite chip's port catches the binary data,
   unpacks it using binary_to_term/1, and forwards it to any registered Erlang
   subscribers.

## Choosing the Absolute Easiest Hardware Interface

With a simple binary buffer model, you no longer need the high-bandwidth
capabilities of custom SPI or SDIO drivers. You can use standard UART (Serial).

The ESP32-P4 and ESP32-C6 chips possess multiple independent hardware UART peripherals.

1. Zero Custom C Code Required: AtomVM already includes a fully native, robust,
   battle-tested UART Peripheral Port Driver.

2. How to implement it: Check the Waveshare schematic to find two general-purpose
   internal copper traces connecting the P4 and C6. In your startup configuration,
   simply tell AtomVM to initialize a UART port on those pins at a high speed
   (e.g., 921,600 bps or even 2,000,000 bps).Because UART handles its own
   hardware buffering, start/stop framing, and handles asynchronous bi-directional
   traffic perfectly out of the box, your hardware implementation work drops
   to exactly zero.

## Enhancing Reliability: Framing Buffers

The only minor hurdle with a stream-based transport like UART is that
term_to_binary/1 outputs variable lengths. If you send a large map, it might
arrive at the receiving chip in two separate chunks depending on internal
buffer timings.

To prevent binary_to_term/1 from crashing on a partial chunk, you can add a
tiny framing wrapper to your Erlang code:

1. When sending, prepend the packet with a 4-byte length header:
   << (byte_size(BinaryPayload)):32, BinaryPayload/binary >>.

2. When receiving, have a helper function in your handle_info/2 loop that
   accumulates incoming bytes into a binary buffer state until the total byte
   length matches the 4-byte header size, then fire binary_to_term/1.

This approach gives us a bulletproof, decoupled, event-driven messaging system
across both chips with an incredibly low memory footprint.

## Phase 1: Hardware Validation & Setup

* **Analyze the Board Schematic:** Inspect the Waveshare ESP32-P4-NANO
  schematics to identify which internal GPIO pins connect the P4 and C6 serial
  interfaces (UART/SPI/SDIO).

* **Identify Free Pin Routings:** Map out distinct, non-conflicting hardware
  peripheral indices (e.g., UART1 or UART2) for both chips so they do not
  clash with the primary flashing/debugging ports (UART0).

* **Prepare Toolchains & Firmware Builds:** Clone the AtomVM repository and
  set up your local Espressif ESP-IDF compilation environments for both the
  esp32p4 and esp32c6 target architectures.

## Phase 2: Firmware Deployment & Validation

* **Flash the ESP32-C6 (Coprocessor):** Wipe the factory esp_hosted firmware
  and flash a clean, standalone build of the AtomVM runtime via the C6's
  dedicated serial pads.

* **Flash the ESP32-P4 (Main Processor):** Flash the corresponding P4 build
  of the AtomVM runtime via the onboard Type-C USB port.

* **Verify Independent Execution:** Deploy a basic "Hello World" AtomVM
  application independently to both chips to verify that both runtimes boot
  and execute BEAM code natively.

## Phase 3: Erlang Software Implementation

* **Build the Framing Protocol Module:**  Write an Erlang module (packet_utils.erl)
  to prepend a 4-byte big-endian length prefix to outgoing binaries, and a
  stateful binary accumulator function to parse incoming fragmented byte
  streams.

* **Develop the Core Buffer Server (buffer_api.erl):** Create the gen_server
  that opens the native AtomVM UART ports at high speed (e.g., 921,600 bps),
  handles client process subscriptions, and routes incoming data.

* **Implement Serialization & Forwarding:** Integrate term_to_binary/1 and
  binary_to_term/1 wrappers inside the server to allow transparent, native
  Erlang data transfer.

## Phase 4: Integration, Testing & Optimization

* **Deploy Loopback Test Code:** Flash the complementary Erlang code to both
  chips, configuring Node A to send a ping tuple {ping, Reference} and Node B
  to reply with {pong, Reference}.

* **Handle Disconnection & Recovery:** Implement recovery logic in the Erlang
  supervision tree to gracefully reset the UART port or flush buffers if
  transmission errors or malformed frames are detected.

* **Optimize Throughput:** Gradually increase the UART baud rate in the
  software configurations to find the maximum stable execution speed allowed
  by the physical PCB trace lengths.

  ## References

[ESP32-P4-NANO](https://www.waveshare.com/esp32-p4-nano.htm)
[ESP32-P4](https://documentation.espressif.com/esp32-p4_datasheet_en.pdf)
[ESP32-C6](https://documentation.espressif.com/esp32-c6_datasheet_en.pdf)
