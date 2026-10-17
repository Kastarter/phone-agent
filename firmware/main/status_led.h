#pragma once
#include <stdbool.h>
#include <stdint.h>
#include "esp_err.h"

typedef enum {
    AGENT_LED_IDLE = 0,
    AGENT_LED_RUNNING = 1,
    AGENT_LED_FAILED = 2,
    AGENT_LED_COMPLETED = 3,
} agent_led_task_state_t;

esp_err_t status_led_init(void);
void status_led_set_connected(bool connected);
void status_led_set_task(agent_led_task_state_t state);
