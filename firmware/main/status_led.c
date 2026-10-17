#include "status_led.h"
#include "sdkconfig.h"

#if CONFIG_AGENTMOUSE_STATUS_RGB
#include <math.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "driver/rmt_tx.h"
#include "driver/rmt_encoder.h"
#include "esp_timer.h"
#include "esp_log.h"

#define FRAME_MS 20
#define RUN_LEASE_US (10LL * 1000 * 1000)
static const char *TAG = "AgentRGB";
static portMUX_TYPE state_lock = portMUX_INITIALIZER_UNLOCKED;
static bool connected;
static agent_led_task_state_t task_state = AGENT_LED_IDLE;
static int64_t heartbeat_us;
static rmt_channel_handle_t channel;
static rmt_encoder_handle_t encoder;

void status_led_set_connected(bool value) {
    portENTER_CRITICAL(&state_lock);
    if (!value || !connected) { task_state = AGENT_LED_IDLE; heartbeat_us = 0; }
    connected = value;
    portEXIT_CRITICAL(&state_lock);
}
void status_led_set_task(agent_led_task_state_t state) {
    const int64_t now = esp_timer_get_time();
    portENTER_CRITICAL(&state_lock);
    task_state = state; heartbeat_us = now;
    portEXIT_CRITICAL(&state_lock);
}
static esp_err_t draw(uint8_t red, uint8_t green, uint8_t blue) {
    // One onboard WS2812. All 25 symbols fit in RMT hardware memory, so
    // Bluetooth interrupt latency cannot starve a mid-frame refill.
    const uint8_t grb[] = {green, red, blue};
    rmt_symbol_word_t symbols[25] = {0};
    for (int byte = 0; byte < 3; ++byte) {
        for (int bit = 0; bit < 8; ++bit) {
            const bool one = (grb[byte] & (0x80 >> bit)) != 0;
            symbols[byte * 8 + bit] = (rmt_symbol_word_t){
                .level0 = 1, .duration0 = one ? 9 : 3,
                .level1 = 0, .duration1 = one ? 3 : 9,
            };
        }
    }
    // 300 us low reset/latch, also accommodating newer WS2812 revisions.
    symbols[24] = (rmt_symbol_word_t){.level0 = 0, .duration0 = 1500, .level1 = 0, .duration1 = 1500};
    const rmt_transmit_config_t tx = {.loop_count = 0};
    esp_err_t rc = rmt_transmit(channel, encoder, symbols, sizeof(symbols), &tx);
    // Keep the payload alive until TX is done. Runs in this task only, never
    // in the NimBLE host queue or a HID callback.
    if (rc == ESP_OK) rc = rmt_tx_wait_all_done(channel, -1);
    return rc;
}
static void rainbow(double phase, uint8_t brightness, uint8_t *r, uint8_t *g, uint8_t *b) {
    const double hue = phase * 6.0;
    const int sector = (int)hue % 6;
    const uint8_t rising = (uint8_t)(brightness * (hue - floor(hue)));
    const uint8_t falling = brightness - rising;
    switch (sector) {
    case 0: *r = brightness; *g = rising; *b = 0; break;
    case 1: *r = falling; *g = brightness; *b = 0; break;
    case 2: *r = 0; *g = brightness; *b = rising; break;
    case 3: *r = 0; *g = falling; *b = brightness; break;
    case 4: *r = rising; *g = 0; *b = brightness; break;
    default: *r = brightness; *g = 0; *b = falling; break;
    }
}
static void led_task(void *arg) {
    (void)arg;
    TickType_t tick = xTaskGetTickCount();
    int previous_mode = -1;
    int64_t mode_started = esp_timer_get_time();
    int64_t last_warning = 0;
    for (;;) {
        const int64_t now = esp_timer_get_time();
        portENTER_CRITICAL(&state_lock);
        if (connected && task_state == AGENT_LED_RUNNING && now - heartbeat_us > RUN_LEASE_US)
            task_state = AGENT_LED_FAILED;
        const int mode = connected ? (int)task_state : 4; // disconnected wins
        portEXIT_CRITICAL(&state_lock);
        if (mode != previous_mode) {
            previous_mode = mode; mode_started = now;
            ESP_LOGI(TAG, "Mode=%s", mode == 4 ? "blue/disconnected" : mode == 0 ? "white/idle" :
                     mode == 1 ? "rainbow/running" : mode == 2 ? "red/failed" : "green/completed");
        }
        const int64_t elapsed = now - mode_started;
        uint8_t r = 0, g = 0, b = 0;
        if (mode == AGENT_LED_RUNNING) {
            rainbow((double)(elapsed % 3000000) / 3000000.0, CONFIG_AGENTMOUSE_RGB_BRIGHTNESS, &r, &g, &b);
        } else {
            const double phase = (double)(elapsed % 2600000) / 2600000.0;
            const double wave = 0.5 - 0.5 * cos(phase * 6.283185307179586);
            const uint8_t level = 1 + (uint8_t)((CONFIG_AGENTMOUSE_RGB_BRIGHTNESS - 1) * wave * wave);
            if (mode == 4) b = level;
            else if (mode == AGENT_LED_FAILED) r = level;
            else if (mode == AGENT_LED_COMPLETED) g = level;
            else r = g = b = level;
        }
        esp_err_t rc = draw(r, g, b);
        if (rc != ESP_OK && now - last_warning > 5000000) {
            ESP_LOGW(TAG, "RGB update: %s", esp_err_to_name(rc)); last_warning = now;
        }
        vTaskDelayUntil(&tick, pdMS_TO_TICKS(FRAME_MS));
    }
}
esp_err_t status_led_init(void) {
    const rmt_tx_channel_config_t config = {
        .gpio_num = CONFIG_AGENTMOUSE_RGB_GPIO, .clk_src = RMT_CLK_SRC_DEFAULT,
        .resolution_hz = 10000000, .mem_block_symbols = 64, .trans_queue_depth = 1,
    };
    esp_err_t rc = rmt_new_tx_channel(&config, &channel);
    if (rc != ESP_OK) return rc;
    const rmt_copy_encoder_config_t copy = {};
    rc = rmt_new_copy_encoder(&copy, &encoder);
    if (rc == ESP_OK) rc = rmt_enable(channel);
    if (rc == ESP_OK && xTaskCreate(led_task, "agent_rgb", 3072, NULL, 2, NULL) != pdPASS) rc = ESP_ERR_NO_MEM;
    if (rc != ESP_OK) {
        rmt_disable(channel);
        if (encoder) { rmt_del_encoder(encoder); encoder = NULL; }
        rmt_del_channel(channel); channel = NULL;
    } else ESP_LOGI(TAG, "WS2812 RGB ready: GPIO%d, GRB, brightness=%d/255", CONFIG_AGENTMOUSE_RGB_GPIO, CONFIG_AGENTMOUSE_RGB_BRIGHTNESS);
    return rc;
}
#else
// RGB can be disabled in menuconfig without changing mouse or keyboard support.
esp_err_t status_led_init(void) { return ESP_OK; }
void status_led_set_connected(bool value) { (void)value; }
void status_led_set_task(agent_led_task_state_t state) { (void)state; }
#endif
