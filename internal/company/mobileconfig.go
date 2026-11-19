package company

import (
	"bytes"
	"crypto/rand"
	"encoding/xml"
	"fmt"

	"watchtower/internal/policy"
)

// Mobileconfig is a configuration profile for IT that forces the managed
// preference CompanyBundle = wire in Watchtower's domain (policy.Domain), the
// same shape as docs/examples/watchtower-policy.mobileconfig. The profile is
// identified as com.watchtower.company.<slug>; newUUID gives the profile's
// and its payload's PayloadUUID (NewUUID, fixed in tests).
func Mobileconfig(slug, wire string, newUUID func() string) ([]byte, error) {
	if !slugRE.MatchString(slug) || slug == draftSlug {
		return nil, fmt.Errorf("invalid company slug %q", slug)
	}
	if wire == "" {
		return nil, fmt.Errorf("empty company bundle")
	}
	id := "com.watchtower.company." + slug
	var b bytes.Buffer
	b.WriteString(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>PayloadDisplayName</key>
    <string>Watchtower company setup</string>
    <key>PayloadIdentifier</key>
    <string>`)
	escape(&b, id)
	b.WriteString(`</string>
    <key>PayloadType</key>
    <string>Configuration</string>
    <key>PayloadUUID</key>
    <string>`)
	escape(&b, newUUID())
	b.WriteString(`</string>
    <key>PayloadVersion</key>
    <integer>1</integer>
    <key>PayloadScope</key>
    <string>User</string>
    <key>PayloadContent</key>
    <array>
        <dict>
            <key>PayloadType</key>
            <string>com.apple.ManagedClient.preferences</string>
            <key>PayloadIdentifier</key>
            <string>`)
	escape(&b, id+".preferences")
	b.WriteString(`</string>
            <key>PayloadUUID</key>
            <string>`)
	escape(&b, newUUID())
	b.WriteString(`</string>
            <key>PayloadVersion</key>
            <integer>1</integer>
            <key>PayloadContent</key>
            <dict>
                <key>`)
	escape(&b, policy.Domain)
	b.WriteString(`</key>
                <dict>
                    <key>Forced</key>
                    <array>
                        <dict>
                            <key>mcx_preference_settings</key>
                            <dict>
                                <key>CompanyBundle</key>
                                <string>`)
	escape(&b, wire)
	b.WriteString(`</string>
                            </dict>
                        </dict>
                    </array>
                </dict>
            </dict>
        </dict>
    </array>
</dict>
</plist>
`)
	return b.Bytes(), nil
}

// escape writes s as XML character data. A wire form is base64url and an
// identifier is a slug, so nothing needs escaping today; this keeps the
// profile well-formed whatever comes in.
func escape(b *bytes.Buffer, s string) {
	_ = xml.EscapeText(b, []byte(s))
}

// NewUUID is a random (version 4) UUID in upper case, the form profiles use.
func NewUUID() string {
	var u [16]byte
	_, _ = rand.Read(u[:]) // crypto/rand.Read never fails (Go 1.24+)
	u[6] = u[6]&0x0f | 0x40
	u[8] = u[8]&0x3f | 0x80
	return fmt.Sprintf("%X-%X-%X-%X-%X", u[0:4], u[4:6], u[6:8], u[8:10], u[10:16])
}
