### MICROPHONE GAIN

```bash
pactl set-source-volume alsa_input.usb-Corsair_CORSAIR_VOID_ELITE_Wireless_Gaming_Dongle-00.mono-fallback +15dB

*(If this doesn't work, use the find source name command below and alter the pactl command accordingly.)*

### FIND SOURCE NAME
`pactl list short sources`
