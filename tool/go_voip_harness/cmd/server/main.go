package main

import (
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"

	"github.com/flutter-telecom/go_voip_harness/internal/harness"
)

func main() {
	addr := flag.String("addr", "127.0.0.1:8090", "HTTP and WebSocket listen address (use 127.0.0.1:0 for dynamic port)")
	flag.Parse()

	ln, err := net.Listen("tcp", *addr)
	if err != nil {
		log.Fatalf("listen error: %v", err)
	}
	actualAddr := ln.Addr().String()

	srv := harness.NewServer()
	fmt.Fprintf(os.Stdout, "HARNESS_LISTENING=http://%s\n", actualAddr)
	_ = os.Stdout.Sync()

	log.Printf("[go_voip_harness] Listening on http://%s (WS: ws://%s/ws)", actualAddr, actualAddr)
	if err := http.Serve(ln, srv.Handler()); err != nil {
		log.Fatalf("server error: %v", err)
	}
}
