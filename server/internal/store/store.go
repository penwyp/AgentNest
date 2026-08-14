package store

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/penwyp/agentnest/server/internal/domain"
)

type State struct {
	Trials            map[string]domain.Trial       `json:"trials"`
	Licenses          map[string]domain.License     `json:"licenses"`
	Policies          map[string]domain.Policy      `json:"policies"`
	Machines          map[string]domain.Machine     `json:"machines"`
	Entitlements      map[string]domain.Entitlement `json:"entitlements"`
	ProcessedWebhooks map[string]time.Time          `json:"processedWebhooks"`
	Audit             []domain.AuditEvent           `json:"audit"`
}

type FileStore struct {
	mu    sync.Mutex
	path  string
	state State
}

func Open(path string) (*FileStore, error) {
	store := &FileStore{path: path, state: State{
		Trials: make(map[string]domain.Trial), Licenses: make(map[string]domain.License), Policies: make(map[string]domain.Policy), Machines: make(map[string]domain.Machine), Entitlements: make(map[string]domain.Entitlement), ProcessedWebhooks: make(map[string]time.Time),
	}}
	info, statErr := os.Lstat(path)
	if statErr == nil {
		if !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 {
			return nil, fmt.Errorf("state path is not a regular file")
		}
		if err := os.Chmod(path, 0o600); err != nil {
			return nil, fmt.Errorf("secure state permissions: %w", err)
		}
	} else if !errors.Is(statErr, os.ErrNotExist) {
		return nil, fmt.Errorf("inspect state: %w", statErr)
	}
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		store.ensureSystemPolicies()
		return store, nil
	}
	if err != nil {
		return nil, fmt.Errorf("read state: %w", err)
	}
	if err := json.Unmarshal(data, &store.state); err != nil {
		return nil, fmt.Errorf("decode state: %w", err)
	}
	if store.state.Trials == nil {
		store.state.Trials = make(map[string]domain.Trial)
	}
	if store.state.Licenses == nil {
		store.state.Licenses = make(map[string]domain.License)
	}
	if store.state.Policies == nil {
		store.state.Policies = make(map[string]domain.Policy)
	}
	if store.state.Machines == nil {
		store.state.Machines = make(map[string]domain.Machine)
	}
	if store.state.Entitlements == nil {
		store.state.Entitlements = make(map[string]domain.Entitlement)
	}
	if store.state.ProcessedWebhooks == nil {
		store.state.ProcessedWebhooks = make(map[string]time.Time)
	}
	store.ensureSystemPolicies()
	return store, nil
}

func (s *FileStore) ensureSystemPolicies() {
	if _, ok := s.state.Policies["trial"]; ok {
		return
	}
	s.state.Policies["trial"] = domain.Policy{
		ID: "trial", Plan: "trial", Features: []string{"scan", "overview"}, MaxMachines: 1,
		RefreshAfterSeconds: int64((24 * time.Hour).Seconds()),
		OfflineTTLSeconds:   int64(domain.TrialOfflineTTL.Seconds()),
	}
}

func (s *FileStore) ApplyPaymentEvent(eventID, eventType, licenseKey, plan string, maxMachines int, expiresAt *time.Time, now time.Time) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, exists := s.state.ProcessedWebhooks[eventID]; exists {
		return false, nil
	}
	keyHash := HashSecret(licenseKey)
	var license domain.License
	for _, candidate := range s.state.Licenses {
		if candidate.KeyHash == keyHash {
			license = candidate
			break
		}
	}
	switch eventType {
	case "purchase", "renewal":
		if license.ID == "" {
			id, err := randomID("lic")
			if err != nil {
				return false, err
			}
			license = domain.License{ID: id, KeyHash: keyHash}
		}
		policy := paidPolicy(plan, maxMachines)
		s.state.Policies[policy.ID] = policy
		license.Status = "active"
		license.PolicyID = policy.ID
		license.SubscriptionTo = expiresAt
	case "refund", "chargeback", "suspend":
		if license.ID == "" {
			return false, fmt.Errorf("license does not exist")
		}
		license.Status = "suspended"
	case "revoke":
		if license.ID == "" {
			return false, fmt.Errorf("license does not exist")
		}
		license.Status = "revoked"
	default:
		return false, fmt.Errorf("unsupported payment event type")
	}
	s.state.Licenses[license.ID] = license
	s.state.ProcessedWebhooks[eventID] = now.UTC()
	s.appendAuditLocked("payment."+eventType, license.ID, now)
	return true, s.persistLocked()
}

func (s *FileStore) EnsureLicense(key, plan string, maxMachines int) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	keyHash := HashSecret(key)
	for _, license := range s.state.Licenses {
		if license.KeyHash == keyHash {
			return nil
		}
	}
	id, err := randomID("lic")
	if err != nil {
		return err
	}
	policy := paidPolicy(plan, maxMachines)
	s.state.Policies[policy.ID] = policy
	s.state.Licenses[id] = domain.License{ID: id, KeyHash: keyHash, PolicyID: policy.ID, Status: "active"}
	return s.persistLocked()
}

func (s *FileStore) Trial(productID, machineIDHash string, now time.Time) (domain.Trial, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	key := productID + ":" + machineIDHash
	if trial, ok := s.state.Trials[key]; ok {
		if now.Before(trial.ExpiresAt) {
			return trial, nil
		}
		s.appendAuditLocked("trial.renewed", key, now)
	} else {
		s.appendAuditLocked("trial.created", key, now)
	}
	trial := domain.Trial{ProductID: productID, MachineIDHash: machineIDHash, StartedAt: now.UTC(), ExpiresAt: now.UTC().Add(domain.TrialDuration)}
	s.state.Trials[key] = trial
	return trial, s.persistLocked()
}

func (s *FileStore) Activate(licenseKey, machineIDHash string, now time.Time) (domain.License, domain.Policy, domain.Machine, string, domain.ErrorCode, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var license domain.License
	for _, candidate := range s.state.Licenses {
		if candidate.KeyHash == HashSecret(licenseKey) {
			license = candidate
			break
		}
	}
	if license.ID == "" {
		return license, domain.Policy{}, domain.Machine{}, "", domain.ErrLicenseInvalid, nil
	}
	policy, ok := s.state.Policies[license.PolicyID]
	if !ok {
		return license, domain.Policy{}, domain.Machine{}, "", domain.ErrLicenseInvalid, nil
	}
	if license.Status != "active" {
		return license, policy, domain.Machine{}, "", domain.ErrLicenseSuspended, nil
	}
	if license.SubscriptionTo != nil && !now.Before(*license.SubscriptionTo) {
		return license, policy, domain.Machine{}, "", domain.ErrLicenseExpired, nil
	}

	for id, machine := range s.state.Machines {
		if machine.LicenseID == license.ID && machine.MachineIDHash == machineIDHash {
			token, err := randomToken()
			if err != nil {
				return license, policy, machine, "", "", err
			}
			machine.Active = true
			machine.RefreshHash = HashSecret(token)
			machine.LastRefreshedAt = now.UTC()
			s.state.Machines[id] = machine
			s.appendAuditLocked("machine.reactivated", id, now)
			return license, policy, machine, token, "", s.persistLocked()
		}
	}
	active := 0
	for _, machine := range s.state.Machines {
		if machine.LicenseID == license.ID && machine.Active {
			active++
		}
	}
	if active >= policy.MaxMachines {
		return license, policy, domain.Machine{}, "", domain.ErrDeviceLimit, nil
	}
	id, err := randomID("mac")
	if err != nil {
		return license, policy, domain.Machine{}, "", "", err
	}
	token, err := randomToken()
	if err != nil {
		return license, policy, domain.Machine{}, "", "", err
	}
	machine := domain.Machine{ID: id, LicenseID: license.ID, MachineIDHash: machineIDHash, RefreshHash: HashSecret(token), Active: true, CreatedAt: now.UTC(), LastRefreshedAt: now.UTC()}
	s.state.Machines[id] = machine
	s.appendAuditLocked("machine.activated", id, now)
	return license, policy, machine, token, "", s.persistLocked()
}

func (s *FileStore) Refresh(token, machineIDHash string, now time.Time) (domain.License, domain.Policy, domain.Machine, domain.ErrorCode, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	tokenHash := HashSecret(token)
	for id, machine := range s.state.Machines {
		if machine.RefreshHash != tokenHash || machine.MachineIDHash != machineIDHash {
			continue
		}
		if !machine.Active {
			return domain.License{}, domain.Policy{}, machine, domain.ErrMachineNotFound, nil
		}
		license := s.state.Licenses[machine.LicenseID]
		policy, ok := s.state.Policies[license.PolicyID]
		if !ok {
			return license, domain.Policy{}, machine, domain.ErrLicenseInvalid, nil
		}
		if license.Status != "active" {
			return license, policy, machine, domain.ErrLicenseSuspended, nil
		}
		if license.SubscriptionTo != nil && !now.Before(*license.SubscriptionTo) {
			return license, policy, machine, domain.ErrLicenseExpired, nil
		}
		machine.LastRefreshedAt = now.UTC()
		s.state.Machines[id] = machine
		s.appendAuditLocked("machine.refreshed", id, now)
		return license, policy, machine, "", s.persistLocked()
	}
	return domain.License{}, domain.Policy{}, domain.Machine{}, domain.ErrRefreshInvalid, nil
}

func (s *FileStore) RecordEntitlement(entitlement domain.Entitlement, now time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.state.Entitlements[entitlement.ReceiptID] = entitlement
	s.appendAuditLocked("entitlement.issued", entitlement.ReceiptID, now)
	return s.persistLocked()
}

func (s *FileStore) UpsertPolicy(policy domain.Policy, now time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.state.Policies[policy.ID] = policy
	s.appendAuditLocked("policy.upserted", policy.ID, now)
	return s.persistLocked()
}

func (s *FileStore) Policy(id string) (domain.Policy, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	policy, ok := s.state.Policies[id]
	return policy, ok
}

func (s *FileStore) CreateLicense(key, policyID string, expiresAt *time.Time, now time.Time) (domain.License, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.state.Policies[policyID]; !ok {
		return domain.License{}, fmt.Errorf("policy does not exist")
	}
	keyHash := HashSecret(key)
	for _, license := range s.state.Licenses {
		if license.KeyHash == keyHash {
			return domain.License{}, fmt.Errorf("license key already exists")
		}
	}
	id, err := randomID("lic")
	if err != nil {
		return domain.License{}, err
	}
	license := domain.License{ID: id, KeyHash: keyHash, PolicyID: policyID, Status: "active", SubscriptionTo: expiresAt}
	s.state.Licenses[id] = license
	s.appendAuditLocked("license.created", id, now)
	return license, s.persistLocked()
}

func (s *FileStore) SetLicenseStatus(id, status string, now time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	license, ok := s.state.Licenses[id]
	if !ok {
		return fmt.Errorf("license does not exist")
	}
	license.Status = status
	s.state.Licenses[id] = license
	s.appendAuditLocked("license."+status, id, now)
	return s.persistLocked()
}

func (s *FileStore) AdminState() State {
	s.mu.Lock()
	defer s.mu.Unlock()
	data, _ := json.Marshal(s.state)
	var result State
	_ = json.Unmarshal(data, &result)
	for id, license := range result.Licenses {
		license.KeyHash = ""
		result.Licenses[id] = license
	}
	for id, machine := range result.Machines {
		machine.RefreshHash = ""
		result.Machines[id] = machine
	}
	return result
}

func (s *FileStore) Deactivate(token, machineIDHash string, now time.Time) (domain.ErrorCode, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	tokenHash := HashSecret(token)
	for id, machine := range s.state.Machines {
		if machine.RefreshHash == tokenHash && machine.MachineIDHash == machineIDHash && machine.Active {
			machine.Active = false
			machine.RefreshHash = ""
			s.state.Machines[id] = machine
			s.appendAuditLocked("machine.deactivated", id, now)
			return "", s.persistLocked()
		}
	}
	return domain.ErrMachineNotFound, nil
}

func HashSecret(value string) string {
	sum := sha256.Sum256([]byte(value))
	return hex.EncodeToString(sum[:])
}

func paidPolicy(plan string, maxMachines int) domain.Policy {
	return domain.Policy{
		ID: fmt.Sprintf("paid:%s:%d", plan, maxMachines), Plan: plan,
		Features:    []string{"scan", "overview", "skill.write", "patch", "cleanup", "trace", "history", "export"},
		MaxMachines: maxMachines, RefreshAfterSeconds: int64((24 * time.Hour).Seconds()),
		OfflineTTLSeconds: int64(domain.PaidOfflineTTL.Seconds()),
	}
}

func (s *FileStore) appendAuditLocked(kind, subject string, now time.Time) {
	id, err := randomID("evt")
	if err != nil {
		return
	}
	s.state.Audit = append(s.state.Audit, domain.AuditEvent{ID: id, Kind: kind, SubjectID: subject, At: now.UTC()})
	const maximumAuditEvents = 10_000
	if len(s.state.Audit) > maximumAuditEvents {
		s.state.Audit = append([]domain.AuditEvent(nil), s.state.Audit[len(s.state.Audit)-maximumAuditEvents:]...)
	}
}

func (s *FileStore) persistLocked() error {
	if err := os.MkdirAll(filepath.Dir(s.path), 0o700); err != nil {
		return fmt.Errorf("create state directory: %w", err)
	}
	data, err := json.MarshalIndent(s.state, "", "  ")
	if err != nil {
		return fmt.Errorf("encode state: %w", err)
	}
	temporary, err := os.CreateTemp(filepath.Dir(s.path), ".state-*")
	if err != nil {
		return fmt.Errorf("create state temporary file: %w", err)
	}
	temporaryName := temporary.Name()
	defer os.Remove(temporaryName)
	if err := temporary.Chmod(0o600); err != nil {
		temporary.Close()
		return err
	}
	if _, err := temporary.Write(data); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Sync(); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	if err := os.Rename(temporaryName, s.path); err != nil {
		return fmt.Errorf("replace state: %w", err)
	}
	return syncDirectory(filepath.Dir(s.path))
}

func syncDirectory(path string) error {
	directory, err := os.Open(path)
	if err != nil {
		return err
	}
	defer directory.Close()
	return directory.Sync()
}

func randomID(prefix string) (string, error) {
	bytes := make([]byte, 12)
	if _, err := rand.Read(bytes); err != nil {
		return "", err
	}
	return prefix + "_" + hex.EncodeToString(bytes), nil
}

func randomToken() (string, error) {
	bytes := make([]byte, 32)
	if _, err := rand.Read(bytes); err != nil {
		return "", err
	}
	return hex.EncodeToString(bytes), nil
}
