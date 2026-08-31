#!/bin/sh
# GoshaCrash BT10 diagnostics
# Non-destructive diagnostic script for ASUSWRT + Download Master.
# Does not install/remove packages and does not change NVRAM.

OUT="/tmp/gcdiag-bt10.out"
DM="/tmp/mnt/SANDISK/asusware.arm"
BASE="/tmp/mnt/SANDISK/goshacrash"
IPKG="$DM/bin/ipkg"
T=".gcdiag-$$"

section() {
    echo
    echo "============================================================"
    echo "$1"
    echo "============================================================"
}

resolve_path() {
    P="$1"
    if /bin/busybox readlink -f "$P" >/dev/null 2>&1; then
        /bin/busybox readlink -f "$P" 2>/dev/null
    else
        echo "UNRESOLVED"
    fi
}

pkg_check() {
    P="$1"
    LIST="/opt/lib/ipkg/info/$P.list"

    echo
    echo "--- $P ---"

    if test ! -f "$LIST"; then
        echo "PACKAGE_LIST_MISSING: $LIST"
        return
    fi

    TOTAL=0
    MISSING=0

    while IFS= read -r F; do
        test -n "$F" || continue
        TOTAL=$((TOTAL + 1))

        if test ! -e "$F" && test ! -L "$F"; then
            echo "MISSING: $F"
            MISSING=$((MISSING + 1))
        fi
    done < "$LIST"

    echo "TOTAL=$TOTAL MISSING=$MISSING"
}

run_diag() {
    section "0. SYSTEM"

    date 2>&1
    uname -a 2>&1
    uname -m 2>&1

    echo
    echo "productid=$(nvram get productid 2>/dev/null)"
    echo "PATH=$PATH"
    echo "HOME=${HOME:-}"
    echo "SHELL=${SHELL:-}"
    echo "TERM=${TERM:-}"
    echo "TERMINFO=${TERMINFO:-}"
    echo "TERMINFO_DIRS=${TERMINFO_DIRS:-}"
    echo "TERMCAP=${TERMCAP:-}"
    echo "LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-}"

    section "1. USB / MOUNTS"

    mount 2>&1

    echo
    echo "--- relevant mounts ---"
    mount 2>&1 | grep -E ' on / |/opt|/tmp/opt|/tmp/mnt/SANDISK|/jffs|/dev/sd' || true

    echo
    echo "--- df ---"
    df -h /opt /tmp/opt "$DM" /jffs 2>&1

    section "2. /opt ROOT"

    ls -ld /opt /tmp/opt "$DM" 2>&1

    echo
    echo "--- /opt directory contents ---"
    ls -la /opt 2>&1

    echo
    echo "--- links / resolved paths ---"
    echo -n "/opt raw link: "
    /bin/busybox readlink /opt 2>/dev/null || echo "NOT_SYMLINK"

    echo -n "/tmp/opt raw link: "
    /bin/busybox readlink /tmp/opt 2>/dev/null || echo "NOT_SYMLINK"

    echo "/opt => $(resolve_path /opt)"
    echo "/tmp/opt => $(resolve_path /tmp/opt)"
    echo "$DM => $(resolve_path "$DM")"

    echo
    echo "--- root filesystem flags ---"
    mount 2>&1 | grep ' on / ' || true

    echo
    echo "--- can root /opt itself be modified? ---"
    if ( : > "/opt/$T" ) 2>/dev/null; then
        echo "/opt file creation: OK"
        rm -f "/opt/$T" 2>/dev/null
    else
        echo "/opt file creation: READ_ONLY_OR_NOT_WRITABLE"
    fi

    if ( mkdir "/opt/$T.dir" ) 2>/dev/null; then
        echo "/opt directory creation: OK"
        rmdir "/opt/$T.dir" 2>/dev/null
    else
        echo "/opt directory creation: READ_ONLY_OR_NOT_WRITABLE"
    fi

    if ( ln -s /tmp/opt "/opt/$T.link" ) 2>/dev/null; then
        echo "/opt symlink creation: OK"
        rm -f "/opt/$T.link" 2>/dev/null
    else
        echo "/opt symlink creation: READ_ONLY_OR_NOT_WRITABLE"
    fi

    section "3. COMPLETE /opt MAP"

    for D in bin sbin lib libexec share etc usr var tmp include man; do
        echo
        echo "--- $D ---"
        ls -ld "/opt/$D" "/tmp/opt/$D" "$DM/$D" 2>&1
        echo "/opt/$D => $(resolve_path "/opt/$D")"
    done

    section "4. WRITE-THROUGH TEST FOR EXISTING /opt SUBDIRS"

    for D in bin sbin lib libexec share etc; do
        if test ! -d "/opt/$D"; then
            echo "$D : OPT_DIR_MISSING"
            continue
        fi

        if test ! -d "$DM/$D"; then
            echo "$D : USB_DIR_MISSING"
            continue
        fi

        rm -f "/opt/$D/$T" "$DM/$D/$T" 2>/dev/null

        if ( : > "/opt/$D/$T" ) 2>/dev/null; then
            if test -e "$DM/$D/$T"; then
                echo "$D : USB_OK"
            else
                echo "$D : WRITE_NOT_ON_USB"
            fi
        else
            echo "$D : NOT_WRITABLE"
        fi

        rm -f "/opt/$D/$T" "$DM/$D/$T" 2>/dev/null
    done

    section "5. WHO BUILDS /opt"

    echo "--- references in firmware scripts ---"
    for D in /rom/scripts /rom/etc /etc /jffs/scripts; do
        test -d "$D" || continue
        echo
        echo "### $D"
        grep -R -E '/tmp/opt|/opt/(bin|sbin|lib|libexec|share|etc)|ln .*opt' "$D" 2>/dev/null | /bin/busybox head -n 120
    done

    echo
    echo "--- Download Master init scripts ---"
    ls -la "$DM/etc/init.d" 2>&1

    echo
    echo "--- /opt references in DM init scripts ---"
    grep -R -E '/tmp/opt|/opt/|libexec' "$DM/etc/init.d" 2>/dev/null | /bin/busybox head -n 160

    section "6. DOWNLOAD MASTER / IPKG"

    ls -l "$IPKG" /opt/bin/ipkg /tmp/opt/bin/ipkg 2>&1

    echo
    echo "--- ipkg version ---"
    "$IPKG" --version 2>&1

    echo
    echo "--- ipkg config ---"
    cat /opt/etc/ipkg.conf 2>/dev/null

    for F in /opt/etc/ipkg/*.conf; do
        test -f "$F" || continue
        echo
        echo "--- $F ---"
        cat "$F"
    done

    echo
    echo "--- selected installed packages ---"
    "$IPKG" list_installed 2>/dev/null | grep -E '^(nano|ncurses|ncurses-base|ncursesw|openssh-sftp-server|openssh|unzip|readline|uclibc-opt|libstdc)' || true

    section "7. PACKAGE DATABASE / PHYSICAL CONSISTENCY"

    pkg_check nano
    pkg_check ncurses
    pkg_check ncurses-base
    pkg_check ncursesw
    pkg_check openssh-sftp-server
    pkg_check unzip

    section "8. SFTP"

    echo "--- package file list ---"
    cat /opt/lib/ipkg/info/openssh-sftp-server.list 2>/dev/null

    echo
    echo "--- package control ---"
    cat /opt/lib/ipkg/info/openssh-sftp-server.control 2>/dev/null

    for X in preinst postinst prerm postrm; do
        F="/opt/lib/ipkg/info/openssh-sftp-server.$X"
        if test -f "$F"; then
            echo
            echo "--- $F ---"
            cat "$F"
        fi
    done

    echo
    echo "--- libexec state ---"
    ls -ld /opt/libexec /tmp/opt/libexec "$DM/libexec" 2>&1

    echo
    echo "--- real sftp-server search ---"
    /bin/busybox find /opt /tmp/opt "$DM" -name 'sftp-server' -print 2>/dev/null

    echo
    echo "--- package feed stanza ---"
    for F in /opt/lib/ipkg/lists/*; do
        test -f "$F" || continue
        sed -n '/^Package: openssh-sftp-server$/,/^$/p' "$F" 2>/dev/null
    done

    section "9. NANO / NCURSES / TERMINFO"

    echo "--- nano ---"
    command -v nano 2>&1
    ls -l /opt/bin/nano "$DM/bin/nano" 2>&1
    /opt/bin/nano --version 2>&1

    echo
    echo "--- environment ---"
    echo "TERM=${TERM:-}"
    echo "TERMINFO=${TERMINFO:-}"
    echo "TERMINFO_DIRS=${TERMINFO_DIRS:-}"
    echo "TERMCAP=${TERMCAP:-}"

    echo
    echo "--- all terminfo paths under Optware ---"
    /bin/busybox find /opt /tmp/opt "$DM" -path '*terminfo*' -print 2>/dev/null | /bin/busybox head -n 120

    echo
    echo "--- common terminal descriptions under Optware ---"
    /bin/busybox find /opt /tmp/opt "$DM" \
        \( -name 'xterm' -o -name 'xterm-256color' -o -name 'vt100' -o -name 'linux' -o -name 'ansi' -o -name 'dumb' \) \
        -print 2>/dev/null | /bin/busybox head -n 120

    echo
    echo "--- available terminfo/ncurses packages ---"
    "$IPKG" list 2>/dev/null | grep -Ei 'terminfo|termcap|ncurses' || true

    echo
    echo "--- ncurses lists ---"
    for F in \
        /opt/lib/ipkg/info/ncurses.list \
        /opt/lib/ipkg/info/ncurses-base.list \
        /opt/lib/ipkg/info/ncursesw.list
    do
        echo
        echo "--- $F ---"
        cat "$F" 2>/dev/null
    done

    echo
    echo "--- tput TERM tests ---"
    for TERMTEST in "${TERM:-xterm-256color}" xterm-256color xterm vt100 linux ansi dumb; do
        echo
        echo "TERM=$TERMTEST"
        TERM="$TERMTEST" /opt/bin/tput cols 2>&1
        echo "rc=$?"
    done

    section "10. GC / PATH"

    echo "PATH=$PATH"

    echo
    echo "--- command resolution before hash reset ---"
    command -v gc 2>&1
    type gc 2>&1

    echo
    echo "--- gc files ---"
    ls -l \
        /jffs/scripts/gc \
        /opt/bin/gc \
        /tmp/opt/bin/gc \
        "$DM/bin/gc" \
        2>&1

    echo
    echo "--- resolved gc paths ---"
    for F in /jffs/scripts/gc /opt/bin/gc /tmp/opt/bin/gc "$DM/bin/gc"; do
        if test -e "$F" || test -L "$F"; then
            echo "$F => $(resolve_path "$F")"
        fi
    done

    echo
    echo "--- command resolution after hash reset ---"
    hash -r 2>/dev/null || true
    command -v gc 2>&1
    type gc 2>&1

    echo
    echo "--- wrapper contents ---"
    echo "### /jffs/scripts/gc"
    cat /jffs/scripts/gc 2>/dev/null

    echo
    echo "### $DM/bin/gc"
    cat "$DM/bin/gc" 2>/dev/null

    echo
    echo "--- direct execution ---"
    /jffs/scripts/gc version 2>&1
    /opt/bin/gc version 2>&1
    /jffs/scripts/gc status 2>&1
    /opt/bin/gc status 2>&1

    section "11. SHELL RESOLUTION"

    echo "command -v sh: $(command -v sh 2>/dev/null)"
    ls -l /bin/sh /usr/bin/sh /opt/bin/sh /tmp/opt/bin/sh "$DM/bin/sh" 2>&1

    echo
    echo "--- /bin/sh sanity ---"
    /bin/sh -c 'echo SYSTEM_BIN_SH_OK' 2>&1

    echo
    echo "--- bare sh sanity ---"
    sh -c 'echo BARE_SH_OK' 2>&1

    section "12. JFFS / PROFILE"

    mount 2>&1 | grep '/jffs' || true

    if ( : > "/jffs/$T" ) 2>/dev/null; then
        echo "JFFS_WRITE_OK"
        rm -f "/jffs/$T" 2>/dev/null
    else
        echo "JFFS_NOT_WRITABLE"
    fi

    echo
    echo "--- /jffs/scripts ---"
    ls -la /jffs/scripts 2>&1

    echo
    echo "--- /jffs/addons/goshacrash ---"
    ls -la /jffs/addons/goshacrash 2>&1

    echo
    echo "--- /etc/profile ---"
    cat /etc/profile 2>/dev/null

    echo
    echo "--- /jffs/configs/profile.add ---"
    cat /jffs/configs/profile.add 2>/dev/null

    section "13. AUTOSTART / NVRAM"

    for K in \
        jffs2_scripts \
        script_usbmount \
        script_usbumount \
        apps_mounted_path \
        apps_install_folder \
        apps_dev \
        apps_state_install \
        apps_state_switch \
        apps_state_stop \
        apps_state_autorun
    do
        echo "$K=$(nvram get "$K" 2>/dev/null)"
    done

    echo
    echo "--- base pointer ---"
    cat /jffs/addons/goshacrash/base 2>/dev/null

    echo
    echo "--- start.sh ---"
    cat /jffs/addons/goshacrash/start.sh 2>/dev/null

    echo
    echo "--- usb-mount-script ---"
    cat /jffs/scripts/usb-mount-script 2>/dev/null

    echo
    echo "--- DM bridge ---"
    cat "$DM/etc/init.d/S50usb-mount-script" 2>/dev/null

    section "14. PROCESSES / LOGS"

    echo "--- DM processes ---"
    ps 2>&1 | grep -Ei 'download|dm2|asusware|lighttpd|optware|ipkg' | grep -v grep || true

    echo
    echo "--- GoshaCrash processes ---"
    ps 2>&1 | grep -Ei 'mihomo|goshacrash' | grep -v grep || true

    echo
    echo "--- GoshaCrash tree ---"
    ls -la "$BASE" 2>&1
    ls -la "$BASE/bin" "$BASE/run" "$BASE/state" "$BASE/logs" 2>&1

    echo
    echo "--- packages.log tail ---"
    tail -n 220 "$BASE/logs/packages.log" 2>/dev/null

    echo
    echo "--- package-related errors ---"
    grep -Ei 'sftp|libexec|nano|ncurses|terminfo|error|fail|cannot|no such|read-only' \
        "$BASE/logs/packages.log" 2>/dev/null | tail -n 220

    echo
    echo "--- mihomo.log tail ---"
    tail -n 180 "$BASE/logs/mihomo.log" 2>/dev/null

    section "15. TUN / ROUTING / IPTABLES"

    ls -l /dev/net/tun 2>&1
    lsmod 2>&1 | grep '^tun' || true
    ip link show tun0 2>&1

    echo
    echo "--- ip rule ---"
    ip rule 2>&1

    echo
    echo "--- table 2022 ---"
    ip route show table 2022 2>&1

    echo
    echo "--- route 1.1.1.1 ---"
    ip route get 1.1.1.1 2>&1

    echo
    echo "--- iptables version ---"
    /usr/sbin/iptables --version 2>&1

    echo
    echo "--- NAT mihomo ---"
    /usr/sbin/iptables -t nat -S 2>/dev/null | grep mihomo || echo "NO_MIHOMO_NAT"

    echo
    echo "--- MANGLE mihomo ---"
    /usr/sbin/iptables -t mangle -S 2>/dev/null | grep mihomo || echo "NO_MIHOMO_MANGLE"

    section "16. FINAL SUMMARY"

    echo "/opt => $(resolve_path /opt)"
    echo "/tmp/opt => $(resolve_path /tmp/opt)"
    echo "/opt/libexec => $(resolve_path /opt/libexec)"
    echo "gc=$(command -v gc 2>/dev/null)"
    echo "nano=$(command -v nano 2>/dev/null)"

    echo
    echo "sftp-server:"
    /bin/busybox find /opt /tmp/opt "$DM" -name sftp-server -print 2>/dev/null

    echo
    echo "terminfo:"
    /bin/busybox find /opt /tmp/opt "$DM" -path '*terminfo*' -print 2>/dev/null | /bin/busybox head -n 20

    echo
    echo "DONE"
}

echo "Collecting diagnostics..."
run_diag > "$OUT" 2>&1
RC=$?

echo
echo "========== REPORT =========="
cat "$OUT" 2>/dev/null

echo
echo "Full report saved to: $OUT"
echo "Diagnostic exit code: $RC"
exit "$RC"
