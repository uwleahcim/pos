# ADR 2: Two hubs per location and two cloud regions, all live

Date: 2026-10-25 · Status: accepted (Mike)

## Decision
Each location runs two hubs (primary and streaming standby, about five seconds to take over, a witness
vote from the cloud or a small on-site device). The cloud runs in a main and a backup region. Hubs and
cloud are each a complete system, both accept orders for a location at the same time, and terminals use
whichever they can reach in this order: primary hub, standby hub, main region, backup region. A location
may run with no hubs at all.

## Why
Screens need not work when both hubs and the cloud are down, but the system must keep selling when either
side is down, including with no internet. Hubs exist for speed, a closed network without NAT or firewall
tricks, and service without internet.

## Consequences
Printers are Ethernet devices the cloud cannot reach; with hubs down a terminal relays print jobs. Remote
units fall back to the cloud when the VPN or hubs are unreachable. Both sides must merge the same way,
which is why the order log (ADR 3) is one small, heavily tested package.
