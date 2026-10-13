// AccessGate.ino
// ESP32 "door" for the ID-verified access demo.
// Board: Sunton ESP32-3248S035R (3.5" 480x320, ST7796), TFT_eSPI library.
//
// The iPhone verifier app calls one of these over WiFi:
//   http://accessgate.local/grant?name=Alex&token=YOUR_TOKEN
//   http://accessgate.local/deny?reason=Under%2021&token=YOUR_TOKEN
//   http://accessgate.local/status
// The screen shows the result for a few seconds, then returns to "waiting".

#include <WiFi.h>
#include <WebServer.h>
#include <ESPmDNS.h>
#include <TFT_eSPI.h>

// ---------- Settings ----------
// WiFi credentials and the shared token live in secrets.h (gitignored).
// Copy secrets.example.h to secrets.h and fill in your values.
#include "secrets.h"
const char* HOSTNAME  = "accessgate";      // -> http://accessgate.local
const unsigned long RESULT_MS = 5000;      // how long to show a result

// Onboard RGB LED (active LOW on most CYD boards). Set to 0 if yours has none.
#define USE_RGB_LED 1
#define LED_R 4
#define LED_G 16
#define LED_B 17
// --------------------------------------------

TFT_eSPI tft;
WebServer server(80);

enum State { WAITING, GRANTED, DENIED };
State state = WAITING;
unsigned long stateSince = 0;

void setLed(bool r, bool g, bool b) {
#if USE_RGB_LED
  digitalWrite(LED_R, r ? LOW : HIGH);
  digitalWrite(LED_G, g ? LOW : HIGH);
  digitalWrite(LED_B, b ? LOW : HIGH);
#endif
}

void centerText(const String& s, int y, int font, int size, uint16_t fg, uint16_t bg) {
  tft.setTextDatum(MC_DATUM);
  tft.setTextSize(size);
  tft.setTextColor(fg, bg);
  tft.drawString(s, tft.width() / 2, y, font);
}

void showWaiting() {
  state = WAITING;
  uint16_t bg = TFT_BLACK;
  tft.fillScreen(bg);
  centerText("ACCESS GATE", 70, 4, 2, TFT_WHITE, bg);
  centerText("Present your mobile ID", 160, 4, 1, TFT_LIGHTGREY, bg);
  centerText("to the verifier", 195, 4, 1, TFT_LIGHTGREY, bg);
  centerText(WiFi.localIP().toString(), 295, 2, 1, TFT_DARKGREY, bg);
  setLed(false, false, true);   // blue = idle
}

void showGranted(const String& name) {
  state = GRANTED;
  stateSince = millis();
  uint16_t bg = TFT_DARKGREEN;
  tft.fillScreen(bg);
  centerText("ACCESS GRANTED", 90, 4, 2, TFT_WHITE, bg);
  if (name.length() > 0) centerText("Welcome, " + name, 180, 4, 1, TFT_WHITE, bg);
  centerText("ID verified", 230, 4, 1, TFT_WHITE, bg);
  setLed(false, true, false);   // green
}

void showDenied(const String& reason) {
  state = DENIED;
  stateSince = millis();
  uint16_t bg = TFT_RED;
  tft.fillScreen(bg);
  centerText("ACCESS DENIED", 90, 4, 2, TFT_WHITE, bg);
  centerText(reason.length() > 0 ? reason : String("Verification failed"), 190, 4, 1, TFT_WHITE, bg);
  setLed(true, false, false);   // red
}

String clean(String s, size_t maxLen) {
  s.trim();
  if (s.length() > maxLen) s = s.substring(0, maxLen);
  return s;
}

bool authorized() {
  if (server.arg("token") == TOKEN) return true;
  server.send(401, "application/json", "{\"ok\":false,\"error\":\"bad token\"}");
  return false;
}

void handleGrant() {
  if (!authorized()) return;
  showGranted(clean(server.arg("name"), 20));
  server.send(200, "application/json", "{\"ok\":true,\"state\":\"granted\"}");
}

void handleDeny() {
  if (!authorized()) return;
  showDenied(clean(server.arg("reason"), 28));
  server.send(200, "application/json", "{\"ok\":true,\"state\":\"denied\"}");
}

void handleStatus() {
  const char* s = state == GRANTED ? "granted" : state == DENIED ? "denied" : "waiting";
  server.send(200, "application/json", String("{\"ok\":true,\"state\":\"") + s + "\"}");
}

void setup() {
  Serial.begin(115200);

#if USE_RGB_LED
  pinMode(LED_R, OUTPUT);
  pinMode(LED_G, OUTPUT);
  pinMode(LED_B, OUTPUT);
  setLed(false, false, false);
#endif

  tft.init();
  tft.setRotation(1);   // landscape, 480x320
  tft.fillScreen(TFT_BLACK);
  centerText("Connecting to WiFi...", 160, 4, 1, TFT_WHITE, TFT_BLACK);

  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASS);
  unsigned long start = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - start < 20000) {
    delay(300);
    Serial.print(".");
  }
  if (WiFi.status() != WL_CONNECTED) {
    tft.fillScreen(TFT_RED);
    centerText("WiFi failed - check settings", 160, 4, 1, TFT_WHITE, TFT_RED);
    return;
  }
  Serial.printf("\nConnected. IP: %s\n", WiFi.localIP().toString().c_str());

  if (MDNS.begin(HOSTNAME)) {
    MDNS.addService("http", "tcp", 80);
    Serial.printf("mDNS: http://%s.local\n", HOSTNAME);
  }

  server.on("/grant", handleGrant);
  server.on("/deny", handleDeny);
  server.on("/status", handleStatus);
  server.onNotFound([]() { server.send(404, "text/plain", "not found"); });
  server.begin();

  showWaiting();
}

void loop() {
  server.handleClient();
  if (state != WAITING && millis() - stateSince > RESULT_MS) {
    showWaiting();
  }
}
