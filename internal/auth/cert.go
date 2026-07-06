package auth

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"fmt"
	"math/big"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// CertDir returns the directory for storing localhost TLS certificates.
func CertDir() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, ".local", "share", "watchtower", ".certs"), nil
}

// CertPaths returns the paths to the cert and key files.
func CertPaths() (certPath, keyPath string, err error) {
	dir, err := CertDir()
	if err != nil {
		return "", "", err
	}
	return filepath.Join(dir, "localhost.crt"), filepath.Join(dir, "localhost.key"), nil
}

// EnsureCert loads an existing cert/key pair or generates a new one.
// The cert is a leaf (non-CA) server cert for 127.0.0.1 and localhost, valid for
// 397 days; it is regenerated once it is within 30 days of expiry.
func EnsureCert() (tls.Certificate, error) {
	certPath, keyPath, err := CertPaths()
	if err != nil {
		return tls.Certificate{}, err
	}

	// Try loading existing cert
	if cert, loadErr := tls.LoadX509KeyPair(certPath, keyPath); loadErr == nil {
		if leaf, parseErr := x509.ParseCertificate(cert.Certificate[0]); parseErr == nil {
			if time.Until(leaf.NotAfter) > 30*24*time.Hour {
				return cert, nil
			}
		}
	}

	return generateAndSaveCert(certPath, keyPath)
}

func generateAndSaveCert(certPath, keyPath string) (tls.Certificate, error) {
	if err := os.MkdirAll(filepath.Dir(certPath), 0o700); err != nil {
		return tls.Certificate{}, fmt.Errorf("creating cert directory: %w", err)
	}

	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return tls.Certificate{}, err
	}

	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return tls.Certificate{}, err
	}

	// Leaf-only self-signed cert for the localhost OAuth callback server. It must
	// NOT be a CA: a trusted CA cert (with its private key on disk) could sign a
	// server cert for ANY domain — the Superfish class of vulnerability. This cert
	// authenticates 127.0.0.1/localhost and nothing else. NotAfter is capped at the
	// 397-day industry limit for leaf certs; EnsureCert regenerates it before expiry.
	template := &x509.Certificate{
		SerialNumber:          serial,
		Subject:               pkix.Name{CommonName: "Watchtower Localhost"},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(397 * 24 * time.Hour),
		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
		IsCA:                  false,
		IPAddresses:           []net.IP{net.IPv4(127, 0, 0, 1)},
		DNSNames:              []string{"localhost"},
	}

	certDER, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		return tls.Certificate{}, err
	}

	// Save cert
	certFile, err := os.OpenFile(certPath, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o644)
	if err != nil {
		return tls.Certificate{}, err
	}
	defer certFile.Close()
	if err := pem.Encode(certFile, &pem.Block{Type: "CERTIFICATE", Bytes: certDER}); err != nil {
		return tls.Certificate{}, err
	}

	// Save key (restricted permissions)
	keyDER, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		return tls.Certificate{}, err
	}
	keyFile, err := os.OpenFile(keyPath, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return tls.Certificate{}, err
	}
	defer keyFile.Close()
	if err := pem.Encode(keyFile, &pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDER}); err != nil {
		return tls.Certificate{}, err
	}

	return tls.Certificate{
		Certificate: [][]byte{certDER},
		PrivateKey:  key,
	}, nil
}

// IsCertTrusted checks whether the localhost cert is trusted by macOS for SSL.
func IsCertTrusted() bool {
	certPath, _, err := CertPaths()
	if err != nil {
		return false
	}
	if _, err := os.Stat(certPath); err != nil {
		return false
	}
	cmd := exec.Command("security", "verify-cert", "-c", certPath, "-p", "ssl", "-s", "127.0.0.1")
	return cmd.Run() == nil
}

// loginKeychainPath returns the path to the user's login keychain.
func loginKeychainPath() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, "Library", "Keychains", "login.keychain-db")
}

// TrustCert imports the localhost cert into the login keychain and marks it as trusted.
// Importing into the keychain is required for Chrome/Firefox to recognise the trust.
func TrustCert() error {
	// Skip if already trusted
	if IsCertTrusted() {
		return nil
	}

	certPath, _, err := CertPaths()
	if err != nil {
		return err
	}
	if _, err := os.Stat(certPath); os.IsNotExist(err) {
		return fmt.Errorf("certificate not found — run the command again to generate it")
	}

	keychain := loginKeychainPath()

	// Step 1: Import cert into login keychain (Chrome needs this).
	importCmd := exec.Command("security", "import", certPath, "-k", keychain)
	if output, err := importCmd.CombinedOutput(); err != nil {
		out := strings.TrimSpace(string(output))
		// "already exists" is fine — skip
		if !strings.Contains(out, "already exists") && !strings.Contains(out, "duplicate") {
			if out != "" {
				return fmt.Errorf("importing cert: %s", out)
			}
			return fmt.Errorf("importing cert: %w", err)
		}
	}

	// Step 2: Set trust policy for SSL on this cert.
	trustCmd := exec.Command("security", "add-trusted-cert", "-r", "trustRoot", "-p", "ssl", "-k", keychain, certPath)
	if output, err := trustCmd.CombinedOutput(); err != nil {
		out := strings.TrimSpace(string(output))
		if out != "" {
			return fmt.Errorf("trusting cert: %s", out)
		}
		return fmt.Errorf("trusting cert: %w", err)
	}

	return nil
}
