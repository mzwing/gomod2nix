// proxygen builds a static Go module proxy directory (GOPROXY=file://...)
// from module source trees. It is used by the offline test suite; only the
// standard library is needed so it can be built with a bare `go build`.
//
// Usage:
//
//	proxygen -out DIR <module>@<version>=<srcdir> [...]
//
// For every module version it writes, following the module proxy protocol:
//
//	<module>/@v/list            all versions, one per line
//	<module>/@v/<version>.info  {"Version": "<version>"}
//	<module>/@v/<version>.mod   the module's go.mod
//	<module>/@v/<version>.zip   sources under <module>@<version>/...
//	<module>/@latest            {"Version": "<highest version>"}
package main

import (
	"archive/zip"
	"encoding/json"
	"fmt"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"
)

type moduleVersion struct {
	module  string
	version string
	src     string
}

func fatal(args ...any) {
	fmt.Fprintln(os.Stderr, args...)
	os.Exit(1)
}

func writeFile(name string, data []byte) {
	if err := os.MkdirAll(filepath.Dir(name), 0755); err != nil {
		fatal(err)
	}
	if err := os.WriteFile(name, data, 0644); err != nil {
		fatal(err)
	}
}

func main() {
	out := ""
	args := []string{}
	for i := 1; i < len(os.Args); i++ {
		arg := os.Args[i]
		if arg == "-out" && i+1 < len(os.Args) {
			out = os.Args[i+1]
			i++
			continue
		}
		args = append(args, arg)
	}

	if out == "" || len(args) == 0 {
		fatal("usage: proxygen -out DIR <module>@<version>=<srcdir> [...]")
	}

	mods := []moduleVersion{}
	for _, arg := range args {
		kv := strings.SplitN(arg, "=", 2)
		if len(kv) != 2 {
			fatal("invalid argument (expected module@version=srcdir):", arg)
		}
		mv := strings.SplitN(kv[0], "@", 2)
		if len(mv) != 2 {
			fatal("invalid module@version:", kv[0])
		}
		mods = append(mods, moduleVersion{module: mv[0], version: mv[1], src: kv[1]})
	}

	versionsByModule := map[string][]string{}

	for _, m := range mods {
		base := filepath.Join(out, filepath.FromSlash(m.module), "@v")
		versionsByModule[m.module] = append(versionsByModule[m.module], m.version)

		// .info
		info, err := json.Marshal(map[string]string{"Version": m.version})
		if err != nil {
			fatal(err)
		}
		writeFile(filepath.Join(base, m.version+".info"), info)

		// .mod
		goMod, err := os.ReadFile(filepath.Join(m.src, "go.mod"))
		if err != nil {
			fatal(err)
		}
		writeFile(filepath.Join(base, m.version+".mod"), goMod)

		// .zip: files under <module>@<version>/...
		zipPath := filepath.Join(base, m.version+".zip")
		if err := os.MkdirAll(filepath.Dir(zipPath), 0755); err != nil {
			fatal(err)
		}
		f, err := os.Create(zipPath)
		if err != nil {
			fatal(err)
		}
		zw := zip.NewWriter(f)

		prefix := m.module + "@" + m.version
		err = filepath.WalkDir(m.src, func(p string, d os.DirEntry, err error) error {
			if err != nil {
				return err
			}
			if d.IsDir() {
				return nil
			}
			rel, err := filepath.Rel(m.src, p)
			if err != nil {
				return err
			}
			w, err := zw.Create(path.Join(prefix, filepath.ToSlash(rel)))
			if err != nil {
				return err
			}
			data, err := os.ReadFile(p)
			if err != nil {
				return err
			}
			_, err = w.Write(data)
			return err
		})
		if err != nil {
			fatal(err)
		}
		if err := zw.Close(); err != nil {
			fatal(err)
		}
		if err := f.Close(); err != nil {
			fatal(err)
		}
	}

	for module, versions := range versionsByModule {
		sort.Strings(versions)
		base := filepath.Join(out, filepath.FromSlash(module), "@v")
		writeFile(filepath.Join(base, "list"), []byte(strings.Join(versions, "\n")+"\n"))

		latest, err := json.Marshal(map[string]string{"Version": versions[len(versions)-1]})
		if err != nil {
			fatal(err)
		}
		writeFile(filepath.Join(out, filepath.FromSlash(module), "@latest"), latest)
	}
}
