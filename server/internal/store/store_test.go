package store

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestOpenRejectsSymlinkState(t *testing.T) {
	directory := t.TempDir()
	target := filepath.Join(directory, "target.json")
	if err := os.WriteFile(target, []byte(`{"trials":{}}`), 0o600); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(directory, "state.json")
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
	if _, err := Open(link); err == nil {
		t.Fatal("expected symlink state path to be rejected")
	}
}

func TestTrialPersistsAndDoesNotRestart(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state.json")
	firstStore, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	startedAt := time.Date(2026, 8, 4, 10, 0, 0, 0, time.UTC)
	first, err := firstStore.Trial("com.agentnest.macos", machineHash("one"), startedAt)
	if err != nil {
		t.Fatal(err)
	}

	secondStore, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	second, err := secondStore.Trial("com.agentnest.macos", machineHash("one"), startedAt.Add(48*time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if !second.StartedAt.Equal(first.StartedAt) || !second.ExpiresAt.Equal(first.ExpiresAt) {
		t.Fatalf("trial restarted after reopening store: first=%+v second=%+v", first, second)
	}
}

func TestActivationEnforcesDeviceLimitAndDeactivateReleasesSeat(t *testing.T) {
	fileStore, err := Open(filepath.Join(t.TempDir(), "state.json"))
	if err != nil {
		t.Fatal(err)
	}
	if err := fileStore.EnsureLicense("FULL-TEST-KEY", "developer", 1); err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 8, 4, 10, 0, 0, 0, time.UTC)
	_, _, first, token, code, err := fileStore.Activate("FULL-TEST-KEY", machineHash("one"), now)
	if err != nil || code != "" {
		t.Fatalf("first activation: code=%s err=%v", code, err)
	}
	if !first.Active || token == "" {
		t.Fatal("first activation did not produce active machine and token")
	}
	_, _, _, _, code, err = fileStore.Activate("FULL-TEST-KEY", machineHash("two"), now)
	if err != nil || code != "device_limit" {
		t.Fatalf("second activation: code=%s err=%v", code, err)
	}
	if code, err := fileStore.Deactivate(token, machineHash("one"), now); err != nil || code != "" {
		t.Fatalf("deactivate: code=%s err=%v", code, err)
	}
	_, _, second, _, code, err := fileStore.Activate("FULL-TEST-KEY", machineHash("two"), now)
	if err != nil || code != "" || !second.Active {
		t.Fatalf("activation after release: code=%s err=%v", code, err)
	}
}

func machineHash(value string) string { return HashSecret("machine:" + value) }
