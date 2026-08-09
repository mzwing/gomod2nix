// Package schema defines the schema for the package metadata used in caching and serialization.
package schema

import (
	"bytes"
	"os"

	"github.com/pelletier/go-toml/v2"
)

const SchemaVersion = 4

type Package struct {
	GoPackagePath string `toml:"-"`
	Version       string `toml:"version"`
	Hash          string `toml:"hash"`
	ReplacedPath  string `toml:"replaced,omitempty"`
}

// CacheModule describes the packages of a single Go module that should be
// pre-compiled into the build cache, along with the set of other (cached)
// modules whose packages are imported by this module's packages.
//
// Deps is derived from actual package-level import relationships.
// Since package-level import cycles are compile errors in Go, the resulting
// module quotient graph is guaranteed to be acyclic.
type CacheModule struct {
	Packages []string `toml:"packages,multiline"`
	Deps     []string `toml:"deps,multiline,omitempty"`
}

type Output struct {
	SchemaVersion int                 `toml:"schema"`
	Mod           map[string]*Package `toml:"mod"`

	// Packages with passed import paths trigger `go install` based on this list
	SubPackages []string `toml:"subPackages,omitempty"`

	// Packages with passed import paths has a "default package" which pname & version is inherit from
	GoPackagePath string `toml:"goPackagePath,omitempty"`

	// List of packages to pre-compile in build cache for faster builds.
	// Deprecated: superseded by CacheModules (per-module cache DAG) in
	// schema version 4. Retained for reading older gomod2nix.toml files;
	// the Nix builder falls back to a monolithic cache when only this
	// field is present.
	CachePackages []string `toml:"cachePackages,multiline,omitempty"`

	// Per-module build cache description: module path -> packages to
	// pre-compile + module-level dependency edges.
	CacheModules map[string]*CacheModule `toml:"cacheModules,omitempty"`
}

func Marshal(pkgs []*Package, goPackagePath string, subPackages []string, cacheModules map[string]*CacheModule) ([]byte, error) {
	out := &Output{
		SchemaVersion: SchemaVersion,
		Mod:           make(map[string]*Package),
		SubPackages:   subPackages,
		GoPackagePath: goPackagePath,
		CacheModules:  cacheModules,
	}

	for _, pkg := range pkgs {
		out.Mod[pkg.GoPackagePath] = pkg
	}

	var buf bytes.Buffer
	e := toml.NewEncoder(&buf)
	e.SetIndentTables(true)
	err := e.Encode(out)
	if err != nil {
		return nil, err
	}

	return buf.Bytes(), nil
}

func ReadCache(filePath string) map[string]*Package {
	ret := make(map[string]*Package)

	if filePath == "" {
		return ret
	}

	b, err := os.ReadFile(filePath)
	if err != nil {
		return ret
	}

	var output Output
	if err := toml.Unmarshal(b, &output); err != nil {
		return ret
	}

	if output.SchemaVersion != SchemaVersion {
		return ret
	}

	for k, v := range output.Mod {
		v.GoPackagePath = k
		ret[k] = v
	}

	return ret
}
