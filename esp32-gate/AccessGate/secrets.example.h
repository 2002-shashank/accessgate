// secrets.example.h
// Copy this file to secrets.h (same folder) and fill in your values.
// secrets.h is gitignored so real credentials never reach the repo.

#pragma once

const char* WIFI_SSID = "YOUR_2.4GHZ_WIFI_NAME";   // ESP32 supports 2.4 GHz only
const char* WIFI_PASS = "YOUR_WIFI_PASSWORD";
const char* TOKEN     = "YOUR_GATE_TOKEN";          // must match Secrets.gateToken in the iOS app
