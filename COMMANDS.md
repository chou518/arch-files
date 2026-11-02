MICROPHONE GAIN:
    pactl set-source-volume alsa_input.usb-Corsair_CORSAIR_VOID_ELITE_Wireless_Gaming_Dongle-00.mono-fallback +15dB
    (If this doesn't work, use "Find Source Name" command below and alter pactl command accordingly.)
    
FIND SOURCE NAME:
    pactl list short sources
