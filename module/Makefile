obj-m := usb_f_hid.o u_audio.o usb_f_uac2.o usb_f_uvc.o
usb_f_hid-y  := f_hid.o
# u_audio needs no <name>-y line - module name already matches the object
# name, and Kbuild flags an explicit "u_audio-y := u_audio.o" as a circular
# self-dependency.
usb_f_uac2-y := f_uac2.o
# uvc_trace.o intentionally omitted: CONFIG_TRACING is unset on this kernel
# (checked /boot/config-$(uname -r) - only the unrelated
# CONFIG_TRACING_SUPPORT=y is set), so the trace_uvcg_*() calls in
# uvc_video.c expand to no-op inline stubs with no external symbol
# reference. If a future kernel here has CONFIG_TRACING=y, add uvc_trace.o
# to this list and copy uvc_trace.c alongside the already-present
# uvc_trace.h, or the module link will fail on undefined __tracepoint_uvcg_*.
usb_f_uvc-y  := f_uvc.o uvc_queue.o uvc_v4l2.o uvc_video.o uvc_configfs.o

KDIR ?= /lib/modules/$(shell uname -r)/build
PWD  := $(shell pwd)

default:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
