package harness_test

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/flutter-telecom/go_voip_harness/internal/harness"
)

func TestBuildApnsVoipEnvelope(t *testing.T) {
	req := harness.ApnsVoipRequest{
		DeviceToken: "deadbeef1234",
		BundleID:    "com.acme.telecom",
		CallID:      "11111111-2222-4333-8444-555566667777",
		CallerName:  "Alice Yılmaz",
		HandleValue: "+905551112233",
		HandleType:  "phoneNumber",
		HasVideo:    true,
		IsCancelled: false,
	}

	env := harness.BuildApnsVoipEnvelope(req, true)
	if env.Headers["apns-push-type"] != "voip" {
		t.Fatalf("expected apns-push-type=voip, got %s", env.Headers["apns-push-type"])
	}
	if env.Headers["apns-priority"] != "10" {
		t.Fatalf("expected apns-priority=10, got %s", env.Headers["apns-priority"])
	}
	if env.Headers["apns-topic"] != "com.acme.telecom.voip" {
		t.Fatalf("expected apns-topic=com.acme.telecom.voip, got %s", env.Headers["apns-topic"])
	}
}

func TestGhostCallAndAudioToneEndpoints(t *testing.T) {
	srv := harness.NewServer()
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	// 1. Ghost Call scenario
	resp, err := http.Post(ts.URL+"/api/calls/ghost", "application/json", bytes.NewReader([]byte(`{}`)))
	if err != nil {
		t.Fatalf("ghost call request failed: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200 OK, got %d", resp.StatusCode)
	}

	var ghostResult map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&ghostResult); err != nil {
		t.Fatalf("decode error: %v", err)
	}
	if ghostResult["scenario"] != "ghost_call" {
		t.Fatalf("unexpected scenario: %v", ghostResult["scenario"])
	}

	// 2. 440Hz PCM16 Audio Tone endpoint
	toneResp, err := http.Get(ts.URL + "/api/audio/tone")
	if err != nil {
		t.Fatalf("tone request failed: %v", err)
	}
	defer toneResp.Body.Close()
	if toneResp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200 OK for tone, got %d", toneResp.StatusCode)
	}
	pcm := harness.GenerateSineWavePCM16(440.0, 16000, 200)
	if len(pcm) != 6400 { // 16000 * 0.2s * 2 bytes/sample = 6400 bytes
		t.Fatalf("expected 6400 bytes of PCM16 data, got %d", len(pcm))
	}
}
