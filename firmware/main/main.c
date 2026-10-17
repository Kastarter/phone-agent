// AgentMouse: ESP-IDF 5.5.4, ESP32-S3, NimBLE HID over GATT.
// HID state transitions run on the NimBLE host queue. RGB rendering uses a
// separate low-priority task and a dedicated encrypted state characteristic.
#include <assert.h>
#include "sdkconfig.h"
#include <stdint.h>
#include <stdlib.h>
#include "esp_timer.h"
#include <string.h>
#include "esp_log.h"
#include "status_led.h"
#include "nvs_flash.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "host/ble_hs.h"
#include "host/ble_sm.h"
#include "host/util/util.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"

#if !CONFIG_IDF_TARGET_ESP32S3
#error "AgentMouse firmware supports ESP32-S3 only."
#endif
#define DEVICE_NAME "AgentMouse-S3"
#define PACKET_SIZE 10
#define MOVE_PACKET_SIZE 14
#define WATCHDOG_MS 1500
#define MAX_LINKS 2
#define ENC_READ (BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_READ_ENC)
#define ENC_WRITE (BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_WRITE_ENC)
#define ENC_WNR (BLE_GATT_CHR_F_WRITE_NO_RSP | BLE_GATT_CHR_F_WRITE_ENC)
#define ENC_NOTIFY (BLE_GATT_CHR_F_NOTIFY | BLE_GATT_CHR_F_NOTIFY_INDICATE_ENC)

// BLE UUID byte order is little endian: A100000x-7A3B-4F45-9F11-123456789ABC.
static const ble_uuid128_t control_uuid = BLE_UUID128_INIT(
    0xbc,0x9a,0x78,0x56,0x34,0x12,0x11,0x9f,0x45,0x4f,0x3b,0x7a,0x01,0x00,0x00,0xa1);
static const ble_uuid128_t command_uuid = BLE_UUID128_INIT(
    0xbc,0x9a,0x78,0x56,0x34,0x12,0x11,0x9f,0x45,0x4f,0x3b,0x7a,0x02,0x00,0x00,0xa1);
static const ble_uuid128_t status_uuid = BLE_UUID128_INIT(
    0xbc,0x9a,0x78,0x56,0x34,0x12,0x11,0x9f,0x45,0x4f,0x3b,0x7a,0x03,0x00,0x00,0xa1);

#if CONFIG_AGENTMOUSE_STATUS_RGB
// A1000004: optional task indicator; appended after existing GATT values.
static const ble_uuid128_t task_uuid = BLE_UUID128_INIT(
    0xbc,0x9a,0x78,0x56,0x34,0x12,0x11,0x9f,0x45,0x4f,0x3b,0x7a,0x04,0x00,0x00,0xa1);
#endif

// Report IDs live in the Report Reference descriptors; GATT values omit the ID.
static const uint8_t report_map[] = {
    0x05,0x01, 0x09,0x02, 0xa1,0x01, 0x85,0x01, 0x09,0x01, 0xa1,0x00,
    0x05,0x09, 0x19,0x01, 0x29,0x03, 0x15,0x00, 0x25,0x01,
    0x95,0x03, 0x75,0x01, 0x81,0x02, 0x95,0x01, 0x75,0x05, 0x81,0x03,
    0x05,0x01, 0x09,0x30, 0x09,0x31, 0x09,0x38, 0x15,0x81,
    0x25,0x7f, 0x75,0x08, 0x95,0x03, 0x81,0x06, 0xc0,0xc0,
    // Keyboard: modifier byte, reserved byte, six key usages; LED output byte.
    0x05,0x01, 0x09,0x06, 0xa1,0x01, 0x85,0x02,
    0x05,0x07, 0x19,0xe0, 0x29,0xe7, 0x15,0x00, 0x25,0x01,
    0x75,0x01, 0x95,0x08, 0x81,0x02,
    0x95,0x01, 0x75,0x08, 0x81,0x03,
    0x05,0x08, 0x19,0x01, 0x29,0x05, 0x95,0x05, 0x75,0x01, 0x91,0x02,
    0x95,0x01, 0x75,0x03, 0x91,0x03,
    0x05,0x07, 0x19,0x00, 0x29,0x65, 0x15,0x00, 0x25,0x65,
    0x95,0x06, 0x75,0x08, 0x81,0x00, 0xc0,
    // Consumer control: one 16-bit usage (AC Home 0x0223 is the only one sent).
    0x05,0x0c, 0x09,0x01, 0xa1,0x01, 0x85,0x03, 0x15,0x00, 0x26,0xff,0x03,
    0x19,0x00, 0x2a,0xff,0x03, 0x75,0x10, 0x95,0x01, 0x81,0x00, 0xc0
};
// Mouse 54 + keyboard 65 + consumer 25 bytes.
_Static_assert(sizeof(report_map) == 144, "HID report map length");
static const uint8_t hid_info[] = {0x11,0x01,0x00,0x02};
static const uint8_t report_ref[] = {0x01,0x01}; // Mouse input.
static const uint8_t keyboard_ref[] = {0x02,0x01};
static const uint8_t keyboard_output_ref[] = {0x02,0x02};
static const uint8_t consumer_ref[] = {0x03,0x01};
#define AC_HOME 0x0223
#define CONSUMER_PRESS_MS 40
// Key sequence (op 7): [1,7,seq lo,seq hi,count,down ms,up ms, count x (modifier,usage)].
// Odd length 9..55, never the 10-byte command or the 14-byte move.
#define KEY_BATCH_MAX 24
#define KEY_PACKET_MAX (7 + 2 * KEY_BATCH_MAX)
#define KEY_QUEUE_SIZE 64
static const uint8_t pnp_id[] = {0x01,0xe5,0x02,0x01,0x00,0x00,0x01};
// USB-powered development fixture. Replace with a real measurement for battery hardware.
static const uint8_t battery_level = CONFIG_AGENTMOUSE_DEMO_BATTERY_LEVEL;
static const char *TAG = "AgentMouse";
// iOS can keep the HID mouse connection in AssistiveTouch while CoreBluetooth
// opens a second connection for the app's custom control service.
static uint16_t links[MAX_LINKS] = {BLE_HS_CONN_HANDLE_NONE, BLE_HS_CONN_HANDLE_NONE};
static uint16_t control_connection = BLE_HS_CONN_HANDLE_NONE;
static uint16_t hid_connection = BLE_HS_CONN_HANDLE_NONE;
static uint16_t report_handle, boot_handle, status_handle;
static uint16_t keyboard_connection = BLE_HS_CONN_HANDLE_NONE;
static uint16_t keyboard_handle, keyboard_boot_handle;
static bool keyboard_subscribed, keyboard_boot_subscribed;
static uint8_t keyboard_report[8], keyboard_leds;
static struct ble_npl_callout keyboard_watchdog;
static uint16_t consumer_connection = BLE_HS_CONN_HANDLE_NONE, consumer_handle;
static bool consumer_subscribed, pending_consumer;
static uint8_t consumer_report[2];
static struct ble_npl_callout consumer_timer;
static uint16_t last_sequence;
static uint8_t own_addr_type, protocol_mode = 1, last_error;
static bool report_subscribed, boot_subscribed, status_subscribed;
static bool suspended, pending_click, click_pressed, pending_move;
static int16_t move_dx, move_dy, move_sent_x, move_sent_y;
static uint16_t move_count, move_index, move_interval, move_owner;
static uint8_t move_buttons;
static int64_t move_next_us;
static uint8_t current_report[4], click_button;
static struct ble_npl_callout watchdog_timer, click_timer, move_timer;
// Queued keystrokes, each pressed for down_ms then released for up_ms. A batch's
// last key carries its sequence; completing it publishes that sequence in status.
typedef struct { uint8_t modifier, key, down_ms, up_ms; uint16_t sequence; bool last; } key_stroke_t;
static key_stroke_t key_queue[KEY_QUEUE_SIZE];
static uint16_t key_head, key_count;
static uint8_t key_retries;
static bool key_pressed;
static struct ble_npl_callout key_timer;
void ble_store_config_init(void);
static void advertise(void);

enum { ERR_NONE, ERR_PACKET, ERR_NOT_READY, ERR_BUSY, ERR_NOTIFY, ERR_WATCHDOG, ERR_INTERRUPTED };

static int link_count(void) {
    int count = 0;
    for (int i = 0; i < MAX_LINKS; ++i) count += links[i] != BLE_HS_CONN_HANDLE_NONE;
    return count;
}
static bool link_exists(uint16_t conn) {
    if (conn == BLE_HS_CONN_HANDLE_NONE) return false;
    for (int i = 0; i < MAX_LINKS; ++i) if (links[i] == conn) return true;
    return false;
}
static bool remember_link(uint16_t conn) {
    for (int i = 0; i < MAX_LINKS; ++i) {
        if (links[i] == conn) return true;
        if (links[i] == BLE_HS_CONN_HANDLE_NONE) { links[i] = conn; return true; }
    }
    return false;
}
static void forget_link(uint16_t conn) {
    for (int i = 0; i < MAX_LINKS; ++i) if (links[i] == conn) links[i] = BLE_HS_CONN_HANDLE_NONE;
}
static bool encrypted(uint16_t conn) {
    struct ble_gap_conn_desc desc;
    return conn != BLE_HS_CONN_HANDLE_NONE && ble_gap_conn_find(conn, &desc) == 0 && desc.sec_state.encrypted;
}
static bool subscribed(void) { return protocol_mode ? report_subscribed : boot_subscribed; }
static bool ready(void) {
    return link_exists(hid_connection) && encrypted(hid_connection) && subscribed() && !suspended;
}
static bool keyboard_ready(void) {
    return link_exists(keyboard_connection) && encrypted(keyboard_connection) && !suspended &&
        (protocol_mode ? keyboard_subscribed : keyboard_boot_subscribed);
}
static bool keyboard_held(void) { return keyboard_report[0] || keyboard_report[2]; }
// Consumer reports exist only in report protocol mode.
static bool consumer_ready(void) {
    return link_exists(consumer_connection) && encrypted(consumer_connection) && !suspended &&
        protocol_mode && consumer_subscribed;
}
static bool consumer_held(void) { return consumer_report[0] || consumer_report[1]; }
static bool busy(void) { return pending_click || pending_move || pending_consumer || key_count; }
static void status_bytes(uint8_t value[8]) {
    value[0] = 1;
    value[1] = (link_exists(control_connection) ? 1 : 0) |
        (encrypted(control_connection) ? 2 : 0) | (subscribed() ? 4 : 0) | (busy() ? 8 : 0) |
        (suspended ? 16 : 0) | (protocol_mode == 0 ? 32 : 0);
    value[2] = current_report[0]; value[3] = last_error;
    value[4] = last_sequence & 0xff; value[5] = last_sequence >> 8;
    // Bit 3: consumer subscribed and usable; bit 4: firmware has consumer control;
    // bit 5: firmware-timed key sequences (op 7).
    value[6] = 1 | (keyboard_ready() ? 2 : 0) | 4 | (consumer_ready() ? 8 : 0) | 16 | 32;
    value[7] = 1 | ((keyboard_leds & 2) ? 2 : 0); // Revision 1; Caps Lock state.
}
static void notify_status(void) {
    if (!link_exists(control_connection) || !status_subscribed) return;
    uint8_t value[8]; status_bytes(value);
    struct os_mbuf *om = ble_hs_mbuf_from_flat(value, sizeof(value));
    if (om) {
        int rc = ble_gatts_notify_custom(control_connection, status_handle, om);
        if (rc) ESP_LOGW(TAG, "Status notification rc=%d", rc);
    }
}
static void reset_timer(struct ble_npl_callout *timer, uint32_t ms) {
    int rc = ble_npl_callout_reset(timer, ble_npl_time_ms_to_ticks32(ms ? ms : 1));
    assert(rc == 0);
}
static int send_report(uint8_t buttons, int8_t x, int8_t y, int8_t wheel) {
    if (!ready()) return BLE_HS_ENOTCONN;
    uint8_t value[] = {buttons, (uint8_t)x, (uint8_t)y, (uint8_t)wheel};
    struct os_mbuf *om = ble_hs_mbuf_from_flat(value, protocol_mode ? 4 : 3);
    if (!om) return BLE_HS_ENOMEM;
    int rc = ble_gatts_notify_custom(hid_connection, protocol_mode ? report_handle : boot_handle, om);
    if (!rc) {
        memcpy(current_report, value, sizeof(value));
        // X/Y/Wheel are relative impulses; reads must never replay them.
        memset(current_report + 1, 0, 3);
        if (buttons) reset_timer(&watchdog_timer, WATCHDOG_MS);
        else ble_npl_callout_stop(&watchdog_timer);
    }
    return rc;
}
static int send_keyboard(uint8_t modifier, uint8_t key) {
    if (!keyboard_ready()) return BLE_HS_ENOTCONN;
    uint8_t value[8] = {modifier, 0, key, 0, 0, 0, 0, 0};
    struct os_mbuf *om = ble_hs_mbuf_from_flat(value, sizeof(value));
    if (!om) return BLE_HS_ENOMEM;
    int rc = ble_gatts_notify_custom(keyboard_connection,
        protocol_mode ? keyboard_handle : keyboard_boot_handle, om);
    if (!rc) {
        memcpy(keyboard_report, value, sizeof(value));
        if (modifier || key) reset_timer(&keyboard_watchdog, WATCHDOG_MS);
        else ble_npl_callout_stop(&keyboard_watchdog);
    }
    return rc;
}
static int release_keyboard(void) {
    if (!keyboard_held()) return 0;
    int rc = send_keyboard(0, 0);
    if (rc) reset_timer(&keyboard_watchdog, 50);
    return rc;
}
static int send_consumer_report(uint16_t usage) {
    if (!consumer_ready()) return BLE_HS_ENOTCONN;
    uint8_t value[2] = {usage & 0xff, usage >> 8};
    struct os_mbuf *om = ble_hs_mbuf_from_flat(value, sizeof(value));
    if (!om) return BLE_HS_ENOMEM;
    int rc = ble_gatts_notify_custom(consumer_connection, consumer_handle, om);
    if (!rc) memcpy(consumer_report, value, sizeof(value));
    return rc;
}
// Releases a held consumer usage; a failed release is retried by the timer.
static int release_consumer(void) {
    if (!consumer_held()) return 0;
    int rc = send_consumer_report(0);
    if (rc && consumer_ready()) reset_timer(&consumer_timer, 50);
    else if (rc) memset(consumer_report, 0, sizeof(consumer_report));
    return rc;
}
static void cancel_consumer(void) {
    pending_consumer = false;
    if (!release_consumer()) ble_npl_callout_stop(&consumer_timer);
}
// Press, then release after CONSUMER_PRESS_MS; busy until the release is sent.
static int send_consumer(uint16_t usage) {
    int rc = send_consumer_report(usage);
    if (rc) return rc;
    pending_consumer = true;
    reset_timer(&consumer_timer, CONSUMER_PRESS_MS);
    return 0;
}
static void consumer_event(struct ble_npl_event *event) {
    (void)event;
    if (release_consumer() && consumer_ready()) {
        last_error = ERR_NOTIFY; notify_status(); return;
    }
    if (!pending_consumer) return;
    pending_consumer = false;
    notify_status();
}
static void cancel_keys(void) {
    ble_npl_callout_stop(&key_timer);
    key_head = key_count = 0; key_pressed = false; key_retries = 0;
}
static void key_event(struct ble_npl_event *event) {
    (void)event;
    if (!key_count) return;
    key_stroke_t *k = &key_queue[key_head];
    int rc = keyboard_ready() ? send_keyboard(key_pressed ? 0 : k->modifier, key_pressed ? 0 : k->key) : BLE_HS_ENOTCONN;
    if (rc == BLE_HS_ENOMEM && key_retries++ < 10) { reset_timer(&key_timer, 4); return; }
    key_retries = 0;
    if (rc) {
        last_sequence = k->sequence; last_error = keyboard_ready() ? ERR_NOTIFY : ERR_NOT_READY;
        cancel_keys(); if (keyboard_held()) reset_timer(&keyboard_watchdog, 50);
        notify_status(); return;
    }
    if (!key_pressed) { key_pressed = true; reset_timer(&key_timer, k->down_ms); return; }
    // Released: identical neighbours always get a full up interval between presses.
    key_pressed = false;
    const bool last = k->last; const uint16_t sequence = k->sequence; const uint8_t gap = k->up_ms;
    key_head = (key_head + 1) % KEY_QUEUE_SIZE; key_count--;
    if (key_count) reset_timer(&key_timer, gap);
    if (last) { last_sequence = sequence; last_error = ERR_NONE; notify_status(); }
}
static void keyboard_watchdog_event(struct ble_npl_event *event) {
    (void)event;
    if (!keyboard_held()) return;
    release_keyboard(); last_error = ERR_WATCHDOG; notify_status();
}
static void cancel_click(void) {
    ble_npl_callout_stop(&click_timer);
    pending_click = click_pressed = false;
}
static void cancel_move(void) {
    ble_npl_callout_stop(&move_timer);
    pending_move = false;
}
static int16_t move_position(int16_t delta, uint16_t index, uint16_t count) {
    int32_t rounded = ((int32_t)abs(delta) * index + count / 2) / count;
    return delta < 0 ? -rounded : rounded;
}
static void move_event(struct ble_npl_event *event) {
    (void)event;
    if (!pending_move) return;
    int64_t scheduled = esp_timer_get_time();
    if (scheduled < move_next_us) {
        reset_timer(&move_timer, (uint32_t)((move_next_us - scheduled + 999) / 1000));
        return;
    }
    if (!ready() || !link_exists(move_owner) || !encrypted(move_owner)) {
        cancel_move(); last_error = ERR_NOT_READY; notify_status(); return;
    }
    // The last report gets a full interval before the completion notification.
    if (move_index == move_count) {
        cancel_move(); last_error = ERR_NONE; notify_status(); return;
    }
    uint16_t next = move_index + 1;
    int16_t x = move_position(move_dx, next, move_count);
    int16_t y = move_position(move_dy, next, move_count);
    if (send_report(move_buttons, (int8_t)(x - move_sent_x), (int8_t)(y - move_sent_y), 0)) {
        cancel_move(); last_error = ERR_NOTIFY;
        if (ready() && send_report(0, 0, 0, 0) && current_report[0]) reset_timer(&watchdog_timer, 50);
        notify_status(); return;
    }
    move_index = next; move_sent_x = x; move_sent_y = y;
    int64_t now = esp_timer_get_time();
    move_next_us += (int64_t)move_interval * 1000;
    // Do not bunch reports together if the host queue was delayed.
    if (move_next_us <= now) move_next_us = now + (int64_t)move_interval * 1000;
    reset_timer(&move_timer, (uint32_t)((move_next_us - now + 999) / 1000));
}
static void watchdog_event(struct ble_npl_event *event) {
    (void)event;
    if (!current_report[0]) return;
    cancel_click(); cancel_move();
    if (send_report(0, 0, 0, 0)) {
        // Do not forget a held button on transient allocation failure.
        reset_timer(&watchdog_timer, 50);
    }
    last_error = ERR_WATCHDOG;
    notify_status();
}
static void click_event(struct ble_npl_event *event) {
    (void)event;
    if (!pending_click) return;
    if (!ready()) {
        cancel_click(); last_error = ERR_NOT_READY; notify_status(); return;
    }
    if (!click_pressed) {
        if (send_report(click_button, 0, 0, 0)) {
            cancel_click(); last_error = ERR_NOTIFY;
        } else {
            click_pressed = true;
            reset_timer(&click_timer, 60);
        }
    } else {
        if (send_report(0, 0, 0, 0)) {
            last_error = ERR_NOTIFY;
            reset_timer(&click_timer, 50);
        } else cancel_click();
    }
    notify_status();
}
static int append(struct ble_gatt_access_ctxt *ctxt, const void *data, size_t len) {
    return os_mbuf_append(ctxt->om, data, len) == 0 ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;
}
static int reject(uint16_t conn, uint8_t error, int att_error) {
    if (!link_exists(control_connection)) control_connection = conn;
    last_error = error; notify_status(); return att_error;
}
static int move_access(uint16_t conn, struct ble_gatt_access_ctxt *ctxt) {
    uint8_t p[MOVE_PACKET_SIZE]; uint16_t len;
    if (ble_hs_mbuf_to_flat(ctxt->om, p, sizeof(p), &len) || len != sizeof(p))
        return reject(conn, ERR_PACKET, BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN);
    int16_t dx = (int16_t)(p[5] | ((uint16_t)p[6] << 8));
    int16_t dy = (int16_t)(p[7] | ((uint16_t)p[8] << 8));
    uint16_t count = p[9] | ((uint16_t)p[10] << 8);
    uint16_t interval = p[11] | ((uint16_t)p[12] << 8);
    if (p[0] != 2 || p[1] != 5 || p[4] > 7 || p[13] ||
        abs(dx) >= 10000 || abs(dy) >= 10000 || !count || count > 2000 ||
        interval < 20 || interval > 100 || (uint32_t)count * interval > 80000 ||
        (abs(dx) + count - 1) / count > 127 || (abs(dy) + count - 1) / count > 127)
        return reject(conn, ERR_PACKET, BLE_ATT_ERR_UNLIKELY);
    if (!encrypted(conn)) return reject(conn, ERR_NOT_READY, BLE_ATT_ERR_INSUFFICIENT_ENC);
    if (!ready()) return reject(conn, ERR_NOT_READY, BLE_ATT_ERR_UNLIKELY);
    if (busy()) return reject(conn, ERR_BUSY, BLE_ATT_ERR_UNLIKELY);
    move_dx = dx; move_dy = dy; move_count = count; move_interval = interval; move_buttons = p[4];
    move_index = 0; move_sent_x = move_sent_y = 0; move_owner = conn;
    last_sequence = p[2] | ((uint16_t)p[3] << 8); last_error = ERR_NONE;
    pending_move = true; move_next_us = esp_timer_get_time() + 1000;
    notify_status(); reset_timer(&move_timer, 1);
    return 0;
}
static int keys_access(uint16_t conn, struct ble_gatt_access_ctxt *ctxt) {
    uint8_t p[KEY_PACKET_MAX]; uint16_t len;
    if (ble_hs_mbuf_to_flat(ctxt->om, p, sizeof(p), &len) || len < 9 || len > KEY_PACKET_MAX)
        return reject(conn, ERR_PACKET, BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN);
    const uint8_t n = p[4];
    if (p[0] != 1 || p[1] != 7 || !n || n > KEY_BATCH_MAX || len != 7 + 2 * n ||
        p[5] < 4 || p[5] > 100 || p[6] < 4 || p[6] > 100)
        return reject(conn, ERR_PACKET, BLE_ATT_ERR_UNLIKELY);
    for (int i = 0; i < n; ++i)
        if (p[8 + 2 * i] < 4 || p[8 + 2 * i] > 101) return reject(conn, ERR_PACKET, BLE_ATT_ERR_UNLIKELY);
    if (!encrypted(conn)) return reject(conn, ERR_NOT_READY, BLE_ATT_ERR_INSUFFICIENT_ENC);
    if (!keyboard_ready()) return reject(conn, ERR_NOT_READY, BLE_ATT_ERR_UNLIKELY);
    // Batches queue behind each other; nothing else may run while keys are pending.
    if (pending_click || pending_move || pending_consumer || key_count + n > KEY_QUEUE_SIZE ||
        (!key_count && keyboard_held())) return reject(conn, ERR_BUSY, BLE_ATT_ERR_UNLIKELY);
    const bool idle = !key_count;
    const uint16_t sequence = p[2] | ((uint16_t)p[3] << 8);
    for (int i = 0; i < n; ++i) {
        key_queue[(key_head + key_count++) % KEY_QUEUE_SIZE] = (key_stroke_t){
            .modifier = p[7 + 2 * i], .key = p[8 + 2 * i], .down_ms = p[5], .up_ms = p[6],
            .sequence = sequence, .last = i == n - 1};
    }
    // last_sequence advances when the batch has been typed, not when it is queued.
    last_error = ERR_NONE; notify_status();
    if (idle) reset_timer(&key_timer, 1);
    return 0;
}
static int control_access(uint16_t conn, uint16_t attr, struct ble_gatt_access_ctxt *ctxt, void *arg) {
    (void)attr;
    control_connection = conn;
    if (arg) {
        uint8_t value[8]; status_bytes(value); return append(ctxt, value, sizeof(value));
    }
    if (OS_MBUF_PKTLEN(ctxt->om) == MOVE_PACKET_SIZE) return move_access(conn, ctxt);
    if (OS_MBUF_PKTLEN(ctxt->om) & 1) return keys_access(conn, ctxt);
    uint8_t p[PACKET_SIZE]; uint16_t len;
    if (OS_MBUF_PKTLEN(ctxt->om) != PACKET_SIZE ||
        ble_hs_mbuf_to_flat(ctxt->om, p, sizeof(p), &len) || len != PACKET_SIZE)
        return reject(conn, ERR_PACKET, BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN);
    if (p[0] == 1 && p[1] == 4) {
        // Byte 4 is the full modifier mask, byte 5 one ordinary key usage.
        if ((p[5] && (p[5] < 4 || p[5] > 101)) || p[6] || p[7] || p[8] || p[9])
            return reject(conn, ERR_PACKET, BLE_ATT_ERR_UNLIKELY);
        if (!encrypted(conn)) return reject(conn, ERR_NOT_READY, BLE_ATT_ERR_INSUFFICIENT_ENC);
        if (!keyboard_ready()) return reject(conn, ERR_NOT_READY, BLE_ATT_ERR_UNLIKELY);
        if (busy()) return reject(conn, ERR_BUSY, BLE_ATT_ERR_UNLIKELY);
        if (send_keyboard(p[4], p[5])) return reject(conn, ERR_NOTIFY, BLE_ATT_ERR_INSUFFICIENT_RES);
        last_sequence = p[2] | ((uint16_t)p[3] << 8);
        last_error = ERR_NONE; notify_status(); return 0;
    }
    if (p[0] == 1 && p[1] == 6) {
        // Bytes 5-6 carry one consumer usage; only AC Home is accepted.
        if ((p[5] | ((uint16_t)p[6] << 8)) != AC_HOME || p[4] || p[7] || p[8] || p[9])
            return reject(conn, ERR_PACKET, BLE_ATT_ERR_UNLIKELY);
        if (!encrypted(conn)) return reject(conn, ERR_NOT_READY, BLE_ATT_ERR_INSUFFICIENT_ENC);
        if (!consumer_ready()) return reject(conn, ERR_NOT_READY, BLE_ATT_ERR_UNLIKELY);
        if (busy() || consumer_held()) return reject(conn, ERR_BUSY, BLE_ATT_ERR_UNLIKELY);
        if (send_consumer(AC_HOME)) return reject(conn, ERR_NOTIFY, BLE_ATT_ERR_INSUFFICIENT_RES);
        last_sequence = p[2] | ((uint16_t)p[3] << 8);
        last_error = ERR_NONE; notify_status(); return 0;
    }
    const uint16_t delay_ms = p[8] | ((uint16_t)p[9] << 8);
    if (p[0] != 1 || p[1] < 1 || p[1] > 3 || p[4] > 7 ||
        p[5] == 0x80 || p[6] == 0x80 || p[7] == 0x80 ||
        (p[1] != 2 && delay_ms) || delay_ms > 10000 ||
        (p[1] == 2 && (p[5] || p[6] || p[7] || (p[4] != 1 && p[4] != 2 && p[4] != 4))) ||
        (p[1] == 3 && (p[4] || p[5] || p[6] || p[7])))
        return reject(conn, ERR_PACKET, BLE_ATT_ERR_UNLIKELY);
    if (!encrypted(conn)) return reject(conn, ERR_NOT_READY, BLE_ATT_ERR_INSUFFICIENT_ENC);
    // RELEASE cancels a delayed click even when the OS has suspended HID.
    if (p[1] == 3) {
        cancel_click(); cancel_move(); cancel_consumer(); cancel_keys();
        int keyboard_rc = release_keyboard();
        if (ready() && send_report(0, 0, 0, 0))
            return reject(conn, ERR_NOTIFY, BLE_ATT_ERR_INSUFFICIENT_RES);
        if (!ready()) {
            // Retain held-button state until a ready transition can send release.
            if (current_report[0]) reset_timer(&watchdog_timer, 50);
        }
        if (keyboard_rc && keyboard_ready()) return reject(conn, ERR_NOTIFY, BLE_ATT_ERR_INSUFFICIENT_RES);
    } else {
        if (!ready()) return reject(conn, ERR_NOT_READY, BLE_ATT_ERR_UNLIKELY);
        if (busy()) return reject(conn, ERR_BUSY, BLE_ATT_ERR_UNLIKELY);
        if (p[1] == 2) {
            if (current_report[0]) return reject(conn, ERR_BUSY, BLE_ATT_ERR_UNLIKELY);
            pending_click = true; click_pressed = false; click_button = p[4];
            reset_timer(&click_timer, delay_ms);
        } else {
            if (protocol_mode == 0 && p[7]) return reject(conn, ERR_PACKET, BLE_ATT_ERR_UNLIKELY);
            if (send_report(p[4], (int8_t)p[5], (int8_t)p[6], (int8_t)p[7]))
                return reject(conn, ERR_NOTIFY, BLE_ATT_ERR_INSUFFICIENT_RES);
        }
    }
    last_sequence = p[2] | ((uint16_t)p[3] << 8);
    last_error = ERR_NONE; notify_status(); return 0;
}
#if CONFIG_AGENTMOUSE_STATUS_RGB
static int task_access(uint16_t conn, uint16_t attr, struct ble_gatt_access_ctxt *ctxt, void *arg) {
    (void)attr; (void)arg;
    uint8_t p[2]; uint16_t length;
    if (ctxt->op != BLE_GATT_ACCESS_OP_WRITE_CHR || OS_MBUF_PKTLEN(ctxt->om) != sizeof(p) ||
        ble_hs_mbuf_to_flat(ctxt->om, p, sizeof(p), &length) || length != sizeof(p) ||
        p[0] != 1 || p[1] > AGENT_LED_COMPLETED)
        return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
    if (!link_exists(conn) || !encrypted(conn)) return BLE_ATT_ERR_INSUFFICIENT_ENC;
    if (control_connection != BLE_HS_CONN_HANDLE_NONE && conn != control_connection)
        return BLE_ATT_ERR_INSUFFICIENT_AUTHOR;
    status_led_set_task((agent_led_task_state_t)p[1]);
    return 0;
}
#endif
enum { ACCESS_INFO, ACCESS_MAP, ACCESS_REPORT, ACCESS_REF, ACCESS_PROTOCOL, ACCESS_CONTROL_POINT,
       ACCESS_BOOT, ACCESS_MANUFACTURER, ACCESS_MODEL, ACCESS_PNP, ACCESS_BATTERY,
       ACCESS_KEYBOARD, ACCESS_KEYBOARD_REF, ACCESS_KEYBOARD_OUTPUT, ACCESS_KEYBOARD_OUTPUT_REF,
       ACCESS_CONSUMER, ACCESS_CONSUMER_REF };
static int hid_access(uint16_t conn, uint16_t attr, struct ble_gatt_access_ctxt *ctxt, void *arg) {
    (void)attr;
    if (hid_connection == BLE_HS_CONN_HANDLE_NONE || hid_connection == conn) hid_connection = conn;
    switch ((intptr_t)arg) {
    case ACCESS_INFO: return append(ctxt, hid_info, sizeof(hid_info));
    case ACCESS_MAP: return append(ctxt, report_map, sizeof(report_map));
    case ACCESS_REPORT: return append(ctxt, current_report, 4);
    case ACCESS_BOOT: return append(ctxt, current_report, 3);
    case ACCESS_REF: return append(ctxt, report_ref, sizeof(report_ref));
    case ACCESS_KEYBOARD: return append(ctxt, keyboard_report, sizeof(keyboard_report));
    case ACCESS_KEYBOARD_REF: return append(ctxt, keyboard_ref, sizeof(keyboard_ref));
    case ACCESS_KEYBOARD_OUTPUT_REF: return append(ctxt, keyboard_output_ref, sizeof(keyboard_output_ref));
    case ACCESS_CONSUMER: return append(ctxt, consumer_report, sizeof(consumer_report));
    case ACCESS_CONSUMER_REF: return append(ctxt, consumer_ref, sizeof(consumer_ref));
    case ACCESS_KEYBOARD_OUTPUT: {
        if (ctxt->op == BLE_GATT_ACCESS_OP_READ_CHR) return append(ctxt, &keyboard_leds, 1);
        uint8_t value; uint16_t len;
        if (OS_MBUF_PKTLEN(ctxt->om) != 1 || ble_hs_mbuf_to_flat(ctxt->om, &value, 1, &len))
            return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
        keyboard_leds = value & 0x1f; notify_status(); return 0;
    }
    case ACCESS_MANUFACTURER: return append(ctxt, "AgentMouse", 10);
    case ACCESS_MODEL: return append(ctxt, DEVICE_NAME, strlen(DEVICE_NAME));
    case ACCESS_PNP: return append(ctxt, pnp_id, sizeof(pnp_id));
    case ACCESS_BATTERY: return append(ctxt, &battery_level, 1);
    case ACCESS_PROTOCOL:
        if (ctxt->op == BLE_GATT_ACCESS_OP_READ_CHR) return append(ctxt, &protocol_mode, 1);
        // Fall through: both writable HID values consist of one byte.
        __attribute__((fallthrough));
    case ACCESS_CONTROL_POINT: {
        uint8_t value; uint16_t len;
        if (OS_MBUF_PKTLEN(ctxt->om) != 1 || ble_hs_mbuf_to_flat(ctxt->om, &value, 1, &len) || value > 1)
            return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
        if (pending_move) last_error = ERR_INTERRUPTED;
        cancel_click(); cancel_move(); cancel_consumer(); cancel_keys();
        if (ready()) send_report(0, 0, 0, 0);
        release_keyboard();
        if ((intptr_t)arg == ACCESS_PROTOCOL) protocol_mode = value;
        else suspended = value == 0;
        if (ready()) send_report(0, 0, 0, 0);
        if (keyboard_ready()) send_keyboard(0, 0);
        notify_status(); return 0;
    }
    default: return BLE_ATT_ERR_UNLIKELY;
    }
}

static struct ble_gatt_dsc_def report_descriptors[] = {
    {.uuid = BLE_UUID16_DECLARE(0x2908), .att_flags = BLE_ATT_F_READ | BLE_ATT_F_READ_ENC,
     .access_cb = hid_access, .arg = (void *)ACCESS_REF}, {0}
};
static struct ble_gatt_dsc_def keyboard_descriptors[] = {
    {.uuid = BLE_UUID16_DECLARE(0x2908), .att_flags = BLE_ATT_F_READ | BLE_ATT_F_READ_ENC,
     .access_cb = hid_access, .arg = (void *)ACCESS_KEYBOARD_REF}, {0}
};
static struct ble_gatt_dsc_def keyboard_output_descriptors[] = {
    {.uuid = BLE_UUID16_DECLARE(0x2908), .att_flags = BLE_ATT_F_READ | BLE_ATT_F_READ_ENC,
     .access_cb = hid_access, .arg = (void *)ACCESS_KEYBOARD_OUTPUT_REF}, {0}
};
static struct ble_gatt_dsc_def consumer_descriptors[] = {
    {.uuid = BLE_UUID16_DECLARE(0x2908), .att_flags = BLE_ATT_F_READ | BLE_ATT_F_READ_ENC,
     .access_cb = hid_access, .arg = (void *)ACCESS_CONSUMER_REF}, {0}
};
static const struct ble_gatt_svc_def services[] = {
    {.type = BLE_GATT_SVC_TYPE_PRIMARY, .uuid = BLE_UUID16_DECLARE(0x1812),
     .characteristics = (struct ble_gatt_chr_def[]) {
        {.uuid = BLE_UUID16_DECLARE(0x2a4a), .access_cb = hid_access, .arg = (void *)ACCESS_INFO, .flags = ENC_READ},
        {.uuid = BLE_UUID16_DECLARE(0x2a4b), .access_cb = hid_access, .arg = (void *)ACCESS_MAP, .flags = ENC_READ},
        {.uuid = BLE_UUID16_DECLARE(0x2a4d), .access_cb = hid_access, .arg = (void *)ACCESS_REPORT,
         .flags = ENC_READ | ENC_NOTIFY, .val_handle = &report_handle, .descriptors = report_descriptors},
        {.uuid = BLE_UUID16_DECLARE(0x2a4e), .access_cb = hid_access, .arg = (void *)ACCESS_PROTOCOL,
         .flags = ENC_READ | ENC_WNR},
        {.uuid = BLE_UUID16_DECLARE(0x2a4c), .access_cb = hid_access, .arg = (void *)ACCESS_CONTROL_POINT, .flags = ENC_WNR},
        {.uuid = BLE_UUID16_DECLARE(0x2a33), .access_cb = hid_access, .arg = (void *)ACCESS_BOOT,
         .flags = ENC_READ | ENC_NOTIFY, .val_handle = &boot_handle},
        {.uuid = BLE_UUID16_DECLARE(0x2a4d), .access_cb = hid_access, .arg = (void *)ACCESS_KEYBOARD,
         .flags = ENC_READ | ENC_NOTIFY, .val_handle = &keyboard_handle, .descriptors = keyboard_descriptors},
        {.uuid = BLE_UUID16_DECLARE(0x2a4d), .access_cb = hid_access, .arg = (void *)ACCESS_KEYBOARD_OUTPUT,
         .flags = ENC_READ | ENC_WRITE | ENC_WNR, .descriptors = keyboard_output_descriptors},
        {.uuid = BLE_UUID16_DECLARE(0x2a22), .access_cb = hid_access, .arg = (void *)ACCESS_KEYBOARD,
         .flags = ENC_READ | ENC_NOTIFY, .val_handle = &keyboard_boot_handle},
        {.uuid = BLE_UUID16_DECLARE(0x2a32), .access_cb = hid_access, .arg = (void *)ACCESS_KEYBOARD_OUTPUT,
         .flags = ENC_READ | ENC_WRITE | ENC_WNR},
        {.uuid = BLE_UUID16_DECLARE(0x2a4d), .access_cb = hid_access, .arg = (void *)ACCESS_CONSUMER,
         .flags = ENC_READ | ENC_NOTIFY, .val_handle = &consumer_handle, .descriptors = consumer_descriptors}, {0}
     }},
    {.type = BLE_GATT_SVC_TYPE_PRIMARY, .uuid = BLE_UUID16_DECLARE(0x180f),
     .characteristics = (struct ble_gatt_chr_def[]) {
        {.uuid = BLE_UUID16_DECLARE(0x2a19), .access_cb = hid_access, .arg = (void *)ACCESS_BATTERY,
         .flags = ENC_READ | ENC_NOTIFY}, {0}
     }},
    {.type = BLE_GATT_SVC_TYPE_PRIMARY, .uuid = BLE_UUID16_DECLARE(0x180a),
     .characteristics = (struct ble_gatt_chr_def[]) {
        {.uuid = BLE_UUID16_DECLARE(0x2a29), .access_cb = hid_access, .arg = (void *)ACCESS_MANUFACTURER, .flags = BLE_GATT_CHR_F_READ},
        {.uuid = BLE_UUID16_DECLARE(0x2a24), .access_cb = hid_access, .arg = (void *)ACCESS_MODEL, .flags = BLE_GATT_CHR_F_READ},
        {.uuid = BLE_UUID16_DECLARE(0x2a50), .access_cb = hid_access, .arg = (void *)ACCESS_PNP, .flags = BLE_GATT_CHR_F_READ}, {0}
     }},
    {.type = BLE_GATT_SVC_TYPE_PRIMARY, .uuid = &control_uuid.u,
     .characteristics = (struct ble_gatt_chr_def[]) {
        {.uuid = &command_uuid.u, .access_cb = control_access, .flags = ENC_WRITE},
        {.uuid = &status_uuid.u, .access_cb = control_access, .arg = (void *)1,
         .flags = BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_NOTIFY, .val_handle = &status_handle},
#if CONFIG_AGENTMOUSE_STATUS_RGB
        {.uuid = &task_uuid.u, .access_cb = task_access, .flags = ENC_WNR},
#endif
        {0}
     }}, {0}
};
static void clear_all(void) {
    cancel_click(); cancel_move(); ble_npl_callout_stop(&watchdog_timer);
    ble_npl_callout_stop(&keyboard_watchdog); cancel_keys();
    ble_npl_callout_stop(&consumer_timer); pending_consumer = false;
    consumer_connection = BLE_HS_CONN_HANDLE_NONE; consumer_subscribed = false;
    memset(consumer_report, 0, sizeof(consumer_report));
    for (int i = 0; i < MAX_LINKS; ++i) links[i] = BLE_HS_CONN_HANDLE_NONE;
    control_connection = hid_connection = BLE_HS_CONN_HANDLE_NONE;
    keyboard_connection = BLE_HS_CONN_HANDLE_NONE;
    keyboard_subscribed = keyboard_boot_subscribed = false; keyboard_leds = 0;
    memset(keyboard_report, 0, sizeof(keyboard_report));
    report_subscribed = boot_subscribed = status_subscribed = suspended = false;
    protocol_mode = 1; last_error = 0; last_sequence = 0;
    memset(current_report, 0, sizeof(current_report));
    status_led_set_connected(false);
}
static void clear_link(uint16_t conn) {
    if (pending_move && (conn == move_owner || conn == hid_connection)) cancel_move();
    if (conn == control_connection && conn != hid_connection && current_report[0] && ready())
        send_report(0, 0, 0, 0);
    if (conn == control_connection || conn == keyboard_connection) cancel_keys();
    if (conn == control_connection && conn != keyboard_connection) release_keyboard();
    if (conn == control_connection && conn != consumer_connection) cancel_consumer();
    if (control_connection == conn) status_led_set_task(AGENT_LED_IDLE);
    forget_link(conn);
    status_led_set_connected(link_count() > 0);
    if (control_connection == conn) { control_connection = BLE_HS_CONN_HANDLE_NONE; status_subscribed = false; }
    if (hid_connection == conn) {
        cancel_click(); cancel_move(); ble_npl_callout_stop(&watchdog_timer);
        hid_connection = BLE_HS_CONN_HANDLE_NONE;
        report_subscribed = boot_subscribed = suspended = false;
        protocol_mode = 1; memset(current_report, 0, sizeof(current_report));
    }
    if (keyboard_connection == conn) {
        ble_npl_callout_stop(&keyboard_watchdog);
        keyboard_connection = BLE_HS_CONN_HANDLE_NONE;
        keyboard_subscribed = keyboard_boot_subscribed = false; keyboard_leds = 0;
        memset(keyboard_report, 0, sizeof(keyboard_report));
    }
    if (consumer_connection == conn) {
        ble_npl_callout_stop(&consumer_timer); pending_consumer = false;
        consumer_connection = BLE_HS_CONN_HANDLE_NONE; consumer_subscribed = false;
        memset(consumer_report, 0, sizeof(consumer_report));
    }
    if (!link_count()) { last_error = 0; last_sequence = 0; }
    notify_status();
}
static int gap_event(struct ble_gap_event *event, void *arg) {
    (void)arg;
    switch (event->type) {
    case BLE_GAP_EVENT_CONNECT:
        if (event->connect.status) { advertise(); return 0; }
        if (!remember_link(event->connect.conn_handle)) {
            ESP_LOGW(TAG, "Rejecting connection: limit reached");
            ble_gap_terminate(event->connect.conn_handle, BLE_ERR_REM_USER_CONN_TERM);
            return 0;
        }
        status_led_set_connected(true);
        ESP_LOGI(TAG, "Connected: handle=%u links=%d", event->connect.conn_handle, link_count());
        {
            int rc = ble_gap_security_initiate(event->connect.conn_handle);
            if (rc && rc != BLE_HS_EALREADY) ESP_LOGW(TAG, "Security request rc=%d", rc);
        }
        advertise();
        return 0;
    case BLE_GAP_EVENT_DISCONNECT:
        ESP_LOGI(TAG, "Disconnected: handle=%u reason=%d", event->disconnect.conn.conn_handle, event->disconnect.reason);
        clear_link(event->disconnect.conn.conn_handle); advertise(); return 0;
    case BLE_GAP_EVENT_ADV_COMPLETE:
        advertise();
        return 0;
    case BLE_GAP_EVENT_ENC_CHANGE:
        ESP_LOGI(TAG, "Encryption handle=%u status=%d secure=%d", event->enc_change.conn_handle,
                 event->enc_change.status, encrypted(event->enc_change.conn_handle));
        if (ready()) send_report(0, 0, 0, 0);
        if (keyboard_ready()) send_keyboard(0, 0);
        if ((event->enc_change.conn_handle == hid_connection || event->enc_change.conn_handle == move_owner)
            && !encrypted(event->enc_change.conn_handle)) { cancel_click(); cancel_move(); }
        notify_status(); return 0;
    case BLE_GAP_EVENT_SUBSCRIBE:
        if (event->subscribe.attr_handle == report_handle) {
            if (event->subscribe.cur_notify) hid_connection = event->subscribe.conn_handle;
            if (event->subscribe.conn_handle == hid_connection) report_subscribed = event->subscribe.cur_notify;
        }
        if (event->subscribe.attr_handle == boot_handle) {
            if (event->subscribe.cur_notify) hid_connection = event->subscribe.conn_handle;
            if (event->subscribe.conn_handle == hid_connection) boot_subscribed = event->subscribe.cur_notify;
        }
        if (event->subscribe.attr_handle == status_handle) {
            if (event->subscribe.cur_notify) control_connection = event->subscribe.conn_handle;
            if (event->subscribe.conn_handle == control_connection) status_subscribed = event->subscribe.cur_notify;
        }
        if (event->subscribe.attr_handle == keyboard_handle) {
            if (event->subscribe.cur_notify) keyboard_connection = event->subscribe.conn_handle;
            if (event->subscribe.conn_handle == keyboard_connection) keyboard_subscribed = event->subscribe.cur_notify;
        }
        if (event->subscribe.attr_handle == keyboard_boot_handle) {
            if (event->subscribe.cur_notify) keyboard_connection = event->subscribe.conn_handle;
            if (event->subscribe.conn_handle == keyboard_connection) keyboard_boot_subscribed = event->subscribe.cur_notify;
        }
        if (event->subscribe.attr_handle == consumer_handle) {
            if (event->subscribe.cur_notify) consumer_connection = event->subscribe.conn_handle;
            if (event->subscribe.conn_handle == consumer_connection) consumer_subscribed = event->subscribe.cur_notify;
            cancel_consumer();
        }
        // Only a HID subscription transition should release a held button.
        if (event->subscribe.attr_handle == report_handle || event->subscribe.attr_handle == boot_handle) {
            if (pending_move) last_error = ERR_INTERRUPTED;
            cancel_click(); cancel_move(); if (ready()) send_report(0, 0, 0, 0);
        }
        if (event->subscribe.attr_handle == keyboard_handle || event->subscribe.attr_handle == keyboard_boot_handle) {
            if (key_count) { last_error = ERR_INTERRUPTED; cancel_keys(); }
            if (keyboard_ready()) send_keyboard(0, 0);
            else if (keyboard_held()) reset_timer(&keyboard_watchdog, 50);
        }
        ESP_LOGI(TAG, "Subscribed: conn=%u report=%d boot=%d keyboard=%d kboot=%d consumer=%d status=%d links=%d",
                 event->subscribe.conn_handle, report_subscribed, boot_subscribed, keyboard_subscribed,
                 keyboard_boot_subscribed, consumer_subscribed, status_subscribed, link_count());
        notify_status(); return 0;
    case BLE_GAP_EVENT_REPEAT_PAIRING:
        // Require explicitly erasing old bonds rather than silently replacing trust.
        ESP_LOGW(TAG, "Stale bond: forget device on iPhone and run idf.py erase-flash");
        return BLE_GAP_REPEAT_PAIRING_IGNORE;
    case BLE_GAP_EVENT_NOTIFY_TX:
        if ((event->notify_tx.attr_handle == keyboard_handle || event->notify_tx.attr_handle == keyboard_boot_handle)
            && event->notify_tx.status) {
            if (keyboard_held()) reset_timer(&keyboard_watchdog, 50);
            last_error = ERR_NOTIFY; notify_status();
        }
        if (event->notify_tx.attr_handle == consumer_handle && event->notify_tx.status) {
            if (consumer_held()) reset_timer(&consumer_timer, 50);
            last_error = ERR_NOTIFY; notify_status();
        }
        if ((event->notify_tx.attr_handle == report_handle || event->notify_tx.attr_handle == boot_handle)
            && event->notify_tx.status) {
            if (pending_move) { cancel_move(); if (ready()) send_report(0, 0, 0, 0); }
            last_error = ERR_NOTIFY; notify_status();
        }
        return 0;
    default: return 0;
    }
}
static void advertise(void) {
    if (link_count() >= MAX_LINKS || ble_gap_adv_active()) return;
    static const ble_uuid16_t hid_uuid = BLE_UUID16_INIT(0x1812);
    struct ble_hs_adv_fields fields = {0};
    fields.flags = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;
    fields.name = (uint8_t *)DEVICE_NAME; fields.name_len = strlen(DEVICE_NAME); fields.name_is_complete = 1;
    fields.appearance = 0x03c0; fields.appearance_is_present = 1; // Generic HID: mouse + keyboard.
    fields.uuids16 = &hid_uuid; fields.num_uuids16 = 1; fields.uuids16_is_complete = 1;
    int rc = ble_gap_adv_set_fields(&fields);
    assert(rc == 0);
    struct ble_hs_adv_fields response = {0};
    response.uuids128 = &control_uuid; response.num_uuids128 = 1; response.uuids128_is_complete = 1;
    rc = ble_gap_adv_rsp_set_fields(&response); assert(rc == 0);
    struct ble_gap_adv_params params = {0};
    params.conn_mode = BLE_GAP_CONN_MODE_UND; params.disc_mode = BLE_GAP_DISC_MODE_GEN;
    rc = ble_gap_adv_start(own_addr_type, NULL, BLE_HS_FOREVER, &params, gap_event, NULL);
    assert(rc == 0);
    ESP_LOGI(TAG, "Advertising %s", DEVICE_NAME);
}
static void on_sync(void) {
    int rc = ble_hs_util_ensure_addr(0); assert(rc == 0);
    rc = ble_hs_id_infer_auto(0, &own_addr_type); assert(rc == 0);
    // Composite HID changes the report map and subsequent service handles.
    // Request complete rediscovery while preserving stored pairing keys.
    ble_svc_gatt_changed(1, UINT16_MAX);
    advertise();
}
static void on_reset(int reason) {
    ESP_LOGW(TAG, "Host reset: %d", reason); clear_all();
}
static void host_task(void *param) {
    (void)param; nimble_port_run(); nimble_port_freertos_deinit();
}
void app_main(void) {
    esp_err_t led_rc = status_led_init();
    if (led_rc != ESP_OK) ESP_LOGW(TAG, "RGB disabled: %s", esp_err_to_name(led_rc));
    esp_err_t rc = nvs_flash_init();
    if (rc == ESP_ERR_NVS_NO_FREE_PAGES || rc == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase()); rc = nvs_flash_init();
    }
    ESP_ERROR_CHECK(rc);
    ESP_ERROR_CHECK(nimble_port_init());
    ble_hs_cfg.sync_cb = on_sync; ble_hs_cfg.reset_cb = on_reset;
    ble_hs_cfg.store_status_cb = ble_store_util_status_rr;
    ble_hs_cfg.sm_io_cap = BLE_HS_IO_NO_INPUT_OUTPUT;
    ble_hs_cfg.sm_bonding = 1; ble_hs_cfg.sm_mitm = 0; ble_hs_cfg.sm_sc = 1;
    ble_hs_cfg.sm_our_key_dist = BLE_SM_PAIR_KEY_DIST_ENC | BLE_SM_PAIR_KEY_DIST_ID;
    ble_hs_cfg.sm_their_key_dist = BLE_SM_PAIR_KEY_DIST_ENC | BLE_SM_PAIR_KEY_DIST_ID;
    ble_svc_gap_init(); ble_svc_gatt_init();
    int ret = ble_svc_gap_device_name_set(DEVICE_NAME); assert(ret == 0);
    ret = ble_svc_gap_device_appearance_set(0x03c0); assert(ret == 0);
    ret = ble_gatts_count_cfg(services); assert(ret == 0);
    ret = ble_gatts_add_svcs(services); assert(ret == 0);
    ble_store_config_init();
    ret = ble_npl_callout_init(&watchdog_timer, nimble_port_get_dflt_eventq(), watchdog_event, NULL); assert(ret == 0);
    ret = ble_npl_callout_init(&click_timer, nimble_port_get_dflt_eventq(), click_event, NULL); assert(ret == 0);
    ret = ble_npl_callout_init(&move_timer, nimble_port_get_dflt_eventq(), move_event, NULL); assert(ret == 0);
    ret = ble_npl_callout_init(&keyboard_watchdog, nimble_port_get_dflt_eventq(), keyboard_watchdog_event, NULL); assert(ret == 0);
    ret = ble_npl_callout_init(&consumer_timer, nimble_port_get_dflt_eventq(), consumer_event, NULL); assert(ret == 0);
    ret = ble_npl_callout_init(&key_timer, nimble_port_get_dflt_eventq(), key_event, NULL); assert(ret == 0);
    ESP_LOGI(TAG, "Composite HID enabled: mouse ID 1, keyboard ID 2, consumer ID 3, automatic key release, timed key sequences");
    ESP_LOGI(TAG, "Buffered pointer trajectories enabled: local timed HID reports");
    nimble_port_freertos_init(host_task);
}
