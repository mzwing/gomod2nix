package schema

import (
	"bytes"
	"os"
	"path/filepath"
	"strconv"
	"testing"

	"github.com/pelletier/go-toml/v2"
)

func TestMarshalReadCacheRoundtrip(t *testing.T) {
	pkgs := []*Package{
		{
			GoPackagePath: "example.com/foo",
			Version:       "v1.0.0",
			Hash:          "sha256-aaaa",
		},
		{
			GoPackagePath: "example.com/bar",
			Version:       "v2.1.0",
			Hash:          "sha256-bbbb",
			ReplacedPath:  "example.com/bar-fork",
		},
	}

	cacheModules := map[string]*CacheModule{
		"example.com/foo": {
			Packages: []string{"example.com/foo", "example.com/foo/sub"},
		},
		"example.com/bar": {
			Packages: []string{"example.com/bar"},
			Deps:     []string{"example.com/foo"},
		},
	}

	out, err := Marshal(pkgs, "1.23", "example.com/main", []string{"cmd/tool"}, cacheModules)
	if err != nil {
		t.Fatalf("Marshal failed: %v", err)
	}

	path := filepath.Join(t.TempDir(), "gomod2nix.toml")
	if err := os.WriteFile(path, out, 0644); err != nil {
		t.Fatalf("WriteFile failed: %v", err)
	}

	cache := ReadCache(path)
	if len(cache) != len(pkgs) {
		t.Fatalf("expected %d cached packages, got %d", len(pkgs), len(cache))
	}

	for _, pkg := range pkgs {
		got, ok := cache[pkg.GoPackagePath]
		if !ok {
			t.Fatalf("package %s missing from cache", pkg.GoPackagePath)
		}
		if got.Version != pkg.Version {
			t.Errorf("package %s: expected version %s, got %s", pkg.GoPackagePath, pkg.Version, got.Version)
		}
		if got.Hash != pkg.Hash {
			t.Errorf("package %s: expected hash %s, got %s", pkg.GoPackagePath, pkg.Hash, got.Hash)
		}
		if got.ReplacedPath != pkg.ReplacedPath {
			t.Errorf("package %s: expected replaced %q, got %q", pkg.GoPackagePath, pkg.ReplacedPath, got.ReplacedPath)
		}
		if got.GoPackagePath != pkg.GoPackagePath {
			t.Errorf("package %s: expected GoPackagePath to be backfilled, got %q", pkg.GoPackagePath, got.GoPackagePath)
		}
	}
}

func TestReadCacheDropsMismatchedSchemaVersion(t *testing.T) {
	pkgs := []*Package{
		{
			GoPackagePath: "example.com/foo",
			Version:       "v1.0.0",
			Hash:          "sha256-aaaa",
		},
	}

	out, err := Marshal(pkgs, "", "", nil, nil)
	if err != nil {
		t.Fatalf("Marshal failed: %v", err)
	}

	path := filepath.Join(t.TempDir(), "gomod2nix.toml")
	if err := os.WriteFile(path, out, 0644); err != nil {
		t.Fatalf("WriteFile failed: %v", err)
	}

	// Sanity check: current schema version is accepted
	if cache := ReadCache(path); len(cache) != 1 {
		t.Fatalf("expected cache with 1 package, got %d", len(cache))
	}

	// Rewrite the file with a different schema version: Marshal writes
	// "schema = N" as the first line.
	other := append([]byte("schema = "+strconv.Itoa(SchemaVersion+1)), out[len("schema = "+strconv.Itoa(SchemaVersion)):]...)
	if err := os.WriteFile(path, other, 0644); err != nil {
		t.Fatalf("WriteFile failed: %v", err)
	}

	if cache := ReadCache(path); len(cache) != 0 {
		t.Fatalf("expected cache to be dropped on schema version mismatch, got %d entries", len(cache))
	}
}

func TestMarshalGoVersion(t *testing.T) {
	pkgs := []*Package{
		{
			GoPackagePath: "example.com/foo",
			Version:       "v1.0.0",
			Hash:          "sha256-aaaa",
		},
	}

	out, err := Marshal(pkgs, "1.27.0", "", nil, nil)
	if err != nil {
		t.Fatalf("Marshal failed: %v", err)
	}

	var output Output
	if err := toml.Unmarshal(out, &output); err != nil {
		t.Fatalf("Unmarshal failed: %v", err)
	}
	if output.GoVersion != "1.27.0" {
		t.Errorf("expected go version 1.27.0, got %q", output.GoVersion)
	}

	// A go.mod without a go directive must leave the key out entirely.
	out, err = Marshal(pkgs, "", "", nil, nil)
	if err != nil {
		t.Fatalf("Marshal failed: %v", err)
	}
	if bytes.Contains(out, []byte("go = ")) {
		t.Errorf("expected no go key, got:\n%s", out)
	}
}

func TestReadCacheMissingFile(t *testing.T) {
	if cache := ReadCache(filepath.Join(t.TempDir(), "does-not-exist.toml")); len(cache) != 0 {
		t.Fatalf("expected empty cache for missing file, got %d entries", len(cache))
	}

	if cache := ReadCache(""); len(cache) != 0 {
		t.Fatalf("expected empty cache for empty path, got %d entries", len(cache))
	}
}
