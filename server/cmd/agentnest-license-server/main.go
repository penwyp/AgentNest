package main

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"github.com/penwyp/agentnest/server/internal/api"
	"github.com/penwyp/agentnest/server/internal/domain"
	"github.com/penwyp/agentnest/server/internal/store"
)

func main() {
	var address string
	var dataDirectory string
	flag.StringVar(&address, "listen", "127.0.0.1:8080", "HTTP listen address")
	flag.StringVar(&dataDirectory, "data", "./var/license", "persistent data directory")
	flag.Parse()

	logger := slog.New(slog.NewJSONHandler(os.Stderr, nil))
	if err := run(address, dataDirectory, logger); err != nil {
		logger.Error("server stopped", "error", err)
		os.Exit(1)
	}
}

func run(address, dataDirectory string, logger *slog.Logger) error {
	privateKey, err := loadOrCreatePrivateKey(filepath.Join(dataDirectory, "signing.key"))
	if err != nil {
		return err
	}
	signer, err := domain.NewReceiptSigner(privateKey)
	if err != nil {
		return err
	}
	fileStore, err := store.Open(filepath.Join(dataDirectory, "state.json"))
	if err != nil {
		return err
	}
	developmentKey := os.Getenv("AGENTNEST_DEVELOPMENT_LICENSE_KEY")
	if developmentKey != "" {
		if err := fileStore.EnsureLicense(developmentKey, "developer", 1); err != nil {
			return err
		}
	}

	httpServer := &http.Server{
		Addr: address, Handler: api.New(fileStore, signer, logger, os.Getenv("AGENTNEST_PAYMENT_WEBHOOK_SECRET")).Handler(),
		ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 10 * time.Second, WriteTimeout: 10 * time.Second, IdleTimeout: 60 * time.Second,
	}
	interruptContext, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	go func() {
		<-interruptContext.Done()
		shutdownContext, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = httpServer.Shutdown(shutdownContext)
	}()
	logger.Info("license server listening", "address", address, "publicKey", base64.RawURLEncoding.EncodeToString(signer.PublicKey()))
	err = httpServer.ListenAndServe()
	if errors.Is(err, http.ErrServerClosed) {
		return nil
	}
	return err
}

func loadOrCreatePrivateKey(path string) (ed25519.PrivateKey, error) {
	info, statErr := os.Lstat(path)
	if statErr == nil {
		if !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 {
			return nil, fmt.Errorf("signing key path is not a regular file")
		}
		if err := os.Chmod(path, 0o600); err != nil {
			return nil, fmt.Errorf("secure signing key permissions: %w", err)
		}
	} else if !errors.Is(statErr, os.ErrNotExist) {
		return nil, fmt.Errorf("inspect signing key: %w", statErr)
	}
	data, err := os.ReadFile(path)
	if err == nil {
		if len(data) != ed25519.PrivateKeySize {
			return nil, fmt.Errorf("invalid signing key file")
		}
		return ed25519.PrivateKey(data), nil
	}
	if !errors.Is(err, os.ErrNotExist) {
		return nil, fmt.Errorf("read signing key: %w", err)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, err
	}
	_, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return nil, err
	}
	temporary, err := os.CreateTemp(filepath.Dir(path), ".signing-*")
	if err != nil {
		return nil, err
	}
	temporaryName := temporary.Name()
	defer os.Remove(temporaryName)
	if err := temporary.Chmod(0o600); err != nil {
		temporary.Close()
		return nil, err
	}
	if _, err := temporary.Write(privateKey); err != nil {
		temporary.Close()
		return nil, err
	}
	if err := temporary.Sync(); err != nil {
		temporary.Close()
		return nil, err
	}
	if err := temporary.Close(); err != nil {
		return nil, err
	}
	if err := os.Rename(temporaryName, path); err != nil {
		return nil, err
	}
	directory, err := os.Open(filepath.Dir(path))
	if err != nil {
		return nil, err
	}
	if err := directory.Sync(); err != nil {
		directory.Close()
		return nil, err
	}
	if err := directory.Close(); err != nil {
		return nil, err
	}
	return privateKey, nil
}
