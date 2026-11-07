package harness

import (
	"encoding/binary"
	"math"
)

// AudioAnalysisReport summarizes the acoustic properties of a 16-bit PCM mono audio frame.
type AudioAnalysisReport struct {
	SampleCount       int     `json:"sampleCount"`
	RmsAmplitude      float64 `json:"rmsAmplitude"`
	RmsDbFS           float64 `json:"rmsDbFs"`
	IsSilent          bool    `json:"isSilent"`
	HasClipping       bool    `json:"hasClipping"`
	TargetFreqHz      float64 `json:"targetFreqHz"`
	TargetMagnitude   float64 `json:"targetMagnitude"`
	TargetTonePresent bool    `json:"targetTonePresent"`
}

// GoertzelMagnitude computes the normalized spectral magnitude at targetFreqHz
// for a 16-bit little-endian mono PCM buffer using the Goertzel algorithm.
func GoertzelMagnitude(pcm16 []byte, sampleRate int, targetFreqHz float64) float64 {
	numSamples := len(pcm16) / 2
	if numSamples == 0 || sampleRate <= 0 {
		return 0
	}

	k := math.Round(float64(numSamples) * targetFreqHz / float64(sampleRate))
	omega := (2.0 * math.Pi * k) / float64(numSamples)
	coeff := 2.0 * math.Cos(omega)

	var q0, q1, q2 float64
	for i := 0; i < numSamples; i++ {
		sample := int16(binary.LittleEndian.Uint16(pcm16[i*2:]))
		normalized := float64(sample) / 32768.0
		q0 = coeff*q1 - q2 + normalized
		q2 = q1
		q1 = q0
	}

	magSquared := q1*q1 + q2*q2 - q1*q2*coeff
	if magSquared < 0 {
		return 0
	}
	return math.Sqrt(magSquared) / float64(numSamples)
}

// AnalyzePCM16Audio performs RMS, silence, clipping, and Goertzel frequency verification
// to prove that voice routing is delivering clean, uncorrupted audio.
func AnalyzePCM16Audio(pcm16 []byte, sampleRate int, expectedFreqHz float64) AudioAnalysisReport {
	numSamples := len(pcm16) / 2
	if numSamples == 0 {
		return AudioAnalysisReport{IsSilent: true, RmsDbFS: -120.0}
	}

	var sumSquares float64
	clippingCount := 0
	for i := 0; i < numSamples; i++ {
		sample := int16(binary.LittleEndian.Uint16(pcm16[i*2:]))
		if sample >= 32700 || sample <= -32700 {
			clippingCount++
		}
		norm := float64(sample) / 32768.0
		sumSquares += norm * norm
	}

	rms := math.Sqrt(sumSquares / float64(numSamples))
	dbFS := -120.0
	if rms > 1e-9 {
		dbFS = 20.0 * math.Log10(rms)
	}

	targetMag := GoertzelMagnitude(pcm16, sampleRate, expectedFreqHz)
	// Also measure an off-target reference frequency (e.g., expectedFreqHz * 1.618)
	offTargetMag := GoertzelMagnitude(pcm16, sampleRate, expectedFreqHz*1.618)

	isSilent := dbFS < -50.0
	tonePresent := !isSilent && targetMag > 0.08 && targetMag > (offTargetMag*4.0)

	return AudioAnalysisReport{
		SampleCount:       numSamples,
		RmsAmplitude:      rms,
		RmsDbFS:           dbFS,
		IsSilent:          isSilent,
		HasClipping:       clippingCount > 2,
		TargetFreqHz:      expectedFreqHz,
		TargetMagnitude:   targetMag,
		TargetTonePresent: tonePresent,
	}
}
