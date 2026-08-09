package generate

import (
	"testing"
)

func TestParseGoListOutput(t *testing.T) {
	output := "example.com/main\u001fexample.com/main\u001ffmt,example.com/foo\n" +
		"fmt\u001f\u001f\n" +
		"example.com/foo\u001fexample.com/foo\u001ffmt\n" +
		"\n" +
		"\r\n"

	listed := parseGoListOutput(output)

	if len(listed) != 3 {
		t.Fatalf("expected 3 packages, got %d", len(listed))
	}

	main := listed["example.com/main"]
	if main == nil {
		t.Fatal("example.com/main missing")
	}
	if main.module != "example.com/main" {
		t.Errorf("expected module example.com/main, got %q", main.module)
	}
	if len(main.imports) != 2 || main.imports[0] != "fmt" || main.imports[1] != "example.com/foo" {
		t.Errorf("unexpected imports: %v", main.imports)
	}

	std := listed["fmt"]
	if std == nil {
		t.Fatal("fmt missing")
	}
	if std.module != "" {
		t.Errorf("expected empty module for std package, got %q", std.module)
	}
	if len(std.imports) != 0 {
		t.Errorf("expected no imports for fmt, got %v", std.imports)
	}
}

func TestComputeCacheModulesBasic(t *testing.T) {
	listed := map[string]*listedPackage{
		"example.com/main":     {module: "example.com/main", imports: []string{"example.com/foo", "fmt"}},
		"fmt":                  {module: ""},
		"example.com/foo":      {module: "example.com/foo", imports: []string{"example.com/bar"}},
		"example.com/foo/sub":  {module: "example.com/foo", imports: []string{"example.com/bar"}},
		"example.com/bar":      {module: "example.com/bar"},
		"example.com/internal": {module: "example.com/internal"},
	}

	ret := computeCacheModules(listed, "example.com/main", nil)

	if len(ret) != 2 {
		t.Fatalf("expected 2 cache modules, got %d: %v", len(ret), ret)
	}

	foo := ret["example.com/foo"]
	if foo == nil {
		t.Fatal("example.com/foo missing")
	}
	if len(foo.Packages) != 2 || foo.Packages[0] != "example.com/foo" || foo.Packages[1] != "example.com/foo/sub" {
		t.Errorf("unexpected packages for foo: %v", foo.Packages)
	}
	if len(foo.Deps) != 1 || foo.Deps[0] != "example.com/bar" {
		t.Errorf("unexpected deps for foo: %v", foo.Deps)
	}

	bar := ret["example.com/bar"]
	if bar == nil {
		t.Fatal("example.com/bar missing")
	}
	if len(bar.Deps) != 0 {
		t.Errorf("expected no deps for bar, got %v", bar.Deps)
	}
}

func TestComputeCacheModulesSkipsNonCacheable(t *testing.T) {
	listed := map[string]*listedPackage{
		"example.com/main":          {module: "example.com/main", imports: []string{"example.com/foo/internal"}},
		"example.com/foo/internal":  {module: "example.com/foo"},
		"vendor/example.com/pinned": {module: "example.com/pinned"},
		// No dot in import path -> not cacheable
		"localpkg": {module: "example.com/local"},
	}

	ret := computeCacheModules(listed, "example.com/main", nil)

	if len(ret) != 0 {
		t.Fatalf("expected no cacheable modules, got %v", ret)
	}
}

func TestComputeCacheModulesLocalReplaceTaint(t *testing.T) {
	// example.com/local is replaced with a local path and imported by
	// example.com/foo, which transitively taints example.com/main's other
	// dependency chain only if connected.
	listed := map[string]*listedPackage{
		"example.com/main":  {module: "example.com/main", imports: []string{"example.com/foo"}},
		"example.com/foo":   {module: "example.com/foo", imports: []string{"example.com/local"}},
		"example.com/local": {module: "example.com/local"},
		// Unrelated chain stays cacheable
		"example.com/bar": {module: "example.com/bar"},
	}
	// main imports bar too
	listed["example.com/main"].imports = append(listed["example.com/main"].imports, "example.com/bar")

	localReplaced := map[string]bool{"example.com/local": true}

	ret := computeCacheModules(listed, "example.com/main", localReplaced)

	if _, ok := ret["example.com/foo"]; ok {
		t.Error("expected example.com/foo to be tainted by local-replaced dependency")
	}
	if _, ok := ret["example.com/local"]; ok {
		t.Error("expected local-replaced module to be excluded")
	}
	if _, ok := ret["example.com/bar"]; !ok {
		t.Error("expected unrelated module example.com/bar to stay cacheable")
	}
}
