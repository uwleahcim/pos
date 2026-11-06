"""Push relay: how the hub wakes a locked or sleeping screen (docs/push-relay.md).

- `apns`: the sender for Apple's push service (a VoIP push for the phone in the app, a notification for a
  desk-phone pick-up), with the key `hubctl push apple` puts on the hub.
- `devices`: the push tokens the screens register, by device name and extension.
- `relay`: what turns a PBX event into a push, and the mark on the PBX that makes its dial wait.
"""
