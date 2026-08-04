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
	handler := New(fileStore, signer, slog.New(slog.NewTextHandler(io.Discard, nil)), Config{WebhookSecret: "webhook-secret"}).Handler()
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

func TestAdminPolicyLicenseAndRevocation(t *testing.T) {
	handler, _ := testHandler(t)
	unauthorized := httptest.NewRecorder()
	handler.ServeHTTP(unauthorized, httptest.NewRequest(http.MethodGet, "/v1/admin/state", nil))
	if unauthorized.Code != http.StatusUnauthorized {
		t.Fatalf("unauthorized admin status=%d", unauthorized.Code)
	}

	policy := adminJSON(t, handler, http.MethodPut, "/v1/admin/policies/team", map[string]any{
		"plan": "team", "features": []string{"scan", "overview", "skill.write", "patch"},
		"maxMachines": 2, "refreshAfterSeconds": 3600, "offlineTtlSeconds": 86400,
	})
	if policy.Code != http.StatusOK {
		t.Fatalf("policy status=%d body=%s", policy.Code, policy.Body.String())
	}
	created := adminJSON(t, handler, http.MethodPost, "/v1/admin/licenses", map[string]any{
		"licenseKey": "ADMIN-CREATED-KEY", "policyId": "team",
	})
	if created.Code != http.StatusCreated {
		t.Fatalf("license status=%d body=%s", created.Code, created.Body.String())
	}
	var license domain.License
	if err := json.NewDecoder(created.Body).Decode(&license); err != nil {
		t.Fatal(err)
	}
	if license.ID == "" || license.PolicyID != "team" || license.KeyHash != "" {
		t.Fatalf("unsafe admin license response: %+v", license)
	}

	machineHash := store.HashSecret("admin-machine")
	activation := postJSON(t, handler, "/v1/activate", map[string]string{
		"productId": domain.ProductID, "machineIdHash": machineHash, "licenseKey": "ADMIN-CREATED-KEY",
	})
	if activation.Code != http.StatusOK {
		t.Fatalf("activation status=%d body=%s", activation.Code, activation.Body.String())
	}
	var entitlement domain.EntitlementResponse
	if err := json.NewDecoder(activation.Body).Decode(&entitlement); err != nil {
		t.Fatal(err)
	}

	state := adminJSON(t, handler, http.MethodGet, "/v1/admin/state", nil)
	if state.Code != http.StatusOK || strings.Contains(state.Body.String(), "ADMIN-CREATED-KEY") ||
		strings.Contains(state.Body.String(), "keyHash") || strings.Contains(state.Body.String(), "refreshHash") ||
		!strings.Contains(state.Body.String(), "entitlement.issued") {
		t.Fatalf("unsafe or incomplete admin state: status=%d body=%s", state.Code, state.Body.String())
	}

	revoked := adminJSON(t, handler, http.MethodPatch, "/v1/admin/licenses/"+license.ID, map[string]string{"status": "revoked"})
	if revoked.Code != http.StatusNoContent {
		t.Fatalf("revoke status=%d body=%s", revoked.Code, revoked.Body.String())
	}
	refresh := postJSON(t, handler, "/v1/refresh", map[string]string{
		"productId": domain.ProductID, "machineIdHash": machineHash, "refreshToken": entitlement.RefreshToken,
	})
	if refresh.Code != http.StatusUnauthorized || !strings.Contains(refresh.Body.String(), "license_suspended") {
		t.Fatalf("revoked refresh status=%d body=%s", refresh.Code, refresh.Body.String())
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
	return New(fileStore, signer, logger, Config{AdminToken: "admin-test-token"}).Handler(), signer.PublicKey()
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

func adminJSON(t *testing.T, handler http.Handler, method, path string, value any) *httptest.ResponseRecorder {
	t.Helper()
	var body io.Reader
	if value != nil {
		encoded, err := json.Marshal(value)
		if err != nil {
			t.Fatal(err)
		}
		body = bytes.NewReader(encoded)
	}
	request := httptest.NewRequest(method, path, body)
	request.Header.Set("Authorization", "Bearer admin-test-token")
	request.Header.Set("Content-Type", "application/json")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	return response
}
