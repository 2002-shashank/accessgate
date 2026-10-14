# Access Gate

An ID-verified smart door. An iPhone app built on the **Credence ID Tap2iD SDK** verifies a mobile driver's license (ISO/IEC 18013-5 mDL) presented from a wallet over QR code and Bluetooth, checks that the holder is over 21, and tells an **ESP32 touchscreen gate** to unlock or stay locked.

The gate never learns your name, address, or birth date. With the Age Check profile, the wallet shares only three items: over 21, a photo to match the holder, and the issuing authority.

## How it works

```
Wallet phone ──QR──▶ iPhone verifier app ──HTTP (local WiFi)──▶ ESP32 gate
     ▲                      │
     └──── Bluetooth LE ────┘   ID data + signatures, verified by Tap2iD SDK
```

1. The holder's wallet shows an ISO 18013-5 engagement QR code.
2. The iPhone scans it and the Tap2iD SDK retrieves the requested data over BLE.
3. The SDK checks the issuer signature, data digests, device binding, and whether the issuer is trusted (per Trust Management in Verify with Credence).
4. The app applies the access policy (all security checks pass, holder over 21).
5. The app calls the gate: `/grant` or `/deny`, authenticated with a shared token.
6. The ESP32 shows the result on its display and LED, then resets after 5 seconds.

## Repository layout

```
Untitled Project/        iOS verifier app (Xcode project, SwiftUI)
esp32-gate/AccessGate/   ESP32 gate firmware (Arduino)
Secrets.example.swift    Template for the iOS app's local secrets
```

## Running the iOS app

Requirements: Xcode, an iPhone (camera + Bluetooth), a Tap2iD SDK license key from Verify with Credence tied to your bundle ID.

1. Copy `Secrets.example.swift` to `Untitled Project/Untitled Project/Secrets.swift` and fill in the license key, the gate's IP address, and the gate token.
2. Open the Xcode project, set your signing team and bundle identifier (it must match the license key).
3. Run on a real iPhone. Allow Camera, Bluetooth, and Local Network access when prompted.

The app uses QR engagement because the NFC and Apple ID Verifier entitlements require a paid Apple Developer account and Apple approval.

## Running the ESP32 gate

Hardware: Sunton ESP32-3248S035R (ESP32 with 3.5" 480x320 display), TFT_eSPI library configured for the board.

1. Copy `esp32-gate/AccessGate/secrets.example.h` to `secrets.h` and fill in a **2.4 GHz** WiFi network and the same token used in the iOS app.
2. Open `AccessGate.ino` in the Arduino IDE, select *ESP32 Dev Module*, and upload (115200 upload speed is the most reliable).
3. The gate's IP address is shown at the bottom of the display.

Endpoints:

| Endpoint | Purpose |
|---|---|
| `/grant?name=…&token=…` | Show Access Granted, green LED |
| `/deny?reason=…&token=…` | Show Access Denied, red LED |
| `/status` | Current state as JSON |

## Trust and test credentials

Testing used the Multipaz Wallet from the OpenWallet Foundation. Its built-in test issuer is not in the trust list by default, so the SDK correctly reports `isIssuerTrusted = false` and the gate stays locked. In production, issuer certificates (IACAs) are managed in **Trust Management** in Verify with Credence.

For demos, the app has an **"Accept test issuers (development only)"** switch, off by default. When on, it accepts the Multipaz test issuer only, and the result screen clearly labels the credential as accepted in development mode. All other security checks still apply.

## Security notes

- License keys, WiFi credentials, and the gate token live in gitignored files (`Secrets.swift`, `secrets.h`).
- The gate rejects requests without the shared token.
- A production version would use HTTPS or a signed message between app and gate instead of a shared token over plain HTTP.

## Use of AI tools

AI tools (Claude) were used to help write and debug the code in this repository. The design decisions, testing on hardware, and integration with the Credence ID platform were done by me.

## Not included

The Credence ID sample app is not part of this repository; it is licensed for internal use only. This app was written from the SDK's published documentation.
