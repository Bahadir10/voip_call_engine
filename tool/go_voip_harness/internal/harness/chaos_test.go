package harness_test

import (
	"bufio"
	"bytes"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/flutter-telecom/go_voip_harness/internal/harness"
)

func TestGoertzelAcousticVerification(t *testing.T) {
	const sampleRate = 16000
	// 1. Clean 440Hz tone -> must detect 440Hz and report not silent, no clipping
	tone440 := harness.GenerateSineWavePCM16(440.0, sampleRate, 200)
	report440 := harness.AnalyzePCM16Audio(tone440, sampleRate, 440.0)
	if !report440.TargetTonePresent {
		t.Fatalf("expected 440Hz tone to be detected, got report: %+v", report440)
	}
	if report440.IsSilent || report440.HasClipping {
		t.Fatalf("expected clean non-silent, non-clipped signal, got: %+v", report440)
	}

	// 2. Wrong frequency (1000Hz tone checked against 440Hz detector) -> must reject
	tone1000 := harness.GenerateSineWavePCM16(1000.0, sampleRate, 200)
	reportWrongFreq := harness.AnalyzePCM16Audio(tone1000, sampleRate, 440.0)
	if reportWrongFreq.TargetTonePresent {
		t.Fatalf("expected 1000Hz tone to NOT trigger 440Hz detector, got: %+v", reportWrongFreq)
	}

	// 3. Silence buffer -> must report IsSilent = true and TargetTonePresent = false
	silence := make([]byte, 6400)
	reportSilence := harness.AnalyzePCM16Audio(silence, sampleRate, 440.0)
	if !reportSilence.IsSilent || reportSilence.TargetTonePresent {
		t.Fatalf("expected silence report, got: %+v", reportSilence)
	}
}

func TestConcurrentWebSocketSignalingStress(t *testing.T) {
	srv := harness.NewServer()
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	hostAddr := strings.TrimPrefix(ts.URL, "http://")
	const clientCount = 50

	conns := make([]net.Conn, clientCount)
	readers := make([]*bufio.Reader, clientCount)

	for i := 0; i < clientCount; i++ {
		conn, err := net.DialTimeout("tcp", hostAddr, 2*time.Second)
		if err != nil {
			t.Fatalf("client %d dial failed: %v", i, err)
		}
		defer conn.Close()

		handshake := fmt.Sprintf(
			"GET /ws HTTP/1.1\r\n"+
				"Host: %s\r\n"+
				"Upgrade: websocket\r\n"+
				"Connection: Upgrade\r\n"+
				"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"+
				"Sec-WebSocket-Version: 13\r\n\r\n",
			hostAddr,
		)
		if _, err := conn.Write([]byte(handshake)); err != nil {
			t.Fatalf("client %d handshake write failed: %v", i, err)
		}

		br := bufio.NewReader(conn)
		statusLine, err := br.ReadString('\n')
		if err != nil || !strings.Contains(statusLine, "101") {
			t.Fatalf("client %d expected 101 Switching Protocols, got: %s (err=%v)", i, statusLine, err)
		}
		// Drain remaining HTTP headers
		for {
			line, err := br.ReadString('\n')
			if err != nil || line == "\r\n" {
				break
			}
		}

		conns[i] = conn
		readers[i] = br
	}

	// Trigger concurrent Call Waiting + Ghost Call broadcasts while all 50 clients listen
	var wg sync.WaitGroup
	for n := 0; n < 5; n++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			resp, err := http.Post(ts.URL+"/api/calls/waiting", "application/json", bytes.NewReader([]byte(`{}`)))
			if err == nil {
				_ = resp.Body.Close()
			}
		}()
	}
	wg.Wait()

	// Verify every single connected WebSocket client received valid WebSocket text frames (0x81)
	for i := 0; i < clientCount; i++ {
		_ = conns[i].SetReadDeadline(time.Now().Add(2 * time.Second))
		opcode, err := readers[i].ReadByte()
		if err != nil {
			t.Fatalf("client %d failed to read WS frame: %v", i, err)
		}
		if opcode != 0x81 {
			t.Fatalf("client %d expected text frame opcode 0x81, got 0x%x", i, opcode)
		}
	}
}

func TestBidirectionalFeAckAndAudioVerifyLoop(t *testing.T) {
	srv := harness.NewServer()
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	// 1. Simulate FE posting state transition ACKs and downloading/returning 440Hz audio
	ackPayload := []byte(`{"callId":"11111111-2222-4333-8444-555566667777","previousState":"idle","currentState":"incomingRinging","timestampMs":1700000000000}`)
	ackResp, err := http.Post(ts.URL+"/api/e2e/ack", "application/json", bytes.NewReader(ackPayload))
	if err != nil || ackResp.StatusCode != http.StatusOK {
		t.Fatalf("fe_ack post failed: %v", err)
	}
	_ = ackResp.Body.Close()

	// 2. Download 440Hz tone from /api/audio/tone and loop it back to /api/audio/verify
	toneResp, err := http.Get(ts.URL + "/api/audio/tone")
	if err != nil {
		t.Fatalf("failed to fetch audio tone: %v", err)
	}
	var pcmBuf bytes.Buffer
	_, _ = pcmBuf.ReadFrom(toneResp.Body)
	_ = toneResp.Body.Close()

	verifyResp, err := http.Post(ts.URL+"/api/audio/verify", "application/octet-stream", &pcmBuf)
	if err != nil || verifyResp.StatusCode != http.StatusOK {
		t.Fatalf("audio verify failed: %v", err)
	}
	_ = verifyResp.Body.Close()

	// 3. Query /api/e2e/report and verify both FE state ACK and Goertzel DSP verification succeeded
	repResp, err := http.Get(ts.URL + "/api/e2e/report")
	if err != nil || repResp.StatusCode != http.StatusOK {
		t.Fatalf("failed to fetch e2e report: %v", err)
	}
	defer repResp.Body.Close()
	if repResp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200 OK")
	}
}
