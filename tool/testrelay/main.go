// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

// Command testrelay runs a DERP relay and STUN server on 127.0.0.1 for the
// tests. It prints {"region": <tailcfg.DERPRegion>} and serves until stdin
// closes. Built via -overlay inside the upstream checkout, so it uses
// upstream's pinned tailscale.com.
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http/httptest"
	"os"

	"tailscale.com/derp/derpserver"
	"tailscale.com/net/stun"
	"tailscale.com/tailcfg"
	"tailscale.com/types/key"
	"tailscale.com/types/logger"
)

func main() {
	relay := derpserver.New(key.NewNode(), logger.Discard)
	defer relay.Close()
	web := httptest.NewUnstartedServer(derpserver.Handler(relay))
	web.Config.ErrorLog = logger.StdLogger(logger.Discard)
	web.StartTLS()
	defer web.Close()

	udp, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	check(err)
	defer udp.Close()
	go serveSTUN(udp)

	region := &tailcfg.DERPRegion{
		RegionID:   1,
		RegionCode: "test",
		Nodes: []*tailcfg.DERPNode{{
			Name:     "test",
			RegionID: 1,
			HostName: "127.0.0.1",
			IPv4:     "127.0.0.1",
			IPv6:     "none",
			DERPPort: web.Listener.Addr().(*net.TCPAddr).Port,
			STUNPort: udp.LocalAddr().(*net.UDPAddr).Port,
			// The relay's certificate is self-signed.
			InsecureForTests: true,
			STUNTestIP:       "127.0.0.1",
		}},
	}
	check(json.NewEncoder(os.Stdout).Encode(map[string]any{"region": region}))
	io.Copy(io.Discard, os.Stdin)
}

func serveSTUN(conn *net.UDPConn) {
	buf := make([]byte, 65536)
	for {
		n, addr, err := conn.ReadFromUDPAddrPort(buf)
		if err != nil {
			return
		}
		if tx, err := stun.ParseBindingRequest(buf[:n]); err == nil {
			conn.WriteToUDPAddrPort(stun.Response(tx, addr), addr)
		}
	}
}

func check(err error) {
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
