package harness

import (
	"bufio"
	"crypto/sha1"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"
)

const wsGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

// ApnsVoipRequest represents an Apple PushKit VoIP push request.
type ApnsVoipRequest struct {
	DeviceToken string `json:"deviceToken"`
	BundleID    string `json:"bundleId"`
	CallID      string `json:"callId"`
	CallerName  string `json:"callerName"`
	HandleValue string `json:"handleValue"`
	HandleType  string `json:"handleType"`
	HasVideo    bool   `json:"hasVideo"`
	IsCancelled bool   `json:"isCancelled"`
}

// ApnsEnvelope holds the prepared HTTP/2 headers and JSON body for an APNs VoIP push.
type ApnsEnvelope struct {
	Endpoint string            `json:"endpoint"`
	Headers  map[string]string `json:"headers"`
	Payload  map[string]any    `json:"payload"`
}

// FeStateAck represents a state transition acknowledgement sent from Flutter FE back to Go BE.
type FeStateAck struct {
	CallID        string `json:"callId"`
	PreviousState string `json:"previousState"`
	CurrentState  string `json:"currentState"`
	EndReason     string `json:"endReason,omitempty"`
	TimestampMs   int64  `json:"timestampMs"`
}

// BuildApnsVoipEnvelope constructs a compliant iOS 13+ PushKit HTTP/2 envelope.
func BuildApnsVoipEnvelope(req ApnsVoipRequest, sandbox bool) ApnsEnvelope {
	host := "https://api.push.apple.com"
	if sandbox {
		host = "https://api.sandbox.push.apple.com"
	}
	topic := req.BundleID
	if !strings.HasSuffix(topic, ".voip") {
		topic = topic + ".voip"
	}

	action := "incoming"
	if req.IsCancelled {
		action = "cancel"
	}

	return ApnsEnvelope{
		Endpoint: fmt.Sprintf("%s/3/device/%s", host, req.DeviceToken),
		Headers: map[string]string{
			"apns-push-type":  "voip",
			"apns-priority":   "10",
			"apns-expiration": "0",
			"apns-topic":      topic,
		},
		Payload: map[string]any{
			"voip": map[string]any{
				"callId":      req.CallID,
				"callerName":  req.CallerName,
				"handleValue": req.HandleValue,
				"handleType":  req.HandleType,
				"hasVideo":    req.HasVideo,
				"isCancelled": req.IsCancelled,
				"action":      action,
			},
		},
	}
}

// GenerateSineWavePCM16 generates a 16-bit little-endian mono PCM sine wave
// (e.g. 440Hz A4 reference tone) used to verify audio routing on Earpiece, Speaker, and Bluetooth.
func GenerateSineWavePCM16(freqHz float64, sampleRate int, durationMs int) []byte {
	totalSamples := (sampleRate * durationMs) / 1000
	buf := make([]byte, totalSamples*2)
	amplitude := 16000.0 // ~50% full scale to prevent clipping

	for i := 0; i < totalSamples; i++ {
		t := float64(i) / float64(sampleRate)
		sample := int16(amplitude * math.Sin(2.0*math.Pi*freqHz*t))
		binary.LittleEndian.PutUint16(buf[i*2:], uint16(sample))
	}
	return buf
}

// Server manages connected WebSocket clients, dispatches simulated VoIP scenarios,
// and records bidirectional FE state acknowledgements and acoustic DSP verifications.
type Server struct {
	mu              sync.Mutex
	clients         map[net.Conn]struct{}
	history         []map[string]any
	feAcks          []FeStateAck
	audioVerified   bool
	lastAudioReport *AudioAnalysisReport
}

func NewServer() *Server {
	return &Server{
		clients: make(map[net.Conn]struct{}),
		history: make([]map[string]any, 0, 64),
		feAcks:  make([]FeStateAck, 0, 64),
	}
}

func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", s.handleHealthz)
	mux.HandleFunc("/ws", s.handleWebSocket)
	mux.HandleFunc("/api/calls/incoming", s.handleTriggerIncoming)
	mux.HandleFunc("/api/calls/answer", s.handleTriggerAnswerCommand)
	mux.HandleFunc("/api/calls/ghost", s.handleTriggerGhostCall)
	mux.HandleFunc("/api/calls/waiting", s.handleTriggerCallWaiting)
	mux.HandleFunc("/api/push/apns-preview", s.handleApnsPreview)
	mux.HandleFunc("/api/audio/tone", s.handleAudioTone)
	mux.HandleFunc("/api/audio/verify", s.handleAudioVerify)
	mux.HandleFunc("/api/e2e/ack", s.handleFeAckHttp)
	mux.HandleFunc("/api/e2e/report", s.handleE2eReport)
	return mux
}

func (s *Server) BroadcastJSON(msg map[string]any) {
	data, err := json.Marshal(msg)
	if err != nil {
		return
	}
	frame := encodeWebSocketTextFrame(data)

	s.mu.Lock()
	s.history = append(s.history, msg)
	conns := make([]net.Conn, 0, len(s.clients))
	for c := range s.clients {
		conns = append(conns, c)
	}
	s.mu.Unlock()

	for _, c := range conns {
		_ = c.SetWriteDeadline(time.Now().Add(2 * time.Second))
		if _, err := c.Write(frame); err != nil {
			s.mu.Lock()
			delete(s.clients, c)
			s.mu.Unlock()
			_ = c.Close()
		}
	}
}

func (s *Server) handleHealthz(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"status":  "ok",
		"service": "go_voip_harness",
	})
}

func (s *Server) handleTriggerIncoming(w http.ResponseWriter, r *http.Request) {
	var body struct {
		CallID     string `json:"callId"`
		CallerName string `json:"callerName"`
		Handle     string `json:"handle"`
	}
	_ = json.NewDecoder(r.Body).Decode(&body)
	if body.CallID == "" {
		body.CallID = "11111111-2222-4333-8444-555566667777"
	}
	if body.CallerName == "" {
		body.CallerName = "Go Signaling Caller"
	}
	if body.Handle == "" {
		body.Handle = "+905551234567"
	}

	msg := map[string]any{
		"type":       "incoming_call",
		"callId":     body.CallID,
		"callerName": body.CallerName,
		"handle":     body.Handle,
	}
	s.BroadcastJSON(msg)

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(msg)
}

func (s *Server) handleTriggerAnswerCommand(w http.ResponseWriter, r *http.Request) {
	var body struct {
		CallID string `json:"callId"`
	}
	_ = json.NewDecoder(r.Body).Decode(&body)
	if body.CallID == "" {
		body.CallID = "11111111-2222-4333-8444-555566667777"
	}

	msg := map[string]any{
		"type":   "command_answer_and_connect",
		"callId": body.CallID,
	}
	s.BroadcastJSON(msg)

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(msg)
}

func (s *Server) handleTriggerGhostCall(w http.ResponseWriter, _ *http.Request) {
	callID := "77777777-8888-4999-8000-111122223333"
	incoming := map[string]any{
		"type":          "incoming_call",
		"callId":        callID,
		"callerName":    "Ghost Caller (Auto-Cancel)",
		"handle":        "+905550000000",
		"isGhostCancel": true,
	}
	s.BroadcastJSON(incoming)

	hangup := map[string]any{
		"type":   "remote_hangup",
		"callId": callID,
		"reason": "remoteCancelled",
	}
	s.BroadcastJSON(hangup)

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"scenario": "ghost_call",
		"callId":   callID,
		"events":   []any{incoming, hangup},
	})
}

func (s *Server) handleTriggerCallWaiting(w http.ResponseWriter, _ *http.Request) {
	call1 := map[string]any{
		"type":       "incoming_call",
		"callId":     "11111111-1111-4111-8111-111111111111",
		"callerName": "Line 1 - Active Peer",
		"handle":     "+905321110001",
	}
	call2 := map[string]any{
		"type":       "incoming_call",
		"callId":     "22222222-2222-4222-8222-222222222222",
		"callerName": "Line 2 - Waiting Peer",
		"handle":     "+905321110002",
	}
	s.BroadcastJSON(call1)
	s.BroadcastJSON(call2)

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"scenario": "call_waiting_dual",
		"calls":    []any{call1, call2},
	})
}

func (s *Server) handleApnsPreview(w http.ResponseWriter, r *http.Request) {
	var req ApnsVoipRequest
	_ = json.NewDecoder(r.Body).Decode(&req)
	if req.BundleID == "" {
		req.BundleID = "com.example.voip"
	}
	if req.CallID == "" {
		req.CallID = "11111111-2222-4333-8444-555566667777"
	}
	env := BuildApnsVoipEnvelope(req, true)
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(env)
}

func (s *Server) handleAudioTone(w http.ResponseWriter, _ *http.Request) {
	pcm := GenerateSineWavePCM16(440.0, 16000, 200)
	w.Header().Set("Content-Type", "application/octet-stream")
	_, _ = w.Write(pcm)
}

func (s *Server) handleAudioVerify(w http.ResponseWriter, r *http.Request) {
	pcm, err := io.ReadAll(io.LimitReader(r.Body, 1024*1024))
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	report := AnalyzePCM16Audio(pcm, 16000, 440.0)

	s.mu.Lock()
	s.audioVerified = report.TargetTonePresent && !report.IsSilent && !report.HasClipping
	s.lastAudioReport = &report
	s.mu.Unlock()

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(report)
}

func (s *Server) handleFeAckHttp(w http.ResponseWriter, r *http.Request) {
	var ack FeStateAck
	if err := json.NewDecoder(r.Body).Decode(&ack); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	s.RecordFeAck(ack)
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{"recorded": true})
}

func (s *Server) handleE2eReport(w http.ResponseWriter, _ *http.Request) {
	s.mu.Lock()
	acks := make([]FeStateAck, len(s.feAcks))
	copy(acks, s.feAcks)
	audioOk := s.audioVerified
	audioRep := s.lastAudioReport
	s.mu.Unlock()

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"ackCount":      len(acks),
		"acks":          acks,
		"audioVerified": audioOk,
		"audioReport":   audioRep,
	})
}

func (s *Server) RecordFeAck(ack FeStateAck) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.feAcks = append(s.feAcks, ack)
}

func (s *Server) handleWebSocket(w http.ResponseWriter, r *http.Request) {
	key := r.Header.Get("Sec-WebSocket-Key")
	if key == "" {
		http.Error(w, "missing Sec-WebSocket-Key", http.StatusBadRequest)
		return
	}

	hj, ok := w.(http.Hijacker)
	if !ok {
		http.Error(w, "hijacking not supported", http.StatusInternalServerError)
		return
	}

	conn, rw, err := hj.Hijack()
	if err != nil {
		return
	}

	accept := computeWebSocketAcceptKey(key)
	response := "HTTP/1.1 101 Switching Protocols\r\n" +
		"Upgrade: websocket\r\n" +
		"Connection: Upgrade\r\n" +
		"Sec-WebSocket-Accept: " + accept + "\r\n\r\n"
	_, _ = rw.WriteString(response)
	_ = rw.Flush()

	s.mu.Lock()
	s.clients[conn] = struct{}{}
	s.mu.Unlock()

	go s.readClientWebSocketFrames(conn, rw.Reader)
}

func (s *Server) readClientWebSocketFrames(conn net.Conn, r *bufio.Reader) {
	defer func() {
		s.mu.Lock()
		delete(s.clients, conn)
		s.mu.Unlock()
		_ = conn.Close()
	}()

	for {
		header := make([]byte, 2)
		if _, err := io.ReadFull(r, header); err != nil {
			return
		}
		opcode := header[0] & 0x0f
		if opcode == 0x8 { // Close frame
			return
		}
		masked := (header[1] & 0x80) != 0
		payloadLen := int64(header[1] & 0x7f)

		switch payloadLen {
		case 126:
			ext := make([]byte, 2)
			if _, err := io.ReadFull(r, ext); err != nil {
				return
			}
			payloadLen = int64(binary.BigEndian.Uint16(ext))
		case 127:
			ext := make([]byte, 8)
			if _, err := io.ReadFull(r, ext); err != nil {
				return
			}
			payloadLen = int64(binary.BigEndian.Uint64(ext))
		}

		var maskKey [4]byte
		if masked {
			if _, err := io.ReadFull(r, maskKey[:]); err != nil {
				return
			}
		}

		if payloadLen < 0 || payloadLen > 1024*1024 {
			return
		}
		payload := make([]byte, payloadLen)
		if _, err := io.ReadFull(r, payload); err != nil {
			return
		}
		if masked {
			for i := range payload {
				payload[i] ^= maskKey[i%4]
			}
		}

		if opcode == 0x1 { // Text frame from Flutter FE
			var envelope struct {
				Type          string `json:"type"`
				CallID        string `json:"callId"`
				PreviousState string `json:"previousState"`
				CurrentState  string `json:"currentState"`
				EndReason     string `json:"endReason"`
				TimestampMs   int64  `json:"timestampMs"`
			}
			if err := json.Unmarshal(payload, &envelope); err == nil && envelope.Type == "fe_ack" {
				s.RecordFeAck(FeStateAck{
					CallID:        envelope.CallID,
					PreviousState: envelope.PreviousState,
					CurrentState:  envelope.CurrentState,
					EndReason:     envelope.EndReason,
					TimestampMs:   envelope.TimestampMs,
				})
			}
		}
	}
}

func computeWebSocketAcceptKey(key string) string {
	h := sha1.New()
	_, _ = h.Write([]byte(key + wsGUID))
	return base64.StdEncoding.EncodeToString(h.Sum(nil))
}

func encodeWebSocketTextFrame(payload []byte) []byte {
	length := len(payload)
	var header []byte
	header = append(header, 0x81) // FIN + text frame
	if length <= 125 {
		header = append(header, byte(length))
	} else if length <= 65535 {
		header = append(header, 126, byte(length>>8), byte(length&0xff))
	} else {
		header = append(header, 127,
			0, 0, 0, 0,
			byte(length>>24), byte(length>>16), byte(length>>8), byte(length&0xff))
	}
	return append(header, payload...)
}
