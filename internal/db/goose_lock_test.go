package db

import (
	"database/sql"

	"github.com/pressly/goose/v3"
)

// Tests drive goose directly through these wrappers: each goose call relinks
// the global registry's Go migrations, so it takes gooseMu like migrate does
// (parallel tests otherwise race under -race).

func gooseUp(db *sql.DB, dir string) error {
	gooseMu.Lock()
	defer gooseMu.Unlock()
	return goose.Up(db, dir)
}

func gooseUpTo(db *sql.DB, dir string, version int64) error {
	gooseMu.Lock()
	defer gooseMu.Unlock()
	return goose.UpTo(db, dir, version)
}

func gooseUpByOne(db *sql.DB, dir string) error {
	gooseMu.Lock()
	defer gooseMu.Unlock()
	return goose.UpByOne(db, dir)
}

func gooseDown(db *sql.DB, dir string) error {
	gooseMu.Lock()
	defer gooseMu.Unlock()
	return goose.Down(db, dir)
}

func gooseDownTo(db *sql.DB, dir string, version int64) error {
	gooseMu.Lock()
	defer gooseMu.Unlock()
	return goose.DownTo(db, dir, version)
}
