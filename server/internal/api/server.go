package api

import (
	"bytes"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
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
}

func New(fileStore *store.FileStore, signer *domain.ReceiptSigner, logger *slog.Logger, webhookSecret ...string) *Server {
	secret := ""
	if len(webhookSecret) > 0 {
		secret = webhookSecret[0]
	}
	return &Server{store: fileStore, signer: signer, clock: time.Now, logger: logger, webhookSecret: secret}
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
	trial, err := s.store.Trial(request.ProductID, request.MachineIDHash, now)
	if err != nil {
		s.internalError(w, err)
		return
	}
	offlineUntil := earlier(now.Add(domain.TrialOfflineTTL), trial.ExpiresAt)
	refreshAfter := earlier(now.Add(24*time.Hour), trial.ExpiresAt)
	payload := domain.ReceiptPayload{
		SchemaVersion: domain.ReceiptSchema, Provider: domain.Provider, LicenseID: "trial:" + request.MachineIDHash[:12],
		MachineIDHash: request.MachineIDHash, ProductID: request.ProductID, Plan: "trial",
		Features: []string{"scan", "overview"}, IssuedAt: now, RefreshAfter: refreshAfter,
		OfflineUntil: offlineUntil, SubscriptionExpiresAt: &trial.ExpiresAt, ReceiptID: newReceiptID(),
	}
	receipt, err := s.signer.Sign(payload)
	if err != nil {
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
	license, machine, refreshToken, code, err := s.store.Activate(request.LicenseKey, request.MachineIDHash, now)
	if err != nil {
		s.internalError(w, err)
		return
	}
	if code != "" {
		writeDomainError(w, code)
		return
	}
	receipt, err := s.paidReceipt(license, machine, now)
	if err != nil {
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
	license, machine, code, err := s.store.Refresh(request.RefreshToken, request.MachineIDHash, now)
	if err != nil {
		s.internalError(w, err)
		return
	}
	if code != "" {
		writeDomainError(w, code)
		return
	}
	receipt, err := s.paidReceipt(license, machine, now)
	if err != nil {
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

func (s *Server) paidReceipt(license domain.License, machine domain.Machine, now time.Time) (domain.SignedEntitlementReceipt, error) {
	offlineUntil := now.Add(domain.PaidOfflineTTL)
	if license.SubscriptionTo != nil {
		offlineUntil = earlier(offlineUntil, *license.SubscriptionTo)
	}
	payload := domain.ReceiptPayload{
		SchemaVersion: domain.ReceiptSchema, Provider: domain.Provider, LicenseID: license.ID,
		MachineIDHash: machine.MachineIDHash, ProductID: domain.ProductID, Plan: license.Plan,
		Features: []string{"scan", "overview", "skill.write", "patch", "cleanup", "trace", "history", "export"},
		IssuedAt: now, RefreshAfter: now.Add(24 * time.Hour), OfflineUntil: offlineUntil,
		SubscriptionExpiresAt: license.SubscriptionTo, ReceiptID: newReceiptID(),
	}
	return s.signer.Sign(payload)
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
