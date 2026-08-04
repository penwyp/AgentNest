package domain

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"fmt"
)

type ReceiptSigner struct {
	privateKey ed25519.PrivateKey
}

func NewReceiptSigner(privateKey ed25519.PrivateKey) (*ReceiptSigner, error) {
	if len(privateKey) != ed25519.PrivateKeySize {
		return nil, fmt.Errorf("invalid Ed25519 private key length")
	}
	return &ReceiptSigner{privateKey: privateKey}, nil
}

func (s *ReceiptSigner) PublicKey() ed25519.PublicKey {
	publicKey := s.privateKey.Public().(ed25519.PublicKey)
	return append(ed25519.PublicKey(nil), publicKey...)
}

func (s *ReceiptSigner) Sign(payload ReceiptPayload) (SignedEntitlementReceipt, error) {
	data, err := json.Marshal(payload)
	if err != nil {
		return SignedEntitlementReceipt{}, fmt.Errorf("marshal receipt payload: %w", err)
	}
	signature := ed25519.Sign(s.privateKey, data)
	return SignedEntitlementReceipt{
		Payload:   base64.RawURLEncoding.EncodeToString(data),
		Signature: base64.RawURLEncoding.EncodeToString(signature),
	}, nil
}
