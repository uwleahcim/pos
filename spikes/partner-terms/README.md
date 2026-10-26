# Spike: partner terms in writing

**Question.** What do the partners allow a third-party POS to do, and on what terms?

| Partner | Ask | Answer |
| --- | --- | --- |
| GoDaddy Payments | Can a third-party POS drive your readers (sale, tip, refund, pre-auth, incremental, offline)? Developer program, fees. | pending |
| ezCater | Direct partner API for orders, menus and confirmations, or an approved order aggregator? Fees and commission reporting. | pending |
| Resy | Partner API for reservations and waitlist into a POS, table status back. | pending |
| FreePBX / hosting | Access to the Asterisk Manager Interface from the POS cloud; queue control for agents. Host: freepbx.chinasky.org, Mike's own Vultr server (144.202.2.62). | **done 2026-10-26.** Own server, no terms. AMI access proven from the hub over an SSH tunnel (Asterisk 18.20.2, FreePBX 16, Twilio SIP trunks, extensions 200-210). Live call seen: Twilio delivers in context `from-pstn-e164-us`, dialed number in E.164, location resolved from the last ten digits. |
| Stripe | Terminal in the restaurant's region, offline mode and incremental authorization support per reader model. | pending |

**Pass.** Every row has a written yes or no (or a named aggregator) by the end of phase 0.

## FreePBX access (freepbx.chinasky.org)

Step-by-step guide for the PBX side, with the rights table and troubleshooting:
https://claude.ai/artifact/Fs93chULAW47LsLYx9Ejq8

The probe is in the repository: `backend/src/pos/phones/ami.py` logs in with a challenge-response, lists the
PBX (version, queues, endpoints, live channels), tails incoming calls with the location detected from the
dialed number, pauses and unpauses an agent in the queues, and originates a call. Those are the three
primitives the phone connector needs. It is tested against a fake PBX (`backend/tests/phones`).

```
cd backend
AMI_SECRET='the secret' .venv/bin/python -m pos.phones.ami --host freepbx.chinasky.org --user pos probe
AMI_SECRET='the secret' .venv/bin/python -m pos.phones.ami --host freepbx.chinasky.org --user pos \
    tail --location 5551230001=Downtown --location 5551230002=Airport
```

The secret is read from the environment, never from a flag. Add `--tls --port 5039` when the manager
interface runs TLS.

What the PBX side needs, in order:

1. **An AMI user for the POS.** FreePBX admin, Settings, Asterisk Manager Users, Add Manager: name `pos`, a
   long random secret, Deny `0.0.0.0/0.0.0.0`, Permit only the address the connector comes from (the tunnel
   subnet, or the POS cloud's fixed addresses). Read rights: `system, call, agent, user, dialplan, reporting,
   cdr`. Write rights: `call, originate, agent, reporting`. Submit, then Apply Config.
2. **A path to the manager port.** Port 5038 must not be open to the internet. Preferred: a WireGuard tunnel
   between the PBX and the POS cloud, the same VPN the remote units use. Alternative: the FreePBX firewall
   permits only the POS cloud's fixed addresses, on the TLS manager port (5039). Fallback if the host cannot
   run a tunnel: the connector runs on the PBX host itself, talks to the manager interface on localhost and
   calls out to the POS cloud over HTTPS, so nothing inbound is opened at all.
3. **A test extension** the POS may use (a PJSIP extension with a softphone registered), so click-to-call
   and queue pause can be exercised without touching a live phone.
4. **Facts to map numbers to locations:** the FreePBX version, the inbound routes (which dialed number belongs
   to which location), and the queue numbers per location.
5. **Who owns the host.** Answered 2026-10-25: Mike's own Vultr server, so no terms are needed, only the
   setup above.

**Fastest live check, no ports opened.** `ami.py` is one file with no dependencies beyond the standard
library (Python 3.11 or newer; FreePBX 17 on Debian 12 ships it, FreePBX 16 on SNG7 does not, so run it from a
laptop there). Copy it to the server, create the AMI user permitted
from `127.0.0.1` only, and run the probe against `--host 127.0.0.1`. That proves the user, the rights and the
events; the tunnel or allow-list comes after, when the connector moves off the box.

Update, later 2026-10-26: Mike rebuilt the PBX as FreePBX 17 on Debian 12 (Asterisk 22.11.0, manager
interface 11.0.0) and restored it from backup; the AMI user, trunks and extensions survived. The probe now
runs on the PBX host itself (`python3 /root/ami.py --host 127.0.0.1 --user pos probe`, Python 3.11 on
board) and the live call test passed again, same context `from-pstn-e164-us`. Plan for phase 3: the
connector runs on the PBX host and calls out to the cloud over HTTPS, so nothing inbound is opened.

Result (2026-10-26): passed. Own server, no terms needed. The AMI user `pos` exists, the probe ran from hub 1
through an SSH tunnel to the PBX (`ssh -fN -L 5038:127.0.0.1:5038 root@<pbx>`, then `--host 127.0.0.1`) and
`tail` printed a live inbound call from the Twilio trunk: context `from-pstn-e164-us`, dialed `+1781729xxxx`,
caller id present, location `Main` resolved. Facts learned: Asterisk 18.20.2, FreePBX 16 on SNG7 (Python 3.6,
so the probe runs off-box), trunks `Twilio-US1-North-America-Oregon` and `-Virginia`, PJSIP extensions
200-210, one queue `default`. Still to collect before phase 3: the other locations' numbers and the queue per
location, plus a test extension. The permanent path (WireGuard instead of the SSH tunnel) is phase 3 work.
