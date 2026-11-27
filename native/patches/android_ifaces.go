// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

//go:build android

// Overlaid into upstream's cmd/libtailcat for Android builds.
//
// Android denies apps the netlink socket net.Interfaces uses (golang/go#40569),
// so netmon has no interfaces. Since tailcat v0.8.0 that no longer crashes,
// but without local addresses peers stay relayed instead of going direct.
// feature/androidbin's fallback skips cgo builds, so this registers the same
// synthetic interface. Remove once upstream does.
package main

import (
	"errors"
	"net"
	"net/netip"
	"time"

	"tailscale.com/net/netmon"
)

func init() {
	netmon.RegisterInterfaceGetter(syntheticInterfaces)
}

// syntheticInterfaces returns one interface with the outbound source addresses.
func syntheticInterfaces() ([]netmon.Interface, error) {
	var addrs []net.Addr
	// Dialing UDP sends nothing; it only makes the kernel pick a source address.
	if ip, ok := outboundIP("udp4", "8.8.8.8:53"); ok {
		addrs = append(addrs, &net.IPNet{IP: ip.AsSlice(), Mask: net.CIDRMask(32, 32)})
	}
	if ip, ok := outboundIP("udp6", "[2001:4860:4860::8888]:53"); ok {
		addrs = append(addrs, &net.IPNet{IP: ip.AsSlice(), Mask: net.CIDRMask(128, 128)})
	}
	if len(addrs) == 0 {
		return nil, errors.New("libtailcat: no outbound routes found")
	}
	return []netmon.Interface{{
		Interface: &net.Interface{
			MTU:   1500,
			Name:  "android",
			Flags: net.FlagUp | net.FlagRunning,
		},
		AltAddrs: addrs,
	}}, nil
}

func outboundIP(network, addr string) (netip.Addr, bool) {
	d := net.Dialer{Timeout: 2 * time.Second}
	c, err := d.Dial(network, addr)
	if err != nil {
		return netip.Addr{}, false
	}
	defer c.Close()
	ua, ok := c.LocalAddr().(*net.UDPAddr)
	if !ok {
		return netip.Addr{}, false
	}
	ip, ok := netip.AddrFromSlice(ua.IP)
	if !ok {
		return netip.Addr{}, false
	}
	ip = ip.Unmap()
	if ip.IsLoopback() || ip.IsUnspecified() {
		return netip.Addr{}, false
	}
	return ip, true
}
