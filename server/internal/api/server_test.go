package api

import (
	"bytes"
	"crypto/ed25519"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

	"github.com/penwyp/agentnest/server/internal/domain"
	"github.com/penwyp/agentnest/server/internal/store"
)

func TestTrialReceiptIsSignedAndBoundToMachine(t *testing.T) {
	handler, publicKey := testHandler(t)
	machineIDHash := store.HashSecret("machine:fixture")
	response := postJSON(t, handler, "/v1/trials", map[string]string{
		"productId": domain.ProductID, "machineIdHash": machineIDHash,
	})
	if response.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
	var entitlement domain.EntitlementResponse
	if err := json.NewDecoder(response.Body).Decode(&entitlement); err != nil {
		t.Fatal(err)
	}
	payloadData, err := base64.RawURLEncoding.DecodeString(entitlement.Receipt.Payload)
	if err != nil {
		t.Fatal(err)
	}
	signature, err := base64.RawURLEncoding.DecodeString(entitlement.Receipt.Signature)
	if err != nil {
		t.Fatal(err)
	}
	if !ed25519.Verify(publicKey, payloadData, signature) {
		t.Fatal("receipt signature did not verify")
	}
	var payload domain.ReceiptPayload
	if err := json.Unmarshal(payloadData, &payload); err != nil {
		t.Fatal(err)
	}
	if payload.MachineIDHash != machineIDHash || payload.Plan != "trial" || payload.ProductID != domain.ProductID {
		t.Fatalf("unexpected payload: %+v", payload)
	}
}

func TestStrictRequestAndDeviceLimit(t *testing.T) {
	handler, _ := testHandler(t)
	invalid := postJSON(t, handler, "/v1/trials", map[string]string{
		"productId": domain.ProductID, "machineIdHash": store.HashSecret("one"), "unknown": "value",
	})
	if invalid.Code != http.StatusBadRequest {
		t.Fatalf("unknown request field status=%d", invalid.Code)
	}

	first := postJSON(t, handler, "/v1/activate", map[string]string{
		"productId": domain.ProductID, "machineIdHash": store.HashSecret("one"), "licenseKey": "FULL-TEST-KEY",
	})
	if first.Code != http.StatusOK {
		t.Fatalf("first activation status=%d body=%s", first.Code, first.Body.String())
	}
	second := postJSON(t, handler, "/v1/activate", map[string]string{
		"productId": domain.ProductID, "machineIdHash": store.HashSecret("two"), "licenseKey": "FULL-TEST-KEY",
	})
	if second.Code != http.StatusConflict {
		t.Fatalf("device limit status=%d body=%s", second.Code, second.Body.String())
	}
}

func TestPaymentWebhookIsSignedAndIdempotent(t *testing.T) {
	seed := bytes.Repeat([]byte{9}, ed25519.SeedSize)
	signer, err := domain.NewReceiptSigner(ed25519.NewKeyFromSeed(seed))
	if err != nil {
		t.Fatal(err)
	}
	fileStore, err := store.Open(filepath.Join(t.TempDir(), "state.json"))
	if err != nil {
		t.Fatal(err)
	}
	handler := New(fileStore, signer, slog.New(slog.NewTextHandler(io.Discard, nil)), "webhook-secret").Handler()
	body, err := json.Marshal(map[string]any{
		"eventId": "evt_purchase_1", "type": "purchase", "licenseKey": "WEBHOOK-LICENSE", "plan": "annual", "maxMachines": 2,
	})
	if err != nil {
		t.Fatal(err)
	}
	signature := hmac.New(sha256.New, []byte("webhook-secret"))
	_, _ = signature.Write(body)
	request := httptest.NewRequest(http.MethodPost, "/v1/webhooks/payment", bytes.NewReader(body))
	request.Header.Set("X-AgentNest-Signature", fmt.Sprintf("%x", signature.Sum(nil)))
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), `"applied":true`) {
		t.Fatalf("webhook status=%d body=%s", response.Code, response.Body.String())
	}

	replay := httptest.NewRequest(http.MethodPost, "/v1/webhooks/payment", bytes.NewReader(body))
	replay.Header.Set("X-AgentNest-Signature", fmt.Sprintf("%x", signature.Sum(nil)))
	replayResponse := httptest.NewRecorder()
	handler.ServeHTTP(replayResponse, replay)
	if replayResponse.Code != http.StatusOK || !strings.Contains(replayResponse.Body.String(), `"applied":false`) {
		t.Fatalf("replay status=%d body=%s", replayResponse.Code, replayResponse.Body.String())
	}

	activation := postJSON(t, handler, "/v1/activate", map[string]string{
		"productId": domain.ProductID, "machineIdHash": store.HashSecret("webhook-machine"), "licenseKey": "WEBHOOK-LICENSE",
	})
	if activation.Code != http.StatusOK {
		t.Fatalf("webhook license activation status=%d body=%s", activation.Code, activation.Body.String())
	}

	invalid := httptest.NewRequest(http.MethodPost, "/v1/webhooks/payment", bytes.NewReader(body))
	invalid.Header.Set("X-AgentNest-Signature", "00")
	invalidResponse := httptest.NewRecorder()
	handler.ServeHTTP(invalidResponse, invalid)
	if invalidResponse.Code != http.StatusUnauthorized {
		t.Fatalf("invalid signature status=%d", invalidResponse.Code)
	}
}

func testHandler(t *testing.T) (http.Handler, ed25519.PublicKey) {
	t.Helper()
	seed := bytes.Repeat([]byte{7}, ed25519.SeedSize)
	privateKey := ed25519.NewKeyFromSeed(seed)
	signer, err := domain.NewReceiptSigner(privateKey)
	if err != nil {
		t.Fatal(err)
	}
	fileStore, err := store.Open(filepath.Join(t.TempDir(), "state.json"))
	if err != nil {
		t.Fatal(err)
	}
	if err := fileStore.EnsureLicense("FULL-TEST-KEY", "developer", 1); err != nil {
		t.Fatal(err)
	}
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	return New(fileStore, signer, logger).Handler(), signer.PublicKey()
}

func postJSON(t *testing.T, handler http.Handler, path string, value any) *httptest.ResponseRecorder {
	t.Helper()
	body, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	request := httptest.NewRequest(http.MethodPost, path, bytes.NewReader(body))
	request.Header.Set("Content-Type", "application/json")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	return response
}
