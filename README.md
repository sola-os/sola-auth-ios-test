# sola-auth-ios-test

Real-iOS check of SOLA HQ sign-in: **passkeys** and the **SOLA Authenticator** web app, driven in
**Safari on an iPhone simulator** (GitHub Actions macOS runner, Face ID enrolled in the simulator).

It runs only against a **disposable test instance** (empty database, one throwaway user, no outbound
network, own WebAuthn relying party). No SOLA source, no HQ data and no HQ secrets are in this repository.
The instance URL, the test user's address and the instance's bootstrap secret are repository secrets.

## What the test does (`AuthUITests/SafariAuthTests.swift`)

1. Signs in the throwaway user with a one-time link (minted by the workflow from the bootstrap secret).
2. **Passkey:** opens *Passkeys & phone*, taps *Add a passkey on this device*, confirms the iOS passkey sheet,
   Face ID (a matching face is sent with `notifyutil`), then signs out and **signs in with the passkey**
   (discoverable: no username), and checks `/api/me`.
3. **SOLA Authenticator:** mints a phone set-up code, signs out, opens `/authenticator/`, enters the code and
   creates the **device key** (a WebAuthn platform credential, user verification required).
4. **Approve:** a second, headless browser session (an ephemeral `URLSession` inside the test: its own cookie
   jar) starts "approve on my phone". Safari shows the request (without the code); the test types the code the
   "laptop" got, taps *Approve with Face ID*, and checks that the laptop session is now signed in.
5. **Deny:** the same with *Deny*: the laptop is told "denied" and gets no session.
6. Best effort: *Share → Add to Home Screen*, then opens the installed web app from the Home Screen.

Screenshots of every step are uploaded as the `ios-auth-screenshots` artifact.

## Running

Actions → **ios-auth** → *Run workflow* (manual only, `permissions: contents: read`, pinned action SHAs).

Secrets: `AUTH_TEST_BASE_URL`, `AUTH_TEST_EMAIL`, `AUTH_TEST_BOOTSTRAP_SECRET`.

Project generated with XcodeGen (`project.yml`); the host app is empty, the UI test drives Safari
(`com.apple.mobilesafari`).
