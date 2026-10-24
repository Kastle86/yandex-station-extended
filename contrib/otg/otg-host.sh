#!/bin/sh
# Switch the Type-C port (USB2 PHY port 1) from dwc2 device mode to xHCI host mode,
# then load USB peripheral drivers built for this kernel. Runtime only: removing
# /etc/init.d/S97otg-host (or touch /data/otg/disable) and rebooting restores device mode.
MOD=/data/otg/modules
reg(){ for a in 0xffe09020 0xffe09080 0xffe09084 0xffe09090; do echo "$a $(devmem $a 32)"; done; }

# Drivers first, so devices bind as soon as the hub enumerates.
for m in sd_mod usb-storage uas \
         mii usbnet cdc_ether cdc_ncm r8152 ax88179_178a asix \
         snd-hwdep snd-rawmidi snd-usbmidi-lib snd-usb-audio; do
	[ -f $MOD/$m.ko ] && { insmod $MOD/$m.ko 2>/dev/null && echo "insmod $m"; }
done

echo "== before"; reg
if [ $(( $(devmem 0xffe09080 32) & 0x80000000 )) -eq 0 ]; then echo "already host"; exit 0; fi
[ -e /sys/bus/platform/drivers/dwc_otg/ff400000.dwc2_a ] && echo ff400000.dwc2_a > /sys/bus/platform/drivers/dwc_otg/unbind
[ -e /sys/bus/platform/drivers/xhci-hcd/xhci-hcd.0.auto ] && echo xhci-hcd.0.auto > /sys/bus/platform/drivers/xhci-hcd/unbind
sleep 1
devmem 0xffe09084 32 $(( $(devmem 0xffe09084 32) & ~0x0000F000 ))  # usb_r1.u3h_host_u2_port_disable = 0
devmem 0xffe09080 32 $(( $(devmem 0xffe09080 32) & ~0x80000000 ))  # usb_r0.u2d_act = 0 (port -> xHCI)
devmem 0xffe09090 32 $(( $(devmem 0xffe09090 32) & ~0x00000002 ))  # usb_r4.p21_SLEEPM0 = 0
devmem 0xffe09020 32 $(( $(devmem 0xffe09020 32) | 0x00000060 ))   # u2p_r0.dm/dppulldown = 1 (host)
echo "== after"; reg
sleep 1
echo xhci-hcd.0.auto > /sys/bus/platform/drivers/xhci-hcd/bind
echo "xhci bind rc=$?"
