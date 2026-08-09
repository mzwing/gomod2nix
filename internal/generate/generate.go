// Package generate provides functions to import Go package sources and generate package metadata for Nix.
package generate

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"

	"github.com/nix-community/go-nix/pkg/nar"
	schema "github.com/nix-community/gomod2nix/internal/schema"
	"golang.org/x/mod/modfile"
	"golang.org/x/sync/errgroup"
)

type goModDownload struct {
	Path     string
	Version  string
	Info     string
	GoMod    string
	Zip      string
	Dir      string
	Sum      string
	GoModSum string
}

func sourceFilter(name string, nodeType nar.NodeType) bool {
	return strings.ToLower(filepath.Base(name)) != ".ds_store"
}

func common(directory string) ([]*goModDownload, map[string]string, error) {
	goModPath := filepath.Join(directory, "go.mod")

	slog.Info("Parsing go.mod", "modPath", goModPath)

	// Read go.mod
	data, err := os.ReadFile(goModPath)
	if err != nil {
		return nil, nil, err
	}

	// Parse go.mod
	mod, err := modfile.Parse(goModPath, data, nil)
	if err != nil {
		return nil, nil, err
	}

	// Map repos -> replacement repo
	replace := make(map[string]string)
	for _, repl := range mod.Replace {
		replace[repl.New.Path] = repl.Old.Path
	}

	var modDownloads []*goModDownload
	{
		slog.Info("Downloading dependencies")

		cmd := exec.Command(
			"go", "mod", "download", "--json",
		)
		cmd.Dir = directory
		stdout, err := cmd.Output()
		if err != nil {
			if exiterr, ok := err.(*exec.ExitError); ok {
				return nil, nil, fmt.Errorf("failed to run 'go mod download --json: %s\n%s", exiterr, exiterr.Stderr)
			} else {
				return nil, nil, fmt.Errorf("failed to run 'go mod download --json': %s", err)
			}
		}

		dec := json.NewDecoder(bytes.NewReader(stdout))
		for {
			var dl *goModDownload
			err := dec.Decode(&dl)
			if err == io.EOF {
				break
			}
			modDownloads = append(modDownloads, dl)
		}

		slog.Info("Done downloading dependencies")
	}

	return modDownloads, replace, nil
}

func ImportPkgs(directory string, numWorkers int) error {
	modDownloads, _, err := common(directory)
	if err != nil {
		return err
	}

	eg := errgroup.Group{}
	eg.SetLimit(numWorkers)

	for _, dl := range modDownloads {
		eg.Go(func() error {
			slog.Info("Importing sources", "goPackagePath", dl.Path)

			pathName := filepath.Base(dl.Path) + "_" + dl.Version

			cmd := exec.Command(
				"nix-instantiate",
				"--eval",
				"--expr",
				fmt.Sprintf(`
builtins.filterSource (name: type: baseNameOf name != ".DS_Store") (
  builtins.path {
    path = "%s";
    name = "%s";
  }
)
`, dl.Dir, pathName),
			)
			cmd.Stderr = os.Stderr

			if err := cmd.Run(); err != nil {
				fmt.Println(cmd)
				return err
			}

			return nil
		})
	}

	return eg.Wait()
}

func GeneratePkgs(directory string, goMod2NixPath string, numWorkers int) ([]*schema.Package, error) {
	modDownloads, replace, err := common(directory)
	if err != nil {
		return nil, err
	}

	eg := errgroup.Group{}
	eg.SetLimit(numWorkers)

	var mux sync.Mutex

	cache := schema.ReadCache(goMod2NixPath)

	packages := []*schema.Package{}
	addPkg := func(pkg *schema.Package) {
		mux.Lock()
		packages = append(packages, pkg)
		mux.Unlock()
	}

	for _, dl := range modDownloads {
		goPackagePath, hasReplace := replace[dl.Path]
		if !hasReplace {
			goPackagePath = dl.Path
		}

		cached, ok := cache[goPackagePath]
		if ok && cached.Version == dl.Version {
			addPkg(cached)
			continue
		}

		eg.Go(func() error {
			slog.Info("Calculating NAR hash", "goPackagePath", goPackagePath)

			h := sha256.New()
			err := nar.DumpPathFilter(h, dl.Dir, sourceFilter)
			if err != nil {
				return err
			}
			digest := h.Sum(nil)

			pkg := &schema.Package{
				GoPackagePath: goPackagePath,
				Version:       dl.Version,
				Hash:          "sha256-" + base64.StdEncoding.EncodeToString(digest),
			}
			if hasReplace {
				pkg.ReplacedPath = dl.Path
			}

			addPkg(pkg)

			slog.Info("Done calculating NAR hash", "goPackagePath", goPackagePath)

			return nil
		})
	}

	err = eg.Wait()
	if err != nil {
		return nil, err
	}

	sort.Slice(packages, func(i, j int) bool {
		return packages[i].GoPackagePath < packages[j].GoPackagePath
	})

	return packages, nil
}

// GenerateCacheDeps generates a list of all imported packages
// (excluding standard library and the current module's packages) for cache optimization.
func GenerateCacheDeps(directory string) ([]string, error) {
	goModPath := filepath.Join(directory, "go.mod")

	slog.Info("Parsing go.mod to get current module path")

	// Read and parse go.mod to get current module path
	data, err := os.ReadFile(goModPath)
	if err != nil {
		return nil, fmt.Errorf("failed to read go.mod: %w", err)
	}

	mod, err := modfile.Parse(goModPath, data, nil)
	if err != nil {
		return nil, fmt.Errorf("failed to parse go.mod: %w", err)
	}

	currentModule := mod.Module.Mod.Path

	slog.Debug("Generating cache dependencies", "currentModule", currentModule)

	// Run go list to get all imported packages
	cmd := exec.Command("go", "list", "-mod=readonly", "-f", "{{.ImportPath}}", "all")
	cmd.Dir = directory
	stdout, err := cmd.Output()
	if err != nil {
		if exiterr, ok := err.(*exec.ExitError); ok {
			return nil, fmt.Errorf("failed to run 'go list': %s\n%s", exiterr, exiterr.Stderr)
		}
		return nil, fmt.Errorf("failed to run 'go list': %w", err)
	}

	// Parse and filter packages
	lines := strings.Split(string(stdout), "\n")
	var filteredPackages []string
	seen := make(map[string]bool)

	for _, line := range lines {
		pkg := strings.TrimSpace(line)
		if pkg == "" {
			continue
		}

		// Skip standard library
		if pkg == "std" {
			continue
		}

		// Skip current module packages
		if pkg == currentModule || strings.HasPrefix(pkg, currentModule+"/") {
			continue
		}

		// Skip vendor packages
		if strings.HasPrefix(pkg, "vendor/") {
			continue
		}

		// Skip internal packages (cannot be imported from outside)
		if strings.Contains(pkg, "/internal") {
			continue
		}

		// Keep only external packages (contain '.')
		if !strings.Contains(pkg, ".") {
			continue
		}

		// Deduplicate
		if !seen[pkg] {
			seen[pkg] = true
			filteredPackages = append(filteredPackages, pkg)
		}
	}

	// Sort for determinism
	sort.Strings(filteredPackages)

	return filteredPackages, nil
}

// listedPackage is a single package as reported by `go list`: the module it
// belongs to ("" for standard library packages) and its direct imports.
type listedPackage struct {
	module  string
	imports []string
}

// parseGoListOutput parses the output of
// `go list -f '{{.ImportPath}}<US>{{if .Module}}{{.Module.Path}}{{end}}<US>{{join .Imports ","}}' all`
// into a map of import path -> package.
func parseGoListOutput(output string) map[string]*listedPackage {
	listed := make(map[string]*listedPackage)
	for _, line := range strings.Split(output, "\n") {
		line = strings.TrimRight(line, "\r")
		if line == "" {
			continue
		}

		parts := strings.SplitN(line, "\u001f", 3)
		if len(parts) < 2 {
			continue
		}

		pkg := &listedPackage{module: parts[1]}
		if len(parts) == 3 && parts[2] != "" {
			pkg.imports = strings.Split(parts[2], ",")
		}
		listed[parts[0]] = pkg
	}
	return listed
}

// computeCacheModules groups cacheable packages by module and aggregates
// module-level dependency edges from actual package imports.
//
// A package is cacheable when it belongs to an external module that is not
// replaced with a local path, is not internal, is not under vendor/ and has
// a dot in its import path. A module that (transitively) imports packages
// from a non-cacheable module (e.g. one replaced with a local path) cannot
// be pre-compiled inside its own isolated module context, because the
// non-cacheable module's sources are not part of the cacheable module
// graph; such modules are excluded by taint propagation. The import-derived
// module graph is acyclic (package-level import cycles are compile errors
// in Go), so the fixpoint terminates and the resulting edges form a DAG.
func computeCacheModules(listed map[string]*listedPackage, currentModule string, localReplaced map[string]bool) map[string]*schema.CacheModule {
	// cacheable reports whether a package should be pre-compiled into the
	// build cache, mirroring the filtering rules of GenerateCacheDeps.
	cacheable := func(importPath string) bool {
		p, ok := listed[importPath]
		if !ok {
			return false
		}

		// Standard library packages (no module / virtual "std" module) and
		// packages without a dot in their path are not cached.
		if p.module == "" || p.module == "std" {
			return false
		}

		// Skip current module packages
		if p.module == currentModule {
			return false
		}

		// Skip modules replaced with a local path (editable sources)
		if localReplaced[p.module] {
			return false
		}

		// Skip vendor packages
		if strings.HasPrefix(importPath, "vendor/") {
			return false
		}

		// Skip internal packages (cannot be imported from outside)
		if strings.Contains(importPath, "/internal") {
			return false
		}

		// Keep only external packages (contain '.')
		if !strings.Contains(importPath, ".") {
			return false
		}

		return true
	}

	// Group cacheable packages by module and aggregate module -> module
	// dependency edges from actual imports.
	//
	// fullDeps tracks edges to *any* external module (including
	// non-cacheable ones such as local-replaced modules) so that taint can
	// propagate through them. Edges emitted into the output are later
	// filtered to included modules only, so the Nix side can resolve every
	// edge to a cache derivation.
	modulePackages := make(map[string]map[string]bool)
	moduleDeps := make(map[string]map[string]bool)
	fullDeps := make(map[string]map[string]bool)

	external := func(modulePath string) bool {
		return modulePath != "" && modulePath != "std" && modulePath != currentModule
	}

	for importPath, p := range listed {
		if !external(p.module) {
			continue
		}

		if cacheable(importPath) {
			if modulePackages[p.module] == nil {
				modulePackages[p.module] = make(map[string]bool)
			}
			modulePackages[p.module][importPath] = true
		}

		for _, imp := range p.imports {
			im, ok := listed[imp]
			if !ok || !external(im.module) || im.module == p.module {
				continue
			}
			if fullDeps[p.module] == nil {
				fullDeps[p.module] = make(map[string]bool)
			}
			fullDeps[p.module][im.module] = true

			if cacheable(importPath) && cacheable(imp) {
				if moduleDeps[p.module] == nil {
					moduleDeps[p.module] = make(map[string]bool)
				}
				moduleDeps[p.module][im.module] = true
			}
		}
	}

	// Taint propagation: iteratively exclude modules that import a
	// non-included module.
	included := make(map[string]bool)
	for modulePath := range modulePackages {
		included[modulePath] = true
	}
	for {
		changed := false
		for modulePath := range included {
			if !included[modulePath] {
				continue
			}
			for dep := range fullDeps[modulePath] {
				if !included[dep] {
					included[modulePath] = false
					delete(moduleDeps, modulePath)
					changed = true
					break
				}
			}
		}
		if !changed {
			break
		}
	}

	for modulePath, inc := range included {
		if !inc {
			slog.Debug("Excluding module from cache: imports a non-cacheable module", "module", modulePath)
			delete(modulePackages, modulePath)
		}
	}

	// Materialize the result with deterministic ordering
	ret := make(map[string]*schema.CacheModule)
	for modulePath, pkgs := range modulePackages {
		cm := &schema.CacheModule{}
		for pkg := range pkgs {
			cm.Packages = append(cm.Packages, pkg)
		}
		sort.Strings(cm.Packages)

		for dep := range moduleDeps[modulePath] {
			if included[dep] {
				cm.Deps = append(cm.Deps, dep)
			}
		}
		sort.Strings(cm.Deps)

		ret[modulePath] = cm
	}

	return ret
}

// GenerateCacheModules generates a per-module description of all imported
// packages (excluding standard library, the current module and modules with
// a local path replace) together with module-level dependency edges derived
// from actual package imports. The resulting module graph is guaranteed to
// be acyclic because package-level import cycles are compile errors in Go.
func GenerateCacheModules(directory string) (map[string]*schema.CacheModule, error) {
	goModPath := filepath.Join(directory, "go.mod")

	slog.Info("Parsing go.mod to get current module path and local replaces")

	// Read and parse go.mod to get current module path
	data, err := os.ReadFile(goModPath)
	if err != nil {
		return nil, fmt.Errorf("failed to read go.mod: %w", err)
	}

	mod, err := modfile.Parse(goModPath, data, nil)
	if err != nil {
		return nil, fmt.Errorf("failed to parse go.mod: %w", err)
	}

	currentModule := mod.Module.Mod.Path

	// Modules replaced with a local filesystem path contain editable sources
	// and must not be pre-compiled into the cache. go list reports the
	// *original* module path (replace target side Old.Path), so key the
	// exclusion set by that.
	localReplaced := make(map[string]bool)
	for _, repl := range mod.Replace {
		if repl.New.Version == "" && (strings.HasPrefix(repl.New.Path, ".") || strings.HasPrefix(repl.New.Path, "/")) {
			localReplaced[repl.Old.Path] = true
		}
	}

	slog.Debug("Generating cache modules", "currentModule", currentModule, "localReplaced", localReplaced)

	// Run go list to get all imported packages, their owning module and
	// their direct imports in a single invocation.
	cmd := exec.Command(
		"go", "list", "-mod=readonly",
		"-f", "{{.ImportPath}}\u001f{{if .Module}}{{.Module.Path}}{{end}}\u001f{{join .Imports \",\"}}",
		"all",
	)
	cmd.Dir = directory
	stdout, err := cmd.Output()
	if err != nil {
		if exiterr, ok := err.(*exec.ExitError); ok {
			return nil, fmt.Errorf("failed to run 'go list': %s\n%s", exiterr, exiterr.Stderr)
		}
		return nil, fmt.Errorf("failed to run 'go list': %w", err)
	}

	// Record every package and the module it belongs to. This includes
	// standard library packages (module "" / "std") so that import edges
	// can be resolved, even though they are never cached.
	listed := parseGoListOutput(string(stdout))

	ret := computeCacheModules(listed, currentModule, localReplaced)

	slog.Info("Done generating cache modules", "modules", len(ret))

	return ret, nil
}
