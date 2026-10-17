# Firmware

The stick runs ESP-IDF firmware that turns an ESP32-S3 into a Bluetooth Low Energy HID mouse and keyboard, plus a small encrypted control service that the app uses to send pointer moves, clicks and keystrokes. It advertises as `AgentMouse-S3`.

## Build

Install [ESP-IDF 5.5.4](https://docs.espressif.com/projects/esp-idf/en/v5.5.4/esp32s3/get-started/), open a terminal with its environment loaded (`. $IDF_PATH/export.sh`), then from the repo root:

```sh
bash scripts/build-firmware.sh
```

The target is always `esp32s3`. Settings live in `firmware/sdkconfig.defaults`. The generated config is `firmware/sdkconfig.esp32s3`, and the output goes to `firmware/build-esp32s3`.

## Flash

Plug the board in with a data-capable USB-C cable and replace the port:

```sh
cd firmware
idf.py -B build-esp32s3 -D SDKCONFIG=sdkconfig.esp32s3 -D SDKCONFIG_DEFAULTS=sdkconfig.defaults \
  -p /dev/cu.usbmodemXXXX flash monitor
```

The serial log should end with `Advertising AgentMouse-S3`.

### First flash on a board that had other firmware

Back up the factory image first, so you can restore it later:

```sh
esptool.py --chip esp32s3 -p /dev/cu.usbmodemXXXX read_flash 0 0x800000 factory-backup.bin
```

After flashing, erase the settings partition once. Leftover data from the previous firmware can stop the board from saving pairing keys (the log shows `Failed to persist local IRK`), and then it forgets the iPhone on every reboot:

```sh
python $IDF_PATH/components/partition_table/parttool.py -p /dev/cu.usbmodemXXXX \
  --partition-table-file build-esp32s3/partition_table/partition-table.bin erase_partition --partition-name nvs
```

Erasing NVS also clears pairings. Forget `AgentMouse-S3` on the iPhone and pair again.

## Boards

| Board | Notes |
|---|---|
| M5StickS3 | Tested. 8 MB flash (`CONFIG_ESPTOOLPY_FLASHSIZE_8MB`). Runs on its battery after flashing, with the screen off. **Keep `CONFIG_AGENTMOUSE_STATUS_RGB` disabled**: GPIO48 is the I2C clock shared by the power chip, IMU and audio codec. |
| Generic ESP32-S3 dev board with a WS2812 on GPIO48 | Enable the status LED with `idf.py menuconfig` → AgentMouse. Blue: not connected, white: idle, rainbow: running, red: failed, green: done. |

## Protocol

The protocol is defined in `Shared/MouseProtocol.swift` and `firmware/main/main.c`. Mouse reports carry relative movement, buttons and the scroll wheel. Keyboard reports carry US key usages with modifiers, and newer firmware plays whole key sequences at a fixed pace. The board plays pointer trajectories at a fixed rate, and the app waits for each sequence to finish before clicking.

The HID report map has three collections: mouse (report ID 1), keyboard (ID 2) and consumer control (ID 3, one 16-bit usage). The app's command `op=6` presses AC Home (`0x0223`) on the consumer report; the board releases it after 40 ms and reports busy until then. Status byte 6 bit 3 means the host subscribed to the consumer report, and bit 4 means the firmware has it. On the device, iOS ignored AC Home (and Cmd+H) from the stick, so the app leaves apps with a flick up from the home bar and sends AC Home only as a last resort.

### Updating from firmware without consumer control

Adding the consumer collection changed the HID report map and the GATT handles, and iOS caches both with the bond. After flashing this firmware: Forget `AgentMouse-S3` on the iPhone (Settings > Bluetooth, and AssistiveTouch > Devices), run `idf.py -B build-esp32s3 -D SDKCONFIG=sdkconfig.esp32s3 -D SDKCONFIG_DEFAULTS=sdkconfig.defaults -p /dev/cu.usbmodemXXXX erase-flash flash`, then pair again.

The same applies to any firmware change that touches the report map or the services: forget the stick on the iPhone and pair again, or iOS keeps using the cached map.

Pointer calibration belongs to the pairing of this board with this iPhone's settings. Recalibrate after changing pointer speed, tracking or the board.
