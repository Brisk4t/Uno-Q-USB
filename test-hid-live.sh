#!/bin/bash
# Live test of the REAL hid.usb0 function on the running gadget g1, before
# wiring it into adbd.service's boot sequence via 10-hid.conf. Same
# unbind/link/rebind pattern validated with the acm.GS1 prototype.
#
# Requires usb_f_hid.ko already loaded (this script modprobes it).
#
# RUN OVER WI-FI SSH (192.168.1.71) OR THE SERIAL CONSOLE, NOT OVER ADB.

set -u

G=/sys/kernel/config/usb_gadget/g1
UDC_NAME=4e00000.usb
FUNC=hid.usb0
FUNC_DIR=${G}/functions/${FUNC}
CONF_DIR=${G}/configs/c.1

HID_PROTOCOL=1
HID_SUBCLASS=1
HID_REPORT_LENGTH=8

# Standard boot keyboard report descriptor, one item per line as "HEX  #
# item" - see arduino-hid-gadget for the byte-by-byte mnemonics.
HID_REPORT_DESC_TABLE='
05 01
09 06
a1 01
05 07
19 e0
29 e7
15 00
25 01
75 01
95 08
81 02
95 01
75 08
81 03
95 05
75 01
05 08
19 01
29 05
91 02
95 01
75 03
91 03
95 06
75 08
15 00
25 65
05 07
19 00
29 65
81 00
c0
'

hid_report_desc() {
    fmt=""
    for hex in $(printf '%s\n' "${HID_REPORT_DESC_TABLE}" | sed 's/#.*//'); do
        fmt="${fmt}\\$(printf '%03o' "0x${hex}")"
    done
    printf '%b' "${fmt}"
}

log() { echo "[$(date +%H:%M:%S)] $*"; }

rebind() {
    if [ -z "$(cat ${G}/UDC 2>/dev/null)" ]; then
        log "rebinding UDC ${UDC_NAME}"
        echo "${UDC_NAME}" > ${G}/UDC 2>/dev/null
        i=0
        while [ $i -lt 10 ]; do
            st="$(cat /sys/class/udc/${UDC_NAME}/state 2>/dev/null)"
            [ "$st" = "configured" ] && { log "rebind OK (state: $st)"; return 0; }
            i=$((i+1))
            sleep 1
        done
        log "!! REBIND DID NOT REACH 'configured' (last state: '$st') - check manually, reboot to recover"
    fi
}
trap rebind EXIT

show_state() {
    log "UDC     : '$(cat ${G}/UDC)'"
    log "state   : $(cat /sys/class/udc/${UDC_NAME}/state 2>/dev/null)"
    log "linked  : $(ls ${CONF_DIR}/ | tr '\n' ' ')"
    log "hidg*   : $(ls /dev/hidg* 2>/dev/null | tr '\n' ' ')"
}

add() {
    log "=== BEFORE ==="; show_state

    log "loading usb_f_hid"
    modprobe usb_f_hid || { log "!! modprobe failed - is the module installed? see README"; exit 1; }

    log "unbinding UDC (adb WILL drop here)"
    echo "" > ${G}/UDC

    log "creating functions/${FUNC}"
    mkdir -p ${FUNC_DIR}
    echo "${HID_PROTOCOL}"      > ${FUNC_DIR}/protocol
    echo "${HID_SUBCLASS}"      > ${FUNC_DIR}/subclass
    echo "${HID_REPORT_LENGTH}" > ${FUNC_DIR}/report_length
    hid_report_desc > ${FUNC_DIR}/report_desc

    log "linking ${FUNC} into configs/c.1"
    i=0
    until ( cd ${G} && ln -s functions/${FUNC} configs/c.1/ ) 2>/tmp/ln.err
    do
        i=$((i+1))
        if [ $i -ge 10 ]; then
            log "!! LINK FAILED after retries:"; cat /tmp/ln.err
            break
        fi
        sleep 1
    done
    rm -f /tmp/ln.err

    rebind

    log "=== AFTER ==="; show_state
    log "host check:  lsusb -v -d 2341:0078 | grep -E 'bNumInterfaces|bInterfaceClass|iInterface'"
    log "then send a test keystroke:  $0 tap-a"
}

# Sends one boot-keyboard report for the letter 'a' (press then release).
# 8-byte report: [modifier, reserved, key1..key6]. 0x04 = HID usage 'a'.
tap_a() {
    [ -e /dev/hidg0 ] || { log "no /dev/hidg0 - run 'add' first"; exit 1; }
    log "sending 'a' keypress to /dev/hidg0"
    printf '\x00\x00\x04\x00\x00\x00\x00\x00' > /dev/hidg0
    sleep 0.05
    printf '\x00\x00\x00\x00\x00\x00\x00\x00' > /dev/hidg0
    log "sent - check the host for an 'a' wherever focus is (a text field is safest)"
}

revert() {
    log "=== REVERTING ==="
    echo "" > ${G}/UDC
    rm -f  ${CONF_DIR}/${FUNC}
    rmdir  ${FUNC_DIR} 2>/dev/null || true
    rebind
    show_state
}

case "${1:-}" in
    add)    add ;;
    tap-a)  trap - EXIT; tap_a ;;
    revert) revert ;;
    state)  trap - EXIT; show_state ;;
    *) echo "Usage: $0 [add|tap-a|revert|state]"; trap - EXIT; exit 1 ;;
esac
