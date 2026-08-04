package api

import (
	"bytes"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/penwyp/agentnest/server/internal/domain"
	"github.com/penwyp/agentnest/server/internal/store"
)

type Server struct {
	store         *store.FileStore
	signer        *domain.ReceiptSigner
	clock         func() time.Time
	logger        *slog.Logger
	webhookSecret string
	adminToken    string
}

type Config struct {
	WebhookSecret string
	AdminToken    string
}

func New(fileStore *store.FileStore, signer *domain.ReceiptSigner, logger *slog.Logger, config Config) *Server {
	return &Server{
		store: fileStore, signer: signer, clock: time.Now, logger: logger,
		webhookSecret: config.WebhookSecret, adminToken: config.AdminToken,
	}
}

func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})
	mux.HandleFunc("GET /v1/public-key", s.publicKey)
	mux.HandleFunc("POST /v1/trials", s.createTrial)
	mux.HandleFunc("POST /v1/activate", s.activate)
	mux.HandleFunc("POST /v1/refresh", s.refresh)
	mux.HandleFunc("POST /v1/deactivate", s.deactivate)
	mux.HandleFunc("POST /v1/webhooks/payment", s.paymentWebhook)
	mux.HandleFunc("GET /v1/admin/state", s.adminState)
	mux.HandleFunc("PUT /v1/admin/policies/{id}", s.adminUpsertPolicy)
	mux.HandleFunc("POST /v1/admin/licenses", s.adminCreateLicense)
	mux.HandleFunc("PATCH /v1/admin/licenses/{id}", s.adminUpdateLicense)
	return s.recover(mux)
}

type machineRequest struct {
	ProductID     string `json:"productId"`
	MachineIDHash string `json:"machineIdHash"`
}

type activateRequest struct {
	ProductID     string `json:"productId"`
	MachineIDHash string `json:"machineIdHash"`
	LicenseKey    string `json:"licenseKey"`
}

type refreshRequest struct {
	ProductID     string `json:"productId"`
	MachineIDHash string `json:"machineIdHash"`
	RefreshToken  string `json:"refreshToken"`
}

type paymentEvent struct {
	EventID               string     `json:"eventId"`
	Type                  string     `json:"type"`
	LicenseKey            string     `json:"licenseKey"`
	Plan                  string     `json:"plan"`
	MaxMachines           int        `json:"maxMachines"`
	SubscriptionExpiresAt *time.Time `json:"subscriptionExpiresAt,omitempty"`
}

type adminPolicyRequest struct {
	Plan                string   `json:"plan"`
	Features            []string `json:"features"`
	MaxMachines         int      `json:"maxMachines"`
	RefreshAfterSeconds int64    `json:"refreshAfterSeconds"`
	OfflineTTLSeconds   int64    `json:"offlineTtlSeconds"`
}

type adminLicenseRequest struct {
	LicenseKey            string     `json:"licenseKey"`
	PolicyID              string     `json:"policyId"`
	SubscriptionExpiresAt *time.Time `json:"subscriptionExpiresAt,omitempty"`
}

type adminLicenseStatusRequest struct {
	Status string `json:"status"`
}

func (s *Server) publicKey(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{
		"algorithm": "Ed25519",
		"publicKey": base64.RawURLEncoding.EncodeToString(s.signer.PublicKey()),
	})
}

func (s *Server) createTrial(w http.ResponseWriter, r *http.Request) {
	var request machineRequest
	if !decodeRequest(w, r, &request) || !validateMachineRequest(w, request.ProductID, request.MachineIDHash) {
		return
	}
	now := s.clock().UTC()
	policy, ok := s.store.Policy("trial")
	if !ok {
		s.internalError(w, errors.New("trial policy missing"))
		return
	}
	trial, err := s.store.Trial(request.ProductID, request.MachineIDHash, now)
	if err != nil {
		s.internalError(w, err)
		return
	}
	offlineUntil := earlier(now.Add(time.Duration(policy.OfflineTTLSeconds)*time.Second), trial.ExpiresAt)
	refreshAfter := earlier(now.Add(time.Duration(policy.RefreshAfterSeconds)*time.Second), trial.ExpiresAt)
	payload := domain.ReceiptPayload{
		SchemaVersion: domain.ReceiptSchema, Provider: domain.Provider, LicenseID: "trial:" + request.MachineIDHash[:12],
		MachineIDHash: request.MachineIDHash, ProductID: request.ProductID, Plan: policy.Plan,
		Features: policy.Features, IssuedAt: now, RefreshAfter: refreshAfter,
		OfflineUntil: offlineUntil, SubscriptionExpiresAt: &trial.ExpiresAt, ReceiptID: newReceiptID(),
	}
	receipt, err := s.signer.Sign(payload)
	if err != nil {
		s.internalError(w, err)
		return
	}
	if err := s.store.RecordEntitlement(domain.Entitlement{
		ReceiptID: payload.ReceiptID, LicenseID: payload.LicenseID, MachineIDHash: request.MachineIDHash,
		PolicyID: policy.ID, IssuedAt: now, OfflineUntil: offlineUntil,
	}, now); err != nil {
		s.internalError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, domain.EntitlementResponse{Receipt: receipt})
}

func (s *Server) activate(w http.ResponseWriter, r *http.Request) {
	var request activateRequest
	if !decodeRequest(w, r, &request) || !validateMachineRequest(w, request.ProductID, request.MachineIDHash) {
		return
	}
	if strings.TrimSpace(request.LicenseKey) == "" {
		writeAPIError(w, http.StatusBadRequest, domain.ErrInvalidRequest)
		return
	}
	now := s.clock().UTC()
	license, policy, machine, refreshToken, code, err := s.store.Activate(request.LicenseKey, request.MachineIDHash, now)
	if err != nil {
		s.internalError(w, err)
		return
	}
	if code != "" {
		writeDomainError(w, code)
		return
	}
	receipt, payload, err := s.paidReceipt(license, policy, machine, now)
	if err != nil {
		s.internalError(w, err)
		return
	}
	if err := s.recordPaidEntitlement(payload, license, policy, machine, now); err != nil {
		s.internalError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, domain.EntitlementResponse{Receipt: receipt, RefreshToken: refreshToken})
}

func (s *Server) refresh(w http.ResponseWriter, r *http.Request) {
	var request refreshRequest
	if !decodeRequest(w, r, &request) || !validateMachineRequest(w, request.ProductID, request.MachineIDHash) {
		return
	}
	if strings.TrimSpace(request.RefreshToken) == "" {
		writeAPIError(w, http.StatusBadRequest, domain.ErrInvalidRequest)
		return
	}
	now := s.clock().UTC()
	license, policy, machine, code, err := s.store.Refresh(request.RefreshToken, request.MachineIDHash, now)
	if err != nil {
		s.internalError(w, err)
		return
	}
	if code != "" {
		writeDomainError(w, code)
		return
	}
	receipt, payload, err := s.paidReceipt(license, policy, machine, now)
	if err != nil {
		s.internalError(w, err)
		return
	}
	if err := s.recordPaidEntitlement(payload, license, policy, machine, now); err != nil {
		s.internalError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, domain.EntitlementResponse{Receipt: receipt})
}

func (s *Server) deactivate(w http.ResponseWriter, r *http.Request) {
	var request refreshRequest
	if !decodeRequest(w, r, &request) || !validateMachineRequest(w, request.ProductID, request.MachineIDHash) {
		return
	}
	code, err := s.store.Deactivate(request.RefreshToken, request.MachineIDHash, s.clock().UTC())
	if err != nil {
		s.internalError(w, err)
		return
	}
	if code != "" {
		writeDomainError(w, code)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) paymentWebhook(w http.ResponseWriter, r *http.Request) {
	if s.webhookSecret == "" {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"code": "webhook_not_configured"})
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 64<<10)
	body, err := io.ReadAll(r.Body)
	if err != nil {
		writeAPIError(w, http.StatusBadRequest, domain.ErrInvalidRequest)
		return
	}
	provided, err := hex.DecodeString(r.Header.Get("X-AgentNest-Signature"))
	expected := hmac.New(sha256.New, []byte(s.webhookSecret))
	_, _ = expected.Write(body)
	if err != nil || !hmac.Equal(provided, expected.Sum(nil)) {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"code": "webhook_signature_invalid"})
		return
	}
	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.DisallowUnknownFields()
	var event paymentEvent
	if err := decoder.Decode(&event); err != nil || event.EventID == "" || event.LicenseKey == "" {
		writeAPIError(w, http.StatusBadRequest, domain.ErrInvalidRequest)
		return
	}
	if (event.Type == "purchase" || event.Type == "renewal") && (event.MaxMachines < 1 || event.Plan == "") {
		writeAPIError(w, http.StatusBadRequest, domain.ErrInvalidRequest)
		return
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		writeAPIError(w, http.StatusBadRequest, domain.ErrInvalidRequest)
		return
	}
	applied, err := s.store.ApplyPaymentEvent(
		event.EventID, event.Type, event.LicenseKey, event.Plan, event.MaxMachines, event.SubscriptionExpiresAt, s.clock().UTC(),
	)
	if err != nil {
		writeAPIError(w, http.StatusBadRequest, domain.ErrInvalidRequest)
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"applied": applied})
}

func (s *Server) adminState(w http.ResponseWriter, r *http.Request) {
	if !s.authorizeAdmin(w, r) {
		return
	}
	writeJSON(w, http.StatusOK, s.store.AdminState())
}

func (s *Server) adminUpsertPolicy(w http.ResponseWriter, r *http.Request) {
	if !s.authorizeAdmin(w, r) {
		return
	}
	id := strings.TrimSpace(r.PathValue("id"))
	var request adminPolicyRequest
	if !decodeRequest(w, r, &request) {
		return
	}
	if id == "" || id == "trial" || !validPolicyRequest(request) {
		writeAPIError(w, http.StatusBadRequest, domain.ErrInvalidRequest)
		return
	}
	policy := domain.Policy{
		ID: id, Plan: request.Plan, Features: request.Features, MaxMachines: request.MaxMachines,
		RefreshAfterSeconds: request.RefreshAfterSeconds, OfflineTTLSeconds: request.OfflineTTLSeconds,
	}
	if err := s.store.UpsertPolicy(policy, s.clock().UTC()); err != nil {
		s.internalError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, policy)
}

func (s *Server) adminCreateLicense(w http.ResponseWriter, r *http.Request) {
	if !s.authorizeAdmin(w, r) {
		return
	}
	var request adminLicenseRequest
	if !decodeRequest(w, r, &request) {
		return
	}
	if strings.TrimSpace(request.LicenseKey) == "" || strings.TrimSpace(request.PolicyID) == "" {
		writeAPIError(w, http.StatusBadRequest, domain.ErrInvalidRequest)
		return
	}
	license, err := s.store.CreateLicense(
		request.LicenseKey, request.PolicyID, request.SubscriptionExpiresAt, s.clock().UTC(),
	)
	if err != nil {
		writeAPIError(w, http.StatusBadRequest, domain.ErrInvalidRequest)
		return
	}
	license.KeyHash = ""
	writeJSON(w, http.StatusCreated, license)
}

func (s *Server) adminUpdateLicense(w http.ResponseWriter, r *http.Request) {
	if !s.authorizeAdmin(w, r) {
		return
	}
	id := strings.TrimSpace(r.PathValue("id"))
	var request adminLicenseStatusRequest
	if !decodeRequest(w, r, &request) {
		return
	}
	if id == "" || (request.Status != "active" && request.Status != "suspended" && request.Status != "revoked") {
		writeAPIError(w, http.StatusBadRequest, domain.ErrInvalidRequest)
		return
	}
	if err := s.store.SetLicenseStatus(id, request.Status, s.clock().UTC()); err != nil {
		writeJSON(w, http.StatusNotFound, map[string]string{"code": "license_not_found"})
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) authorizeAdmin(w http.ResponseWriter, r *http.Request) bool {
	if s.adminToken == "" {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"code": "admin_not_configured"})
		return false
	}
	provided := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	if subtle.ConstantTimeCompare([]byte(provided), []byte(s.adminToken)) != 1 {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"code": "admin_unauthorized"})
		return false
	}
	return true
}

func validPolicyRequest(request adminPolicyRequest) bool {
	if strings.TrimSpace(request.Plan) == "" || request.MaxMachines < 1 || request.MaxMachines > 100 ||
		request.RefreshAfterSeconds < 300 || request.RefreshAfterSeconds > int64((7*24*time.Hour).Seconds()) ||
		request.OfflineTTLSeconds < 3600 || request.OfflineTTLSeconds > int64((30*24*time.Hour).Seconds()) ||
		len(request.Features) == 0 {
		return false
	}
	allowed := map[string]bool{
		"scan": true, "overview": true, "skill.write": true, "patch": true,
		"cleanup": true, "trace": true, "history": true, "export": true,
	}
	seen := make(map[string]bool, len(request.Features))
	for _, feature := range request.Features {
		if !allowed[feature] || seen[feature] {
			return false
		}
		seen[feature] = true
	}
	return seen["scan"] && seen["overview"]
}

func (s *Server) paidReceipt(license domain.License, policy domain.Policy, machine domain.Machine, now time.Time) (domain.SignedEntitlementReceipt, domain.ReceiptPayload, error) {
	offlineUntil := now.Add(time.Duration(policy.OfflineTTLSeconds) * time.Second)
	if license.SubscriptionTo != nil {
		offlineUntil = earlier(offlineUntil, *license.SubscriptionTo)
	}
	payload := domain.ReceiptPayload{
		SchemaVersion: domain.ReceiptSchema, Provider: domain.Provider, LicenseID: license.ID,
		MachineIDHash: machine.MachineIDHash, ProductID: domain.ProductID, Plan: policy.Plan,
		Features: policy.Features,
		IssuedAt: now, RefreshAfter: now.Add(time.Duration(policy.RefreshAfterSeconds) * time.Second), OfflineUntil: offlineUntil,
		SubscriptionExpiresAt: license.SubscriptionTo, ReceiptID: newReceiptID(),
	}
	receipt, err := s.signer.Sign(payload)
	return receipt, payload, err
}

func (s *Server) recordPaidEntitlement(payload domain.ReceiptPayload, license domain.License, policy domain.Policy, machine domain.Machine, now time.Time) error {
	return s.store.RecordEntitlement(domain.Entitlement{
		ReceiptID: payload.ReceiptID, LicenseID: license.ID, MachineIDHash: machine.MachineIDHash,
		PolicyID: policy.ID, IssuedAt: payload.IssuedAt, OfflineUntil: payload.OfflineUntil,
	}, now)
}

func validateMachineRequest(w http.ResponseWriter, productID, machineIDHash string) bool {
	if productID != domain.ProductID {
		writeAPIError(w, http.StatusBadRequest, domain.ErrProductMismatch)
		return false
	}
	decoded, err := hex.DecodeString(machineIDHash)
	if err != nil || len(decoded) != 32 {
		writeAPIError(w, http.StatusBadRequest, domain.ErrInvalidRequest)
		return false
	}
	return true
}

func decodeRequest(w http.ResponseWriter, r *http.Request, target any) bool {
	r.Body = http.MaxBytesReader(w, r.Body, 32<<10)
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		writeAPIError(w, http.StatusBadRequest, domain.ErrInvalidRequest)
		return false
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		writeAPIError(w, http.StatusBadRequest, domain.ErrInvalidRequest)
		return false
	}
	return true
}

func writeDomainError(w http.ResponseWriter, code domain.ErrorCode) {
	status := http.StatusUnauthorized
	if code == domain.ErrDeviceLimit {
		status = http.StatusConflict
	}
	if code == domain.ErrMachineNotFound {
		status = http.StatusNotFound
	}
	writeAPIError(w, status, code)
}

func writeAPIError(w http.ResponseWriter, status int, code domain.ErrorCode) {
	writeJSON(w, status, map[string]string{"code": string(code)})
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

func (s *Server) internalError(w http.ResponseWriter, err error) {
	s.logger.Error("request failed", "error", err)
	writeJSON(w, http.StatusInternalServerError, map[string]string{"code": "internal_error"})
}

func (s *Server) recover(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if recovered := recover(); recovered != nil {
				s.internalError(w, fmt.Errorf("panic: %v", recovered))
			}
		}()
		next.ServeHTTP(w, r)
	})
}

func earlier(first, second time.Time) time.Time {
	if first.Before(second) {
		return first
	}
	return second
}

func newReceiptID() string {
	bytes := make([]byte, 16)
	if _, err := rand.Read(bytes); err != nil {
		return fmt.Sprintf("rcpt_%d", time.Now().UnixNano())
	}
	return "rcpt_" + hex.EncodeToString(bytes)
}
