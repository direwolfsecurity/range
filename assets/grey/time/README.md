# time

The range's clock. Grey cell, VLAN 110, proposed address 172.16.11.123.

Every log, ticket and scoring event on the range needs the same time, and the range is often
air-gapped (CLOSED mode), so time can't come from the internet. It comes from GPS satellites instead.

## The 5G Pi does double duty

| Job | How |
|---|---|
| **GPS source for NTP** | The 5G HAT's GNSS receiver feeds gpsd, gpsd feeds chrony, chrony serves NTP on UDP 123. No SIM needed. |
| **5G comms** | The same HAT is the range's cellular link. To be documented. |

## What's here

| Folder | What |
|---|---|
| `5g/ntp/` | **Current build.** Turns the Pi into the range NTP server, plus a satellite dashboard page. Start with `5g/ntp/README.md`. |
| `5g/html/`, `5g/systemd/` | Version 1 of the satellite dashboard, which read the GPS port directly. Replaced by `5g/ntp/`; kept for reference. |

## Hardware

- Raspberry Pi with a Waveshare RM520N-GL 5G HAT
- GNSS antenna with a view of the sky

## Test it

From any range machine: `chronyc sources` should list 172.16.11.123, or on Windows
`w32tm /stripchart /computer:172.16.11.123 /samples:3`.
