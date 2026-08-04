package domain

import "time"

const (
	ProductID       = "com.agentnest.macos"
	ReceiptSchema   = 1
	Provider        = "agentnest-local"
	TrialDuration   = 7 * 24 * time.Hour
	TrialOfflineTTL = 72 * time.Hour
	PaidOfflineTTL  = 7 * 24 * time.Hour
)

type Trial struct {
	ProductID     string    `json:"productId"`
	MachineIDHash string    `json:"machineIdHash"`
	StartedAt     time.Time `json:"startedAt"`
	ExpiresAt     time.Time `json:"expiresAt"`
}

type License struct {
	ID             string     `json:"id"`
	KeyHash        string     `json:"keyHash,omitempty"`
	PolicyID       string     `json:"policyId"`
	Status         string     `json:"status"`
	SubscriptionTo *time.Time `json:"subscriptionExpiresAt,omitempty"`
}

type Policy struct {
	ID                  string   `json:"id"`
	Plan                string   `json:"plan"`
	Features            []string `json:"features"`
	MaxMachines         int      `json:"maxMachines"`
	RefreshAfterSeconds int64    `json:"refreshAfterSeconds"`
	OfflineTTLSeconds   int64    `json:"offlineTtlSeconds"`
}

type Entitlement struct {
	ReceiptID     string    `json:"receiptId"`
	LicenseID     string    `json:"licenseId"`
	MachineIDHash string    `json:"machineIdHash"`
	PolicyID      string    `json:"policyId"`
	IssuedAt      time.Time `json:"issuedAt"`
	OfflineUntil  time.Time `json:"offlineUntil"`
}

type Machine struct {
	ID              string    `json:"id"`
	LicenseID       string    `json:"licenseId"`
	MachineIDHash   string    `json:"machineIdHash"`
	RefreshHash     string    `json:"refreshHash,omitempty"`
	Active          bool      `json:"active"`
	CreatedAt       time.Time `json:"createdAt"`
	LastRefreshedAt time.Time `json:"lastRefreshedAt"`
}

type AuditEvent struct {
	ID        string    `json:"id"`
	Kind      string    `json:"kind"`
	SubjectID string    `json:"subjectId"`
	At        time.Time `json:"at"`
}

type ReceiptPayload struct {
	SchemaVersion         int        `json:"schemaVersion"`
	Provider              string     `json:"provider"`
	LicenseID             string     `json:"licenseId"`
	MachineIDHash         string     `json:"machineIdHash"`
	ProductID             string     `json:"productId"`
	Plan                  string     `json:"plan"`
	Features              []string   `json:"features"`
	IssuedAt              time.Time  `json:"issuedAt"`
	RefreshAfter          time.Time  `json:"refreshAfter"`
	OfflineUntil          time.Time  `json:"offlineUntil"`
	SubscriptionExpiresAt *time.Time `json:"subscriptionExpiresAt,omitempty"`
	MinAppVersion         *string    `json:"minAppVersion,omitempty"`
	ReceiptID             string     `json:"receiptId"`
}

type SignedEntitlementReceipt struct {
	Payload   string `json:"payload"`
	Signature string `json:"signature"`
}

type EntitlementResponse struct {
	Receipt      SignedEntitlementReceipt `json:"receipt"`
	RefreshToken string                   `json:"refreshToken,omitempty"`
}

type ErrorCode string

const (
	ErrInvalidRequest   ErrorCode = "invalid_request"
	ErrProductMismatch  ErrorCode = "product_mismatch"
	ErrLicenseInvalid   ErrorCode = "license_invalid"
	ErrLicenseSuspended ErrorCode = "license_suspended"
	ErrLicenseExpired   ErrorCode = "license_expired"
	ErrDeviceLimit      ErrorCode = "device_limit"
	ErrRefreshInvalid   ErrorCode = "refresh_invalid"
	ErrMachineNotFound  ErrorCode = "machine_not_found"
)
