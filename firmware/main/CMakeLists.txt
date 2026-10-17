idf_component_register(SRCS "main.c" "status_led.c" INCLUDE_DIRS "." REQUIRES bt nvs_flash esp_driver_rmt esp_timer)
