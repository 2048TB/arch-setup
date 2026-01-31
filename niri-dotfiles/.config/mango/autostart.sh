#! /bin/bash

waybar & 

mako & 

/usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1 & 

swww-daemon &

fcitx5 & 

copyq &

dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP=wlroots

/usr/lib/xdg-desktop-portal-wlr &

hypridle &

clipse --listen &


