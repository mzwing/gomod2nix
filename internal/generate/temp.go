package generate

import (
	"fmt"
	"go/ast"
	"go/printer"
	"go/token"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
)

type TempProject struct {
	Dir           string
	SubPackages   []string
	GoPackagePath string
}

func NewTempProject(packages []string) (*TempProject, error) {
	// Imports without version suffix
	install := make([]string, len(packages))
	for i, imp := range packages {
		idx := strings.Index(imp, "@")
		if idx == -1 {
			idx = len(imp)
		}

		install[i] = imp[:idx]
	}

	slog.Info("Setting up temporary project")

	dir, err := os.MkdirTemp("", "gomod2nix-proj")
	if err != nil {
		return nil, err
	}

	slog.Info("Created temporary directory", "dir", dir)

	// Create tools.go
	{
		slog.Info("Creating tools.go", "dir", dir)

		astFile := &ast.File{
			Name: ast.NewIdent("main"),
			Decls: []ast.Decl{
				&ast.GenDecl{
					Tok: token.IMPORT,
					Specs: func() []ast.Spec {
						specs := make([]ast.Spec, len(install))

						i := 0
						for _, imp := range install {
							specs[i] = &ast.ImportSpec{
								Name: ast.NewIdent("_"),
								Path: &ast.BasicLit{
									ValuePos: token.NoPos,
									Kind:     token.STRING,
									Value:    strconv.Quote(imp),
								},
							}

							i++
						}

						return specs
					}(),
				},
			},
		}

		f, err := os.Create(filepath.Join(dir, "tools.go"))
		if err != nil {
			return nil, fmt.Errorf("error creating tools.go: %v", err)
		}
		defer func() {
			err := f.Close()
			if err != nil {
				slog.Error("Error closing tools.go", "err", err)
			}
		}()

		fset := token.NewFileSet()
		err = printer.Fprint(f, fset, astFile)
		if err != nil {
			return nil, fmt.Errorf("error writing tools.go: %v", err)
		}

		slog.Info("Created tools.go", "dir", dir)
	}

	// Set up go module
	{
		slog.Info("Initializing go.mod", "dir", dir)

		cmd := exec.Command("go", "mod", "init", "gomod2nix/dummy/package")
		cmd.Dir = dir
		cmd.Stderr = os.Stderr

		_, err := cmd.Output()
		if err != nil {
			return nil, fmt.Errorf("error creating go module: %v", err)
		}

		slog.Info("Done initializing go.mod", "dir", dir)

		// For every dependency fetch it
		{
			slog.Info("Getting dependencies", "dir", dir)

			args := []string{"get"}
			args = append(args, packages...)

			cmd := exec.Command("go", args...)
			cmd.Dir = dir
			cmd.Stderr = os.Stderr

			_, err := cmd.Output()
			if err != nil {
				return nil, fmt.Errorf("error fetching: %v", err)
			}

			slog.Info("Done getting dependencies", "dir", dir)
		}
	}

	// Resolve the module path of every requested package with go list.
	// This replaces the old VCS probing (golang.org/x/tools/go/vcs): the go
	// command resolves modules through the configured proxy, which works
	// for any GOPROXY (including file:// proxies) and for modules that do
	// not live at their repository root.
	modulePaths := make(map[string]string) // import path -> module path
	{
		args := []string{"list", "-f", "{{.ImportPath}}\u001f{{.Module.Path}}"}
		args = append(args, install...)

		cmd := exec.Command("go", args...)
		cmd.Dir = dir
		cmd.Stderr = os.Stderr

		stdout, err := cmd.Output()
		if err != nil {
			return nil, fmt.Errorf("error resolving module paths: %v", err)
		}

		for _, line := range strings.Split(string(stdout), "\n") {
			line = strings.TrimRight(line, "\r")
			if line == "" {
				continue
			}

			parts := strings.SplitN(line, "\u001f", 2)
			if len(parts) != 2 {
				continue
			}
			modulePaths[parts[0]] = parts[1]
		}
	}

	var goPackagePath string
	for _, path := range install {
		slog.Info("Resolving module path for import path", "path", path)

		p, ok := modulePaths[path]
		if !ok || p == "" {
			return nil, fmt.Errorf("could not resolve module for import path: %s", path)
		}

		if goPackagePath != "" && p != goPackagePath {
			return nil, fmt.Errorf("mixed origin packages are not allowed")
		}

		goPackagePath = p
	}

	subPackages := []string{}
	for _, path := range install {
		p := strings.TrimPrefix(path, goPackagePath)
		p = strings.TrimPrefix(p, "/")

		if p == "" {
			continue
		}

		subPackages = append(subPackages, p)
	}

	return &TempProject{
		Dir:           dir,
		SubPackages:   subPackages,
		GoPackagePath: goPackagePath,
	}, nil
}

func (t *TempProject) Remove() error {
	return os.RemoveAll(t.Dir)
}
