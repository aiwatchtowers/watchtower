package jirakey

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestKeyRegexp(t *testing.T) {
	assert.Equal(t, []string{"PROJ-12", "AB_C2-3"}, KeyRegexp.FindAllString("PROJ-12 and AB_C2-3, not proj-1 or X-", -1))
}
