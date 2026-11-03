# Spike: take a FreePBX call in the app

**Question.** Can a terminal register with FreePBX as a phone and take a call inside the POS app, with audio
good enough for the host stand?

**Setup.** The app registers over a secure WebSocket (`wss://<pbx>:8089/ws`) as a PJSIP extension of its own
and carries the audio as WebRTC media (DTLS-SRTP), the same path FreePBX's own browser phone uses. The Flutter
side is `sip_ua` (a Dart port of JsSIP from the flutter-webrtc project) behind a phone setting that is off by
default. The assessment with the options and the effort is in the project thread "Take FreePBX calls in the app".

**Pass.** A two-way call with clear audio on a Mac and on an iPad over the restaurant's internet, answered in
the app, with mute and hang up working, and the terminal ringing again afterwards.

## What the app does in this spike

- Settings, Phone: a switch, the PBX address, the extension and its secret. Saved on the device like the hub
  address. Off by default, so nothing changes for a terminal that is not a phone.
- While the phone is on and filled in, the app registers at start and stays registered (`sip_ua` reconnects
  on its own after a dropped connection).
- A call rings as a banner over whatever screen is open: the caller's number and name, Answer, Decline. The
  Mac plays its alert sound; iPad and Android stay silent for now.
- During a call a small strip at the top shows the number, the call time, Mute and Hang up.
- A second call while one is on gets a busy answer; the ring group carries it to the other phones.
- Not yet: hold, transfer, keypad, outgoing calls, ringing on a locked iPad (needs a push relay), the caller's
  number into an order, a ringtone on iPad and Android.

## PBX setup (about half an hour)

All in the FreePBX admin, with **Apply Config** after each step.

1. **Certificate.** Admin, Certificate Management. If there is no Let's Encrypt certificate for
   freepbx.chinasky.org yet: **+ New Certificate, Generate Let's Encrypt Certificate**, hostname
   `freepbx.chinasky.org`, your email, Generate. Let's Encrypt must reach port 80 on the PBX (Connectivity,
   Firewall, Advanced: **Responsive LetsEncrypt Rules** on). Then make it the default certificate (the
   Default column). A self-signed certificate will not do: the app refuses it, like a browser would.
2. **Asterisk's HTTPS server.** Settings, Advanced Settings, section *Asterisk Builtin mini-HTTP server*:
   - Enable the mini-HTTP Server: Yes
   - Enable TLS for the mini-HTTP Server: Yes
   - HTTP Bind Address: leave `127.0.0.1`; HTTP Bind Port: 8088
   - **HTTPS Bind Address: `0.0.0.0`**, not `127.0.0.1`: the WebSocket rides on this server, and a loopback
     bind refuses every terminal (the FreePBX default `::` works too)
   - HTTPS Bind Port: 8089
   - **HTTP Prefix: empty**. A value there, such as `8089`, moves the WebSocket to `/<prefix>/ws`
   - HTTPS TLS Certificate Location: `/etc/asterisk/keys/integration/certificate.pem`
   - HTTPS TLS Private Key Location: `/etc/asterisk/keys/integration/webserver.key`

   Those are the copies Certificate Management keeps of the default certificate. If the fields already point
   at files of the default certificate, leave them. The same two fixes from the shell: `fwconsole setting
   HTTPTLSBINDADDRESS 0.0.0.0`, `fwconsole setting HTTPPREFIX ''`, then `fwconsole reload`.
3. **WebSocket transport.** Settings, Asterisk SIP Settings, tab *SIP Settings [chan_pjsip]*, Transports:
   set **wss** to Yes; leave udp, tcp and tls as they are. On the *General SIP Settings* tab the External
   Address (144.202.2.62), the Local Networks and the RTP port range (10000 to 20000) stay as they are for the
   existing phones.
4. **An extension for the terminal.** Applications, Extensions, + Add Extension, + Add New SIP [chan_pjsip]
   Extension: User Extension `301`, Display Name `POS mac1`, Secret: keep the generated one and copy it (it goes
   into the app). Advanced tab: **Enable WebRTC defaults: Yes**, **Media Encryption: DTLS-SRTP**, **Direct Media: No**,
   Max Contacts 1. Submit, Apply Config. One extension per terminal: 302 for the iPad, and so on.
5. **Check on the console.** `ssh root@144.202.2.62`, then `asterisk -rvvv`:

   ```
   http show status          Prefix empty, HTTPS bound to 0.0.0.0:8089 (not 127.0.0.1), /ws among the enabled URIs
   pjsip show transports     a wss transport listed (the port it prints is unused; the WebSocket is on 8089)
   pjsip show endpoint 301   media_encryption: dtls, ice_support: true, use_avpf: true, rtcp_mux: true,
                             dtls_auto_generate_cert: true (or a dtls_cert_file), webrtc: true
   ```

   From the shell, `ss -ltnp | grep 8089` must show `0.0.0.0:8089`, and from any other machine this must answer
   `101 Switching Protocols`:

   ```
   curl -sv https://freepbx.chinasky.org:8089/ws -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
     -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' -H 'Sec-WebSocket-Protocol: sip'
   ```

   If the endpoint does not show those, set them on the extension's Advanced tab by hand (older FreePBX
   versions did not apply the WebRTC switch fully): Media Encryption DTLS-SRTP, Enable AVPF Yes, Enable ICE
   Support Yes, Enable rtcp Mux Yes, DTLS Verify Fingerprint, DTLS Setup Act/Pass, DTLS Auto Generate
   Certificate Yes (or the default certificate under DTLS Certificate).
6. **Firewall.** Connectivity, Firewall, Networks: the restaurant's public address in the **Trusted** zone,
   which opens 8089 and the RTP ports to it. To avoid trusting the whole address, allow 8089/tcp and
   10000 to 20000/udp from it under Services, Custom Services instead. Add the same address under Admin,
   Intrusion Detection, Whitelist, so a mistyped secret cannot ban the restaurant. The firewall's own
   **Webrtc** service (8088 and 8089) is attached to the Internal zone only, and the External zone allows
   nothing but VPN, so an address in no zone is dropped silently on 8089.
7. **A way to ring it.** For the first test nothing more: dial `301` from a desk phone. To ring 301 from the
   restaurant's number, add it where that number lands today: Applications, Queues, `default`, Static Agents
   `301`, or the ring group the inbound route points at.

## Device setup

1. Pull `main`. On the Mac: `cd ~/pos/apps/pos_app && flutter run -d macos --release`. The first build
   downloads the WebRTC framework, a few minutes.
2. In the app: Settings, Phone: switch on, PBX address `freepbx.chinasky.org`, Extension `301`, Secret from
   PBX step 4. Save. The Phone line reads *Registered as 301 on freepbx.chinasky.org*; if not, it says what the
   PBX answered.
3. macOS asks for the microphone on the first answered call. Allow.
4. iPad: `flutter run -d <ipad> --release`, the same settings with the iPad's own extension (302). The iPad
   asks for the microphone once.

## Test

1. From a desk phone dial 301: the app shows the banner. Answer; talk both ways; Mute; Hang up. Note the audio
   at the host stand with the speaker, then with a headset.
2. Hang up from the other side: the strip disappears and the terminal is registered again.
3. Call the restaurant's number from a cell (after PBX step 7): the terminal rings together with the desk
   phones; answer in the app; the others stop.
4. Second call while on a call: the app answers busy; the ring group carries it to the other phones.

## Troubleshooting

Settings, Phone shows the PBX's answer under the switch; a release build logs nothing else (a debug run,
`flutter run -d macos`, prints the whole SIP exchange).

| Status line | Cause |
| --- | --- |
| `Connecting to … · 500 … Connection refused` | 8089 closed: HTTPS Bind Address `127.0.0.1` (step 2), or the firewall rejects the address (step 6) |
| `Connecting to …` with no error for a minute, then `… timed out` | the firewall drops the packets (step 6) |
| `… was not upgraded to websocket` | HTTP Prefix set (step 2) or no wss transport (step 3) |
| `… HandshakeException …` | certificate not trusted (step 1: Let's Encrypt, made the default, Apply Config) |
| `Not registered: 401 Unauthorized` or `403 Forbidden` | extension or secret (step 4) |
| Rings, but Answer ends the call at once | the extension lacks the WebRTC defaults (step 4; `pjsip show endpoint 301`) |

## Result

Pending (2026-11-03). First attempt the same day: the app never reached the PBX, because the HTTPS server was
bound to `127.0.0.1`, the HTTP Prefix was `8089` and extension 301 lacked the WebRTC defaults (all three
found over SSH, none on the app side); the steps above now say so.
